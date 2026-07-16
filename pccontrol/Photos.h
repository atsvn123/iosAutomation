#ifndef PHOTOS_H
#define PHOTOS_H

#import <Foundation/Foundation.h>

#define PHOTOS_TASK_CLEAR_ALL 1
#define PHOTOS_TASK_IMPORT_FILE 2
#define PHOTOS_TASK_IMPORT_BASE64 3
#define PHOTOS_TASK_UPLOAD_BEGIN 4
#define PHOTOS_TASK_UPLOAD_CHUNK 5
#define PHOTOS_TASK_UPLOAD_COMMIT 6
#define PHOTOS_TASK_IMPORT_URL 7

NSString *handlePhotosTaskFromRawData(UInt8 *eventData, NSError **error);

#endif
