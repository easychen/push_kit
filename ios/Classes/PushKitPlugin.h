#import <Flutter/Flutter.h>
#import <UserNotifications/UserNotifications.h>

@interface PushKitPlugin : NSObject <FlutterPlugin, FlutterStreamHandler, UNUserNotificationCenterDelegate>
@end
