#import "PushKitPlugin.h"
#import <UIKit/UIKit.h>

static const NSUInteger PushKitMaximumPendingEvents = 32;

@interface PushKitPlugin ()
@property(nonatomic, strong) FlutterMethodChannel *methodChannel;
@property(nonatomic, strong) FlutterEventChannel *eventChannel;
@property(nonatomic, copy) FlutterEventSink eventSink;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *pendingEvents;
@property(nonatomic, weak) id<UNUserNotificationCenterDelegate> previousNotificationDelegate;
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
    [registrar addMethodCallDelegate:plugin channel:methods];
    [events setStreamHandler:plugin];
    [registrar addApplicationDelegate:plugin];
    // Install early enough to receive a foreground notification delivered
    // during application launch, while retaining and forwarding the host's
    // existing delegate.
    [plugin ensureNotificationDelegate];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pendingEvents = [NSMutableArray arrayWithCapacity:PushKitMaximumPendingEvents];
    }
    return self;
}

- (void)dealloc {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    if (center.delegate == self) {
        center.delegate = self.previousNotificationDelegate;
    }
    self.eventSink = nil;
    [self.pendingEvents removeAllObjects];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"is_available"]) {
        result(@YES);
        return;
    }

    if ([call.method isEqualToString:@"apple_init"]) {
        [self ensureNotificationDelegate];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] registerForRemoteNotifications];
            result(nil);
        });
        return;
    }

    if ([call.method isEqualToString:@"apple_requestAuthorizationWithOptions"]) {
        [self ensureNotificationDelegate];
        BOOL hasCustomOptions = NO;
        UNAuthorizationOptions options = [self authorizationOptionsForArgument:call.arguments
                                                                        found:&hasCustomOptions];
        if (!hasCustomOptions) {
            options = UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                    | UNAuthorizationOptionBadge;
        }
        [[UNUserNotificationCenter currentNotificationCenter]
         requestAuthorizationWithOptions:options
         completionHandler:^(BOOL granted, NSError *error) {
             dispatch_async(dispatch_get_main_queue(), ^{
                 if (error) {
                     result([FlutterError errorWithCode:@"AUTHORIZATION_FAILED"
                                                message:error.localizedDescription
                                                details:nil]);
                 } else {
                     result(@(granted));
                 }
             });
         }];
        return;
    }

    if ([call.method isEqualToString:@"requestNotificationPermission"]) {
        [self ensureNotificationDelegate];
        UNAuthorizationOptions options = UNAuthorizationOptionAlert
                | UNAuthorizationOptionSound | UNAuthorizationOptionBadge;
        [[UNUserNotificationCenter currentNotificationCenter]
         requestAuthorizationWithOptions:options
         completionHandler:^(BOOL granted, NSError *error) {
             dispatch_async(dispatch_get_main_queue(), ^{
                 if (error) {
                     result([FlutterError errorWithCode:@"AUTHORIZATION_FAILED"
                                                message:error.localizedDescription
                                                details:nil]);
                 } else {
                     result(granted ? @"granted" : @"denied");
                 }
             });
         }];
        return;
    }

    if ([call.method isEqualToString:@"apple_getsetting"]
            || [call.method isEqualToString:@"checkNotificationPermission"]) {
        [[UNUserNotificationCenter currentNotificationCenter]
         getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
             NSString *status = [self statusForAuthorization:settings.authorizationStatus];
             if ([call.method isEqualToString:@"checkNotificationPermission"]) {
                 if ([status isEqualToString:@"Authorized"]) {
                     status = @"granted";
                 } else if ([status isEqualToString:@"Denied"]) {
                     status = @"denied";
                 } else {
                     status = @"notDetermined";
                 }
             }
             dispatch_async(dispatch_get_main_queue(), ^{
                 result(status);
             });
         }];
        return;
    }

    if ([call.method isEqualToString:@"ping"]) {
        result([FlutterError errorWithCode:@"UNSUPPORTED"
                                   message:@"ping is only available on Android"
                                   details:nil]);
        return;
    }

    if ([call.method isEqualToString:@"hw_getToken"]
            || [call.method isEqualToString:@"mi_init"]
            || [call.method isEqualToString:@"oppo_init"]
            || [call.method isEqualToString:@"vivo_init"]
            || [call.method isEqualToString:@"oppo_requestNotificationPermission"]) {
        result(nil);
        return;
    }

    result(FlutterMethodNotImplemented);
}

