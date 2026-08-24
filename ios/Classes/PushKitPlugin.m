#import "PushKitPlugin.h"
#import <UserNotifications/UserNotifications.h>
#import <UIKit/UIKit.h>

static __weak PushKitPlugin *PushKitSharedPlugin;

@interface PushKitPlugin ()
@property(nonatomic, strong) FlutterMethodChannel *methodChannel;
@property(nonatomic, strong) FlutterEventChannel *eventChannel;
@property(nonatomic, copy) FlutterEventSink eventSink;
@end

@implementation PushKitPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *methods = [FlutterMethodChannel methodChannelWithName:@"push_kit/methods"
                                                                binaryMessenger:registrar.messenger];
    FlutterEventChannel *events = [FlutterEventChannel eventChannelWithName:@"push_kit/events"
                                                              binaryMessenger:registrar.messenger];
    PushKitPlugin *plugin = [[PushKitPlugin alloc] init];
    plugin.methodChannel = methods;
    plugin.eventChannel = events;
    PushKitSharedPlugin = plugin;
    [registrar addMethodCallDelegate:plugin channel:methods];
    [events setStreamHandler:plugin];
    [registrar addApplicationDelegate:plugin];
}

- (FlutterError *)checkReady {
    return nil;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"apple_init"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] registerForRemoteNotifications];
            result(nil);
        });
    } else if ([call.method isEqualToString:@"apple_requestAuthorizationWithOptions"]) {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        center.delegate = self;
        [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                              completionHandler:^(BOOL granted, NSError *error) {
            if (error) { result([FlutterError errorWithCode:@"AUTHORIZATION_FAILED" message:error.localizedDescription details:nil]); return; }
            result(@(granted));
        }];
    } else if ([call.method isEqualToString:@"requestNotificationPermission"]) {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        center.delegate = self;
        [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                              completionHandler:^(BOOL granted, NSError *error) {
            if (error) { result([FlutterError errorWithCode:@"AUTHORIZATION_FAILED" message:error.localizedDescription details:nil]); return; }
            result(granted ? @"granted" : @"denied");
        }];
    } else if ([call.method isEqualToString:@"apple_getsetting"] ||
               [call.method isEqualToString:@"checkNotificationPermission"]) {
        [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            NSString *status = [self statusForAuthorization:settings.authorizationStatus];
            if ([call.method isEqualToString:@"checkNotificationPermission"]) {
                status = [status lowercaseString];
                if ([status isEqualToString:@"notdetermined"]) status = @"notDetermined";
            }
            result(status);
        }];
    } else if ([call.method isEqualToString:@"ping"]) {
        result([FlutterError errorWithCode:@"UNSUPPORTED" message:@"ping is only available on Android" details:nil]);
    } else if ([call.method isEqualToString:@"hw_getToken"] || [call.method hasSuffix:@"_init"] ||
               [call.method isEqualToString:@"oppo_requestNotificationPermission"]) {
        result(nil);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (NSString *)statusForAuthorization:(UNAuthorizationStatus)status {
    if (status == UNAuthorizationStatusAuthorized || status == UNAuthorizationStatusProvisional || status == UNAuthorizationStatusEphemeral) return @"Authorized";
    if (status == UNAuthorizationStatusDenied) return @"Denied";
    return @"NotDetermined";
}

- (FlutterError *)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events {
    self.eventSink = events;
    return nil;
}

- (FlutterError *)onCancelWithArguments:(id)arguments {
    self.eventSink = nil;
    return nil;
}

- (void)emit:(NSString *)name data:(NSDictionary *)data {
    FlutterEventSink sink = self.eventSink;
    if (!sink) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        sink(@{ @"name": name, @"data": data ?: @{} });
    });
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    const unsigned char *bytes = deviceToken.bytes;
    NSMutableString *token = [NSMutableString string];
    for (NSUInteger i = 0; i < deviceToken.length; i++) [token appendFormat:@"%02x", bytes[i]];
    [self emit:@"applepush.didRegisterForRemoteNotificationsWithDeviceToken" data:@{ @"devicetoken": token }];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    [self emit:@"push.registrationError" data:@{ @"code": @(error.code), @"message": error.localizedDescription ?: @"" }];
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    NSString *event = UIApplication.sharedApplication.applicationState == UIApplicationStateActive
        ? @"push.localNotification" : @"push.openNotification";
    [self emit:event data:userInfo ?: @{}];
    if (completionHandler) completionHandler(UIBackgroundFetchResultNewData);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler API_AVAILABLE(ios(10.0)) {
    [self emit:@"push.localNotification" data:notification.request.content.userInfo ?: @{}];
    if (completionHandler) completionHandler(UNNotificationPresentationOptionBadge | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionBanner);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
          withCompletionHandler:(void (^)(void))completionHandler API_AVAILABLE(ios(10.0)) {
    [self emit:@"push.openNotification" data:response.notification.request.content.userInfo ?: @{}];
    if (completionHandler) completionHandler();
}

- (void)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [self emit:@"push.finishLaunching" data:launchOptions ?: @{}];
}

@end
