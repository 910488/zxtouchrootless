#ifndef RUNNER_H
#define RUNNER_H

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <signal.h>

// SpringBoard side of zxtouch-runner. See zxtouch-runner/main.m.

void zxRunnerRegister(const char *secret, CFWriteStreamRef stream);
void zxRunnerHandleEvent(const char *payload, CFWriteStreamRef stream);
void zxRunnerStreamClosed(CFWriteStreamRef stream);

BOOL zxRunnerWaitAvailable(double seconds);

// Runs `/bin/sh -c command` through the runner and blocks until it exits.
// Returns the exit code, 128 + signal, or -1 if it could not be run.
int zxRunnerRunCommand(const char *command, pid_t *processGroup, volatile sig_atomic_t *cancelRequested);

#endif
