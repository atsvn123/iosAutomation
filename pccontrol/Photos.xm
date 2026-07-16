#import "Photos.h"
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

static NSString *ZXPhotosUploadDirectory(void)
{
    NSString *path = @"/var/mobile/Library/ZXTouch/uploads/photos";
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

static void ZXPhotosSetError(NSError **error, NSString *message)
{
    if (!error) return;
    *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp.photos" code:999 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"-1;;%@\r\n", message ?: @"Unknown Photos error."]
    }];
}

static NSString *ZXPhotosJSONString(id object)
{
    if (!object) object = @{};
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

static BOOL ZXPhotosPerformChanges(void (^changes)(void), NSError **error)
{
    __block BOOL success = NO;
    __block NSError *changeError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
            changeError = [NSError errorWithDomain:@"com.zjx.zxtouchsp.photos" code:998 userInfo:@{
                NSLocalizedDescriptionKey: @"-1;;Photos authorization was denied.\r\n"
            }];
            dispatch_semaphore_signal(semaphore);
            return;
        }

        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:changes completionHandler:^(BOOL didSucceed, NSError *err) {
            success = didSucceed;
            changeError = err;
            dispatch_semaphore_signal(semaphore);
        }];
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    if (!success && error) {
        *error = changeError ?: [NSError errorWithDomain:@"com.zjx.zxtouchsp.photos" code:999 userInfo:@{
            NSLocalizedDescriptionKey: @"-1;;Photos operation failed.\r\n"
        }];
    }
    return success;
}

static NSUInteger ZXPhotosAssetCount(PHAssetMediaType mediaType)
{
    PHFetchOptions *options = [[PHFetchOptions alloc] init];
    options.predicate = [NSPredicate predicateWithFormat:@"mediaType == %d", mediaType];
    return [PHAsset fetchAssetsWithOptions:options].count;
}

static NSString *ZXPhotosImportImageData(NSData *imageData, NSString *source, NSError **error)
{
    if (!imageData.length) {
        ZXPhotosSetError(error, @"Image data is empty.");
        return nil;
    }

    UIImage *image = [UIImage imageWithData:imageData scale:[UIScreen mainScreen].scale];
    if (!image || image.size.width <= 0 || image.size.height <= 0) {
        ZXPhotosSetError(error, [NSString stringWithFormat:@"Unable to decode image data: %@", source ?: @""]);
        return nil;
    }

    __block NSString *localIdentifier = @"";
    BOOL success = ZXPhotosPerformChanges(^{
        PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
        PHAssetResourceCreationOptions *options = [[PHAssetResourceCreationOptions alloc] init];
        [request addResourceWithType:PHAssetResourceTypePhoto data:imageData options:options];
        localIdentifier = request.placeholderForCreatedAsset.localIdentifier ?: @"";
    }, error);

    if (!success) return nil;
    return ZXPhotosJSONString(@{
        @"imported": @YES,
        @"local_identifier": localIdentifier,
        @"source": source ?: @"",
        @"width": @(image.size.width * image.scale),
        @"height": @(image.size.height * image.scale)
    });
}

static NSString *ZXPhotosImportFile(NSString *filePath, NSError **error)
{
    if (filePath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        ZXPhotosSetError(error, [NSString stringWithFormat:@"Image file does not exist: %@", filePath ?: @""]);
        return nil;
    }

    NSData *imageData = [NSData dataWithContentsOfFile:filePath];
    NSString *result = ZXPhotosImportImageData(imageData, filePath, error);
    if (!result) return nil;

    NSMutableDictionary *payload = [[NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] mutableCopy];
    payload[@"path"] = filePath;
    return ZXPhotosJSONString(payload ?: @{});
}

static NSString *ZXPhotosImportURL(NSString *urlString, NSError **error)
{
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    if (!url) {
        ZXPhotosSetError(error, [NSString stringWithFormat:@"Invalid image URL: %@", urlString ?: @""]);
        return nil;
    }

    NSError *downloadError = nil;
    NSData *imageData = [NSData dataWithContentsOfURL:url options:0 error:&downloadError];
    if (!imageData.length) {
        ZXPhotosSetError(error, [NSString stringWithFormat:@"Unable to download image URL: %@. Error: %@", urlString ?: @"", downloadError.localizedDescription ?: @""]);
        return nil;
    }

    return ZXPhotosImportImageData(imageData, urlString, error);
}

static NSString *ZXPhotosClearAll(NSError **error)
{
    PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithOptions:nil];
    NSUInteger count = assets.count;
    if (count == 0) {
        return ZXPhotosJSONString(@{ @"deleted": @(0) });
    }

    NSMutableArray<PHAsset *> *assetsToDelete = [NSMutableArray arrayWithCapacity:count];
    [assets enumerateObjectsUsingBlock:^(PHAsset *asset, NSUInteger idx, BOOL *stop) {
        [assetsToDelete addObject:asset];
    }];

    BOOL success = ZXPhotosPerformChanges(^{
        [PHAssetChangeRequest deleteAssets:assetsToDelete];
    }, error);

    if (!success) return nil;
    return ZXPhotosJSONString(@{ @"deleted": @(count) });
}

