#import "AppDelegate.h"
#import <ScriptingBridge/ScriptingBridge.h>

NSString * const TerminalNotifierBundleID = @"fr.julienxx.oss.terminal-notifier";

@implementation NSUserDefaults (SubscriptAndUnescape)
- (id)objectForKeyedSubscript:(id)key;
{
  id obj = [self objectForKey:key];
  if ([obj isKindOfClass:[NSString class]] && [(NSString *)obj hasPrefix:@"\\"]) {
    obj = [(NSString *)obj substringFromIndex:1];
  }
  return obj;
}
@end


@implementation AppDelegate {
  BOOL _responseHandled;
}

- (void)printHelpBanner;
{
  const char *appName = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"] UTF8String];
  const char *appVersion = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String];
  printf("%s (%s) is a command-line tool to send macOS User Notifications.\n" \
         "\n" \
         "Usage: %s -[message|list|remove] [VALUE|ID|ID] [options]\n" \
         "\n" \
         "   Either of these is required (unless message data is piped to the tool):\n" \
         "\n" \
         "       -help              Display this help banner.\n" \
         "       -version           Display terminal-notifier version.\n" \
         "       -message VALUE     The notification message.\n" \
         "       -remove ID         Removes a notification with the specified ‘group’ ID.\n" \
         "       -list ID           If the specified ‘group’ ID exists show when it was delivered,\n" \
         "                          or use ‘ALL’ as ID to see all notifications.\n" \
         "                          The output is a tab-separated list.\n"
         "\n" \
         "   Optional:\n" \
         "\n" \
         "       -title VALUE       The notification title. Defaults to ‘Terminal’.\n" \
         "       -subtitle VALUE    The notification subtitle.\n" \
         "       -sound NAME        The name of a sound to play when the notification appears. The names are listed\n" \
         "                          in Sound Preferences. Use 'default' for the default notification sound.\n" \
         "       -group ID          A string which identifies the group the notifications belong to.\n" \
         "                          Old notifications with the same ID will be removed.\n" \
         "       -activate ID       The bundle identifier of the application to activate when the user clicks the notification.\n" \
         "       -sender ID         (Deprecated — no-op under the UserNotifications framework.)\n" \
         "       -appIcon URL       (Deprecated — no-op under the UserNotifications framework.)\n" \
         "       -contentImage URL  The URL of an image to display attached to the notification.\n" \
         "                          Supported types: png, jpg, jpeg, gif. (.icns is NOT supported.)\n" \
         "       -open URL          The URL of a resource to open when the user clicks the notification.\n" \
         "       -execute COMMAND   A shell command to perform when the user clicks the notification.\n" \
         "       -ignoreDnD         Mark notification as time-sensitive (requires entitlement to bypass Focus/DnD).\n" \
         "\n" \
         "When the user activates a notification, the results are logged to the system logs.\n" \
         "Use Console.app to view these logs.\n" \
         "\n" \
         "Note that in some circumstances the first character of a message has to be escaped in order to be recognized.\n" \
         "An example of this is when using an open bracket, which has to be escaped like so: ‘\\[’.\n" \
         "\n" \
         "For more information see https://github.com/julienXX/terminal-notifier.\n",
         appName, appVersion, appName);
}

