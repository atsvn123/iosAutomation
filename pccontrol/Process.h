#ifndef PROCESS_H
#define PROCESS_H

#import <Foundation/Foundation.h>
#include <dlfcn.h>

int switchProcessForegroundFromRawData(UInt8 *eventData);
int bringAppForeground(NSString *appIdentifier);
NSString *closeAppFromRawData(UInt8 *eventData, NSError **error);
NSString *closeAppWithBundleIdentifier(NSString *bundleIdentifier, NSError **error);
NSString *ensureScreenActive(NSError **error);
id getFrontMostApplication();

#endif
