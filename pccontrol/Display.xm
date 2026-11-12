#include "Display.h"
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#import <objc/message.h>

/*
TASK_DISPLAY (31): turn the panel dark while the foreground app keeps running,
so an OLED screen is not lit for hours of automation. Locking would do that too,
but it pauses the app and screenshots come back black.

Requests (task data after "31"), replies are one line:
    status
    brightness;;<0-1>
    blank;;<method>;;<seconds>[;;brightness=<0-1>][;;mask=<n>]
    renew;;<seconds>
    unblank
    wake[;;api|home]
    lock

Every reply except brightness is the status line:
    0;;blanked=<0|1>;;method=<name>;;remaining=<s>;;brightness=<0-1>;;
       saved=<0-1 or ->;;hidden=<0|1|->;;locked=<0|1|->;;reason=<why it last lit up>;;
       screen=<0|1|->
brightness replies 0;;previous=<0-1>;;brightness=<0-1>. Errors are -1;;<message>.

wake and lock start a run on a phone that sleeps between runs and put it back to
sleep afterwards. They are for a phone without a passcode: wake never enters or
skips one, so on a phone with a passcode the passcode screen comes up and the
device stays locked (the status line says locked=1).
    wake     only acts while the device is locked. api (the default) turns the
             screen on as a home button press does (backlight source 2) and asks
             SBLockScreenManager to unlock the UI (source 2). home simulates a
             home button press instead; each press goes one step (wake, then
             unlock), so the caller checks the status and presses again. An
             unlocked device is left alone, so a running app is never sent home.
             Unlocking finishes after the reply: poll status for locked=0.
    lock     simulates a lock button press, but only while the screen is on, so
             it always puts the phone to sleep and never wakes it. A blank is lit
             first. The foreground app pauses, as it does when someone locks.

Methods:
    overlay  a black SpringBoard window above everything that touches go through,
             with CALayer's private disableUpdateMask (0x12 unless mask= says
             otherwise) so screen captures leave it out. Black OLED pixels are
             off, and nothing about the display's power state changes.
    bks      BackBoardServices' BKSDisplayServicesSetScreenBlanked. Real blanking,
             but nobody knows yet what it does to the frame rate or to captures,
             and backboardd, not SpringBoard, holds that state.

Safety: a blank always comes with a lease of 1-3600 seconds and the screen lights
up again by itself once it runs out, or as soon as the device locks. Nothing here
ever blanks, wakes or locks on its own, and keeps no state on disk: a respring takes
the overlay away (a bks blank may outlive it until the next lock and wake). Every
private symbol is looked up first; a missing one is an error reply, never a crash.
*/

#define DISPLAY_LEASE_MAX 3600.0
#define DISPLAY_DEFAULT_MASK 0x12

typedef void (*BKSSetScreenBlankedFn)(BOOL blanked);

static NSString *blankMethod = nil;          // nil while lit
static NSDate *leaseEnd = nil;
static UIWindow *overlayWindow = nil;
static CGFloat savedBrightness = -1;         // brightness to restore, or -1
static int overlayHidden = -1;               // 1/0 once the mask was tried, -1 before
static NSString *litReason = @"start";
static dispatch_source_t leaseTimer = NULL;

// userInteractionEnabled = NO is not enough: the window server hit-tests an opaque
// layer before UIKit has a say, and the touch ends here instead of in the app. With
// _ignoresHitTest UIKit creates the window's CAContext with kCAContextIgnoresHitTest,
// as it does for its own UISoftwareDimmingWindow.
@interface ZXDisplayOverlayWindow : UIWindow
@end

@implementation ZXDisplayOverlayWindow
- (BOOL)_ignoresHitTest
{
    return YES;
}
@end

static void runOnMain(void (^block)(void))
{
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static NSError *displayError(NSString *message)
{
    return [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:31
                           userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"-1;;%@\r\n", message]}];
}

static BKSSetScreenBlankedFn screenBlankedFunction()
{
    static BKSSetScreenBlankedFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
        if (handle) {
            fn = (BKSSetScreenBlankedFn)dlsym(handle, "BKSDisplayServicesSetScreenBlanked");
        }
    });
    return fn;
}