- (void)printVersion;
{
  const char *appName = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"] UTF8String];
  const char *appVersion = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String];
  printf("%s %s.\n", appName, appVersion);
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification;
{
  // Set the UN delegate before launch completes so click-launched responses
  // are delivered to us instead of being dropped.
  [UNUserNotificationCenter currentNotificationCenter].delegate = self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification;
{
  NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
  if ([args containsObject:@"-help"]) { [self printHelpBanner]; exit(0); }
  if ([args containsObject:@"-version"]) { [self printVersion]; exit(0); }

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSString *subtitle = defaults[@"subtitle"];
  NSString *message  = defaults[@"message"];
  NSString *remove   = defaults[@"remove"];
  NSString *list     = defaults[@"list"];
  NSString *sound    = defaults[@"sound"];

  // If there is no message and data is piped to the application, use that instead.
  // When the .app is launched by Launch Services (e.g. from a notification click),
  // stdin is /dev/null — non-tty but EOFs immediately — so the read yields @"".
  // Treat an empty read as "no message" so we fall through to the response-waiting
  // fallback rather than posting an empty notification.
  if (message == nil && !isatty(STDIN_FILENO)) {
    NSData *inputData = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    NSString *piped = [[NSString alloc] initWithData:inputData encoding:NSUTF8StringEncoding];
    if (piped.length > 0) message = piped;
  }

  if (message == nil && remove == nil && list == nil) {
    // The binary may have been re-launched in response to a notification click;
    // give the UN delegate a moment to fire didReceiveNotificationResponse:
    // before assuming this is a bare invocation that should print help.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      if (!self->_responseHandled) {
        [self printHelpBanner];
        exit(1);
      }
    });
    return;
  }

  if (list) {
    [self listNotificationWithGroupID:list];
    return;
  }

  NSMutableDictionary *options = [NSMutableDictionary dictionary];
  if (defaults[@"activate"]) options[@"bundleID"]         = defaults[@"activate"];
  if (defaults[@"group"])    options[@"groupID"]          = defaults[@"group"];
  if (defaults[@"execute"])  options[@"command"]          = defaults[@"execute"];
  if (defaults[@"contentImage"]) options[@"contentImage"] = defaults[@"contentImage"];

  if (defaults[@"open"]) {
    NSURL *url = [NSURL URLWithString:defaults[@"open"]];
    if ((url && url.scheme && url.host) || [url isFileURL]) {
      options[@"open"] = defaults[@"open"];
    } else {
      NSLog(@"'%@' is not a valid URI.", defaults[@"open"]);
      exit(1);
    }
  }

  if ([args containsObject:@"-ignoreDnD"]) {
    options[@"ignoreDnD"] = @YES;
  }

  void (^deliverIfNeeded)(void) = ^{
    if (message) {
      [self requestAuthorizationThenDeliverWithTitle:defaults[@"title"] ?: @"Terminal"
                                            subtitle:subtitle
                                             message:message
                                             options:options
                                               sound:sound];
    } else {
      exit(0);
    }
  };

  if (remove) {
    [self removeNotificationsWithGroupID:remove completion:deliverIfNeeded];
  } else {
    deliverIfNeeded();
  }
}

- (NSURL *)resolveImageURL:(NSString *)url;
{
  NSURL *imageURL = [NSURL URLWithString:url];
  if ([[imageURL scheme] length] == 0) {
    imageURL = [NSURL fileURLWithPath:url];
  }
  return imageURL;
}

- (void)requestAuthorizationThenDeliverWithTitle:(NSString *)title
                                        subtitle:(NSString *)subtitle
                                         message:(NSString *)message
                                         options:(NSDictionary *)options
                                           sound:(NSString *)sound;
{
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  UNAuthorizationOptions authOptions = UNAuthorizationOptionAlert | UNAuthorizationOptionSound;
  [center requestAuthorizationWithOptions:authOptions
                        completionHandler:^(BOOL granted, NSError * _Nullable error) {
    if (error) {
      NSLog(@"[!] Authorization request failed: %@", error.localizedDescription);
      exit(1);
    }
    if (!granted) {
      NSLog(@"[!] Notification authorization not granted. Enable notifications for terminal-notifier in System Settings.");
      exit(1);
    }
    [self deliverNotificationWithTitle:title
                              subtitle:subtitle
                               message:message
                               options:options
                                 sound:sound];
  }];
}

- (void)deliverNotificationWithTitle:(NSString *)title
                            subtitle:(NSString *)subtitle
                             message:(NSString *)message
                             options:(NSDictionary *)options
                               sound:(NSString *)sound;
{
  UNMutableNotificationContent *content = [UNMutableNotificationContent new];
  content.title = title ?: @"";
  if (subtitle) content.subtitle = subtitle;
  content.body = message ?: @"";
  content.userInfo = options;

  if (sound != nil) {
    content.sound = [sound isEqualToString:@"default"]
        ? [UNNotificationSound defaultSound]
        : [UNNotificationSound soundNamed:sound];
  }

  if (options[@"contentImage"]) {
    NSURL *imageURL = [self resolveImageURL:options[@"contentImage"]];
    NSError *attachErr = nil;
    UNNotificationAttachment *attachment =
      [UNNotificationAttachment attachmentWithIdentifier:@"contentImage"
                                                     URL:imageURL
                                                 options:nil
                                                   error:&attachErr];
    if (attachment) {
      content.attachments = @[attachment];
    } else {
      NSLog(@"[!] Failed to attach contentImage: %@", attachErr.localizedDescription);
    }
  }

  if (options[@"ignoreDnD"]) {
    if (@available(macOS 12.0, *)) {
      content.interruptionLevel = UNNotificationInterruptionLevelTimeSensitive;
    }
  }

  // Use the group ID as the request identifier so re-sending the same group
  // replaces the existing notification, matching the historical behavior.
  NSString *identifier = options[@"groupID"] ?: [[NSUUID UUID] UUIDString];
  UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                       content:content
                                                                       trigger:nil];

  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  [center addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
    if (error) {
      NSLog(@"[!] Failed to deliver notification: %@", error.localizedDescription);
      exit(1);
    }
    exit(0);
  }];
}

