# push_kit

[![License](https://img.shields.io/github/license/Wgga/push_kit)](https://github.com/Wgga/push_kit/blob/main/LICENSE)

统一 Huawei、Xiaomi、OPPO、vivo、Apple 和 HarmonyOS 推送服务的 Flutter 插件，
支持 Android、iOS 和 HarmonyOS。插件通过统一的 Dart API 初始化厂商推送 SDK，
并通过事件流返回通知、点击、注册和权限变化。

## 功能

| 功能 | Android | iOS | 鸿蒙 |
| --- | :---: | :---: | :---: |
| 获取 Push Token | 支持 | — | 支持（Push Kit） |
| Xiaomi 推送初始化和注册回调 | 支持 | — | — |
| OPPO 推送初始化和通知权限 | 支持 | — | — |
| vivo 推送初始化和注册回调 | 支持 | — | — |
| Apple APNs 注册 | — | 支持 | — |
| Apple 通知授权和状态查询 | — | 支持 | — |
| 通知权限查询和申请 | 支持 | — | 支持 |
| 推送通知事件流 | 支持 | 支持 | 支持 |
| 主机 Ping | 支持 | — | — |

## 环境要求

- Dart `>=3.7.0 <4.0.0`
- Flutter `>=3.29.0`
- Android API 21 或更高、AndroidX、Java 17
- iOS 12.0 或更高
- 鸿蒙 HarmonyOS 5.0.0（API 12）或更高，需安装 DevEco Studio 与本机签名证书
- Android 工程使用 Gradle 8 或更高版本

## 安装

从 Git 仓库依赖：

```yaml
dependencies:
  push_kit:
    git:
      url: https://github.com/Wgga/push_kit.git
      ref: main
```

本地开发时可以使用路径依赖：

```yaml
dependencies:
  push_kit:
    path: ../push_kit
```

然后执行：

```shell
flutter pub get
```

## Android 配置

### 使用 CLI 配置宿主

不要手动编辑 Manifest 或复制占位 XML。插件提供 `dart run` 配置命令，直接在 Flutter 宿主工程根目录执行：

```shell
dart run push_kit:setup \\
  --platforms android \\
  --hms-app-id your-huawei-app-id \\
  --mi-app-id your-xiaomi-app-id \\
  --mi-app-key your-xiaomi-app-key \\
  --oppo-app-key your-oppo-app-key \\
  --oppo-app-secret your-oppo-app-secret \\
  --vivo-app-id your-vivo-app-id \\
  --vivo-app-key your-vivo-api-key
```

只使用某个厂商时，只传递该厂商的参数即可。命令会自动更新：

- `android/app/src/main/AndroidManifest.xml` 中的厂商 metadata。
- `android/app/src/main/res/values/push_kit.xml` 中的资源值。
- 传入 `--hms-services path/to/agconnect-services.json` 时，复制 Huawei 配置文件到 `android/app/`。

可以先预览或在 CI 中检查：

```shell
dart run push_kit:setup --platforms android --mi-app-id id --mi-app-key key --dry-run
dart run push_kit:setup --platforms android --mi-app-id id --mi-app-key key --check
```

真实密钥会写入宿主工程，请把生成的 `push_kit.xml` 和 `agconnect-services.json` 加入宿主项目的 Git 忽略规则。

### 厂商参数

参数名已经由 CLI 固定，不需要再手动维护 Android XML。Android 插件会从宿主 Manifest 读取这些值。

### Huawei

1. 在 AppGallery Connect 创建 Android 应用并启用 Push Kit。
2. 下载 `agconnect-services.json`，通过 `--hms-services` 交给 CLI。
3. 按 Huawei 文档在宿主 Android 工程中配置 AGConnect Gradle 插件。
4. 确保包名、签名证书和 AppGallery Connect 中登记的信息一致。

### 通知权限

Android 13 及更高版本需要运行时通知权限：

```dart
final status = await PushKit.checkNotificationPermission();
if (status == 'notDetermined') {
  await PushKit.requestNotificationPermission();
}
```

插件会自动合并网络、唤醒锁、震动和 `POST_NOTIFICATIONS` 等所需 Manifest 权限。

## 鸿蒙配置

鸿蒙端直接使用系统 Push Kit，不需要引入第三方推送 SDK。`ohos/` 是 HAR 源码模块，
由 Flutter 工具自动 include 到宿主的 `ohos` 工程，`GeneratedPluginRegistrant` 会注册
`PushKitPlugin`。

### 前置条件

- 在 AppGallery Connect 为 HarmonyOS 应用开通推送服务，并完成签名信息配置。
- 使用与 AppGallery Connect 应用一致的**签名证书和 Profile** 打包，签名不一致会导致
  `getToken` 失败（常见错误码 `1000900010`）。
- 测试设备已登录华为账号。

### 配置 client_id

在宿主 `entry/src/main/module.json5` 的 `module.metadata` 中填入 AGC 的 `client_id`：

```json5
"metadata": [
  { "name": "client_id", "value": "your-agc-client-id" }
]
```

宿主需要 `ohos.permission.INTERNET`（插件模块已声明，构建时会自动合并）。
完整可运行工程见 [`example/ohos`](example/ohos)。

### Dart API 映射

| Dart API | 鸿蒙实现 |
| --- | --- |
| `hwGetToken()` | `pushService.getToken()`，即 HarmonyOS Push Token |
| `checkNotificationPermission()` | `notificationManager.isNotificationEnabled()`，返回 `granted` / `denied` |
| `requestNotificationPermission()` | `notificationManager.requestEnableNotification()`，返回 `granted` / `denied` |
| `miInit` / `oppoInit` / `vivoInit` / `appleInit` | 空实现并返回成功，鸿蒙侧统一由 Push Kit 下发 |
| `oppoRequestNotificationPermission` | 等同 `requestNotificationPermission`，返回成功（不回传状态） |
| `appleRequestAuthorizationWithOptions` | 返回 `false` |
| `appleGetSetting` | 返回 `NotDetermined` |
| `ping` | 抛出 `PlatformException('unsupported')`，仅 Android 支持 |

鸿蒙没有“未询问”状态，`checkNotificationPermission` 只会返回 `granted` 或 `denied`。

### 事件

| 事件名 | 触发时机 | `data` |
| --- | --- | --- |
| `push.receiveNotification` | 应用在前台收到通知消息（`receiveMessage('DEFAULT')`） | 服务端下发的 `data` 字段，JSON 解析后的键值；非 JSON 时放在 `data` 键 |
| `push.openNotification` | 用户点击通知（冷启动取 `launchWant`，热启动取 `onNewWant`） | `want.parameters` 的键值（已过滤 `ohos.*`、`component.*` 等系统启动参数），另附 `action` / `uri` |
| `hms.token` | Push Token 变化（`tokenUpdate`） | `token` |

`push.openNotification` 的 `data` 来自服务端 `clickAction.data`。例如服务端下发
`"clickAction": { "actionType": 1, "action": "com.test.action", "data": { "testKey": "testValue" } }`，
客户端在事件中即可取到 `event.data['testKey']`；`actionType` 为 1 时还需要在目标
Ability 的 `skills` 中声明匹配的 `actions` 或 `uris`。

监听方式与 Android / iOS 一致：

```dart
PushKit.events.listen((PushEvent event) {
  if (event.name == PushEventName.openNotification) {
    final testKey = event.data['testKey'];
  }
});
```

### 构建

```shell
cd example
flutter build hap --debug
```

未配置签名时，Flutter 会提示用 DevEco Studio 打开 `example/ohos`，在
File -> Project Structure -> Signing Configs 中勾选自动签名后再构建。

## iOS 配置

也可以通过同一个 CLI 生成 APNs 宿主配置：

```shell
dart run push_kit:setup --platforms ios
# 不传参数时保留已有 aps-environment；新建 entitlement 默认 development。
# 发布包使用 production：
dart run push_kit:setup --platforms ios --aps-environment production
```

命令会更新 `ios/Runner/Info.plist` 和 `ios/Runner/Runner.entitlements`。完整宿主工程位于 [`example/ios`](example/ios)，示例已经包含：

- `Runner/Runner.entitlements` 中的 `aps-environment` 示例值；发布环境请使用与 provisioning profile 一致的值。
- `Runner/Info.plist` 中的 `remote-notification` 后台模式。
- `Runner.xcodeproj` 对 entitlements 文件的引用。

如果命令提示 plist 不包含 `<dict>`，请确认这两个文件是有效的 XML plist，且根节点结构为
`<plist><dict>...</dict></plist>`；不要把二进制 plist 或空文件作为输入。

1. 在 Runner target 的 Signing & Capabilities 中添加 Push Notifications。
2. 如果需要后台接收通知，添加 Background Modes 并勾选 Remote notifications。
3. 在 Apple Developer 中创建 APNs 证书或 Key，并配置正确的 provisioning profile。
4. 在 App 的 `Info.plist` 和开发者后台使用一致的 Bundle ID。

推送权限由系统弹窗控制。`appleInit` 只注册远程通知，不会自动弹出授权窗口；需要授权
时显式调用 `appleRequestAuthorizationWithOptions()`。

## 使用

新增或升级插件后，请完全停止并重新启动 Flutter 应用，再订阅
`PushKit.events`。原生插件是在应用启动时由 `GeneratedPluginRegistrant` 注册的，
仅执行热重载不会重新注册插件，可能出现 `MissingPluginException`。

### 监听推送事件

建议在初始化厂商 SDK 前建立事件监听：

```dart
import 'package:push_kit/push_kit.dart';

final subscription = PushKit.events.listen((PushEvent event) {
  switch (event.name) {
    case PushEventName.receiveNotification:
      // App 前台收到通知，或后台收到静默/数据消息。
      break;
    case PushEventName.openNotification:
      // 用户点击通知后打开或唤醒 App。
      break;
    case PushEventName.appleDeviceToken:
      final token = event.data['devicetoken'];
      break;
  }
});

await subscription.cancel();
```

事件中的 `data` 是可直接序列化的 `Map<String, dynamic>`。不同厂商消息字段可能不同，
业务代码应根据事件来源和实际消息负载解析。

### 初始化推送服务

```dart
await PushKit.miInit();
await PushKit.oppoInit();
// 宿主展示并记录厂商隐私声明同意后再初始化：
await PushKit.vivoInit(true);

await PushKit.appleInit();
final authorized =
    await PushKit.appleRequestAuthorizationWithOptions();
final huaweiToken = await PushKit.hwGetToken();
```

初始化方法应在 App 启动后调用一次。vivo SDK 要求宿主先取得用户隐私声明同意，
再通过 `vivoInit(true)`（或 `vivoInit({'privacyAgreed': true})`）传入明确同意结果。
Huawei、Xiaomi、OPPO 和 vivo 的注册结果会通过
事件流返回：

```dart
PushKit.events.listen((event) {
  if (event.name == PushEventName.miRegister ||
      event.name == PushEventName.oppoRegister ||
      event.name == PushEventName.vivoRegister) {
    final registrationId = event.data['regId'];
  }
});
```

### 查询通知权限

```dart
final androidStatus = await PushKit.checkNotificationPermission();
final iosStatus = await PushKit.appleGetSetting();
```

Android 返回 `granted`、`denied` 或 `notDetermined`；iOS 返回
`Authorized`、`Denied` 或 `NotDetermined`。

### Android Ping

`ping` 使用 Android 系统 Ping 命令测试多个地址，返回每个地址的请求和响应统计：

```dart
final results = await PushKit.ping(<String>['8.8.8.8', '1.1.1.1']);
```

该接口仅支持 Android，iOS 调用会返回 `PlatformException`。

## 平台 SDK

Android 插件内置以下厂商 AAR：

| 厂商 | SDK 文件 |
| --- | --- |
| Xiaomi | `MiPush_SDK_Client_6_0_1-C_3rd.aar` |
| OPPO | `com.heytap.msp_V3.7.1.aar` |
| vivo | `vpush_clientSDK_v4.1.0.0_510.aar` |
| Huawei | Maven 依赖 `com.huawei.hms:push:6.13.0.300` |

内置二进制 SDK 可能有独立的授权和再分发条款。公开发布插件前，请确认对应厂商许可，
并在仓库中补充其许可证和版权声明。

鸿蒙端直接使用系统 Kit，不引入任何二进制依赖：

| Kit | 用途 |
| --- | --- |
| `@kit.PushKit` | 获取 Push Token、接收消息、监听 Token 变化 |
| `@kit.NotificationKit` | 通知权限查询与申请 |

## 示例与测试

示例入口：[example/lib/main.dart](example/lib/main.dart)

运行静态检查和单元测试：

```shell
flutter analyze
flutter test
```

推送能力必须在配置了对应厂商应用、签名和证书的真机上验证。模拟器无法完整验证各厂商
推送注册和 APNs 到达流程。

## License

Apache License 2.0，详见 [LICENSE](LICENSE)。
