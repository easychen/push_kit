## Unreleased

- Fix Xiaomi push on MIUI / HyperOS devices: declare `MiPushReceiver` as `android:exported="true"`.
  On these devices registration results and messages are broadcast by the system push service
  `com.xiaomi.xmsf` (a different uid), so a non-exported receiver is rejected with
  `Permission Denial: ... is not exported` and the app never receives its regId.

## 1.1.0

- Add HarmonyOS support backed by Push Kit: Push Token via `hwGetToken`, notification
  permission query/request via Notification Kit, foreground messages, notification taps
  and token updates through the existing event stream.
- Ignore HarmonyOS system launch parameters (`ohos.*`, `component.*`, home actions) when
  deriving `push.openNotification`, so a plain cold start no longer reports a tap.

## 1.0.2

- Fix Android library packaging with AGP 8 by resolving bundled vendor AARs through a local Maven repository.

## 1.0.1

- Fix Android 12 manifest compatibility by declaring `android:exported` for OPPO push services.

## 1.0.0

* Initial release of the unified Flutter push notification plugin.
