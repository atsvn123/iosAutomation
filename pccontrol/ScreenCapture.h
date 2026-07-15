#ifndef SCREEN_CAPTURE_H
#define SCREEN_CAPTURE_H

#import <Foundation/Foundation.h>

#define SCREEN_CAPTURE_TASK_SAVE 1
#define SCREEN_CAPTURE_TASK_BYTES 2

NSString *handleScreenCaptureTaskFromRawData(UInt8 *eventData, NSError **error);

#endif