static NSString *ZXPhotosImportBase64(NSString *base64Data, NSString *extension, NSError **error)
{
    NSData *imageData = [[NSData alloc] initWithBase64EncodedString:base64Data options:0];
    if (!imageData.length) {
        ZXPhotosSetError(error, @"Image buffer is empty or not valid base64.");
        return nil;
    }

    NSString *safeExtension = extension.length ? extension : @"jpg";
    NSString *fileName = [NSString stringWithFormat:@"%@.%@", [[NSUUID UUID] UUIDString], safeExtension];
    NSString *filePath = [ZXPhotosUploadDirectory() stringByAppendingPathComponent:fileName];
    if (![imageData writeToFile:filePath atomically:YES]) {
        ZXPhotosSetError(error, @"Unable to write uploaded image buffer.");
        return nil;
    }
    return ZXPhotosImportImageData(imageData, @"base64", error);
}

static NSString *ZXPhotosUploadPath(NSString *uploadID, NSString *extension)
{
    NSString *safeID = uploadID.length ? uploadID.lastPathComponent : [[NSUUID UUID] UUIDString];
    NSString *safeExtension = extension.length ? extension.lastPathComponent : @"jpg";
    return [ZXPhotosUploadDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", safeID, safeExtension]];
}

NSString *handlePhotosTaskFromRawData(UInt8 *eventData, NSError **error)
{
    NSArray *args = [[NSString stringWithFormat:@"%s", eventData] componentsSeparatedByString:@";;"];
    if (args.count == 0) {
        ZXPhotosSetError(error, @"Photos task data is empty.");
        return nil;
    }

    int task = [args[0] intValue];
    @try {
        if (task == PHOTOS_TASK_CLEAR_ALL) {
            return ZXPhotosClearAll(error);
        }
        else if (task == PHOTOS_TASK_IMPORT_FILE) {
            if (args.count < 2) {
                ZXPhotosSetError(error, @"Missing image file path.");
                return nil;
            }
            return ZXPhotosImportFile(args[1], error);
        }
        else if (task == PHOTOS_TASK_IMPORT_BASE64) {
            if (args.count < 2) {
                ZXPhotosSetError(error, @"Missing image buffer.");
                return nil;
            }
            NSString *extension = args.count >= 3 ? args[2] : @"jpg";
            return ZXPhotosImportBase64(args[1], extension, error);
        }
        else if (task == PHOTOS_TASK_UPLOAD_BEGIN) {
            if (args.count < 2) {
                ZXPhotosSetError(error, @"Missing upload identifier.");
                return nil;
            }
            NSString *extension = args.count >= 3 ? args[2] : @"jpg";
            NSString *filePath = ZXPhotosUploadPath(args[1], extension);
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
            [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil];
            return ZXPhotosJSONString(@{ @"upload_id": args[1], @"path": filePath });
        }
        else if (task == PHOTOS_TASK_UPLOAD_CHUNK) {
            if (args.count < 4) {
                ZXPhotosSetError(error, @"Missing upload identifier, extension, or chunk data.");
                return nil;
            }
            NSString *filePath = ZXPhotosUploadPath(args[1], args[2]);
            NSData *chunk = [[NSData alloc] initWithBase64EncodedString:args[3] options:0];
            if (!chunk) {
                ZXPhotosSetError(error, @"Upload chunk is not valid base64.");
                return nil;
            }
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:filePath];
            if (!handle) {
                ZXPhotosSetError(error, @"Upload session does not exist.");
                return nil;
            }
            [handle seekToEndOfFile];
            [handle writeData:chunk];
            [handle synchronizeFile];
            [handle closeFile];
            return ZXPhotosJSONString(@{ @"upload_id": args[1], @"written": @(chunk.length) });
        }
        else if (task == PHOTOS_TASK_UPLOAD_COMMIT) {
            if (args.count < 2) {
                ZXPhotosSetError(error, @"Missing upload identifier.");
                return nil;
            }
            NSString *extension = args.count >= 3 ? args[2] : @"jpg";
            NSString *filePath = ZXPhotosUploadPath(args[1], extension);
            return ZXPhotosImportFile(filePath, error);
        }
        else if (task == PHOTOS_TASK_IMPORT_URL) {
            if (args.count < 2) {
                ZXPhotosSetError(error, @"Missing image URL.");
                return nil;
            }
            return ZXPhotosImportURL(args[1], error);
        }

        ZXPhotosSetError(error, @"Unknown Photos task.");
        return nil;
    }
    @catch (NSException *exception) {
        ZXPhotosSetError(error, [NSString stringWithFormat:@"Photos operation failed: %@", exception.reason ?: exception.name]);
        return nil;
    }
}
