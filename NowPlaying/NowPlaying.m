// Now Playing helper for Aula Lights: what's playing (any app: Arc, Spotify, Music, …)
// and play/pause, next, previous.
//
// macOS only answers its own programs on this API, so Aula Lights loads this library
// into /usr/bin/perl, which macOS does answer (the technique open-source tools such as
// mediaremote-adapter use). It runs once on load, prints one line of JSON, and exits.
//
// AULA_NP = info | toggle | next | previous   (default: info)

#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef Boolean (*SendCommand)(int, NSDictionary *);

static id call(id target, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!target || ![target respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    inv.target = target;
    [inv invoke];
    const char *type = sig.methodReturnType;
    if (type[0] == '@') { void *p = NULL; [inv getReturnValue:&p]; return (__bridge id)p; }
    if (type[0] == 'd') { double d = 0; [inv getReturnValue:&d]; return @(d); }
    if (type[0] == 'B' || type[0] == 'c') { BOOL b = NO; [inv getReturnValue:&b]; return @(b); }
    return nil;
}

__attribute__((constructor)) static void run(void) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        NSString *what = NSProcessInfo.processInfo.environment[@"AULA_NP"] ?: @"info";
        NSDictionary *commands = @{ @"toggle": @2, @"next": @4, @"previous": @5 };
        NSMutableDictionary *out = [NSMutableDictionary dictionary];

        if (commands[what]) {
            SendCommand send = (SendCommand)dlsym(h, "MRMediaRemoteSendCommand");
            out[@"sent"] = @(send ? send([commands[what] intValue], nil) : NO);
            if (![what isEqualToString:@"toggle"]) [NSThread sleepForTimeInterval:0.35];  // let the next track load
        }

        Class request = NSClassFromString(@"MRNowPlayingRequest");
        id metadata = call(call(request, @"localNowPlayingItem"), @"metadata");
        id client = call(call(request, @"localNowPlayingPlayerPath"), @"client");
        out[@"title"] = call(metadata, @"title") ?: @"";
        out[@"artist"] = call(metadata, @"trackArtistName") ?: @"";
        out[@"album"] = call(metadata, @"albumName") ?: @"";
        out[@"duration"] = call(metadata, @"duration") ?: @0;
        out[@"app"] = call(client, @"bundleIdentifier") ?: @"";
        out[@"playing"] = call(request, @"localIsPlaying") ?: @NO;

        NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }
}
