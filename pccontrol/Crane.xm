#import "Crane.h"
#import "Process.h"
#include <dlfcn.h>
#include <roothide.h>

@interface CraneManager : NSObject
+ (instancetype)sharedManager;
- (NSDictionary *)preferencesCopy;
- (BOOL)isApplicationSupportedByCrane:(NSString *)applicationID;
- (NSArray *)identfiersOfApplicationsThatHaveNonDefaultContainers;
- (NSArray *)identifiersOfAllSupportedApplications;
- (NSString *)displayNameForApplicationWithIdentifier:(NSString *)applicationID;
- (NSDictionary *)applicationSettingsForApplicationWithIdentifier:(NSString *)applicationID;
- (void)setApplicationSettings:(NSDictionary *)appSettings forApplicationWithIdentifier:(NSString *)applicationID;
- (NSString *)activeContainerIdentifierForApplicationWithIdentifier:(NSString *)applicationID;
- (void)setActiveContainerIdentifier:(NSString *)containerID forApplicationWithIdentifier:(NSString *)applicationID;
- (NSArray *)containerIdentifiersOfApplicationWithIdentifier:(NSString *)applicationID;
- (void)createNewContainerWithName:(NSString *)containerName andIdentifier:(NSString *)containerID forApplicationWithIdentifier:(NSString *)applicationID;
- (NSString *)createNewContainerWithName:(NSString *)containerName forApplicationWithIdentifier:(NSString *)applicationID;
- (void)deleteContentOfContainerWithIdentifier:(NSString *)containerID forApplicationWithIdentifier:(NSString *)applicationID;
- (void)deleteContainerWithIdentifier:(NSString *)containerID forApplicationWithIdentifier:(NSString *)applicationID;
- (void)wipeContainerWithIdentifier:(NSString *)containerID forApplicationWithIdentifier:(NSString *)applicationID shouldRepopulate:(BOOL)repopulate;
- (NSString *)makeDefaultForContainerWithIdentifier:(NSString *)containerID forApplicationWithIdentifier:(NSString *)applicationID;
- (NSDictionary *)containerSettingsForContainerWithIdentifier:(NSString *)containerID ofApplicationWithIdentifier:(NSString *)applicationID;
- (void)setContainerSettings:(NSDictionary *)containerSettings forContainerWithIdentifier:(NSString *)containerID ofApplicationWithIdentifier:(NSString *)applicationID;
- (NSString *)displayNameForContainerWithIdentifier:(NSString *)containerID ofApplicationWithIdentifier:(NSString *)applicationID shouldUseShortVersion:(BOOL)shortVersion;
- (void)flushCFPrefsdCacheForApplicationWithIdentifier:(NSString *)applicationID;
- (void)reloadApplicationWithIdentifier:(NSString *)applicationID;
@end

static void ZXCraneSetError(NSError **error, NSString *message)
{
    if (!error) return;
    *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp.crane" code:999 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"-1;;%@\r\n", message ?: @"Unknown Crane error."]
    }];
}

static NSString *ZXCraneJSONString(id object)
{
    if (!object) object = @{};
    if (![NSJSONSerialization isValidJSONObject:object]) return @"{}";
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

static NSDictionary *ZXCraneBase64JSONDictionary(NSString *value)
{
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:value options:0];
    if (!decodedData) return @{};
    id object = [NSJSONSerialization JSONObjectWithData:decodedData options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : @{};
}

static CraneManager *ZXCraneManager(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *paths = @[
            jbroot(@"/usr/lib/libcrane.dylib"),
            @"/var/jb/usr/lib/libcrane.dylib",
            @"/usr/lib/libcrane.dylib",
            @"/Library/MobileSubstrate/DynamicLibraries/Crane.dylib",
            jbroot(@"/Library/MobileSubstrate/DynamicLibraries/Crane.dylib")
        ];
        for (NSString *path in paths) {
            if (path.length > 0) dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
        }
    });

    Class managerClass = NSClassFromString(@"CraneManager");
    if (!managerClass || ![managerClass respondsToSelector:@selector(sharedManager)]) return nil;
    return [managerClass sharedManager];
}

static NSArray *ZXCraneArguments(UInt8 *eventData)
{
    NSString *raw = [NSString stringWithFormat:@"%s", eventData];
    return [raw componentsSeparatedByString:@";;"];
}

static NSDictionary *ZXCraneAppInfo(CraneManager *manager, NSString *applicationID)
{
    NSString *displayName = [manager displayNameForApplicationWithIdentifier:applicationID] ?: @"";
    NSArray *containers = [manager containerIdentifiersOfApplicationWithIdentifier:applicationID] ?: @[];
    NSString *active = [manager activeContainerIdentifierForApplicationWithIdentifier:applicationID] ?: @"";
    return @{
        @"bundle_id": applicationID ?: @"",
        @"display_name": displayName,
        @"active_container": active,
        @"container_count": @(containers.count)
    };
}

