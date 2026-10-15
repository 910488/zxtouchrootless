//
//  Socket.m
//  zxtouch
//
//  Created by Jason on 2020/12/11.
//

#import "Socket.h"
#include <errno.h>
#include <sys/time.h>


@implementation Socket
{
    int socketHandle;
}

/**
 Connect to a server, return -1 if fail
 */
-(int) connect: (NSString*) ip byPort:(int) port
{
    //NSLog(@"ip: %@, and port: %d", ip, port);、
    int sock = 0;
    struct sockaddr_in serv_addr;

    if ((sock = socket(AF_INET, SOCK_STREAM, 0)) < 0)
    {
        NSLog(@"### com.zjx.zxtouchb:  Socket creation error");
        return -1;
        
    }
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_port = htons(port);

    // Convert IPv4 and IPv6 addresses from text to binary form
    if(inet_pton(AF_INET, [ip UTF8String], &serv_addr.sin_addr)<=0)
    {
        NSLog(@"### com.zjx.zxtouchb: Invalid address. Address not supported");
        return -1;
    }

    if (connect(sock, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0)
    {
        NSLog(@"### com.zjx.zxtouchb: \nConnection Failed \n");
        return -1;
    }
    // Never block the caller forever. playButtonClick: and friends call -recv:
    // straight from the main thread, so a tweak that does not answer freezes the
    // whole app until it is force quit, which is exactly what a missing frame
    // terminator used to cause.
    struct timeval timeout;
    timeout.tv_sec = 10;
    timeout.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    socketHandle = sock;
    return 0;
}

-(BOOL) isConnected {
    return socketHandle != 0;
}

-(void) send: (NSString*)msg
{
    // The tweak frames commands on CRLF. Callers have always been inconsistent
    // about adding it, and it only worked because the old server parsed with
    // strtok on a zero-filled buffer, which returns the whole string when no
    // delimiter is present. Proper framing made that leniency disappear and an
    // unterminated command simply sits in the server's buffer, so the reply
    // never comes. Terminate here, once, for every caller.
    if (![msg hasSuffix:@"\r\n"]) {
        msg = [msg stringByAppendingString:@"\r\n"];
    }
    const char *buffer = [msg UTF8String];
    send(socketHandle , buffer, strlen(buffer) , 0);
}

-(void) sendChar: (char*)msg
{
    send(socketHandle , msg, strlen(msg) , 0);
}

-(NSString*) recv:(int)length
{
    char buffer[length];
    memset(buffer, 0, sizeof(buffer));
    ssize_t received = recv(socketHandle, buffer, length - 1, 0);
    if (received <= 0) {
        NSLog(@"### com.zjx.zxtouchb: recv returned %zd (%s)", received, strerror(errno));
        return @"";
    }
    buffer[received] = '\0';
    return [NSString stringWithUTF8String:buffer] ?: @"";
}

-(void)close {
    if (!socketHandle)
        return;
    close(socketHandle);
    socketHandle = 0;
}

-(void)dealloc {
    [self close];
}

@end
