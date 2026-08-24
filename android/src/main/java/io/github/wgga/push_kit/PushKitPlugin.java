package io.github.wgga.push_kit;

import android.Manifest;
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
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

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
    private MethodChannel methods;
    private EventChannel events;
    private static volatile EventChannel.EventSink eventSink;
    private Context context;
    private Activity activity;
    private MethodChannel.Result permissionResult;

    static void emit(String name, Map<String, Object> data) {
        EventChannel.EventSink sink = eventSink;
        if (sink == null) return;
        Map<String, Object> event = new HashMap<>();
        event.put("name", name);
        event.put("data", data == null ? new HashMap<>() : data);
        new Handler(Looper.getMainLooper()).post(() -> sink.success(event));
    }

    static Map<String, Object> map(Object... values) {
        Map<String, Object> result = new HashMap<>();
        for (int i = 0; i + 1 < values.length; i += 2) {
            result.put(String.valueOf(values[i]), values[i + 1]);
        }
        return result;
    }

    @Override public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        methods = new MethodChannel(binding.getBinaryMessenger(), "push_kit/methods");
        methods.setMethodCallHandler(this);
        events = new EventChannel(binding.getBinaryMessenger(), "push_kit/events");
        events.setStreamHandler(this);
    }

    @Override public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (methods != null) methods.setMethodCallHandler(null);
        if (events != null) events.setStreamHandler(null);
        eventSink = null;
        methods = null;
        events = null;
        context = null;
    }

    @Override public void onListen(Object arguments, EventChannel.EventSink sink) { eventSink = sink; }
    @Override public void onCancel(Object arguments) { eventSink = null; }

    @Override public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
        binding.addRequestPermissionsResultListener(this);
    }
    @Override public void onDetachedFromActivityForConfigChanges() { activity = null; }
    @Override public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) { activity = binding.getActivity(); }
    @Override public void onDetachedFromActivity() { activity = null; }

    @Override public boolean onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        if (requestCode != 8127 || permissionResult == null) return false;
        permissionResult.success(grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED ? "granted" : "denied");
        permissionResult = null;
        return true;
    }

    @Override public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "hw_getToken": getHuaweiToken(result); break;
            case "mi_init": initMi(result); break;
            case "oppo_init": initOppo(result); break;
            case "oppo_requestNotificationPermission": requestOppoPermission(result); break;
            case "vivo_init": initVivo(result); break;
            case "ping": ping(call.arguments, result); break;
            case "checkNotificationPermission": checkPermission(result); break;
            case "requestNotificationPermission": requestPermission(result); break;
            case "apple_init": result.success(null); break;
            case "apple_requestAuthorizationWithOptions": result.success(false); break;
            case "apple_getsetting": result.success("NotDetermined"); break;
            default: result.notImplemented();
        }
    }

    private void getHuaweiToken(MethodChannel.Result result) {
        new Thread(() -> {
            try {
                String appId = null;
                try { appId = AGConnectServicesConfig.fromContext(context).getString("client/app_id"); } catch (Throwable ignored) { }
                if (appId == null || appId.isEmpty()) appId = metadata("HMS_APP_ID");
                if (appId == null || appId.isEmpty()) throw new IllegalStateException("HMS_APP_ID is not configured");
                String token = HmsInstanceId.getInstance(context).getToken(appId, "HCM");
                new Handler(Looper.getMainLooper()).post(() -> result.success(token));
            } catch (Exception e) {
                new Handler(Looper.getMainLooper()).post(() -> result.error("HUAWEI_TOKEN_FAILED", e.getMessage(), null));
            }
        }).start();
    }

    private void initMi(MethodChannel.Result result) {
        try {
            String appId = metadata("MiPushAppId");
            String appKey = metadata("MiPushAppKey");
            if (appId == null || appKey == null) throw new IllegalStateException("MiPushAppId and MiPushAppKey are required");
            appId = appId.replace("mipush", "");
            appKey = appKey.replace("mipush", "");
            MiPushClient.registerPush(context, appId, appKey);
            result.success(null);
        } catch (Exception e) { result.error("MIPUSH_INIT_FAILED", e.getMessage(), null); }
    }

    private void initOppo(MethodChannel.Result result) {
        try {
            String key = metadata("OPPOPushAppKey");
            String secret = metadata("OPPOPushAppSecret");
            if (key == null || secret == null) throw new IllegalStateException("OPPOPushAppKey and OPPOPushAppSecret are required");
            HeytapPushManager.init(context, true);
            HeytapPushManager.register(context, key, secret, new ICallBackResultService() {
                @Override public void onRegister(int code, String id, String packageName, String miniPackageName) {
                    if (code == 0) emit("oppopush.receiveRegisterResult", map("regId", id));
                }
                @Override public void onGetPushStatus(int code, int status) { }
                @Override public void onGetNotificationStatus(int code, int status) { }
                @Override public void onError(int code, String message, String packageName, String miniProgramPkg) { }
                @Override public void onUnRegister(int code, String packageName, String miniProgramPkg) { }
                @Override public void onSetPushTime(int code, String result) { }
            });
            result.success(null);
        } catch (Exception e) { result.error("OPPO_INIT_FAILED", e.getMessage(), null); }
    }

    private void requestOppoPermission(MethodChannel.Result result) {
        try { HeytapPushManager.requestNotificationPermission(); result.success(null); }
        catch (Exception e) { result.error("OPPO_PERMISSION_FAILED", e.getMessage(), null); }
    }

    private void initVivo(MethodChannel.Result result) {
        try {
            PushConfig config = new PushConfig.Builder().agreePrivacyStatement(true).build();
            PushClient.getInstance(context).initialize(config);
            PushClient.getInstance(context).turnOnPush(new IPushActionListener() {
                @Override public void onStateChanged(int state) {
                    if (state == 0) PushClient.getInstance(context).getRegId(new IPushQueryActionListener() {
                        @Override public void onSuccess(String id) { emit("vivopush.receiveRegisterResult", map("regId", id)); }
                        @Override public void onFail(Integer code) { Log.w(TAG, "vivo getRegId failed: " + code); }
                    });
                }
            });
            result.success(null);
        } catch (Exception e) { result.error("VIVO_INIT_FAILED", e.getMessage(), null); }
    }

    private void checkPermission(MethodChannel.Result result) {
        if (Build.VERSION.SDK_INT < 33) { result.success(NotificationManagerCompat.from(context).areNotificationsEnabled() ? "granted" : "denied"); return; }
        if (activity == null) { result.success("notDetermined"); return; }
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) result.success("granted");
        else if (activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) result.success("denied");
        else result.success("notDetermined");
    }

    private void requestPermission(MethodChannel.Result result) {
        if (Build.VERSION.SDK_INT < 33 || activity == null) { result.success(NotificationManagerCompat.from(context).areNotificationsEnabled() ? "granted" : "denied"); return; }
        permissionResult = result;
        activity.requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 8127);
    }

    private String metadata(String key) throws Exception {
        ApplicationInfo info = context.getPackageManager().getApplicationInfo(context.getPackageName(), PackageManager.GET_META_DATA);
        return info.metaData == null ? null : info.metaData.getString(key);
    }

    private void ping(Object arguments, MethodChannel.Result result) {
        if (!(arguments instanceof List)) { result.error("INVALID_ARGUMENT", "ping expects a list of hosts", null); return; }
        new Thread(() -> {
            List<Map<String, Object>> output = new ArrayList<>();
            for (Object value : (List<?>) arguments) output.add(doPing(String.valueOf(value)));
            new Handler(Looper.getMainLooper()).post(() -> result.success(output));
        }).start();
    }

    private Map<String, Object> doPing(String host) {
        Map<String, Object> request = map("query", host, "timeout", "1", "retry", "3", "version", "v4");
        Map<String, Object> response = new HashMap<>();
        Map<String, Object> item = new HashMap<>();
        try {
            Process process = Runtime.getRuntime().exec(new String[]{"/system/bin/ping", "-n", "-W", "1", "-c", "3", host});
            String summary = ""; String transmitted = "";
            BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()));
            String line;
            while ((line = reader.readLine()) != null) { if (line.contains("avg")) summary = line; if (line.contains("transmitted")) transmitted = line; }
            process.waitFor();
            String[] parts = summary.substring(summary.indexOf('=') + 1).trim().split("/");
            item.put("avgRtt", Double.parseDouble(parts[1])); item.put("minRtt", Double.parseDouble(parts[0])); item.put("maxRtt", Double.parseDouble(parts[2]));
            String[] stats = transmitted.trim().split(",");
            item.put("pctTransmitted", stats[0].trim().split(" ")[0]); item.put("pctReceived", stats[1].trim().split(" ")[0]); item.put("pctLoss", stats[2].trim().split(" ")[0]);
            response.put("status", "success");
        } catch (Exception ignored) {
            item.put("avgRtt", 0); item.put("minRtt", 0); item.put("maxRtt", 0); item.put("pctTransmitted", "3"); item.put("pctReceived", 0); item.put("pctLoss", "100%"); response.put("status", "timeout");
        }
        response.put("result", item);
        return map("request", request, "response", response);
    }
}