static NSArray *ZXCraneContainersForApp(CraneManager *manager, NSString *applicationID)
{
    NSMutableArray *result = [NSMutableArray array];
    NSArray *containerIDs = [manager containerIdentifiersOfApplicationWithIdentifier:applicationID] ?: @[];
    NSString *active = [manager activeContainerIdentifierForApplicationWithIdentifier:applicationID] ?: @"";
    for (NSString *containerID in containerIDs) {
        NSString *name = [manager displayNameForContainerWithIdentifier:containerID ofApplicationWithIdentifier:applicationID shouldUseShortVersion:NO] ?: @"";
        NSDictionary *settings = [manager containerSettingsForContainerWithIdentifier:containerID ofApplicationWithIdentifier:applicationID] ?: @{};
        [result addObject:@{
            @"id": containerID ?: @"",
            @"name": name,
            @"active": @([containerID isEqualToString:active]),
            @"settings": settings
        }];
    }
    return result;
}

NSString *handleCraneTaskFromRawData(UInt8 *eventData, NSError **error)
{
    NSArray *args = ZXCraneArguments(eventData);
    if (args.count == 0) {
        ZXCraneSetError(error, @"Crane task data is empty.");
        return nil;
    }

    int task = [args[0] intValue];
    CraneManager *manager = ZXCraneManager();

    if (task == CRANE_TASK_CHECK) {
        return ZXCraneJSONString(@{
            @"available": @(manager != nil),
            @"class_loaded": @(NSClassFromString(@"CraneManager") != nil)
        });
    }

    if (!manager) {
        ZXCraneSetError(error, @"Crane is not available. Install Crane and make sure libCrane can be loaded.");
        return nil;
    }

    @try {
        if (task == CRANE_TASK_SUPPORTED_APPS) {
            NSMutableArray *apps = [NSMutableArray array];
            for (NSString *applicationID in ([manager identifiersOfAllSupportedApplications] ?: @[])) {
                [apps addObject:ZXCraneAppInfo(manager, applicationID)];
            }
            return ZXCraneJSONString(@{ @"apps": apps });
        }
        else if (task == CRANE_TASK_APPS_WITH_CONTAINERS) {
            NSMutableArray *apps = [NSMutableArray array];
            NSArray *applicationIDs = nil;
            if ([manager respondsToSelector:@selector(identfiersOfApplicationsThatHaveNonDefaultContainers)]) {
                applicationIDs = [manager identfiersOfApplicationsThatHaveNonDefaultContainers];
            }
            for (NSString *applicationID in (applicationIDs ?: @[])) {
                [apps addObject:ZXCraneAppInfo(manager, applicationID)];
            }
            return ZXCraneJSONString(@{ @"apps": apps });
        }
        else if (task == CRANE_TASK_APP_CONTAINERS) {
            if (args.count < 2) {
                ZXCraneSetError(error, @"Missing bundle identifier.");
                return nil;
            }
            NSString *applicationID = args[1];
            if (![manager isApplicationSupportedByCrane:applicationID]) {
                ZXCraneSetError(error, [NSString stringWithFormat:@"Application is not supported by Crane: %@", applicationID]);
                return nil;
            }
            return ZXCraneJSONString(@{
                @"bundle_id": applicationID,
                @"active_container": [manager activeContainerIdentifierForApplicationWithIdentifier:applicationID] ?: @"",
                @"containers": ZXCraneContainersForApp(manager, applicationID)
            });
        }
        else if (task == CRANE_TASK_ACTIVE_CONTAINER) {
            if (args.count < 2) {
                ZXCraneSetError(error, @"Missing bundle identifier.");
                return nil;
            }
            NSString *applicationID = args[1];
            NSString *containerID = [manager activeContainerIdentifierForApplicationWithIdentifier:applicationID] ?: @"";
            return ZXCraneJSONString(@{ @"bundle_id": applicationID, @"container_id": containerID });
        }
        else if (task == CRANE_TASK_SET_ACTIVE_CONTAINER) {
            if (args.count < 3) {
                ZXCraneSetError(error, @"Missing bundle identifier or container identifier.");
                return nil;
            }
            [manager setActiveContainerIdentifier:args[2] forApplicationWithIdentifier:args[1]];
            return ZXCraneJSONString(@{ @"bundle_id": args[1], @"container_id": args[2] });
        }
        else if (task == CRANE_TASK_CREATE_CONTAINER) {
            if (args.count < 3) {
                ZXCraneSetError(error, @"Missing bundle identifier or container name.");
                return nil;
            }
            NSString *containerID = nil;
            if (args.count >= 4 && [args[3] length] > 0) {
                containerID = args[3];
                [manager createNewContainerWithName:args[2] andIdentifier:containerID forApplicationWithIdentifier:args[1]];
            } else {
                containerID = [manager createNewContainerWithName:args[2] forApplicationWithIdentifier:args[1]] ?: @"";
            }
            return ZXCraneJSONString(@{ @"bundle_id": args[1], @"container_id": containerID });
        }
        else if (task == CRANE_TASK_DELETE_CONTAINER) {
            if (args.count < 3) {
                ZXCraneSetError(error, @"Missing bundle identifier or container identifier.");
                return nil;
            }
            [manager deleteContainerWithIdentifier:args[2] forApplicationWithIdentifier:args[1]];
            return ZXCraneJSONString(@{ @"deleted": @YES, @"bundle_id": args[1], @"container_id": args[2] });
        }
        else if (task == CRANE_TASK_DELETE_CONTAINER_CONTENT) {
            if (args.count < 3) {
                ZXCraneSetError(error, @"Missing bundle identifier or container identifier.");
                return nil;
            }
            [manager deleteContentOfContainerWithIdentifier:args[2] forApplicationWithIdentifier:args[1]];
            return ZXCraneJSONString(@{ @"deleted_content": @YES, @"bundle_id": args[1], @"container_id": args[2] });
        }
        else if (task == CRANE_TASK_WIPE_CONTAINER) {
            if (args.count < 3) {
                ZXCraneSetError(error, @"Missing bundle identifier or container identifier.");
                return nil;
            }
            BOOL repopulate = args.count >= 4 ? [args[3] boolValue] : YES;
            [manager wipeContainerWithIdentifier:args[2] forApplicationWithIdentifier:args[1] shouldRepopulate:repopulate];
            return ZXCraneJSONString(@{ @"wiped": @YES, @"bundle_id": args[1], @"container_id": args[2], @"repopulate": @(repopulate) });
        }
        else if (task == CRANE_TASK_MAKE_DEFAULT) {
            if (args.count < 3) {
                ZXCraneSetError(error, @"Missing bundle identifier or container identifier.");
                return nil;
            }
            NSString *newID = [manager makeDefaultForContainerWithIdentifier:args[2] forApplicationWithIdentifier:args[1]] ?: @"";
            return ZXCraneJSONString(@{ @"bundle_id": args[1], @"container_id": newID });
        }
        else if (task == CRANE_TASK_CONTAINER_SETTINGS) {
            if (args.count < 3) {
                ZXCraneSetError(error, @"Missing bundle identifier or container identifier.");
                return nil;
            }
            NSDictionary *settings = [manager containerSettingsForContainerWithIdentifier:args[2] ofApplicationWithIdentifier:args[1]] ?: @{};
            return ZXCraneJSONString(@{ @"bundle_id": args[1], @"container_id": args[2], @"settings": settings });
        }
        else if (task == CRANE_TASK_SET_CONTAINER_SETTINGS) {
            if (args.count < 4) {
                ZXCraneSetError(error, @"Missing bundle identifier, container identifier, or settings JSON.");
                return nil;
            }
            NSDictionary *settings = ZXCraneBase64JSONDictionary(args[3]);
            [manager setContainerSettings:settings forContainerWithIdentifier:args[2] ofApplicationWithIdentifier:args[1]];
            return ZXCraneJSONString(@{ @"bundle_id": args[1], @"container_id": args[2], @"settings": settings });
        }
        else if (task == CRANE_TASK_LAUNCH_APP_WITH_CONTAINER) {
            if (args.count < 3) {
                ZXCraneSetError(error, @"Missing bundle identifier or container identifier.");
                return nil;
            }
            NSString *applicationID = args[1];
            NSString *containerID = args[2];
            [manager setActiveContainerIdentifier:containerID forApplicationWithIdentifier:applicationID];
            [manager flushCFPrefsdCacheForApplicationWithIdentifier:applicationID];
            [manager reloadApplicationWithIdentifier:applicationID];
            bringAppForeground(applicationID);
            return ZXCraneJSONString(@{ @"launched": @YES, @"bundle_id": applicationID, @"container_id": containerID });
        }

        ZXCraneSetError(error, @"Unknown Crane task.");
        return nil;
    }
    @catch (NSException *exception) {
        ZXCraneSetError(error, [NSString stringWithFormat:@"Crane operation failed: %@", exception.reason ?: exception.name]);
        return nil;
    }
}
