#include "UIKeyboard.h"
#include "Process.h"
#import <UIKit/UIKit.h>
#import <Foundation/NSDistributedNotificationCenter.h>
#include <objc/message.h>

typedef id (*ZXKeyboardMsgSendIdNoArg)(id, SEL);

#define TASK_GET_TEXT_FROM_CLIPBOARD 6
#define TASK_SAVE_TEXT_TO_CLIPBOARD 7

NSString* inputTextFromRawData(UInt8 *eventData, NSError **error)
{
    NSArray *data = [[NSString stringWithUTF8String:(char*)eventData] componentsSeparatedByString:@";;"];

    if ([data count] < 1)
    {
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Keyboard related event length error. You have to specify the task id.\r\n"}];
        return nil;
    }

    int taskType = [data[0] intValue];

    if (taskType == TASK_GET_TEXT_FROM_CLIPBOARD)
    {
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        return pasteboard.string ?: @"";
    }
    else if (taskType == TASK_SAVE_TEXT_TO_CLIPBOARD)
    {
        if ([data count] < 2)
        {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Keyboard related event error. You have to specify the content you want to paste to clipboard.\r\n"}];
            return nil;
        }
        [UIPasteboard generalPasteboard].string = data[1];
        return @"";
    }

    // Forward to appdelegate tweak injected in the frontmost app.
    // deliverImmediately:NO (async) — avoids the SpringBoard crash from synchronous delivery.
    NSString *taskContent = ([data count] >= 2) ? data[1] : @"";
    id frontMostApp = getFrontMostApplication();
    NSString *targetBundleIdentifier = nil;
    if ([frontMostApp respondsToSelector:@selector(bundleIdentifier)]) {
        targetBundleIdentifier = [frontMostApp bundleIdentifier];
    }
    if (targetBundleIdentifier.length == 0 && [frontMostApp respondsToSelector:@selector(displayIdentifier)]) {
        targetBundleIdentifier = ((ZXKeyboardMsgSendIdNoArg)objc_msgSend)(frontMostApp, @selector(displayIdentifier));
    }
    if (targetBundleIdentifier.length == 0) targetBundleIdentifier = @"";

    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"com.zjx.zxtouch.keyboardcontrol"
        object:nil
        userInfo:@{@"task_id": data[0], @"task_content": taskContent, @"target_bundle_id": targetBundleIdentifier}
        deliverImmediately:NO];

    return @"";
}
