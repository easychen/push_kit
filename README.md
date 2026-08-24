# push_kit

`push_kit` provides one Flutter API for Huawei, Xiaomi, OPPO, vivo and Apple
push services. Native callbacks are exposed through a Flutter `MethodChannel`
and a broadcast event stream.

```dart
import 'package:push_kit/push_kit.dart';

final subscription = PushKit.events.listen((event) {
  if (event.name == PushEventName.receiveNotification) {
    print(event.data);
  }
});

await PushKit.miInit();
await PushKit.oppoInit();
await PushKit.vivoInit();
await PushKit.appleInit();
final hmsToken = await PushKit.hwGetToken();
```

## API mapping

| Native operation | Flutter |
| --- | --- |
| `hw_getToken` | `PushKit.hwGetToken()` |
| `mi_init` | `PushKit.miInit()` |
| `oppo_init` | `PushKit.oppoInit()` |
| `oppo_requestNotificationPermission` | `PushKit.oppoRequestNotificationPermission()` |
| `vivo_init` | `PushKit.vivoInit()` |
| `apple_init` | `PushKit.appleInit()` |
| `apple_requestAuthorizationWithOptions` | `PushKit.appleRequestAuthorizationWithOptions()` |
| `apple_getsetting` | `PushKit.appleGetSetting()` |
| `ping` | `PushKit.ping(addresses)` |
| `checkNotificationPermission` | `PushKit.checkNotificationPermission()` |
| `requestNotificationPermission` | `PushKit.requestNotificationPermission()` |

Events are `PushEventName.receiveNotification`, `openNotification`,
`localNotification`, `finishLaunching`, `appleDeviceToken`, and the vendor
registration events (`miRegister`, `oppoRegister`, `vivoRegister`). Huawei
token refresh is emitted as `hms.token`.

## Native configuration

The Android application must provide these metadata values:

```xml
<meta-data android:name="HMS_APP_ID" android:value="..." />
<meta-data android:name="MiPushAppId" android:value="..." />
<meta-data android:name="MiPushAppKey" android:value="..." />
<meta-data android:name="OPPOPushAppKey" android:value="..." />
<meta-data android:name="OPPOPushAppSecret" android:value="..." />
```

Huawei projects should also place `agconnect-services.json` in the Android
application and apply Huawei's AGConnect Gradle plugin. iOS projects must
enable Push Notifications and Background Modes/Remote notifications in the
Runner target and configure APNs provisioning.

The original `ping` implementation is Android-only because it invokes the
platform `/system/bin/ping` command. The Xiaomi, OPPO and vivo AARs are kept in
`android/` so their proprietary SDKs remain part of this plugin package.

When testing the Android library directly, use it through a Flutter application
(`flutter run` or an example app). Flutter supplies the Android embedding to a
plugin module; the library's standalone Gradle file intentionally contains only
the vendor dependencies.