- (NSString *)statusForAuthorization:(UNAuthorizationStatus)status {
    if (status == UNAuthorizationStatusAuthorized
            || status == UNAuthorizationStatusProvisional) {
        return @"Authorized";
    }
    if (@available(iOS 14.0, *)) {
        if (status == UNAuthorizationStatusEphemeral) {
            return @"Authorized";
        }
    }
    if (status == UNAuthorizationStatusDenied) {
        return @"Denied";
    }
    return @"NotDetermined";
}

- (FlutterError *)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events {
    self.eventSink = events;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<NSDictionary *> *buffer = [self.pendingEvents copy];
        [self.pendingEvents removeAllObjects];
        FlutterEventSink sink = self.eventSink;
        if (!sink) {
            for (NSDictionary *event in buffer) {
                if (self.pendingEvents.count >= PushKitMaximumPendingEvents) {
                    [self.pendingEvents removeObjectAtIndex:0];
                }
                [self.pendingEvents addObject:event];
            }
            return;
        }
        for (NSDictionary *event in buffer) sink(event);
    });
    return nil;
}

- (FlutterError *)onCancelWithArguments:(id)arguments {
    self.eventSink = nil;
    return nil;
}

- (void)emit:(NSString *)name data:(NSDictionary *)data {
    NSDictionary *safeData = [self codecSafeDictionary:data];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *event = @{
            @"name": name ?: @"",
            @"data": safeData ?: @{}
        };
        FlutterEventSink sink = self.eventSink;
        if (sink) {
            sink(event);
            return;
        }
        if (self.pendingEvents.count >= PushKitMaximumPendingEvents) {
            [self.pendingEvents removeObjectAtIndex:0];
        }
        [self.pendingEvents addObject:event];
    });
}

- (void)ensureNotificationDelegate {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    id<UNUserNotificationCenterDelegate> current = center.delegate;
    if (current != self) {
        self.previousNotificationDelegate = current;
        center.delegate = self;
    }
}

