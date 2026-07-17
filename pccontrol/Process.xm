#include "Process.h"
#include "Common.h"
#include <roothide.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <objc/message.h>

extern char **environ;

typedef id (*ZXMsgSendIdNoArg)(id, SEL);
typedef id (*ZXMsgSendIdObject)(id, SEL, id);
typedef void (*ZXMsgSendVoidNoArg)(id, SEL);
typedef BOOL (*ZXMsgSendBoolNoArg)(id, SEL);
typedef void (*ZXMsgSendVoidObjectIntBoolObject)(id, SEL, id, int, BOOL, id);

int (*openApp)(CFStringRef, Boolean);

static void* sbServices = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);

int switchProcessForegroundFromRawData(UInt8 *eventData)
{
    return bringAppForeground([NSString stringWithFormat:@"%s", eventData]);
}

int bringAppForeground(NSString *appIdentifier)
{
    CFStringRef appBundleName = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@"), appIdentifier);
    //[NSString stringWithFormat:@"%s", eventData];
    NSLog(@"### com.zjx.springboard: Switch to application: %@", appBundleName);
    if (!openApp)
        openApp = (int(*)(CFStringRef, Boolean))dlsym(sbServices,"SBSLaunchApplicationWithIdentifier");

    return openApp(appBundleName, false);
}

static NSString *processJSONString(NSDictionary *dictionary)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

static void processSetError(NSError **error, NSString *message)
{
    if (!error) return;
    *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp.process" code:999 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"-1;;%@\r\n", message ?: @"Unknown process error."]
    }];
}

static id runningApplicationForBundleIdentifier(NSString *bundleIdentifier)
{
    __block id result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            SpringBoard *springboard = (SpringBoard*)[%c(SpringBoard) sharedApplication];
            NSArray *candidates = @[
                @"_accessibilityRunningApplications",
                @"runningApplications",
                @"_runningApplications"
            ];
            for (NSString *selectorName in candidates) {
                SEL selector = NSSelectorFromString(selectorName);
                if (![springboard respondsToSelector:selector]) continue;
                NSArray *apps = ((ZXMsgSendIdNoArg)objc_msgSend)(springboard, selector);
                for (id app in apps) {
                    NSString *candidateBundleID = nil;
                    if ([app respondsToSelector:@selector(bundleIdentifier)]) candidateBundleID = [app bundleIdentifier];
                    else if ([app respondsToSelector:@selector(displayIdentifier)]) candidateBundleID = [app displayIdentifier];
                    if ([candidateBundleID isEqualToString:bundleIdentifier]) {
                        result = app;
                        return;
                    }
                }
            }
        }
        @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: close app lookup failed: %@", exception.reason);
        }
    });
    return result;
}

static NSString *executableNameForBundleIdentifier(NSString *bundleIdentifier)
{
    __block NSString *executableName = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            Class controllerClass = NSClassFromString(@"SBApplicationController");
            id controller = nil;
            if ([controllerClass respondsToSelector:@selector(sharedInstance)]) {
                controller = ((ZXMsgSendIdNoArg)objc_msgSend)(controllerClass, @selector(sharedInstance));
            }
            id appInfo = nil;
            if ([controller respondsToSelector:@selector(applicationWithBundleIdentifier:)]) {
                appInfo = ((ZXMsgSendIdObject)objc_msgSend)(controller, @selector(applicationWithBundleIdentifier:), bundleIdentifier);
            }
            if (!appInfo && [controller respondsToSelector:@selector(applicationWithDisplayIdentifier:)]) {
                appInfo = ((ZXMsgSendIdObject)objc_msgSend)(controller, @selector(applicationWithDisplayIdentifier:), bundleIdentifier);
            }
            if (!appInfo && [controller respondsToSelector:@selector(appInfoForDisplayID:)]) {
                appInfo = ((ZXMsgSendIdObject)objc_msgSend)(controller, @selector(appInfoForDisplayID:), bundleIdentifier);
            }
            if ([appInfo respondsToSelector:@selector(executableName)]) {
                executableName = ((ZXMsgSendIdNoArg)objc_msgSend)(appInfo, @selector(executableName));
            }
            else if ([appInfo respondsToSelector:@selector(bundleExecutable)]) {
                executableName = ((ZXMsgSendIdNoArg)objc_msgSend)(appInfo, @selector(bundleExecutable));
            }
        }
        @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: executable lookup failed: %@", exception.reason);
        }
    });
    return executableName;
}

static BOOL terminateRunningApplication(id app)
{
    if (!app) return NO;
    __block BOOL attempted = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            NSArray *selectors = @[
                @"kill",
                @"terminate",
                @"terminateWithReason:",
                @"killForReason:andReport:withDescription:"
            ];
            for (NSString *selectorName in selectors) {
                SEL selector = NSSelectorFromString(selectorName);
                if (![app respondsToSelector:selector]) continue;
                attempted = YES;
                if ([selectorName isEqualToString:@"terminateWithReason:"]) {
                    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[app methodSignatureForSelector:selector]];
                    int reason = 1;
                    [invocation setSelector:selector];
                    [invocation setTarget:app];
                    [invocation setArgument:&reason atIndex:2];
                    [invocation invoke];
                } else if ([selectorName isEqualToString:@"killForReason:andReport:withDescription:"]) {
                    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[app methodSignatureForSelector:selector]];
                    int reason = 1;
                    BOOL report = NO;
                    NSString *description = @"ZXTouch close_app";
                    [invocation setSelector:selector];
                    [invocation setTarget:app];
                    [invocation setArgument:&reason atIndex:2];
                    [invocation setArgument:&report atIndex:3];
                    [invocation setArgument:&description atIndex:4];
                    [invocation invoke];
                } else {
                    ((ZXMsgSendVoidNoArg)objc_msgSend)(app, selector);
                }
                return;
            }
        }
        @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: terminate app failed: %@", exception.reason);
        }
    });
    return attempted;
}

