#import "ScreenCapture.h"
#import "Screen.h"
#import "Toast.h"

static dispatch_semaphore_t ZXScreenCaptureSemaphore(void)
{
    static dispatch_semaphore_t semaphore;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        semaphore = dispatch_semaphore_create(1);
    });
    return semaphore;
}

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

static CGRect ZXScreenCaptureParseRegion(NSString *regionString)
{
    if (regionString.length == 0) return CGRectZero;
    NSArray *parts = [regionString componentsSeparatedByString:@",,"];
    if (parts.count < 4) return CGRectZero;
    return CGRectMake([parts[0] floatValue], [parts[1] floatValue], [parts[2] floatValue], [parts[3] floatValue]);
}

static NSData *ZXScreenCaptureImageData(NSString *format, CGFloat quality, CGRect region, NSError **error)
{
    dispatch_semaphore_wait(ZXScreenCaptureSemaphore(), DISPATCH_TIME_FOREVER);
    CGImageRef cgImage = NULL;
    NSData *imageData = nil;

    @try {
    [Toast setToastWindowsHiddenForCapture:YES];
    cgImage = [Screen createScreenShotCGImageRef];
    [Toast setToastWindowsHiddenForCapture:NO];

    if (!cgImage) {
        ZXScreenCaptureSetError(error, @"Unable to capture screen.");
        return nil;
    }

    UIImage *image = [[UIImage alloc] initWithCGImage:cgImage];
    if (!CGRectEqualToRect(region, CGRectZero)) {
        CGRect imageBounds = CGRectMake(0, 0, image.size.width * image.scale, image.size.height * image.scale);
        CGRect safeRegion = CGRectIntersection(imageBounds, region);
        if (!CGRectIsNull(safeRegion) && safeRegion.size.width > 0 && safeRegion.size.height > 0) {
            CGFloat scale = image.scale;
            CGRect cropRect = CGRectMake(safeRegion.origin.x / scale, safeRegion.origin.y / scale,
                                         safeRegion.size.width / scale, safeRegion.size.height / scale);
            CGImageRef cropped = CGImageCreateWithImageInRect(image.CGImage, cropRect);
            if (cropped) {
                image = [[UIImage alloc] initWithCGImage:cropped scale:image.scale orientation:UIImageOrientationUp];
                CGImageRelease(cropped);
            }
        }
    }

    NSString *normalizedFormat = (format ?: @"png").lowercaseString;
    if ([normalizedFormat isEqualToString:@"jpg"] || [normalizedFormat isEqualToString:@"jpeg"]) {
        if (quality <= 0 || quality > 1) quality = 0.75f;
        imageData = UIImageJPEGRepresentation(image, quality);
    } else {
        normalizedFormat = @"png";
        imageData = UIImagePNGRepresentation(image);
    }

    if (!imageData.length) {
        ZXScreenCaptureSetError(error, [NSString stringWithFormat:@"Unable to encode screenshot as %@.", format ?: @"png"]);
        return nil;
    }
    return imageData;
    }
    @finally {
        [Toast setToastWindowsHiddenForCapture:NO];
        if (cgImage) CGImageRelease(cgImage);
        dispatch_semaphore_signal(ZXScreenCaptureSemaphore());
    }
}

static NSString *ZXScreenCaptureDefaultPath(NSString *format)
{
    NSString *directory = @"/var/mobile/Library/ZXTouch/captures";
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *extension = ([format.lowercaseString isEqualToString:@"jpg"] || [format.lowercaseString isEqualToString:@"jpeg"]) ? @"jpg" : @"png";
    return [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", [[NSUUID UUID] UUIDString], extension]];
}

static NSString *ZXScreenCaptureUploadURL(NSString *urlString, NSData *pngData, NSError **error)
{
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    if (!url) {
        ZXScreenCaptureSetError(error, [NSString stringWithFormat:@"Invalid upload URL: %@", urlString ?: @""]);
        return nil;
    }

    __block NSData *responseData = nil;
    __block NSError *requestError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"image/png" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)pngData.length] forHTTPHeaderField:@"Content-Length"];
    request.HTTPBody = pngData;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *sessionError) {
        responseData = data;
        requestError = sessionError;
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));

    if (requestError) {
        ZXScreenCaptureSetError(error, [NSString stringWithFormat:@"Unable to upload screenshot: %@", requestError.localizedDescription ?: @""]);
        return nil;
    }

    return ZXScreenCaptureJSONString(@{ @"uploaded": @YES, @"url": urlString ?: @"", @"size": @(pngData.length), @"response_size": @(responseData.length) });
}

NSString *handleScreenCaptureTaskFromRawData(UInt8 *eventData, NSError **error)
{
    NSArray *args = [[NSString stringWithFormat:@"%s", eventData] componentsSeparatedByString:@";;"];
    if (args.count == 0) {
        ZXScreenCaptureSetError(error, @"Screen capture task data is empty.");
        return nil;
    }

    int task = [args[0] intValue];
    NSString *pathArg = args.count >= 2 ? args[1] : @"";
    NSString *format = args.count >= 3 && [args[2] length] > 0 ? args[2] : @"png";
    CGFloat quality = args.count >= 4 ? [args[3] floatValue] : 0.75f;
    CGRect region = args.count >= 5 ? ZXScreenCaptureParseRegion(args[4]) : CGRectZero;
    NSData *imageData = ZXScreenCaptureImageData(format, quality, region, error);
    if (!imageData) return nil;
    NSString *normalizedFormat = ([format.lowercaseString isEqualToString:@"jpg"] || [format.lowercaseString isEqualToString:@"jpeg"]) ? @"jpg" : @"png";

    if (task == SCREEN_CAPTURE_TASK_SAVE) {
        NSString *path = pathArg.length > 0 ? pathArg : ZXScreenCaptureDefaultPath(normalizedFormat);
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        if (![imageData writeToFile:path atomically:YES]) {
            ZXScreenCaptureSetError(error, [NSString stringWithFormat:@"Unable to write screenshot to %@", path]);
            return nil;
        }
        return ZXScreenCaptureJSONString(@{ @"path": path, @"size": @(imageData.length), @"format": normalizedFormat });
    }
    else if (task == SCREEN_CAPTURE_TASK_BYTES) {
        NSString *base64 = [imageData base64EncodedStringWithOptions:0] ?: @"";
        return ZXScreenCaptureJSONString(@{ @"data": base64, @"size": @(imageData.length), @"format": normalizedFormat });
    }
    else if (task == SCREEN_CAPTURE_TASK_UPLOAD_URL) {
        if (pathArg.length == 0) {
            ZXScreenCaptureSetError(error, @"Missing screenshot upload URL.");
            return nil;
        }
        return ZXScreenCaptureUploadURL(pathArg, imageData, error);
    }

    ZXScreenCaptureSetError(error, @"Unknown screen capture task.");
    return nil;
}
