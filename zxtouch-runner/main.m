// zxtouch-runner
//
// Runs shell commands for the ZXTouch tweak from outside SpringBoard.
//
// On iOS 18, SpringBoard's sandbox refuses to exec anything inside the jbroot:
// posix_spawn and execve both fail with EPERM, and the executable extension
// Dopamine hands every process does not authorize exec for SpringBoard there.
// The tweak therefore cannot start a script itself. This daemon runs under
// launchd as mobile, connects to the tweak's socket on port 6000, proves it is
// the real runner with a shared secret, and runs whatever the tweak sends it.
//
// One message per line, CRLF terminated:
//   runner -> tweak   40<secret>                 register
//                     41STARTED;;<job>;;<pid>     running; pid is also its process group
//                     41DONE;;<job>;;<status>     exit code, or 128 + signal number
//                     41FAILED;;<job>;;<errno>    the shell could not be started
//   tweak -> runner   RUN;;<job>;;<base64 command>
//                     KILL;;<pgid>

#import <Foundation/Foundation.h>
#include <roothide.h>
#include <spawn.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <netinet/in.h>

extern char **environ;

#define TWEAK_PORT 6000

static NSString *const kSecretPath = @"/var/mobile/Library/ZXTouch/config/tweak/runner.secret";

// Guards gSock, gGeneration and gGroups.
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static int gSock = -1;
static unsigned long gGeneration = 0;
static NSMutableSet<NSNumber *> *gGroups;

static char gShellPath[PATH_MAX];

static void sendLine(unsigned long generation, NSString *line)
{
    NSData *data = [[line stringByAppendingString:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding];

    pthread_mutex_lock(&gLock);
    // A job can outlive the connection it arrived on. Its result must not be
    // written into a newer connection that reused the same descriptor number.
    if (generation == gGeneration && gSock >= 0) {
        const uint8_t *bytes = data.bytes;
        size_t left = data.length;
        while (left > 0) {
            ssize_t n = send(gSock, bytes, left, 0);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            bytes += n;
            left -= (size_t)n;
        }
    }
    pthread_mutex_unlock(&gLock);
}

static NSString *loadOrCreateSecret(void)
{
    NSString *existing = [[NSString stringWithContentsOfFile:kSecretPath encoding:NSUTF8StringEncoding error:nil]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (existing.length >= 64) return existing;

    uint8_t raw[32];
    arc4random_buf(raw, sizeof(raw));
    NSMutableString *hex = [NSMutableString stringWithCapacity:sizeof(raw) * 2];
    for (size_t i = 0; i < sizeof(raw); i++) [hex appendFormat:@"%02x", raw[i]];

    [[NSFileManager defaultManager] createDirectoryAtPath:[kSecretPath stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];

    // Created 0600 from the outset so there is no moment where it is readable
    // by anyone but mobile.
    int fd = open(kSecretPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return nil;
    fchmod(fd, 0600);
    const char *bytes = hex.UTF8String;
    BOOL ok = write(fd, bytes, strlen(bytes)) == (ssize_t)strlen(bytes);
    close(fd);
    return ok ? hex : nil;
}

static BOOL looksExecutable(const char *path)
{
    struct stat st;
    return path && stat(path, &st) == 0 && S_ISREG(st.st_mode) && (st.st_mode & 0111);
}

static void resolveShell(void)
{
    // jbroot() writes into one static buffer, so take a copy before calling it
    // or anything else that might.
    char viaJbroot[PATH_MAX];
    strlcpy(viaJbroot, jbroot("/bin/sh"), sizeof(viaJbroot));

    const char *candidates[] = { viaJbroot, "/var/jb/bin/sh", "/var/jb/usr/bin/sh", "/bin/sh", NULL };
    for (int i = 0; candidates[i]; i++) {
        if (looksExecutable(candidates[i])) {
            strlcpy(gShellPath, candidates[i], sizeof(gShellPath));
            return;
        }
    }
    strlcpy(gShellPath, "/bin/sh", sizeof(gShellPath));
}

static void prepareEnvironment(void)
{
    // launchd starts daemons with a bare environment. Scripts call plain rm,
    // cat and friends, which on a rootless jailbreak only exist in the jbroot.
    NSArray<NSString *> *dirs = @[
        jbroot(@"/usr/local/bin"), jbroot(@"/usr/bin"), jbroot(@"/bin"),
        jbroot(@"/usr/sbin"), jbroot(@"/sbin"),
        @"/usr/bin", @"/bin", @"/usr/sbin", @"/sbin"
    ];
    setenv("PATH", [dirs componentsJoinedByString:@":"].UTF8String, 1);
    setenv("HOME", "/var/mobile", 0);
    setenv("USER", "mobile", 0);
    setenv("LOGNAME", "mobile", 0);
    setenv("TMPDIR", "/var/tmp", 0);
}

static void runJob(unsigned long generation, NSString *jobId, NSString *command)
{
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    // Matches the tweak's own spawn when no pipes are requested: the command
    // writes its own log, so the shell's standard streams go nowhere.
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    posix_spawnattr_t attrs;
    posix_spawnattr_init(&attrs);
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    posix_spawnattr_setsigmask(&attrs, &none);
    // This daemon ignores SIGPIPE. Without resetting dispositions the script
    // would inherit that and survive a broken pipe it should die from.
    posix_spawnattr_setsigdefault(&attrs, &all);
    // A process group of its own, so a stop ends the shell, python and the
    // log pipeline together.
    posix_spawnattr_setpgroup(&attrs, 0);
    posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP);

    char *argv[] = { (char *)"sh", (char *)"-c", (char *)command.UTF8String, NULL };
    pid_t pid = 0;
    int err = posix_spawn(&pid, gShellPath, &actions, &attrs, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attrs);

    if (err != 0) {
        sendLine(generation, [NSString stringWithFormat:@"41FAILED;;%@;;%d", jobId, err]);
        return;
    }

    pthread_mutex_lock(&gLock);
    [gGroups addObject:@(pid)];
    pthread_mutex_unlock(&gLock);

    sendLine(generation, [NSString stringWithFormat:@"41STARTED;;%@;;%d", jobId, pid]);

    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(pid, &status, 0);
    } while (waited < 0 && errno == EINTR);

    pthread_mutex_lock(&gLock);
    [gGroups removeObject:@(pid)];
    pthread_mutex_unlock(&gLock);

    int code = -1;
    if (waited == pid) {
        if (WIFEXITED(status)) code = WEXITSTATUS(status);
        else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
    }
    sendLine(generation, [NSString stringWithFormat:@"41DONE;;%@;;%d", jobId, code]);
}

static void handleLine(unsigned long generation, NSString *line)
{
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@";;"];

    if (parts.count == 3 && [parts[0] isEqualToString:@"RUN"]) {
        NSString *jobId = parts[1];
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:parts[2] options:0];
        NSString *command = decoded ? [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding] : nil;
        if (!command) {
            sendLine(generation, [NSString stringWithFormat:@"41FAILED;;%@;;%d", jobId, EINVAL]);
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                runJob(generation, jobId, command);
            }
        });
    }
    else if (parts.count == 2 && [parts[0] isEqualToString:@"KILL"]) {
        pid_t pgid = (pid_t)[parts[1] intValue];
        pthread_mutex_lock(&gLock);
        BOOL ours = pgid > 1 && [gGroups containsObject:@(pgid)];
        pthread_mutex_unlock(&gLock);
        // Only groups this runner started, never an arbitrary pid it is handed.
        if (ours) kill(-pgid, SIGKILL);
    }
}

