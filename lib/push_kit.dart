import 'dart:async';

import 'package:flutter/services.dart';

/// Event names emitted by the native push services.
abstract final class PushEventName {
  static const receiveNotification = 'push.receiveNotification';
  static const openNotification = 'push.openNotification';
  static const localNotification = 'push.localNotification';
  static const finishLaunching = 'push.finishLaunching';
  static const appleDeviceToken =
      'applepush.didRegisterForRemoteNotificationsWithDeviceToken';
  static const miRegister = 'mipush.receiveRegisterResult';
  static const oppoRegister = 'oppopush.receiveRegisterResult';
  static const vivoRegister = 'vivopush.receiveRegisterResult';
}

/// A notification or registration callback from a native push SDK.
final class PushEvent {
  const PushEvent(this.name, this.data);

  final String name;
  final Map<String, dynamic> data;

  factory PushEvent.fromMap(Map<dynamic, dynamic> value) {
    final dynamic rawData = value['data'];
    final Map<String, dynamic> data = <String, dynamic>{};
    if (rawData is Map) {
      try {
        for (final MapEntry<dynamic, dynamic> entry in rawData.entries) {
          if (entry.key is String) {
            data[entry.key as String] = entry.value;
          }
        }
      } on Object {
        // A malformed platform map should not terminate every event listener.
        data.clear();
      }
    }
    return PushEvent(
      value['name'] is String ? value['name'] as String : '',
      data,
    );
  }
}

/// Unified Flutter API for the supported push services.
class PushKit {
  PushKit._();

  static const MethodChannel _methods = MethodChannel('push_kit/methods');
  static const EventChannel _eventChannel = EventChannel('push_kit/events');
  static Stream<PushEvent>? _events;

  /// All native push events are delivered in their stable public names.
  ///
  /// The stream is cached so every Dart listener shares the one native
  /// EventChannel subscription. Creating a new EventChannel stream per getter
  /// call would let one listener cancel another listener's native sink.
  static Stream<PushEvent> get events => _events ??= _createEvents();

  static Stream<PushEvent> _createEvents() {
    StreamSubscription<dynamic>? nativeSubscription;
    late final StreamController<PushEvent> controller;
    bool activating = false;

    Future<void> activate() async {
      if (activating || nativeSubscription != null || !controller.hasListener) {
        return;
      }
      activating = true;
      try {
        // EventChannel reports a missing `listen` handler directly through
        // FlutterError, before a Stream transformer can observe it. Probe the
        // MethodChannel first so a stale hot-reloaded host does not activate
        // the EventChannel until it has been rebuilt with this plugin.
        final bool available =
            await _methods.invokeMethod<bool>('is_available') ?? false;
        if (!available || !controller.hasListener) {
          return;
        }
        nativeSubscription = _eventChannel.receiveBroadcastStream().listen(
          (dynamic value) {
            if (value is Map) {
              controller.add(PushEvent.fromMap(value));
            }
          },
          onError: controller.addError,
          onDone: () {
            nativeSubscription = null;
          },
        );
      } on MissingPluginException {
        // The current engine was not rebuilt with push_kit. Keep the shared
        // stream idle; a later subscription after a full restart can retry.
      } finally {
        activating = false;
      }
    }

    controller = StreamController<PushEvent>.broadcast(
      onListen: () {
        unawaited(activate());
      },
      onCancel: () async {
        final StreamSubscription<dynamic>? subscription = nativeSubscription;
        nativeSubscription = null;
        if (subscription != null) {
          await subscription.cancel();
        }
      },
    );
    return controller.stream;
  }

  static Future<String?> hwGetToken([dynamic argument]) =>
      _methods.invokeMethod<String>('hw_getToken', argument);

  static Future<void> miInit([dynamic argument]) =>
      _methods.invokeMethod<void>('mi_init', argument);

  static Future<void> oppoInit([dynamic argument]) =>
      _methods.invokeMethod<void>('oppo_init', argument);

  static Future<void> oppoRequestNotificationPermission([dynamic argument]) =>
      _methods.invokeMethod<void>(
        'oppo_requestNotificationPermission',
        argument,
      );

  /// Initializes vivo push after the host has obtained user privacy consent.
  /// Pass `true` or `{'privacyAgreed': true}` as [argument].
  static Future<void> vivoInit([dynamic argument]) =>
      _methods.invokeMethod<void>('vivo_init', argument);

  static Future<void> appleInit([dynamic argument]) =>
      _methods.invokeMethod<void>('apple_init', argument);

  static Future<bool> appleRequestAuthorizationWithOptions([
    dynamic argument,
  ]) async =>
      await _methods.invokeMethod<bool>(
        'apple_requestAuthorizationWithOptions',
        argument,
      ) ??
      false;

  static Future<String> appleGetSetting([dynamic argument]) async =>
      await _methods.invokeMethod<String>('apple_getsetting', argument) ??
      'NotDetermined';

  static Future<List<Map<String, dynamic>>> ping(List<String> addresses) async {
    if (addresses.length > 64 ||
        addresses.any(
          (dynamic address) => address is! String || address.trim().isEmpty,
        )) {
      throw ArgumentError(
        'ping addresses must be non-empty and contain at most 64 hosts',
      );
    }
    final value = await _methods.invokeMethod<List<dynamic>>('ping', addresses);
    final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
    for (final dynamic item in value ?? const <dynamic>[]) {
      if (item is! Map) {
        continue;
      }
      try {
        result.add(Map<String, dynamic>.from(item));
      } on Object {
        // Ignore malformed individual results rather than crashing callers.
      }
    }
    return result.toList(growable: false);
  }

  static Future<String> checkNotificationPermission() async =>
      await _methods.invokeMethod<String>('checkNotificationPermission') ??
      'notDetermined';

  static Future<String> requestNotificationPermission() async =>
      await _methods.invokeMethod<String>('requestNotificationPermission') ??
      'denied';
}

/// Short alias for applications that prefer the generic name.
typedef Push = PushKit;
