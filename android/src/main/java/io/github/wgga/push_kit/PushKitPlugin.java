package io.github.wgga.push_kit;

import android.app.Activity;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.core.app.NotificationManagerCompat;
import androidx.core.content.ContextCompat;

import com.heytap.msp.push.HeytapPushManager;
import com.heytap.msp.push.callback.ICallBackResultService;
import com.huawei.agconnect.config.AGConnectServicesConfig;
import com.huawei.hms.aaid.HmsInstanceId;
import com.vivo.push.IPushActionListener;
import com.vivo.push.PushClient;
import com.vivo.push.PushConfig;
import com.vivo.push.listener.IPushQueryActionListener;
import com.xiaomi.mipush.sdk.MiPushClient;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.WeakHashMap;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Native bridge for the push_kit public API. */
public final class PushKitPlugin implements FlutterPlugin, ActivityAware,
        MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
        io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener {
    static final String TAG = "PushKit";
    private static final String METHODS_CHANNEL = "push_kit/methods";
    private static final String EVENTS_CHANNEL = "push_kit/events";
    private static final int NOTIFICATION_PERMISSION_REQUEST = 8127;
    private static final int MAX_PENDING_EVENTS = 32;
    private static final int MAX_PING_HOSTS = 64;
    private static final long PING_TIMEOUT_SECONDS = 5L;
    private static final String POST_NOTIFICATIONS_PERMISSION =
            "android.permission.POST_NOTIFICATIONS";
    private static final String PERMISSION_PREFS = "push_kit.preferences";
    private static final String PERMISSION_REQUESTED = "post_notifications_requested";
    private static final Handler MAIN_HANDLER = new Handler(Looper.getMainLooper());
    private static final Object INSTANCES_LOCK = new Object();
    private static final Map<PushKitPlugin, Boolean> INSTANCES = new WeakHashMap<>();
    private static final Set<String> INITIALIZED_VENDORS = Collections.newSetFromMap(
            new ConcurrentHashMap<String, Boolean>());
    private static final ArrayDeque<Map<String, Object>> ORPHAN_EVENTS = new ArrayDeque<>();
    private static final Pattern RTT_PATTERN = Pattern.compile(
            "=\\s*([0-9]+(?:[.,][0-9]+)?)\\s*/\\s*"
                    + "([0-9]+(?:[.,][0-9]+)?)\\s*/\\s*"
                    + "([0-9]+(?:[.,][0-9]+)?)",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern NUMBER_PATTERN = Pattern.compile(
            "[0-9]+(?:[.,][0-9]+)?");

    private final Set<PendingResult> pendingResults = Collections.newSetFromMap(
            new ConcurrentHashMap<PendingResult, Boolean>());
    private final ArrayDeque<Map<String, Object>> pendingEvents = new ArrayDeque<>();

    private MethodChannel methods;
    private EventChannel events;
    private volatile EventChannel.EventSink eventSink;
    private volatile Context context;
    private volatile Activity activity;
    private ActivityPluginBinding activityBinding;
    private ExecutorService executor;
    private boolean attached;
    private boolean miInitialized;
    private boolean oppoInitialized;
    private boolean vivoInitialized;
    private PendingResult permissionResult;

    /**
     * Vendor receivers are created outside Flutter. Weak plugin instances
     * prevent a stale engine from being retained by a static EventSink.
     */
    static void emit(String name, Map<String, Object> data) {
        final Map<String, Object> event = new java.util.HashMap<>();
        event.put("name", name == null ? "" : name);
        event.put("data", sanitizeMap(data));

        final List<PushKitPlugin> targets;
        synchronized (INSTANCES_LOCK) {
            targets = new ArrayList<>(INSTANCES.keySet());
            if (targets.isEmpty()) {
                enqueueBounded(ORPHAN_EVENTS, event);
            }
        }
        for (PushKitPlugin plugin : targets) {
            plugin.dispatchEvent(event);
        }
    }

    static Map<String, Object> map(Object... values) {
        final Map<String, Object> result = new java.util.HashMap<>();
        for (int i = 0; i + 1 < values.length; i += 2) {
            result.put(String.valueOf(values[i]), values[i + 1]);
        }
        return result;
    }

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        methods = new MethodChannel(binding.getBinaryMessenger(), METHODS_CHANNEL);
        methods.setMethodCallHandler(this);
        events = new EventChannel(binding.getBinaryMessenger(), EVENTS_CHANNEL);
        events.setStreamHandler(this);
        executor = Executors.newFixedThreadPool(2, runnable -> {
            final Thread thread = new Thread(runnable, "push-kit-worker");
            thread.setDaemon(true);
            return thread;
        });
        attached = true;
        synchronized (INSTANCES_LOCK) {
            INSTANCES.put(this, Boolean.TRUE);
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        attached = false;
        removeActivityListener();
        cancelPermissionRequest("Flutter engine detached");
        synchronized (INSTANCES_LOCK) {
            INSTANCES.remove(this);
        }
        eventSink = null;
        synchronized (pendingEvents) {
            pendingEvents.clear();
        }
        if (methods != null) {
            methods.setMethodCallHandler(null);
        }
        if (events != null) {
            events.setStreamHandler(null);
        }
        if (executor != null) {
            executor.shutdownNow();
            try {
                executor.awaitTermination(1, TimeUnit.SECONDS);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
            }
            executor = null;
        }
        for (PendingResult pending : new ArrayList<>(pendingResults)) {
            pending.error("PLUGIN_DETACHED", "Flutter engine detached", null);
        }
        methods = null;
        events = null;
        activity = null;
        context = null;
    }

    @Override
    public void onListen(Object arguments, EventChannel.EventSink sink) {
        if (!attached) {
            return;
        }
        eventSink = sink;
        synchronized (INSTANCES_LOCK) {
            synchronized (pendingEvents) {
                while (!ORPHAN_EVENTS.isEmpty() && pendingEvents.size() < MAX_PENDING_EVENTS) {
                    pendingEvents.addLast(ORPHAN_EVENTS.removeFirst());
                }
            }
        }
        flushPendingEvents();
    }

    @Override
    public void onCancel(Object arguments) {
        eventSink = null;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        removeActivityListener();
        activityBinding = binding;
        activity = binding.getActivity();
        binding.addRequestPermissionsResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        // Keep a permission request alive across rotation; the new binding is
        // registered again in onReattachedToActivityForConfigChanges.
        removeActivityListener();
        activity = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        removeActivityListener();
        activity = null;
        cancelPermissionRequest("Activity detached");
    }

    @Override
    public boolean onRequestPermissionsResult(
            int requestCode,
            @NonNull String[] permissions,
            @NonNull int[] grantResults) {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST || permissionResult == null) {
            return false;
        }
        final PendingResult result = permissionResult;
        permissionResult = null;
        final int permissionIndex = permissionIndex(permissions,
                POST_NOTIFICATIONS_PERMISSION);
        final boolean granted = permissionIndex >= 0
                && permissionIndex < grantResults.length
                && grantResults[permissionIndex] == PackageManager.PERMISSION_GRANTED;
        result.success(granted && notificationsEnabled() ? "granted" : "denied");
        return true;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        final PendingResult pending = new PendingResult(result);
        pendingResults.add(pending);
        if (!attached || context == null) {
            pending.error("PLUGIN_UNAVAILABLE", "Plugin is not attached", null);
            return;
        }
        try {
            switch (call.method) {
                case "is_available":
                    pending.success(true);
                    break;
                case "hw_getToken":
                    getHuaweiToken(pending);
                    break;
                case "mi_init":
                    initMi(pending);
                    break;
                case "oppo_init":
                    initOppo(pending);
                    break;
                case "oppo_requestNotificationPermission":
                    requestOppoPermission(pending);
                    break;
                case "vivo_init":
                    initVivo(call.arguments, pending);
                    break;
                case "ping":
                    ping(call.arguments, pending);
                    break;
                case "checkNotificationPermission":
                    checkPermission(pending);
                    break;
                case "requestNotificationPermission":
                    requestPermission(pending);
                    break;
                // Keep the cross-platform API stable; these are no-ops on Android.
                case "apple_init":
                    pending.success(null);
                    break;
                case "apple_requestAuthorizationWithOptions":
                    pending.success(false);
                    break;
                case "apple_getsetting":
                    pending.success("NotDetermined");
                    break;
                default:
                    pending.notImplemented();
                    break;
            }
        } catch (Exception error) {
            pending.error("METHOD_FAILED", messageFor(error), null);
        }
    }

    private void getHuaweiToken(PendingResult result) {
        final Context appContext = context;
        runAsync(result, "HUAWEI_TOKEN_FAILED", () -> {
            String appId = null;
            try {
                appId = AGConnectServicesConfig.fromContext(appContext)
                        .getString("client/app_id");
            } catch (Exception ignored) {
                // Fall back to plugin metadata when AGConnect is unavailable.
            }
            if (isBlank(appId)) {
                appId = metadata("HMS_APP_ID", appContext);
            }
            if (isBlank(appId)) {
                throw new IllegalStateException("HMS_APP_ID is not configured");
            }
            return HmsInstanceId.getInstance(appContext).getToken(appId.trim(), "HCM");
        });
    }

    private void initMi(PendingResult result) {
        if (miInitialized || vendorInitialized("mi")) {
            miInitialized = true;
            result.success(null);
            return;
        }
        try {
            final String appId = requiredMetadata("MiPushAppId");
            final String appKey = requiredMetadata("MiPushAppKey");
            MiPushClient.registerPush(context, appId, appKey);
            markVendorInitialized("mi");
            miInitialized = true;
            result.success(null);
        } catch (Exception error) {
            result.error("MIPUSH_INIT_FAILED", messageFor(error), null);
        }
    }

    private void initOppo(PendingResult result) {
        if (oppoInitialized || vendorInitialized("oppo")) {
            oppoInitialized = true;
            result.success(null);
            return;
        }
        try {
            final Context appContext = context;
            final String key = requiredMetadata("OPPOPushAppKey");
            final String secret = requiredMetadata("OPPOPushAppSecret");
            if (!HeytapPushManager.isSupportPush(appContext)) {
                throw new IllegalStateException("OPPO push is not supported on this device");
            }
            HeytapPushManager.init(appContext, true);
            HeytapPushManager.register(appContext, key, secret,
                    new ICallBackResultService() {
                        @Override
                        public void onRegister(int code, String id,
                                                String packageName,
                                                String miniPackageName) {
                            if (code == 0 && !isBlank(id)) {
                                PushKitPlugin.emit("oppopush.receiveRegisterResult",
                                        PushKitPlugin.map("regId", id));
                            } else if (code != 0) {
                                Log.w(TAG, "OPPO registration failed: " + code);
                            }
                        }

                        @Override
                        public void onGetPushStatus(int code, int status) { }

                        @Override
                        public void onGetNotificationStatus(int code, int status) { }

                        @Override
                        public void onError(int code, String message,
                                            String packageName,
                                            String miniProgramPkg) {
                            Log.w(TAG, "OPPO push error " + code + ": " + message);
                        }

                        @Override
                        public void onUnRegister(int code, String packageName,
                                                 String miniProgramPkg) { }

                        @Override
                        public void onSetPushTime(int code, String result) { }
                    });
            markVendorInitialized("oppo");
            oppoInitialized = true;
            result.success(null);
        } catch (Exception error) {
            result.error("OPPO_INIT_FAILED", messageFor(error), null);
        }
    }

    private void requestOppoPermission(PendingResult result) {
        try {
            HeytapPushManager.requestNotificationPermission();
            result.success(null);
        } catch (Exception error) {
            result.error("OPPO_PERMISSION_FAILED", messageFor(error), null);
        }
    }

    private void initVivo(Object arguments, PendingResult result) {
        if (vivoInitialized || vendorInitialized("vivo")) {
            vivoInitialized = true;
            result.success(null);
            return;
        }
        final boolean privacyAgreed = privacyWasAccepted(arguments);
        if (!privacyAgreed) {
            result.error("VIVO_PRIVACY_REQUIRED",
                    "Pass a true privacy consent flag to vivoInit before initializing Vivo Push",
                    null);
            return;
        }
        try {
            final Context appContext = context;
            final PushClient client = PushClient.getInstance(appContext);
            if (!client.isSupport()) {
                throw new IllegalStateException("vivo push is not supported on this device");
            }
            final PushConfig config = new PushConfig.Builder()
                    .agreePrivacyStatement(privacyAgreed)
                    .build();
            client.initialize(config);
            client.turnOnPush(new IPushActionListener() {
                @Override
                public void onStateChanged(int state) {
                    if (state != 0) {
                        Log.w(TAG, "vivo turnOnPush failed: " + state);
                        return;
                    }
                    client.getRegId(new IPushQueryActionListener() {
                        @Override
                        public void onSuccess(String id) {
                            if (!isBlank(id)) {
                                PushKitPlugin.emit("vivopush.receiveRegisterResult",
                                        PushKitPlugin.map("regId", id));
                            }
                        }

                        @Override
                        public void onFail(Integer code) {
                            Log.w(TAG, "vivo getRegId failed: " + code);
                        }
                    });
                }
            });
            markVendorInitialized("vivo");
            vivoInitialized = true;
            result.success(null);
        } catch (Exception error) {
            result.error("VIVO_INIT_FAILED", messageFor(error), null);
        }
    }

    private void checkPermission(PendingResult result) {
        if (context == null) {
            result.error("PLUGIN_UNAVAILABLE", "Application context is unavailable", null);
            return;
        }
        if (Build.VERSION.SDK_INT < 33) {
            result.success(notificationsEnabled() ? "granted" : "denied");
            return;
        }
        final boolean granted = ContextCompat.checkSelfPermission(
                context, POST_NOTIFICATIONS_PERMISSION)
                == PackageManager.PERMISSION_GRANTED;
        if (granted) {
            result.success(notificationsEnabled() ? "granted" : "denied");
            return;
        }
        final Activity currentActivity = activity;
        if (currentActivity != null
                && currentActivity.shouldShowRequestPermissionRationale(
                POST_NOTIFICATIONS_PERMISSION)) {
            result.success("denied");
        } else {
            result.success(permissionWasRequested() ? "denied" : "notDetermined");
        }
    }

    private void requestPermission(PendingResult result) {
        if (context == null) {
            result.error("PLUGIN_UNAVAILABLE", "Application context is unavailable", null);
            return;
        }
        if (Build.VERSION.SDK_INT < 33) {
            result.success(notificationsEnabled() ? "granted" : "denied");
            return;
        }
        final Activity currentActivity = activity;
        if (currentActivity == null) {
            result.error("ACTIVITY_UNAVAILABLE",
                    "An attached Activity is required to request notification permission",
                    null);
            return;
        }
        if (permissionResult != null) {
            result.error("PERMISSION_REQUEST_IN_PROGRESS",
                    "A notification permission request is already in progress", null);
            return;
        }
        if (ContextCompat.checkSelfPermission(
                context, POST_NOTIFICATIONS_PERMISSION)
                == PackageManager.PERMISSION_GRANTED) {
            result.success(notificationsEnabled() ? "granted" : "denied");
            return;
        }
        markPermissionRequested();
        permissionResult = result;
        try {
            currentActivity.requestPermissions(
                    new String[]{POST_NOTIFICATIONS_PERMISSION},
                    NOTIFICATION_PERMISSION_REQUEST);
        } catch (Exception error) {
            permissionResult = null;
            result.error("PERMISSION_REQUEST_FAILED", messageFor(error), null);
        }
    }

    private void ping(Object arguments, PendingResult result) {
        if (!(arguments instanceof List<?>)) {
            result.error("INVALID_ARGUMENT", "ping expects a list of hosts", null);
            return;
        }
        final List<String> hosts = new ArrayList<>();
        for (Object value : (List<?>) arguments) {
            if (!(value instanceof String) || isBlank((String) value)) {
                result.error("INVALID_ARGUMENT", "ping hosts must be non-empty strings", null);
                return;
            }
            hosts.add(((String) value).trim());
            if (hosts.size() > MAX_PING_HOSTS) {
                result.error("INVALID_ARGUMENT",
                        "ping accepts at most " + MAX_PING_HOSTS + " hosts", null);
                return;
            }
        }
        runAsync(result, "PING_FAILED", () -> {
            final List<Map<String, Object>> output = new ArrayList<>();
            for (String host : hosts) {
                output.add(doPing(host));
            }
            return output;
        });
    }

    private Map<String, Object> doPing(String host) {
        final Map<String, Object> request = map(
                "query", host, "timeout", "1", "retry", "3", "version", "v4");
        final Map<String, Object> response = new java.util.HashMap<>();
        final Map<String, Object> item = new java.util.HashMap<>();
        Process process = null;
        try {
            process = new ProcessBuilder(
                    "/system/bin/ping", "-n", "-W", "1", "-c", "3", host)
                    .redirectErrorStream(true)
                    .start();
            if (!waitForProcess(process, PING_TIMEOUT_SECONDS * 1000L)) {
                destroyProcess(process);
                throw new IOException("ping timed out");
            }
            final StringBuilder output = new StringBuilder();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                    process.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    output.append(line).append('\n');
                }
            }
            parsePingOutput(output.toString(), item);
            response.put("status", "success");
        } catch (Exception error) {
            if (error instanceof InterruptedException) {
                Thread.currentThread().interrupt();
            }
            Log.d(TAG, "ping failed for " + host + ": " + error.getMessage());
            item.put("avgRtt", 0);
            item.put("minRtt", 0);
            item.put("maxRtt", 0);
            item.put("pctTransmitted", "3");
            item.put("pctReceived", "0");
            item.put("pctLoss", "100%");
            response.put("status", "timeout");
        } finally {
            if (process != null) {
                process.destroy();
                try {
                    process.getInputStream().close();
                } catch (IOException ignored) { }
                try {
                    process.getErrorStream().close();
                } catch (IOException ignored) { }
            }
        }
        response.put("result", item);
        return map("request", request, "response", response);
    }

    private void parsePingOutput(String output, Map<String, Object> item)
            throws IOException {
        final Matcher rtt = RTT_PATTERN.matcher(output);
        if (!rtt.find()) {
            throw new IOException("ping RTT summary is unavailable");
        }
        item.put("minRtt", decimal(rtt.group(1)));
        item.put("avgRtt", decimal(rtt.group(2)));
        item.put("maxRtt", decimal(rtt.group(3)));

        List<String> packetValues = null;
        for (String line : output.split("\\r?\\n")) {
            if (line.indexOf('%') < 0) continue;
            final Matcher numbers = NUMBER_PATTERN.matcher(line);
            final List<String> values = new ArrayList<>();
            while (numbers.find()) values.add(numbers.group());
            if (values.size() < 3) continue;
            packetValues = values;
            final String lower = line.toLowerCase(java.util.Locale.ROOT);
            if (lower.contains("loss") || lower.contains("verlust")
                    || lower.contains("perte")) break;
        }
        if (packetValues == null) {
            throw new IOException("ping packet summary is malformed");
        }
        item.put("pctTransmitted", integerText(packetValues.get(0)));
        item.put("pctReceived", integerText(packetValues.get(1)));
        item.put("pctLoss", integerText(packetValues.get(2)) + "%");
    }

    private double decimal(String value) {
        return Double.parseDouble(value.replace(',', '.'));
    }

    private String integerText(String value) {
        final double number = decimal(value);
        if (number == Math.rint(number)) {
            return Long.toString((long) number);
        }
        return String.format(java.util.Locale.US, "%.2f", number);
    }

    private boolean waitForProcess(Process process, long timeoutMillis)
            throws InterruptedException {
        final long deadline = System.nanoTime()
                + TimeUnit.MILLISECONDS.toNanos(timeoutMillis);
        while (System.nanoTime() < deadline) {
            try {
                process.exitValue();
                return true;
            } catch (IllegalThreadStateException running) {
                Thread.sleep(50L);
            }
        }
        return false;
    }

    private void destroyProcess(Process process) {
        // Process.destroyForcibly was added in API 26; destroy is the safe
        // fallback on API 21-25.
        if (Build.VERSION.SDK_INT >= 26) {
            process.destroyForcibly();
        } else {
            process.destroy();
        }
    }

    private String requiredMetadata(String key) throws Exception {
        final String value = metadata(key, context);
        if (isBlank(value)) {
            throw new IllegalStateException(key + " is not configured");
        }
        return value.trim();
    }

    private String metadata(String key, Context appContext) throws Exception {
        if (appContext == null) {
            throw new IllegalStateException("Application context is unavailable");
        }
        final ApplicationInfo info = appContext.getPackageManager().getApplicationInfo(
                appContext.getPackageName(), PackageManager.GET_META_DATA);
        if (info.metaData == null || !info.metaData.containsKey(key)) {
            return null;
        }
        final Object raw = info.metaData.get(key);
        if (raw instanceof String) {
            return ((String) raw).trim();
        }
        if (raw instanceof Integer) {
            try {
                return appContext.getResources().getString((Integer) raw).trim();
            } catch (Exception error) {
                throw new IllegalStateException(
                        "Unable to resolve metadata resource " + key, error);
            }
        }
        return String.valueOf(raw).trim();
    }

    private boolean privacyWasAccepted(Object arguments) {
        if (arguments instanceof Boolean) {
            return (Boolean) arguments;
        }
        if (arguments instanceof Map<?, ?>) {
            final Map<?, ?> values = (Map<?, ?>) arguments;
            final Object value = values.containsKey("privacyAgreed")
                    ? values.get("privacyAgreed") : values.get("agreePrivacyStatement");
            return Boolean.TRUE.equals(value);
        }
        return false;
    }

    private boolean vendorInitialized(String vendor) {
        final Context appContext = context;
        return appContext != null
                && INITIALIZED_VENDORS.contains(vendor + ':' + appContext.getPackageName());
    }

    private void markVendorInitialized(String vendor) {
        final Context appContext = context;
        if (appContext != null) {
            INITIALIZED_VENDORS.add(vendor + ':' + appContext.getPackageName());
        }
    }

    private boolean notificationsEnabled() {
        final Context appContext = context;
        return appContext != null
                && NotificationManagerCompat.from(appContext).areNotificationsEnabled();
    }

    private boolean permissionWasRequested() {
        final Context appContext = context;
        return appContext != null && appContext.getSharedPreferences(
                PERMISSION_PREFS, Context.MODE_PRIVATE)
                .getBoolean(PERMISSION_REQUESTED, false);
    }

    private void markPermissionRequested() {
        final Context appContext = context;
        if (appContext != null) {
            appContext.getSharedPreferences(PERMISSION_PREFS, Context.MODE_PRIVATE)
                    .edit().putBoolean(PERMISSION_REQUESTED, true).apply();
        }
    }

    private void cancelPermissionRequest(String message) {
        final PendingResult pending = permissionResult;
        permissionResult = null;
        if (pending != null) {
            pending.error("ACTIVITY_DETACHED", message, null);
        }
    }

    private void removeActivityListener() {
        if (activityBinding != null) {
            try {
                activityBinding.removeRequestPermissionsResultListener(this);
            } catch (Exception error) {
                Log.w(TAG, "Unable to remove permission listener", error);
            }
            activityBinding = null;
        }
    }

    private void runAsync(PendingResult result, String errorCode, Work work) {
        final ExecutorService worker = executor;
        if (!attached || worker == null || worker.isShutdown()) {
            result.error("PLUGIN_UNAVAILABLE", "Plugin worker is unavailable", null);
            return;
        }
        try {
            worker.execute(() -> {
                try {
                    result.success(work.run());
                } catch (Exception error) {
                    result.error(errorCode, messageFor(error), null);
                }
            });
        } catch (RuntimeException error) {
            result.error("PLUGIN_UNAVAILABLE", messageFor(error), null);
        }
    }

    private void dispatchEvent(Map<String, Object> event) {
        MAIN_HANDLER.post(() -> {
            if (!attached) {
                return;
            }
            final EventChannel.EventSink sink = eventSink;
            if (sink == null) {
                synchronized (pendingEvents) {
                    enqueueBounded(pendingEvents, event);
                }
                return;
            }
            try {
                sink.success(event);
            } catch (RuntimeException error) {
                Log.w(TAG, "Unable to deliver push event", error);
            }
        });
    }

    private void flushPendingEvents() {
        MAIN_HANDLER.post(() -> {
            final EventChannel.EventSink sink = eventSink;
            if (!attached || sink == null) {
                return;
            }
            while (true) {
                final Map<String, Object> event;
                synchronized (pendingEvents) {
                    event = pendingEvents.pollFirst();
                }
                if (event == null) {
                    return;
                }
                try {
                    sink.success(event);
                } catch (RuntimeException error) {
                    Log.w(TAG, "Unable to deliver buffered push event", error);
                    return;
                }
            }
        });
    }

    private static void enqueueBounded(ArrayDeque<Map<String, Object>> queue,
                                       Map<String, Object> event) {
        while (queue.size() >= MAX_PENDING_EVENTS) {
            queue.removeFirst();
        }
        queue.addLast(event);
    }

    private static Map<String, Object> sanitizeMap(Map<String, Object> input) {
        final Map<String, Object> result = new java.util.HashMap<>();
        if (input == null) {
            return result;
        }
        for (Map.Entry<String, Object> entry : input.entrySet()) {
            if (entry.getKey() != null) {
                result.put(entry.getKey(), sanitizeValue(entry.getValue()));
            }
        }
        return result;
    }

    private static Object sanitizeValue(Object value) {
        if (value == null || value instanceof String || value instanceof Boolean
                || value instanceof Integer || value instanceof Long
                || value instanceof Double || value instanceof byte[]) {
            return value;
        }
        if (value instanceof Float) {
            return ((Float) value).doubleValue();
        }
        if (value instanceof Number) {
            return ((Number) value).doubleValue();
        }
        if (value instanceof Map<?, ?>) {
            final Map<String, Object> result = new java.util.HashMap<>();
            for (Map.Entry<?, ?> entry : ((Map<?, ?>) value).entrySet()) {
                if (entry.getKey() != null) {
                    result.put(String.valueOf(entry.getKey()), sanitizeValue(entry.getValue()));
                }
            }
            return result;
        }
        if (value instanceof Iterable<?>) {
            final List<Object> result = new ArrayList<>();
            for (Object item : (Iterable<?>) value) {
                result.add(sanitizeValue(item));
            }
            return result;
        }
        if (value.getClass().isArray()) {
            final List<Object> result = new ArrayList<>();
            final int length = java.lang.reflect.Array.getLength(value);
            for (int index = 0; index < length; index++) {
                result.add(sanitizeValue(java.lang.reflect.Array.get(value, index)));
            }
            return result;
        }
        return String.valueOf(value);
    }

    private static int permissionIndex(String[] permissions, String target) {
        for (int index = 0; index < permissions.length; index++) {
            if (target.equals(permissions[index])) {
                return index;
            }
        }
        return -1;
    }

    private static boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }

    private static String messageFor(Exception error) {
        final String message = error.getMessage();
        return message == null || message.trim().isEmpty()
                ? error.getClass().getSimpleName() : message;
    }

    private interface Work {
        Object run() throws Exception;
    }

    private final class PendingResult {
        private final MethodChannel.Result delegate;
        private final AtomicBoolean completed = new AtomicBoolean();

        PendingResult(MethodChannel.Result delegate) {
            this.delegate = delegate;
        }

        void success(Object value) {
            finish(() -> delegate.success(value));
        }

        void error(String code, String message, Object details) {
            finish(() -> delegate.error(code, message, details));
        }

        void notImplemented() {
            finish(delegate::notImplemented);
        }

        private void finish(Runnable callback) {
            if (!completed.compareAndSet(false, true)) {
                return;
            }
            pendingResults.remove(this);
            final Runnable deliver = () -> {
                try {
                    callback.run();
                } catch (RuntimeException error) {
                    Log.w(TAG, "Unable to complete method call", error);
                }
            };
            if (Looper.myLooper() == Looper.getMainLooper()) {
                deliver.run();
            } else {
                MAIN_HANDLER.post(deliver);
            }
        }
    }
}
