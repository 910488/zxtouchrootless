#include "Runner.h"
#include "SocketServer.h"
#include "Common.h"

// SpringBoard side of zxtouch-runner (see zxtouch-runner/main.m for why it
// exists). Jobs travel over the runner's own connection to the socket server,
// and the caller blocks until the runner reports how the job ended.

@interface ZXRunnerJob : NSObject
@property (nonatomic, strong) dispatch_semaphore_t signal;
@property (nonatomic) pid_t pid;
@property (nonatomic) int status;
@property (nonatomic) BOOL finished;
@end

@implementation ZXRunnerJob
@end

static NSString *const kRunnerSecretPath = @"/var/mobile/Library/ZXTouch/config/tweak/runner.secret";

// gRunnerLock guards the stream, the job table and the job counter.
// gRunnerWriteLock serialises writes, so blocking I/O never holds gRunnerLock.
static NSLock *gRunnerLock;
static NSLock *gRunnerWriteLock;
static CFWriteStreamRef gRunnerStream;
static NSMutableDictionary<NSNumber *, ZXRunnerJob *> *gRunnerJobs;
static long long gRunnerNextJob;

static void zxRunnerInit(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gRunnerLock = [NSLock new];
        gRunnerWriteLock = [NSLock new];
        gRunnerJobs = [NSMutableDictionary dictionary];
    });
}

static BOOL zxRunnerSend(CFWriteStreamRef stream, NSString *line)
{
    NSData *data = [[line stringByAppendingString:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding];
    [gRunnerWriteLock lock];
    int rc = notifyClientData((const UInt8 *)data.bytes, (CFIndex)data.length, stream);
    [gRunnerWriteLock unlock];
    return rc == 0;
}

void zxRunnerRegister(const char *secret, CFWriteStreamRef stream)
{
    zxRunnerInit();

    // Port 6000 listens on every interface so ZXTouch can be driven over Wi-Fi.
    // The runner is always local, so a registration from anywhere else is not it.
    if (!zxSocketClientIsLoopback(stream)) {
        zxAppendRuntimeLog(@"ZXTouch: ignored a runner registration from a non-local connection.");
        return;
    }

    NSString *expected = [[NSString stringWithContentsOfFile:kRunnerSecretPath encoding:NSUTF8StringEncoding error:nil]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *offered = secret ? [NSString stringWithUTF8String:secret] : nil;
    if (expected.length < 64 || ![expected isEqualToString:offered]) {
        zxAppendRuntimeLog(@"ZXTouch: ignored a runner registration with the wrong secret.");
        return;
    }

    [gRunnerLock lock];
    gRunnerStream = stream;
    [gRunnerLock unlock];
    NSLog(@"com.zjx.springboard: zxtouch-runner connected.");
}

void zxRunnerHandleEvent(const char *payload, CFWriteStreamRef stream)
{
    zxRunnerInit();
    if (!payload) return;

    NSArray<NSString *> *parts = [[NSString stringWithUTF8String:payload] componentsSeparatedByString:@";;"];
    if (parts.count != 3) return;

    NSNumber *jobId = @([parts[1] longLongValue]);
    int value = [parts[2] intValue];

    ZXRunnerJob *job = nil;
    [gRunnerLock lock];
    // Only the registered runner may report on jobs. Anyone else on port 6000
    // could otherwise fake a script finishing.
    if (stream == gRunnerStream) {
        job = gRunnerJobs[jobId];
        if ([parts[0] isEqualToString:@"STARTED"]) {
            job.pid = value;
        } else if ([parts[0] isEqualToString:@"DONE"]) {
            job.status = value;
            job.finished = YES;
        } else if ([parts[0] isEqualToString:@"FAILED"]) {
            job.status = -1;
            job.finished = YES;
        } else {
            job = nil;
        }
    }
    [gRunnerLock unlock];

    if (job && [parts[0] isEqualToString:@"FAILED"]) {
        zxAppendRuntimeLog([NSString stringWithFormat:
            @"ZXTouch: zxtouch-runner could not start the shell: %s", strerror(value)]);
    }
    if (job) dispatch_semaphore_signal(job.signal);
}

void zxRunnerStreamClosed(CFWriteStreamRef stream)
{
    zxRunnerInit();

    NSArray<ZXRunnerJob *> *orphaned = nil;
    [gRunnerLock lock];
    if (stream && stream == gRunnerStream) {
        gRunnerStream = NULL;
        orphaned = gRunnerJobs.allValues;
        for (ZXRunnerJob *job in orphaned) {
            if (!job.finished) {
                job.status = -1;
                job.finished = YES;
            }
        }
    }
    [gRunnerLock unlock];

    // The runner kills its children when it loses us. Release anyone waiting
    // rather than leaving a script thread blocked forever.
    for (ZXRunnerJob *job in orphaned) dispatch_semaphore_signal(job.signal);
}

BOOL zxRunnerWaitAvailable(double seconds)
{
    zxRunnerInit();
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    for (;;) {
        [gRunnerLock lock];
        BOOL available = gRunnerStream != NULL;
        [gRunnerLock unlock];
        if (available) return YES;
        if ([deadline timeIntervalSinceNow] <= 0) return NO;
        // Right after a respring the runner may still be reconnecting.
        usleep(100 * 1000);
    }
}

int zxRunnerRunCommand(const char *command, pid_t *processGroup, volatile sig_atomic_t *cancelRequested)
{
    zxRunnerInit();
    if (processGroup) *processGroup = 0;
    if (!command) return -1;

    ZXRunnerJob *job = [ZXRunnerJob new];
    job.signal = dispatch_semaphore_create(0);

    [gRunnerLock lock];
    CFWriteStreamRef stream = gRunnerStream;
    long long jobId = ++gRunnerNextJob;
    if (stream) gRunnerJobs[@(jobId)] = job;
    [gRunnerLock unlock];
    if (!stream) return -1;

    NSString *encoded = [[NSData dataWithBytes:command length:strlen(command)] base64EncodedStringWithOptions:0];
    if (!zxRunnerSend(stream, [NSString stringWithFormat:@"RUN;;%lld;;%@", jobId, encoded])) {
        [gRunnerLock lock];
        [gRunnerJobs removeObjectForKey:@(jobId)];
        [gRunnerLock unlock];
        return -1;
    }

    BOOL killSent = NO;
    for (;;) {
        dispatch_semaphore_wait(job.signal, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC));

        [gRunnerLock lock];
        pid_t pid = job.pid;
        BOOL finished = job.finished;
        int status = job.status;
        if (finished) [gRunnerJobs removeObjectForKey:@(jobId)];
        [gRunnerLock unlock];

        if (processGroup) *processGroup = finished ? 0 : pid;
        if (finished) return status;

        // ScriptPlayer's stop sets cancelRequested and also tries kill() itself,
        // which a sandboxed SpringBoard may not be allowed to do to a process
        // the runner started. Ask the runner, which owns that group.
        if (cancelRequested && *cancelRequested && pid > 0 && !killSent) {
            zxRunnerSend(stream, [NSString stringWithFormat:@"KILL;;%d", pid]);
            killSent = YES;
        }
    }
}