static BOOL terminateBundleIdentifierWithFrontBoard(NSString *bundleIdentifier)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY | RTLD_GLOBAL);
    });

    Class serviceClass = NSClassFromString(@"FBSSystemService");
    if (![serviceClass respondsToSelector:@selector(sharedService)]) return NO;

    id service = ((ZXMsgSendIdNoArg)objc_msgSend)(serviceClass, @selector(sharedService));
    SEL selector = @selector(terminateApplication:forReason:andReport:withDescription:);
    if (!service || ![service respondsToSelector:selector]) return NO;

    @try {
        int reason = 1;
        BOOL report = NO;
        NSString *description = @"ZXTouch close_app";
        ((ZXMsgSendVoidObjectIntBoolObject)objc_msgSend)(service, selector, bundleIdentifier, reason, report, description);
        return YES;
    }
    @catch (NSException *exception) {
        NSLog(@"com.zjx.springboard: FrontBoard terminate failed: %@", exception.reason);
        return NO;
    }
}

static BOOL killExecutableName(NSString *executableName)
{
    if (executableName.length == 0) return NO;
    pid_t pid = 0;
    NSString *killallPath = jbroot(@"/usr/bin/killall");
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:killallPath]) killallPath = @"/usr/bin/killall";
    const char *argv[] = {killallPath.UTF8String, executableName.UTF8String, NULL};
    int status = posix_spawn(&pid, killallPath.UTF8String, NULL, NULL, (char * const *)argv, environ);
    if (status != 0) return NO;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

NSString *closeAppFromRawData(UInt8 *eventData, NSError **error)
{
    NSString *bundleIdentifier = [NSString stringWithFormat:@"%s", eventData];
    return closeAppWithBundleIdentifier(bundleIdentifier, error);
}

NSString *closeAppWithBundleIdentifier(NSString *bundleIdentifier, NSError **error)
{
    if (bundleIdentifier.length == 0) {
        processSetError(error, @"Missing bundle identifier.");
        return nil;
    }

    BOOL terminated = terminateBundleIdentifierWithFrontBoard(bundleIdentifier);
    NSString *method = terminated ? @"frontboard" : @"";

    if (!terminated) {
        id app = runningApplicationForBundleIdentifier(bundleIdentifier);
        terminated = terminateRunningApplication(app);
        method = terminated ? @"springboard" : @"";
    }

    if (!terminated) {
        NSString *executableName = executableNameForBundleIdentifier(bundleIdentifier);
        terminated = killExecutableName(executableName);
        method = terminated ? @"killall" : @"";
    }

    if (!terminated) {
        processSetError(error, [NSString stringWithFormat:@"Unable to close app: %@", bundleIdentifier]);
        return nil;
    }

    return processJSONString(@{ @"closed": @YES, @"bundle_id": bundleIdentifier, @"method": method });
}

NSString *ensureScreenActive(NSError **error)
{
    __block BOOL attempted = NO;
    __block BOOL wasLocked = NO;
    __block BOOL isLockedAfter = NO;

    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            SpringBoard *springboard = (SpringBoard*)[%c(SpringBoard) sharedApplication];
            if ([springboard respondsToSelector:@selector(isLocked)]) {
                wasLocked = ((ZXMsgSendBoolNoArg)objc_msgSend)(springboard, @selector(isLocked));
            }

            NSArray<NSString *> *selectors = @[
                @"wakeUp",
                @"_wakeUp",
                @"wakeUpForReason:",
                @"turnOnScreenFullyWithBacklightSource:"
            ];

            for (NSString *selectorName in selectors) {
                SEL selector = NSSelectorFromString(selectorName);
                if (![springboard respondsToSelector:selector]) continue;
                attempted = YES;
                if ([selectorName hasSuffix:@":"]) {
                    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[springboard methodSignatureForSelector:selector]];
                    int reason = 1;
                    [invocation setSelector:selector];
                    [invocation setTarget:springboard];
                    [invocation setArgument:&reason atIndex:2];
                    [invocation invoke];
                } else {
                    ((ZXMsgSendVoidNoArg)objc_msgSend)(springboard, selector);
                }
                break;
            }

            if ([springboard respondsToSelector:@selector(isLocked)]) {
                isLockedAfter = ((ZXMsgSendBoolNoArg)objc_msgSend)(springboard, @selector(isLocked));
            }
        }
        @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: ensure screen active failed: %@", exception.reason);
        }
    });

    if (!attempted) {
        processSetError(error, @"Unable to wake screen: no supported SpringBoard wake selector found.");
        return nil;
    }

    return processJSONString(@{
        @"screen_active": @YES,
        @"was_locked": @(wasLocked),
        @"is_locked": @(isLockedAfter),
        @"method": @"springboard"
    });
}

id getFrontMostApplication()
{
    //TODO: might cause problem here. Both _accessibilityFrontMostApplication failed or front most application springboard will cause app be nil.
    __block id app = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try{
            SpringBoard *springboard = (SpringBoard*)[%c(SpringBoard) sharedApplication];
            app = [springboard _accessibilityFrontMostApplication];
            //NSLog(@"com.zjx.springboard: app: %@, id: %@", app, [app displayIdentifier]);
        }
        @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
        }
        });
    return app;
}
