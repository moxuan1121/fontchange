#import <Foundation/Foundation.h>

#import <roothide.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static int rebootUserspace(void) {
    const char *launchctl = jbroot("/bin/launchctl");
    char *const argv[] = {(char *)launchctl, "reboot", "userspace", NULL};
    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, launchctl, NULL, NULL, argv, environ);
    if (spawnResult != 0) return spawnResult;

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return 70;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 71;
}

static BOOL clearDirectoryContents(NSString *path, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&isDirectory]) return YES;

    if (!isDirectory) {
        return [manager removeItemAtPath:path error:error];
    }

    NSArray<NSString *> *children = [manager contentsOfDirectoryAtPath:path error:error];
    if (!children) return NO;

    for (NSString *child in children) {
        NSString *childPath = [path stringByAppendingPathComponent:child];
        if (![manager removeItemAtPath:childPath error:error]) return NO;
    }
    return YES;
}

static BOOL clearFontRelatedCaches(NSError **error) {
    NSArray<NSString *> *rootFSPaths = @[
        @"/bindfs/var/mobile/Library/Caches/com.apple.keyboards",
        @"/bindfs/var/mobile/Library/Caches/TelephonyUI-7",
        @"/bindfs/var/mobile/Library/Caches/TelephonyUI-8",
        @"/bindfs/var/mobile/Library/Caches/com.apple.UIStatusBar",
        @"/bindfs/var/mobile/Library/Caches/com.apple.sharingd",
        @"/bindfs/var/mobile/Library/SMS/com.apple.messages.geometrycache_v3.plist",
    ];

    for (NSString *rootFSPath in rootFSPaths) {
        NSString *path = jbroot(rootFSPath);
        if (!clearDirectoryContents(path, error)) {
            NSLog(@"Failed to clear cache at %@: %@", path, error ? *error : nil);
            return NO;
        }
    }
    return YES;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (geteuid() != 0) {
            NSLog(@"fontchange-helper must run as root");
            return 77;
        }

        NSString *argument = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        if ([argument isEqualToString:@"--clear-cache"]) {
            NSError *error = nil;
            if (!clearFontRelatedCaches(&error)) return 1;
            sync();
            return rebootUserspace();
        }

        NSLog(@"Usage: fontchange-helper --clear-cache");
        return 64;
    }
}