- (void)removeNotificationsWithGroupID:(NSString *)groupID
                            completion:(void (^)(void))completion;
{
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (UNNotification *n in notifications) {
      NSString *deliveredGroupID = n.request.content.userInfo[@"groupID"];
      if ([@"ALL" isEqualToString:groupID] || [deliveredGroupID isEqualToString:groupID]) {
        [identifiers addObject:n.request.identifier];
        printf("* Removing previously sent notification, which was sent on: %s\n",
               [[n.date description] UTF8String]);
      }
    }
    if (identifiers.count > 0) {
      [center removeDeliveredNotificationsWithIdentifiers:identifiers];
    }
    dispatch_async(dispatch_get_main_queue(), completion);
  }];
}

- (void)listNotificationWithGroupID:(NSString *)listGroupID;
{
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (UNNotification *n in notifications) {
      NSString *deliveredGroupID = n.request.content.userInfo[@"groupID"];
      if ([@"ALL" isEqualToString:listGroupID] || [deliveredGroupID isEqualToString:listGroupID]) {
        [lines addObject:[NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@",
                          deliveredGroupID ?: @"",
                          n.request.content.title ?: @"",
                          n.request.content.subtitle ?: @"",
                          n.request.content.body ?: @"",
                          [n.date description]]];
      }
    }
    if (lines.count > 0) {
      printf("GroupID\tTitle\tSubtitle\tMessage\tDelivered At\n");
      for (NSString *line in lines) {
        printf("%s\n", [line UTF8String]);
      }
    }
    exit(0);
  }];
}

#pragma mark - UNUserNotificationCenterDelegate

// Show the banner even if our (short-lived) app is foreground when delivery happens.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler;
{
  completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

// Invoked when the user clicks a delivered notification (relaunches the app).
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler;
{
  _responseHandled = YES;

  UNNotification *userNotification = response.notification;
  NSDictionary *userInfo = userNotification.request.content.userInfo;
  NSString *groupID  = userInfo[@"groupID"];
  NSString *bundleID = userInfo[@"bundleID"];
  NSString *command  = userInfo[@"command"];
  NSString *open     = userInfo[@"open"];

  NSLog(@"User activated notification:");
  NSLog(@" group ID: %@", groupID);
  NSLog(@"    title: %@", userNotification.request.content.title);
  NSLog(@" subtitle: %@", userNotification.request.content.subtitle);
  NSLog(@"  message: %@", userNotification.request.content.body);
  NSLog(@"bundle ID: %@", bundleID);
  NSLog(@"  command: %@", command);
  NSLog(@"     open: %@", open);

  BOOL success = YES;
  if (bundleID) success &= [self activateAppWithBundleID:bundleID];
  if (command)  success &= [self executeShellCommand:command];
  if (open)     success &= [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:open]];

  completionHandler();
  exit(success ? 0 : 1);
}

- (BOOL)activateAppWithBundleID:(NSString *)bundleID;
{
  id app = [SBApplication applicationWithBundleIdentifier:bundleID];
  if (app) {
    [app activate];
    return YES;

  } else {
    NSLog(@"Unable to find an application with the specified bundle indentifier.");
    return NO;
  }
}

- (BOOL)executeShellCommand:(NSString *)command;
{
  NSPipe *pipe = [NSPipe pipe];
  NSFileHandle *fileHandle = [pipe fileHandleForReading];

  NSTask *task = [NSTask new];
  task.launchPath = @"/bin/sh";
  task.arguments = @[@"-c", command];
  task.standardOutput = pipe;
  task.standardError = pipe;
  [task launch];

  NSData *data = nil;
  NSMutableData *accumulatedData = [NSMutableData data];
  while ((data = [fileHandle availableData]) && [data length]) {
    [accumulatedData appendData:data];
  }

  [task waitUntilExit];
  NSLog(@"command output:\n%@", [[NSString alloc] initWithData:accumulatedData encoding:NSUTF8StringEncoding]);
  return [task terminationStatus] == 0;
}

@end
