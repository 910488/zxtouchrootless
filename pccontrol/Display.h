#ifndef DISPLAY_H
#define DISPLAY_H

#import <Foundation/Foundation.h>

// TASK_DISPLAY: blank the panel while the foreground app keeps running, on a
// lease that lights the screen again by itself. See Display.xm for the protocol.
NSString *handleDisplayTaskFromRawData(UInt8 *eventData, NSError **error);

#endif
