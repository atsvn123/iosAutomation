#include "DeviceInfo.h"
#include "Screen.h"
#include "Play.h"
#include "Process.h"
#include "Record.h"
#import <sys/utsname.h>
#import <sys/sysctl.h>
#include <dlfcn.h>

typedef CFTypeRef (*MGCopyAnswerType)(CFStringRef property);

static NSString* modelName()
{
    struct utsname systemInfo;
    uname(&systemInfo);

    return [NSString stringWithCString:systemInfo.machine
                                encoding:NSUTF8StringEncoding];
}

static NSString *sysctlString(NSString *name)
{
    size_t size = 0;
    if (sysctlbyname([name UTF8String], NULL, &size, NULL, 0) != 0 || size == 0) return nil;
    char *value = (char *)malloc(size);
    if (!value) return nil;
    NSString *result = nil;
    if (sysctlbyname([name UTF8String], value, &size, NULL, 0) == 0) {
        result = [NSString stringWithUTF8String:value];
    }
    free(value);
    return result;
}

static id mobileGestaltValue(NSString *key)
{
    static MGCopyAnswerType MGCopyAnswer = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        if (handle) {
            MGCopyAnswer = (MGCopyAnswerType)dlsym(handle, "MGCopyAnswer");
        }
    });

    if (!MGCopyAnswer || key.length == 0) return nil;
    CFTypeRef value = MGCopyAnswer((__bridge CFStringRef)key);
    return value ? CFBridgingRelease(value) : nil;
}

static NSString *stringOrNil(id value)
{
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return [value description];
}

static NSString *firstGestaltString(NSArray<NSString *> *keys)
{
    for (NSString *key in keys) {
        NSString *value = stringOrNil(mobileGestaltValue(key));
        if (value.length > 0) return value;
    }
    return nil;
}

static id jsonValue(id value)
{
    return value ?: [NSNull null];
}

static NSString *jsonString(NSDictionary *dictionary)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

static NSDictionary *fullDeviceDetails(void)
{
    UIDevice *device = [UIDevice currentDevice];
    [device setBatteryMonitoringEnabled:YES];

    __block CGRect bounds = CGRectZero;
    __block CGRect nativeBounds = CGRectZero;
    __block CGFloat scale = 1.0f;
    void (^readScreen)(void) = ^{
        UIScreen *screen = [UIScreen mainScreen];
        bounds = screen.bounds;
        nativeBounds = screen.nativeBounds;
        scale = screen.scale;
    };
    if ([NSThread isMainThread]) readScreen();
    else dispatch_sync(dispatch_get_main_queue(), readScreen);

    NSString *machine = modelName();
    NSString *productName = firstGestaltString(@[@"ProductName"]);
    NSString *marketingName = firstGestaltString(@[@"MarketingName", @"DeviceName"]);
    NSString *buildVersion = firstGestaltString(@[@"BuildVersion"]);
    NSString *productVersion = firstGestaltString(@[@"ProductVersion"]);
    NSString *serialNumber = firstGestaltString(@[@"SerialNumber", @"SerialNumberString"]);
    NSString *udid = firstGestaltString(@[@"UniqueDeviceID", @"UniqueDeviceIDData"]);
    NSString *imei = firstGestaltString(@[@"InternationalMobileEquipmentIdentity", @"InternationalMobileEquipmentIdentity2", @"IMEI"]);
    NSString *meid = firstGestaltString(@[@"MobileEquipmentIdentifier", @"MEID"]);
    NSString *wifiAddress = firstGestaltString(@[@"WifiAddress", @"WiFiAddress"]);
    NSString *bluetoothAddress = firstGestaltString(@[@"BluetoothAddress"]);
    NSString *chipID = firstGestaltString(@[@"ChipID"]);
    NSString *ecid = firstGestaltString(@[@"UniqueChipID", @"ECID"]);
    NSString *deviceClass = firstGestaltString(@[@"DeviceClass"]);
    NSString *regionCode = firstGestaltString(@[@"RegionCode"]);
    NSString *regionInfo = firstGestaltString(@[@"RegionInfo"]);

    id frontMostApp = getFrontMostApplication();
    NSString *frontMostBundle = nil;
    if ([frontMostApp respondsToSelector:@selector(bundleIdentifier)]) {
        frontMostBundle = [frontMostApp bundleIdentifier];
    }
    if (frontMostBundle.length == 0) frontMostBundle = @"com.apple.springboard";

    return @{
        @"name": jsonValue([device name]),
        @"system_name": jsonValue([device systemName]),
        @"system_version": jsonValue([device systemVersion]),
        @"product_version": jsonValue(productVersion),
        @"build_version": jsonValue(buildVersion),
        @"model": jsonValue(machine),
        @"product_name": jsonValue(productName),
        @"marketing_name": jsonValue(marketingName),
        @"device_class": jsonValue(deviceClass),
        @"localized_model": jsonValue([device localizedModel]),
        @"identifier_for_vendor": jsonValue([[device identifierForVendor] UUIDString]),
        @"serial_number": jsonValue(serialNumber),
        @"udid": jsonValue(udid),
        @"imei": jsonValue(imei),
        @"meid": jsonValue(meid),
        @"ecid": jsonValue(ecid),
        @"chip_id": jsonValue(chipID),
        @"wifi_address": jsonValue(wifiAddress),
        @"bluetooth_address": jsonValue(bluetoothAddress),
        @"region_code": jsonValue(regionCode),
        @"region_info": jsonValue(regionInfo),
        @"kernel_version": jsonValue(sysctlString(@"kern.version")),
        @"kernel_osrelease": jsonValue(sysctlString(@"kern.osrelease")),
        @"hardware_machine": jsonValue(sysctlString(@"hw.machine")),
        @"hardware_model": jsonValue(sysctlString(@"hw.model")),
        @"screen": @{
            @"width": @(CGRectGetWidth(bounds) * scale),
            @"height": @(CGRectGetHeight(bounds) * scale),
            @"points_width": @(CGRectGetWidth(bounds)),
            @"points_height": @(CGRectGetHeight(bounds)),
            @"native_width": @(CGRectGetWidth(nativeBounds)),
            @"native_height": @(CGRectGetHeight(nativeBounds)),
            @"scale": @(scale),
            @"orientation": @([Screen getScreenOrientation])
        },
        @"battery": @{
            @"state": @([device batteryState]),
            @"level": @([device batteryLevel] * 100.0f)
        },
        @"runtime": @{
            @"foreground_app": jsonValue(frontMostBundle),
            @"script_playing": @(isScriptPlaying()),
            @"recording": @(isRecordingStart())
        }
    };
}