- (UNAuthorizationOptions)authorizationOptionsForArgument:(id)argument
                                                     found:(BOOL *)found {
    if (!argument || argument == [NSNull null]) {
        if (found) *found = NO;
        return 0;
    }
    if ([argument isKindOfClass:[NSNumber class]]) {
        if (found) *found = YES;
        return (UNAuthorizationOptions)[argument unsignedIntegerValue];
    }
    if ([argument isKindOfClass:[NSDictionary class]]) {
        id nested = argument[@"options"] ?: argument[@"authorizationOptions"];
        if (nested) {
            return [self authorizationOptionsForArgument:nested found:found];
        }
        if (found) *found = YES;
        UNAuthorizationOptions options = 0;
        for (NSString *key in argument) {
            id enabled = argument[key];
            if (![enabled boolValue]) continue;
            NSArray *single = @[key];
            options |= [self authorizationOptionsForArgument:single found:NULL];
        }
        return options;
    }
    if ([argument isKindOfClass:[NSArray class]]) {
        if (found) *found = YES;
        UNAuthorizationOptions options = 0;
        for (id value in (NSArray *)argument) {
            if (![value isKindOfClass:[NSString class]]) continue;
            NSString *name = [(NSString *)value lowercaseString];
            if ([name isEqualToString:@"alert"]) options |= UNAuthorizationOptionAlert;
            else if ([name isEqualToString:@"sound"]) options |= UNAuthorizationOptionSound;
            else if ([name isEqualToString:@"badge"]) options |= UNAuthorizationOptionBadge;
            else if ([name isEqualToString:@"carplay"]) options |= UNAuthorizationOptionCarPlay;
            else if ([name isEqualToString:@"provisional"]) {
                if (@available(iOS 12.0, *)) options |= UNAuthorizationOptionProvisional;
            }
            else if ([name isEqualToString:@"criticalalert"]) {
                if (@available(iOS 12.0, *)) options |= UNAuthorizationOptionCriticalAlert;
            }
            else if ([name isEqualToString:@"providesappnotificationsettings"]) {
                if (@available(iOS 12.0, *)) options |= UNAuthorizationOptionProvidesAppNotificationSettings;
            }
            else if ([name isEqualToString:@"announcement"]) {
                if (@available(iOS 13.0, *)) options |= UNAuthorizationOptionAnnouncement;
            }
        }
        return options;
    }
    if ([argument isKindOfClass:[NSString class]]) {
        return [self authorizationOptionsForArgument:@[argument] found:found];
    }
    if (found) *found = NO;
    return 0;
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler API_AVAILABLE(ios(10.0)) {
    [self emit:@"push.localNotification"
           data:notification.request.content.userInfo ?: @{}];

    id<UNUserNotificationCenterDelegate> delegate = self.previousNotificationDelegate;
    if (delegate && delegate != self
            && [delegate respondsToSelector:@selector(userNotificationCenter:willPresentNotification:withCompletionHandler:)]) {
        [delegate userNotificationCenter:center
                 willPresentNotification:notification
                   withCompletionHandler:completionHandler];
        return;
    }
    UNNotificationPresentationOptions options = UNNotificationPresentationOptionBadge
            | UNNotificationPresentationOptionSound;
    if (@available(iOS 14.0, *)) {
        options |= UNNotificationPresentationOptionBanner;
    } else {
        options |= UNNotificationPresentationOptionAlert;
    }
    if (completionHandler) completionHandler(options);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
          withCompletionHandler:(void (^)(void))completionHandler API_AVAILABLE(ios(10.0)) {
    [self emit:@"push.openNotification"
           data:response.notification.request.content.userInfo ?: @{}];

    id<UNUserNotificationCenterDelegate> delegate = self.previousNotificationDelegate;
    if (delegate && delegate != self
            && [delegate respondsToSelector:@selector(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:)]) {
        [delegate userNotificationCenter:center
           didReceiveNotificationResponse:response
                    withCompletionHandler:completionHandler];
        return;
    }
    if (completionHandler) completionHandler();
}

- (void)application:(UIApplication *)application
 didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    const unsigned char *bytes = deviceToken.bytes;
    NSMutableString *token = [NSMutableString stringWithCapacity:deviceToken.length * 2];
    for (NSUInteger index = 0; index < deviceToken.length; index++) {
        [token appendFormat:@"%02x", bytes[index]];
    }
    [self emit:@"applepush.didRegisterForRemoteNotificationsWithDeviceToken"
           data:@{ @"devicetoken": token }];
}

- (void)application:(UIApplication *)application
 didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    [self emit:@"push.registrationError"
           data:@{ @"code": @(error.code),
                   @"message": error.localizedDescription ?: @"" }];
}

- (BOOL)application:(UIApplication *)application
 didReceiveRemoteNotification:(NSDictionary *)userInfo
 fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    // This callback also represents silent/background data delivery. A user
    // click is reported only by didReceiveNotificationResponse below.
    NSString *event = application.applicationState == UIApplicationStateActive
            ? @"push.localNotification" : @"push.receiveNotification";
    [self emit:event data:userInfo ?: @{}];
    if (completionHandler) completionHandler(UIBackgroundFetchResultNewData);
    return YES;
}

- (BOOL)application:(UIApplication *)application
 didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [self emit:@"push.finishLaunching" data:launchOptions ?: @{}];
    return YES;
}

- (NSDictionary *)codecSafeDictionary:(NSDictionary *)dictionary {
    if (!dictionary) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:dictionary.count];
    [dictionary enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]]) return;
        result[key] = [self codecSafeValue:value] ?: [NSNull null];
    }];
    return result;
}

- (id)codecSafeValue:(id)value {
    if (!value || value == [NSNull null]
            || [value isKindOfClass:[NSString class]]
            || [value isKindOfClass:[NSNumber class]]
            || [value isKindOfClass:[NSData class]]) {
        return value ?: [NSNull null];
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        return [self codecSafeDictionary:value];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:[value count]];
        for (id item in (NSArray *)value) {
            [items addObject:[self codecSafeValue:item] ?: [NSNull null]];
        }
        return items;
    }
    return [value description] ?: @"";
}

@end
