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

  factory PushEvent.fromMap(Map<dynamic, dynamic> value) => PushEvent(
    value['name'] as String? ?? '',
    Map<String, dynamic>.from(value['data'] as Map? ?? const {}),
  );
}

/// Unified Flutter API for the supported push services.
class PushKit {
  PushKit._();

  static const MethodChannel _methods = MethodChannel('push_kit/methods');
  static const EventChannel _eventChannel = EventChannel('push_kit/events');

  /// All native push events are delivered in their stable public names.
  static Stream<PushEvent> get events => _eventChannel
      .receiveBroadcastStream()
      .map((value) => PushEvent.fromMap(value as Map));

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
    final value = await _methods.invokeMethod<List<dynamic>>('ping', addresses);
    return (value ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
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
