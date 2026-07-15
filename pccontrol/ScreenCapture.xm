#import "ScreenCapture.h"
#import "Screen.h"
#import "Toast.h"

static void ZXScreenCaptureSetError(NSError **error, NSString *message)
{
    if (!error) return;
    *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp.screencapture" code:999 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"-1;;%@\r\n", message ?: @"Unknown screen capture error."]
    }];
}

static NSString *ZXScreenCaptureJSONString(id object)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:(object ?: @{}) options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

static NSData *ZXScreenCapturePNGData(NSError **error)
{
    [Toast setToastWindowsHiddenForCapture:YES];
    CGImageRef cgImage = [Screen createScreenShotCGImageRef];
    [Toast setToastWindowsHiddenForCapture:NO];

    if (!cgImage) {
        ZXScreenCaptureSetError(error, @"Unable to capture screen.");
        return nil;
    }

    UIImage *image = [[UIImage alloc] initWithCGImage:cgImage];
    NSData *pngData = UIImagePNGRepresentation(image);
    CGImageRelease(cgImage);

    if (!pngData.length) {
        ZXScreenCaptureSetError(error, @"Unable to encode screenshot as PNG.");
        return nil;
    }
    return pngData;
}

static NSString *ZXScreenCaptureDefaultPath(void)
{
    NSString *directory = @"/var/mobile/Library/ZXTouch/captures";
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", [[NSUUID UUID] UUIDString]]];
}

NSString *handleScreenCaptureTaskFromRawData(UInt8 *eventData, NSError **error)
{
    NSArray *args = [[NSString stringWithFormat:@"%s", eventData] componentsSeparatedByString:@";;"];
    if (args.count == 0) {
        ZXScreenCaptureSetError(error, @"Screen capture task data is empty.");
        return nil;
    }

    int task = [args[0] intValue];
    NSData *pngData = ZXScreenCapturePNGData(error);
    if (!pngData) return nil;

    if (task == SCREEN_CAPTURE_TASK_SAVE) {
        NSString *path = args.count >= 2 && [args[1] length] > 0 ? args[1] : ZXScreenCaptureDefaultPath();
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        if (![pngData writeToFile:path atomically:YES]) {
            ZXScreenCaptureSetError(error, [NSString stringWithFormat:@"Unable to write screenshot to %@", path]);
            return nil;
        }
        return ZXScreenCaptureJSONString(@{ @"path": path, @"size": @(pngData.length), @"format": @"png" });
    }
    else if (task == SCREEN_CAPTURE_TASK_BYTES) {
        NSString *base64 = [pngData base64EncodedStringWithOptions:0] ?: @"";
        return ZXScreenCaptureJSONString(@{ @"data": base64, @"size": @(pngData.length), @"format": @"png" });
    }

    ZXScreenCaptureSetError(error, @"Unknown screen capture task.");
    return nil;
}
