import { pushService, pushCommon } from '@kit.PushKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Want } from '@kit.AbilityKit';
import UIAbility from '@ohos.app.ability.UIAbility';
import common from '@ohos.app.ability.common';
import {
  AbilityAware,
  AbilityPluginBinding,
  EventChannel,
  EventSink,
  FlutterPlugin,
  FlutterPluginBinding,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  NewWantListener,
  StreamHandler,
} from '@ohos/flutter_ohos';

const TAG: string = 'PushKitPlugin';
const METHODS_CHANNEL: string = 'push_kit/methods';
const EVENTS_CHANNEL: string = 'push_kit/events';

const EVENT_RECEIVE_NOTIFICATION: string = 'push.receiveNotification';
const EVENT_OPEN_NOTIFICATION: string = 'push.openNotification';
const EVENT_TOKEN: string = 'hms.token';

/** Buffered events are dropped once this limit is exceeded. */
const MAX_PENDING_EVENTS: number = 32;

/**
 * Process-wide state. Push Kit rejects a second registration for the same
 * push type, and the registration cannot be removed, so it is kept across
 * ability detach/attach cycles and dispatched to the current plugin instance.
 */
let activePlugin: PushKitPlugin | null = null;
let messageReceiverRegistered: boolean = false;
let tokenListenerRegistered: boolean = false;

/**
 * HarmonyOS implementation backed by the system Push Kit.
 *
 * HarmonyOS delivers every vendor push through Push Kit, so the Xiaomi, OPPO,
 * vivo and Apple entry points are accepted as no-ops to keep the cross-platform
 * Dart API usable on this platform.
 */