static void killAllGroups(void)
{
    pthread_mutex_lock(&gLock);
    for (NSNumber *pgid in gGroups) kill(-pgid.intValue, SIGKILL);
    pthread_mutex_unlock(&gLock);
}

static int connectToTweak(void)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;

    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(TWEAK_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(s, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(s);
        return -1;
    }
    return s;
}

int main(void)
{
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        gGroups = [NSMutableSet set];
        resolveShell();
        prepareEnvironment();
    }

    for (;;) {
        @autoreleasepool {
            NSString *secret = loadOrCreateSecret();
            int s = secret ? connectToTweak() : -1;
            if (s < 0) {
                // SpringBoard is not up yet, or is respringing.
                sleep(2);
                continue;
            }

            pthread_mutex_lock(&gLock);
            gSock = s;
            unsigned long generation = ++gGeneration;
            pthread_mutex_unlock(&gLock);

            sendLine(generation, [@"40" stringByAppendingString:secret]);

            NSData *crlf = [NSData dataWithBytes:"\r\n" length:2];
            NSMutableData *pending = [NSMutableData data];
            uint8_t buf[4096];
            for (;;) {
                ssize_t n = recv(s, buf, sizeof(buf), 0);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) break;
                [pending appendBytes:buf length:(NSUInteger)n];

                for (;;) {
                    NSRange r = [pending rangeOfData:crlf options:0 range:NSMakeRange(0, pending.length)];
                    if (r.location == NSNotFound) break;
                    NSString *line = [[NSString alloc] initWithData:[pending subdataWithRange:NSMakeRange(0, r.location)]
                                                           encoding:NSUTF8StringEncoding];
                    [pending replaceBytesInRange:NSMakeRange(0, r.location + 2) withBytes:NULL length:0];
                    if (line.length) handleLine(generation, line);
                }
                // A peer that never sends a line terminator is not the tweak.
                if (pending.length > (1 << 20)) break;
            }

            pthread_mutex_lock(&gLock);
            gSock = -1;
            pthread_mutex_unlock(&gLock);
            close(s);

            // SpringBoard is gone. Scripts talk to it constantly, so leaving
            // them running with nothing on the other end helps no one.
            killAllGroups();
        }
        sleep(1);
    }
}