static id sharedIfExists(NSString *className)
{
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(@"sharedInstanceIfExists");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

// 1 locked, 0 unlocked, -1 when SpringBoard does not say.
static int lockState()
{
    id manager = sharedIfExists(@"SBLockScreenManager");
    SEL sel = NSSelectorFromString(@"isUILocked");
    if (!manager || ![manager respondsToSelector:sel]) return -1;
    return ((BOOL (*)(id, SEL))objc_msgSend)(manager, sel) ? 1 : 0;
}

// 1 on, 0 off, -1 when SpringBoard does not say.
static int screenOnState()
{
    id backlight = sharedIfExists(@"SBBacklightController");
    SEL sel = NSSelectorFromString(@"screenIsOn");
    if (!backlight || ![backlight respondsToSelector:sel]) return -1;
    return ((BOOL (*)(id, SEL))objc_msgSend)(backlight, sel) ? 1 : 0;
}

// Backlight and unlock source 2 is the home button: SpringBoard logs it when the
// home button wakes the screen, and unlock-on-wake tweaks pass it to unlockUIFromSource.
#define DISPLAY_SOURCE_HOME_BUTTON 2

// Main queue only. Starts waking and unlocking a locked device; NO with *why when
// a private method is missing.
static BOOL wakeAndUnlock(NSString *method, NSString **why)
{
    if ([method isEqualToString:@"home"]) {
        id springboard = [UIApplication sharedApplication];
        SEL press = NSSelectorFromString(@"_simulateHomeButtonPressWithCompletion:");
        if (![springboard respondsToSelector:press]) {
            *why = @"SpringBoard has no _simulateHomeButtonPressWithCompletion:";
            return NO;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(springboard, press, nil);
        NSLog(@"com.zjx.springboard: display: wake: home button press");
        return YES;
    }

    id backlight = sharedIfExists(@"SBBacklightController");
    id manager = sharedIfExists(@"SBLockScreenManager");
    SEL turnOn = NSSelectorFromString(@"turnOnScreenFullyWithBacklightSource:");
    SEL unlock = NSSelectorFromString(@"unlockUIFromSource:withOptions:");
    if (!backlight || ![backlight respondsToSelector:turnOn]) {
        *why = @"SBBacklightController has no turnOnScreenFullyWithBacklightSource:";
        return NO;
    }
    if (!manager || ![manager respondsToSelector:unlock]) {
        *why = @"SBLockScreenManager has no unlockUIFromSource:withOptions:";
        return NO;
    }
    if (screenOnState() != 1) {
        ((void (*)(id, SEL, long long))objc_msgSend)(backlight, turnOn, DISPLAY_SOURCE_HOME_BUTTON);
    }
    BOOL started = ((BOOL (*)(id, SEL, int, id))objc_msgSend)(manager, unlock, DISPLAY_SOURCE_HOME_BUTTON, nil);
    NSLog(@"com.zjx.springboard: display: wake: screen on, unlock UI returned %d", started);
    return YES;
}

// Main queue only. The caller has checked that the screen is on.
static BOOL pressLockButton(NSString **why)
{
    id springboard = [UIApplication sharedApplication];
    SEL press = NSSelectorFromString(@"_simulateLockButtonPress");
    if (![springboard respondsToSelector:press]) {
        *why = @"SpringBoard has no _simulateLockButtonPress";
        return NO;
    }
    ((void (*)(id, SEL))objc_msgSend)(springboard, press);
    NSLog(@"com.zjx.springboard: display: lock button press");
    return YES;
}

static UIWindowScene *mainWindowScene()
{
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && ((UIWindowScene *)scene).screen == [UIScreen mainScreen]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static BOOL showOverlay(unsigned int mask, NSString **why)
{
    UIWindowScene *scene = mainWindowScene();
    CGRect bounds = [UIScreen mainScreen].bounds;
    // Square on the long side: covers the panel whichever way the scene is turned.
    CGFloat side = MAX(bounds.size.width, bounds.size.height);
    UIWindow *window = scene ? [[ZXDisplayOverlayWindow alloc] initWithWindowScene:scene]
                             : [[ZXDisplayOverlayWindow alloc] initWithFrame:CGRectZero];
    if (!window) {
        *why = @"could not create the overlay window";
        return NO;
    }
    window.frame = CGRectMake(0, 0, side, side);
    window.windowLevel = UIWindowLevelAlert + 1000;   // above the touch indicator (Alert + 2)
    window.backgroundColor = [UIColor blackColor];
    window.opaque = YES;
    window.userInteractionEnabled = NO;
    if ([window.layer respondsToSelector:NSSelectorFromString(@"setAllowsHitTesting:")]) {
        [window.layer setValue:@NO forKey:@"allowsHitTesting"];
    }

    overlayHidden = 0;
    SEL getter = NSSelectorFromString(@"disableUpdateMask");
    SEL setter = NSSelectorFromString(@"setDisableUpdateMask:");
    if ([window.layer respondsToSelector:getter] && [window.layer respondsToSelector:setter]) {
        @try {
            [window.layer setValue:@(mask) forKey:@"disableUpdateMask"];
            overlayHidden = 1;
        }
        @catch (NSException *exception) {
            NSLog(@"com.zjx.springboard: display: disableUpdateMask refused: %@", exception.reason);
        }
    }
    window.hidden = NO;
    overlayWindow = window;
    return YES;
}

static void hideOverlay()
{
    if (!overlayWindow) return;
    overlayWindow.hidden = YES;
    overlayWindow = nil;
}

static void stopLeaseTimer()
{
    if (leaseTimer) {
        dispatch_source_cancel(leaseTimer);
        leaseTimer = NULL;
    }
}

// Main queue only.
static void lightUp(NSString *reason)
{
    if (!blankMethod) return;
    stopLeaseTimer();
    if ([blankMethod isEqualToString:@"overlay"]) {
        hideOverlay();
    } else if ([blankMethod isEqualToString:@"bks"]) {
        BKSSetScreenBlankedFn fn = screenBlankedFunction();
        if (fn) fn(NO);
    }
    if (savedBrightness >= 0) {
        [UIScreen mainScreen].brightness = savedBrightness;
    }
    NSLog(@"com.zjx.springboard: display: lit (%@) after %@ blank, brightness %.2f",
          reason, blankMethod, [UIScreen mainScreen].brightness);
    blankMethod = nil;
    leaseEnd = nil;
    savedBrightness = -1;
    overlayHidden = -1;
    litReason = reason;
}

static void startLeaseTimer()
{
    stopLeaseTimer();
    leaseTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(leaseTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(leaseTimer, ^{
        if (!blankMethod) return;
        if (lockState() == 1) {
            lightUp(@"locked");
        } else if (!leaseEnd || [leaseEnd timeIntervalSinceNow] <= 0) {
            lightUp(@"lease expired");
        }
    });
    dispatch_resume(leaseTimer);
}

static NSString *statusLine()
{
    double remaining = (blankMethod && leaseEnd) ? MAX([leaseEnd timeIntervalSinceNow], 0) : 0;
    int locked = lockState();
    int screen = screenOnState();
    return [NSString stringWithFormat:@"0;;blanked=%d;;method=%@;;remaining=%.0f;;brightness=%.3f;;saved=%@;;hidden=%@;;locked=%@;;reason=%@;;screen=%@\r\n",
            blankMethod ? 1 : 0, blankMethod ?: @"-", remaining, [UIScreen mainScreen].brightness,
            savedBrightness >= 0 ? [NSString stringWithFormat:@"%.3f", savedBrightness] : @"-",
            overlayHidden >= 0 ? [NSString stringWithFormat:@"%d", overlayHidden] : @"-",
            locked >= 0 ? [NSString stringWithFormat:@"%d", locked] : @"-",
            blankMethod ? @"-" : litReason,
            screen >= 0 ? [NSString stringWithFormat:@"%d", screen] : @"-"];
}

static BOOL parseUnit(NSString *text, double *value)
{
    NSScanner *scanner = [NSScanner scannerWithString:text];
    double v;
    if (![scanner scanDouble:&v] || ![scanner isAtEnd] || v < 0 || v > 1) return NO;
    *value = v;
    return YES;
}

static BOOL parseLease(NSString *text, double *seconds)
{
    NSScanner *scanner = [NSScanner scannerWithString:text];
    double v;
    if (![scanner scanDouble:&v] || ![scanner isAtEnd] || v < 1 || v > DISPLAY_LEASE_MAX) return NO;
    *seconds = v;
    return YES;
}

NSString *handleDisplayTaskFromRawData(UInt8 *eventData, NSError **error)
{
    NSString *data = [NSString stringWithUTF8String:(const char *)eventData];
    NSArray<NSString *> *parts = [data componentsSeparatedByString:@";;"];
    NSString *command = parts.count ? parts[0] : @"";

    __block NSString *reply = nil;
    __block NSString *failure = nil;

    if ([command isEqualToString:@"status"]) {
        runOnMain(^{ reply = statusLine(); });
    }
    else if ([command isEqualToString:@"brightness"]) {
        double level;
        if (parts.count != 2 || !parseUnit(parts[1], &level)) {
            failure = @"usage: brightness;;<0-1>";
        } else {
            runOnMain(^{
                CGFloat previous = [UIScreen mainScreen].brightness;
                [UIScreen mainScreen].brightness = level;
                NSLog(@"com.zjx.springboard: display: brightness %.3f -> %.3f", previous, level);
                reply = [NSString stringWithFormat:@"0;;previous=%.3f;;brightness=%.3f\r\n",
                         previous, [UIScreen mainScreen].brightness];
            });
        }
    }
    else if ([command isEqualToString:@"blank"]) {
        double seconds;
        if (parts.count < 3 || !parseLease(parts[2], &seconds)) {
            failure = [NSString stringWithFormat:@"usage: blank;;overlay|bks;;<1-%.0f seconds>[;;brightness=<0-1>][;;mask=<n>]", DISPLAY_LEASE_MAX];
        } else {
            NSString *method = parts[1];
            double level = -1;
            unsigned int mask = DISPLAY_DEFAULT_MASK;
            for (NSUInteger i = 3; i < parts.count && !failure; i++) {
                NSString *option = parts[i];
                if ([option hasPrefix:@"brightness="]) {
                    if (!parseUnit([option substringFromIndex:11], &level)) failure = @"brightness must be 0-1";
                } else if ([option hasPrefix:@"mask="]) {
                    unsigned long long value = 0;
                    NSScanner *scanner = [NSScanner scannerWithString:[option substringFromIndex:5]];
                    if (![scanner scanHexLongLong:&value] || ![scanner isAtEnd] || value > 0xFFFF) failure = @"mask must be hex, at most 0xFFFF";
                    else mask = (unsigned int)value;
                } else {
                    failure = [NSString stringWithFormat:@"unknown option %@", option];
                }
            }
            if (!failure && ![method isEqualToString:@"overlay"] && ![method isEqualToString:@"bks"]) {
                failure = [NSString stringWithFormat:@"unknown method %@ (overlay, bks)", method];
            }
            if (!failure) {
                runOnMain(^{
                    if (blankMethod) {
                        if (![blankMethod isEqualToString:method]) {
                            failure = [NSString stringWithFormat:@"already blank with %@; unblank first", blankMethod];
                            return;
                        }
                        leaseEnd = [NSDate dateWithTimeIntervalSinceNow:seconds];
                        reply = statusLine();
                        return;
                    }
                    int locked = lockState();
                    if (locked != 0) {
                        failure = locked == 1 ? @"device is locked" : @"cannot tell whether the device is locked";
                        return;
                    }
                    if (screenOnState() == 0) {
                        failure = @"screen is already off";
                        return;
                    }
                    if ([method isEqualToString:@"overlay"]) {
                        NSString *why = nil;
                        if (!showOverlay(mask, &why)) {
                            failure = why;
                            return;
                        }
                    } else {
                        BKSSetScreenBlankedFn fn = screenBlankedFunction();
                        if (!fn) {
                            failure = @"BKSDisplayServicesSetScreenBlanked is missing";
                            return;
                        }
                        fn(YES);
                    }
                    blankMethod = method;
                    leaseEnd = [NSDate dateWithTimeIntervalSinceNow:seconds];
                    if (level >= 0) {
                        savedBrightness = [UIScreen mainScreen].brightness;
                        [UIScreen mainScreen].brightness = level;
                    }
                    startLeaseTimer();
                    NSLog(@"com.zjx.springboard: display: blank with %@ for %.0f s (mask 0x%x hidden %d, brightness %.2f)",
                          method, seconds, mask, overlayHidden, [UIScreen mainScreen].brightness);
                    reply = statusLine();
                });
            }
        }
    }
    else if ([command isEqualToString:@"renew"]) {
        double seconds;
        if (parts.count != 2 || !parseLease(parts[1], &seconds)) {
            failure = [NSString stringWithFormat:@"usage: renew;;<1-%.0f seconds>", DISPLAY_LEASE_MAX];
        } else {
            runOnMain(^{
                if (!blankMethod) {
                    failure = [NSString stringWithFormat:@"not blank (lit: %@)", litReason];
                    return;
                }
                leaseEnd = [NSDate dateWithTimeIntervalSinceNow:seconds];
                reply = statusLine();
            });
        }
    }
    else if ([command isEqualToString:@"unblank"]) {
        runOnMain(^{
            lightUp(@"unblank");
            reply = statusLine();
        });
    }
    else if ([command isEqualToString:@"wake"]) {
        NSString *method = parts.count > 1 ? parts[1] : @"api";
        if (parts.count > 2 || (![method isEqualToString:@"api"] && ![method isEqualToString:@"home"])) {
            failure = @"usage: wake[;;api|home]";
        } else {
            runOnMain(^{
                int locked = lockState();
                if (locked == -1) {
                    failure = @"cannot tell whether the device is locked";
                    return;
                }
                if (locked == 1) {
                    NSString *why = nil;
                    if (!wakeAndUnlock(method, &why)) {
                        failure = why;
                        return;
                    }
                }
                reply = statusLine();
            });
        }
    }
    else if ([command isEqualToString:@"lock"]) {
        if (parts.count != 1) {
            failure = @"usage: lock";
        } else {
            runOnMain(^{
                int screen = screenOnState();
                if (screen == -1) {
                    failure = @"cannot tell whether the screen is on";
                    return;
                }
                if (screen == 1) {
                    lightUp(@"lock");
                    NSString *why = nil;
                    if (!pressLockButton(&why)) {
                        failure = why;
                        return;
                    }
                }
                reply = statusLine();
            });
        }
    }
    else {
        failure = [NSString stringWithFormat:@"unknown display command %@ (status, brightness, blank, renew, unblank, wake, lock)", command];
    }

    if (failure) {
        *error = displayError(failure);
        return nil;
    }
    return reply;
}
