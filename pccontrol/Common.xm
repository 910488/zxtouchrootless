#include "Common.h"
#include "Config.h"
#import <sys/utsname.h>
#import <sys/wait.h>
#include <dlfcn.h>
#include <spawn.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>


// Does this path look like a runnable program?
//
// Deliberately NOT access(X_OK) or isExecutableFileAtPath:. Those ask "may THIS
// process exec this file", and this process is SpringBoard. On iOS 18 the
// sandbox answers EPERM for Procursus binaries that plainly exist, are readable
// and are mode 0755, so a perfectly good python3 was reported missing and
// scripts refused to run.
//
// SpringBoard never execs the interpreter itself. It posix_spawns /bin/sh and
// the shell execs it, under the shell's own sandbox. So the question to ask
// here is only whether the file is a regular file carrying an execute bit, and
// to let the spawn report a real failure if there is one.
Boolean zxPathLooksExecutable(const char *path)
{
    if (!path || !*path) return false;

    struct stat st;
    if (stat(path, &st) != 0) return false;   // follows symlinks, so python3 -> python3.9 resolves
    if (!S_ISREG(st.st_mode)) return false;

    return (st.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0;
}

// Write to the same log the app's Logs tab reads. A failure here happens before
// any script launches, so the shell wrapper that normally writes this file never
// runs, and the user is left with an empty log and nothing to report.
void zxAppendRuntimeLog(NSString *text)
{
    NSString *logPath = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/output";
    NSFileManager *fm = [NSFileManager defaultManager];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"MM-dd-yyyy HH:mm:ss";
    NSString *stamped = [NSString stringWithFormat:@"%@: %@\n", [formatter stringFromDate:[NSDate date]], text];

    if (![fm fileExistsAtPath:logPath]) {
        [fm createDirectoryAtPath:[logPath stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
        [stamped writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
    }
    @catch (NSException *exception) {
        NSLog(@"com.zjx.springboard: could not append to runtime log: %@", exception.reason);
    }
    @finally {
        [handle closeFile];
    }
}

int call_system(const char *cmd)
{
    static int (*sys_fn)(const char *) = NULL;
    if (!sys_fn)
        sys_fn = (int (*)(const char *))dlsym(RTLD_DEFAULT, "system");
    return sys_fn ? sys_fn(cmd) : -1;
}


/*
Get device model name
*/
NSString* getDeviceName()
{
    struct utsname systemInfo;
    uname(&systemInfo);

    return [NSString stringWithCString:systemInfo.machine
                                encoding:NSUTF8StringEncoding];
}

/*
round up number by multiple of another number
*/
int roundUp(int numToRound, int multiple)
{
    if (multiple == 0)
        return numToRound;

    int remainder = numToRound % multiple;
    if (remainder == 0)
        return numToRound;

    return numToRound + multiple - remainder;
}

/*
Check whether current device is an iPad
*/
Boolean isIpad()
{
    if ( [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad )
    {
        return YES;
    }
    return NO;
}

/*
generate a random integer between min and max.

ONLY POSITIVE NUMBER IS SUPPORTED!
*/
int getRandomNumberInt(int min, int max)
{
	min = abs(min);
	max = abs(max);

	if (max < min)
	{
		NSLog(@"### com.zjx.springboard: Max is less than min in getRandomNumberInt(). max: %d, min: %d", max, min);
	}
	return arc4random_uniform(abs(max-min)) + min;
}

/*
generate a random float between min and max.

ONLY POSITIVE NUMBER IS SUPPORTED!
ONLY SUPPORTS TO UP TO 5 DIGIT.
*/
float getRandomNumberFloat(float min, float max)
{
	min = abs(min);
	max = abs(max);

	if (max < min)
	{
		NSLog(@"### com.zjx.springboard: Max is less than min in getRandomNumberFloat(). max: %f, min: %f", max, min);
	}

	
	return getRandomNumberInt((int)(min*10000), (int)(max*10000))/10000.0f;
}

/**
Get document root of springboard
*/
NSString* getDocumentRoot()
{
    //NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [NSString stringWithFormat:@"/var/mobile/Library/%s/" ,DOCUMENT_ROOT_FOLDER_NAME];
}

/**
Get scripts path
*/
NSString* getScriptsFolder()
{
    //NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [NSString stringWithFormat:@"%@/%s/", getDocumentRoot(), SCRIPT_FOLDER_NAME];
}

/**
Get config dir
*/
NSString *getConfigFilePath()
{
	return [getDocumentRoot() stringByAppendingPathComponent:@CONFIG_FOLDER_NAME];
}

NSString *getCommonConfigFilePath()
{
    return [getConfigFilePath() stringByAppendingPathComponent:@COMMON_CONFIG_NAME];
}

void swapCGFloat(CGFloat *a, CGFloat *b)
{
	CGFloat temp = *a;
	*a = *b;
	*b = temp;
}

// Spawn `/bin/sh -c command` via posix_spawn. Raw fork() is blocked by the
// sandbox in a SpringBoard-injected tweak on some jailbreaks (palera1n-rootless,
// certain roothide setups), which surfaces to users as "Python script exited
// with code -1" with an empty log. posix_spawn is the supported path.
pid_t system2(const char *command, int *infp, int *outfp)
{
    return system2Cancelable(command, infp, outfp, NULL, NULL);
}

pid_t system2Cancelable(const char *command, int *infp, int *outfp,
                        pid_t *processGroup, volatile sig_atomic_t *cancelRequested)
{
    int p_stdin[2] = {-1, -1};
    int p_stdout[2] = {-1, -1};
    if (processGroup) *processGroup = 0;

    if (pipe(p_stdin) == -1) {
        NSLog(@"com.zjx.springboard: system2 pipe(stdin) failed: %s", strerror(errno));
        return -1;
    }

    if (pipe(p_stdout) == -1) {
        NSLog(@"com.zjx.springboard: system2 pipe(stdout) failed: %s", strerror(errno));
        close(p_stdin[0]);
        close(p_stdin[1]);
        return -1;
    }

    const char *shellPath = jbroot("/bin/sh");
    if (!shellPath || !zxPathLooksExecutable(shellPath)) {
        // jbroot() returned something unusable; try known rootless fallbacks.
        static const char *candidates[] = {
            "/var/jb/bin/sh",
            "/var/jb/usr/bin/sh",
            "/bin/sh",
            "/usr/bin/sh",
            NULL
        };
        shellPath = NULL;
        for (int i = 0; candidates[i]; ++i) {
            if (zxPathLooksExecutable(candidates[i])) { shellPath = candidates[i]; break; }
        }
        if (!shellPath) {
            NSString *report = [NSString stringWithFormat:
                @"ZXTouch: no usable shell found. jbroot(\"/bin/sh\") = %@", jbroot(@"/bin/sh")];
            NSLog(@"com.zjx.springboard: %@", report);
            zxAppendRuntimeLog(report);
            close(p_stdin[0]); close(p_stdin[1]);
            close(p_stdout[0]); close(p_stdout[1]);
            return -1;
        }
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);

    // stdin: child reads from p_stdin[0]
    posix_spawn_file_actions_adddup2(&actions, p_stdin[0], STDIN_FILENO);
    posix_spawn_file_actions_addclose(&actions, p_stdin[0]);
    posix_spawn_file_actions_addclose(&actions, p_stdin[1]);

    if (outfp == NULL) {
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addclose(&actions, p_stdout[0]);
        posix_spawn_file_actions_addclose(&actions, p_stdout[1]);
    } else {
        posix_spawn_file_actions_adddup2(&actions, p_stdout[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, p_stdout[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, p_stdout[0]);
        posix_spawn_file_actions_addclose(&actions, p_stdout[1]);
    }

    posix_spawnattr_t attrs;
    posix_spawnattr_init(&attrs);
    // Reset signal handlers and clear any inherited signal mask so the shell
    // doesn't inherit SpringBoard's oddities.
    sigset_t emptyset;
    sigemptyset(&emptyset);
    posix_spawnattr_setsigmask(&attrs, &emptyset);
    short spawnFlags = POSIX_SPAWN_SETSIGMASK;
    if (processGroup) {
        // A dedicated process group lets ScriptPlayer stop the shell, Python,
        // and the log pipeline together without killing unrelated Python jobs.
        posix_spawnattr_setpgroup(&attrs, 0);
        spawnFlags |= POSIX_SPAWN_SETPGROUP;
    }
    posix_spawnattr_setflags(&attrs, spawnFlags);

    char * const argv[] = {
        (char *)"sh",
        (char *)"-c",
        (char *)command,
        NULL
    };
    extern char **environ;

    pid_t pid = 0;
    int spawnErr = posix_spawn(&pid, shellPath, &actions, &attrs, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attrs);

    if (spawnErr != 0) {
        // Put this in the log the app shows. Telling a user to open Console.app
        // is useless in practice, and the errno is the whole diagnosis: EPERM
        // means the sandbox refused the exec, ENOENT means the path is wrong.
        NSString *report = [NSString stringWithFormat:
            @"ZXTouch: posix_spawn(%s) failed: %s (errno %d). command=%.120s",
            shellPath, strerror(spawnErr), spawnErr, command];
        NSLog(@"com.zjx.springboard: %@", report);
        zxAppendRuntimeLog(report);

        struct stat sst;
        if (stat(shellPath, &sst) == 0) {
            zxAppendRuntimeLog([NSString stringWithFormat:
                @"ZXTouch: shell %s exists, mode=%04o, size=%lld",
                shellPath, sst.st_mode & 07777, (long long)sst.st_size]);
        } else {
            zxAppendRuntimeLog([NSString stringWithFormat:
                @"ZXTouch: shell %s cannot be stat'd: %s", shellPath, strerror(errno)]);
        }

        // Dopamine's own 2.2.2 changelog records that certain sandbox profiles
        // "block posix_spawn but allow execve". SpringBoard on iOS 18 behaves
        // exactly that way: the shell is present and mode 0755, yet the spawn
        // is refused with EPERM while the same binary runs fine from a shell.
        // So fall back to fork + execve rather than giving up.
        //
        // posix_spawn stays the primary path on purpose. Raw fork() is itself
        // denied inside SpringBoard on some other jailbreaks (that is why this
        // function stopped using fork in the first place), so neither call
        // works everywhere and each covers the other's gap.
        if (spawnErr == EPERM) {
            zxAppendRuntimeLog(@"ZXTouch: retrying with fork + execve.");

            pid = fork();
            if (pid == 0) {
                // Child. Nothing here may allocate or call into Objective-C:
                // only async-signal-safe syscalls between fork and execve.
                if (processGroup) setpgid(0, 0);
                dup2(p_stdin[0], STDIN_FILENO);
                dup2(p_stdout[1], STDOUT_FILENO);
                dup2(p_stdout[1], STDERR_FILENO);
                close(p_stdin[0]); close(p_stdin[1]);
                close(p_stdout[0]); close(p_stdout[1]);
                execve(shellPath, argv, environ);

                // execve failed. stderr is already pointed at the pipe that
                // feeds the log, so report the reason there. Only
                // async-signal-safe calls are allowed between fork and exec,
                // which rules out NSLog and friends.
                int execErrno = errno;
                const char *prefix = "ZXTouch: execve failed: ";
                write(STDERR_FILENO, prefix, strlen(prefix));
                const char *reason = strerror(execErrno);
                if (reason) write(STDERR_FILENO, reason, strlen(reason));
                write(STDERR_FILENO, "\n", 1);

                // 125, not 127: the shell itself uses 126 and 127 for "found
                // but not executable" and "not found", so a distinct code keeps
                // "our exec failed" apart from "the shell could not run python".
                _exit(125);
            }

            if (pid > 0) {
                // Only fork() is known to have worked at this point. Whether the
                // execve in the child succeeded is reported by the child itself,
                // either through its output or through exit code 125.
                zxAppendRuntimeLog([NSString stringWithFormat:
                    @"ZXTouch: fork succeeded (pid %d), exec result follows.", pid]);
                goto spawned;
            }

            zxAppendRuntimeLog([NSString stringWithFormat:
                @"ZXTouch: fork also failed: %s", strerror(errno)]);
        }

        close(p_stdin[0]); close(p_stdin[1]);
        close(p_stdout[0]); close(p_stdout[1]);
        return -1;
    }

spawned:
    if (processGroup) *processGroup = pid;
    if (cancelRequested && *cancelRequested) {
        kill(-pid, SIGKILL);
    }

    close(p_stdin[0]);
    close(p_stdout[1]);

    if (infp == NULL) {
        close(p_stdin[1]);
    } else {
        *infp = p_stdin[1];
    }

    if (outfp == NULL) {
        close(p_stdout[0]);
    } else {
        *outfp = p_stdout[0];
    }

    int status = 0;
    if (waitpid(pid, &status, 0) == -1) {
        NSLog(@"com.zjx.springboard: system2 waitpid failed: %s", strerror(errno));
        if (processGroup) *processGroup = 0;
        return -1;
    }
    if (processGroup) *processGroup = 0;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}