export default class PushKitPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware, StreamHandler,
  NewWantListener {
  private methodChannel: MethodChannel | null = null;
  private eventChannel: EventChannel | null = null;
  private abilityBinding: AbilityPluginBinding | null = null;
  private ability: UIAbility | null = null;
  private eventSink: EventSink | null = null;
  private pendingEvents: Array<Record<string, Object>> = [];

  getUniqueClassName(): string {
    return 'PushKitPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.methodChannel = new MethodChannel(binding.getBinaryMessenger(), METHODS_CHANNEL);
    this.methodChannel.setMethodCallHandler(this);
    this.eventChannel = new EventChannel(binding.getBinaryMessenger(), EVENTS_CHANNEL);
    this.eventChannel.setStreamHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.methodChannel?.setMethodCallHandler(null);
    this.methodChannel = null;
    this.eventChannel?.setStreamHandler(null);
    this.eventChannel = null;
    this.eventSink = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.abilityBinding = binding;
    this.ability = binding.getAbility();
    activePlugin = this;
    binding.addOnNewWantListener(this);
    this.registerMessageReceiver();
    this.registerTokenListener();
    // A notification tap that started the app is only visible in the launch want.
    this.handleWant(this.ability.launchWant);
  }

  onDetachedFromAbility(): void {
    this.abilityBinding?.removeOnNewWantListener(this);
    this.abilityBinding = null;
    this.ability = null;
    if (activePlugin === this) {
      activePlugin = null;
    }
  }

  /** A notification tap while the app is already running arrives as a new want. */
  onNewWant(want: Want): void {
    this.handleWant(want);
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'is_available':
        result.success(true);
        return;
      case 'hw_getToken':
        this.getToken(result);
        return;
      case 'checkNotificationPermission':
        this.checkNotificationPermission(result);
        return;
      case 'requestNotificationPermission':
        this.requestNotificationPermission(result);
        return;
      case 'oppo_requestNotificationPermission':
        this.requestNotificationPermissionThenComplete(result);
        return;
      // Push Kit is the only push channel on HarmonyOS; keep the shared API usable.
      case 'mi_init':
      case 'oppo_init':
      case 'vivo_init':
      case 'apple_init':
        result.success(null);
        return;
      case 'apple_requestAuthorizationWithOptions':
        result.success(false);
        return;
      case 'apple_getsetting':
        result.success('NotDetermined');
        return;
      case 'ping':
        result.error('unsupported', 'ping is only available on Android', null);
        return;
      default:
        result.notImplemented();
        return;
    }
  }

  // ---------------------------------------------------------------------------
  // EventChannel
  // ---------------------------------------------------------------------------

  onListen(args: ESObject, events: EventSink): void {
    this.eventSink = events;
    this.flushPendingEvents();
  }

  onCancel(args: ESObject): void {
    this.eventSink = null;
  }

  /** Emits `{ name, data }`; buffered until Dart starts listening. */
  private emit(name: string, data: Record<string, Object>): void {
    const event: Record<string, Object> = {};
    event['name'] = name;
    event['data'] = data;
    const sink: EventSink | null = this.eventSink;
    if (sink === null) {
      while (this.pendingEvents.length >= MAX_PENDING_EVENTS) {
        this.pendingEvents.shift();
      }
      this.pendingEvents.push(event);
      return;
    }
    try {
      sink.success(event);
    } catch (error) {
      Log.e(TAG, 'Unable to deliver push event');
    }
  }

  private flushPendingEvents(): void {
    const sink: EventSink | null = this.eventSink;
    if (sink === null) {
      return;
    }
    while (this.pendingEvents.length > 0) {
      const event: Record<string, Object> | undefined = this.pendingEvents.shift();
      if (event === undefined) {
        return;
      }
      try {
        sink.success(event);
      } catch (error) {
        Log.e(TAG, 'Unable to deliver buffered push event');
        return;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Push Kit message and token callbacks
  // ---------------------------------------------------------------------------

  private registerMessageReceiver(): void {
    if (messageReceiverRegistered || this.ability === null) {
      return;
    }
    try {
      // 'DEFAULT' receives notification messages while the app is in the foreground.
      pushService.receiveMessage('DEFAULT', this.ability, (payload: pushCommon.PushPayload): void => {
        activePlugin?.onPushPayload(payload);
      });
      messageReceiverRegistered = true;
    } catch (error) {
      Log.e(TAG, `receiveMessage failed: ${this.errorMessage(error)}`);
    }
  }

  private registerTokenListener(): void {
    if (tokenListenerRegistered || this.ability === null) {
      return;
    }
    try {
      pushService.on('tokenUpdate', this.ability, (token: string): void => {
        const data: Record<string, Object> = {};
        data['token'] = token;
        activePlugin?.emit(EVENT_TOKEN, data);
      });
      tokenListenerRegistered = true;
    } catch (error) {
      Log.e(TAG, `tokenUpdate listener failed: ${this.errorMessage(error)}`);
    }
  }

  private onPushPayload(payload: pushCommon.PushPayload): void {
    this.emit(EVENT_RECEIVE_NOTIFICATION, this.parsePayload(payload.data));
  }

  /** The server `data` field is a JSON string; keep it readable for Dart. */
  private parsePayload(raw: string | undefined): Record<string, Object> {
    const data: Record<string, Object> = {};
    if (raw === undefined || raw === null || raw.length === 0) {
      return data;
    }
    try {
      const parsed: ESObject = JSON.parse(raw);
      if (parsed !== null && parsed !== undefined && typeof parsed === 'object') {
        const record: Record<string, Object> = parsed as Record<string, Object>;
        const keys: string[] = Object.keys(record);
        for (const key of keys) {
          const value: Object | undefined = record[key];
          if (value !== undefined) {
            data[key] = value;
          }
        }
        return data;
      }
    } catch (error) {
      // Not JSON: fall through and expose the raw string.
    }
    data['data'] = raw;
    return data;
  }

  /**
   * Notification taps arrive through the launch want: the `data` object of the
   * `clickAction` payload is merged into `want.parameters`.
   *
   * A plain launch (icon tap, `aa start`, another app) also carries
   * `want.parameters`, but only with system keys such as
   * `ohos.aafwk.param.callerPid` or `component.startup.newRules`. Those are
   * filtered out so they are not reported as notification taps.
   */
  private handleWant(want: Want): void {
    if (want === undefined || want === null) {
      return;
    }
    const data: Record<string, Object> = {};
    const parameters: Record<string, Object> | undefined = want.parameters;
    if (parameters !== undefined && parameters !== null) {
      const keys: string[] = Object.keys(parameters);
      for (const key of keys) {
        if (this.isSystemWantParameter(key)) {
          continue;
        }
        const value: Object | undefined = parameters[key];
        if (value !== undefined) {
          data[key] = value;
        }
      }
    }
    const action: string | undefined = want.action;
    if (action !== undefined && action.length > 0 && !this.isSystemWantAction(action)) {
      data['action'] = action;
    }
    const uri: string | undefined = want.uri;
    if (uri !== undefined && uri.length > 0) {
      data['uri'] = uri;
    }
    if (Object.keys(data).length === 0) {
      return;
    }
    this.emit(EVENT_OPEN_NOTIFICATION, data);
  }

  private isSystemWantParameter(key: string): boolean {
    return key.startsWith('ohos.') || key.startsWith('component.') || key.startsWith('ability.') ||
      key === 'moduleName' || key === 'isCallBySCB' || key === 'isShellCall';
  }

  private isSystemWantAction(action: string): boolean {
    return action === 'ohos.want.action.home' || action === 'action.system.home';
  }

  // ---------------------------------------------------------------------------
  // Token and notification permission
  // ---------------------------------------------------------------------------

  private getToken(result: MethodResult): void {
    pushService.getToken().then((token: string): void => {
      result.success(token);
    }).catch((error: BusinessError): void => {
      this.completeError(error, result);
    });
  }

  private checkNotificationPermission(result: MethodResult): void {
    notificationManager.isNotificationEnabled().then((enabled: boolean): void => {
      result.success(enabled ? 'granted' : 'denied');
    }).catch((error: BusinessError): void => {
      this.completeError(error, result);
    });
  }

  private requestNotificationPermission(result: MethodResult): void {
    this.requestEnableNotification().then((enabled: boolean): void => {
      result.success(enabled ? 'granted' : 'denied');
    }).catch((error: BusinessError): void => {
      this.completeError(error, result);
    });
  }

  private requestNotificationPermissionThenComplete(result: MethodResult): void {
    this.requestEnableNotification().then((): void => {
      result.success(null);
    }).catch((error: BusinessError): void => {
      this.completeError(error, result);
    });
  }

  /**
   * Returns whether notifications end up enabled. A user who already denied the
   * dialog cannot be prompted again, which surfaces as a failed request.
   */
  private async requestEnableNotification(): Promise<boolean> {
    if (await notificationManager.isNotificationEnabled()) {
      return true;
    }
    const context: common.UIAbilityContext = this.requireAbilityContext();
    try {
      await notificationManager.requestEnableNotification(context);
    } catch (error) {
      Log.w(TAG, `requestEnableNotification failed: ${this.errorMessage(error)}`);
      return false;
    }
    return await notificationManager.isNotificationEnabled();
  }

  private requireAbilityContext(): common.UIAbilityContext {
    if (this.ability === null) {
      throw new Error('push_kit requires a foreground UIAbility');
    }
    return this.ability.context;
  }

  private errorMessage(error: ESObject): string {
    return error instanceof Error ? error.message : `${error}`;
  }

  private completeError(error: ESObject, result: MethodResult): void {
    const businessError: BusinessError = error as BusinessError;
    if (typeof businessError.code === 'number') {
      result.error(`${businessError.code}`, businessError.message, null);
      return;
    }
    result.error('push_kit_error', this.errorMessage(error), null);
  }
}