NSString *getDeviceInfoFromRawData(UInt8* eventData, NSError **error)
{
    NSArray *data = [[NSString stringWithFormat:@"%s", eventData] componentsSeparatedByString:@";;"];
    int task = [data[0] intValue];
    if (task == DEVICE_INFO_TASK_GET_SCREEN_SIZE)
    {
        __block CGRect bounds = CGRectZero;
        __block CGFloat scale = 1.0f;
        void (^readScreen)(void) = ^{
            UIScreen *screen = [UIScreen mainScreen];
            bounds = screen.bounds;
            scale = screen.scale;
        };
        if ([NSThread isMainThread]) readScreen();
        else dispatch_sync(dispatch_get_main_queue(), readScreen);
        return [NSString stringWithFormat:@"%f;;%f", CGRectGetWidth(bounds) * scale, CGRectGetHeight(bounds) * scale];
    }
    else if (task == DEVICE_INFO_TASK_GET_SCREEN_ORIENTATION)
    {
        return [NSString stringWithFormat:@"%d", [Screen getScreenOrientation]];
    }
    else if (task == DEVICE_INFO_TASK_GET_SCREEN_SCALE)
    {
        return [NSString stringWithFormat:@"%f", [Screen getScale]];
    }
    else if (task == DEVICE_INFO_TASK_GET_DEVICE_INFO)
    {
        return [NSString stringWithFormat:@"%@;;%@;;%@;;%@;;%@", 
                                        [[UIDevice currentDevice] name], 
                                        [[UIDevice currentDevice] systemName], 
                                        [[UIDevice currentDevice] systemVersion], 
                                        modelName(), 
                                        [[UIDevice currentDevice] identifierForVendor]];
    }
    else if (task == DEVICE_INFO_TASK_GET_BATTERY_INFO)
    {
        UIDevice *myDevice = [UIDevice currentDevice];
        [myDevice setBatteryMonitoringEnabled:YES];

        int state = [myDevice batteryState];
        double batLeft = (float)[myDevice batteryLevel] * 100;


        return [NSString stringWithFormat:@"%d;;%f", 
                                state, 
                                batLeft];
    }
    else if (task == DEVICE_INFO_TASK_GET_RUNTIME_STATUS)
    {
        id frontMostApp = getFrontMostApplication();
        NSString *bundleIdentifier = nil;
        if ([frontMostApp respondsToSelector:@selector(bundleIdentifier)]) {
            bundleIdentifier = [frontMostApp bundleIdentifier];
        }
        if (bundleIdentifier.length == 0) bundleIdentifier = @"com.apple.springboard";
        return [NSString stringWithFormat:@"%@;;%d;;%d", bundleIdentifier, isScriptPlaying(), isRecordingStart()];
    }
    else if (task == DEVICE_INFO_TASK_GET_DEVICE_DETAILS)
    {
        return jsonString(fullDeviceDetails());
    }
    else
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;Unknown device info task type. The task you provide: %d\r\n", task]}];
        return @"";
    }
}
