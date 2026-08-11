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

static NSUInteger clearDirectoryContentsExcluding(NSString *path, NSSet<NSString *> *excludedNames) {
    NSFileManager *manager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) return 0;

    NSError *listingError = nil;
    NSArray<NSString *> *children = [manager contentsOfDirectoryAtPath:path error:&listingError];
    if (!children) {
        NSLog(@"Unable to list cache directory %@: %@", path, listingError);
        return 0;
    }

    NSUInteger removed = 0;
    for (NSString *child in children) {
        if ([excludedNames containsObject:child.lowercaseString]) {
            NSLog(@"Preserving protected cache entry %@", child);
            continue;
        }
        NSString *childPath = [path stringByAppendingPathComponent:child];
        NSError *removeError = nil;
        if ([manager removeItemAtPath:childPath error:&removeError]) {
            removed++;
        } else {
            NSLog(@"Unable to remove cache item %@: %@", childPath, removeError);
        }
    }
    return removed;
}

static NSUInteger clearDirectoryContents(NSString *path) {
    return clearDirectoryContentsExcluding(path, [NSSet set]);
}

static NSUInteger clearCachesInsideContainers(NSString *containersRoot) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSError *error = nil;
    NSArray<NSString *> *containers = [manager contentsOfDirectoryAtPath:containersRoot error:&error];
    if (!containers) {
        NSLog(@"Unable to list container root %@: %@", containersRoot, error);
        return 0;
    }

    NSUInteger removed = 0;
    for (NSString *container in containers) {
        // Never descend into RootHide's hidden .jbroot-* directories.
        if ([container hasPrefix:@"."]) continue;
        NSString *cachePath = [[[containersRoot stringByAppendingPathComponent:container]
            stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:@"Caches"];
        removed += clearDirectoryContents(cachePath);
    }
    return removed;
}

static NSUInteger clearICleanerStyleCaches(void) {
    NSUInteger removed = 0;

    // Preserve authorization and privacy state maintained by location/TCC services.
    NSSet<NSString *> *protectedMobileCaches = [NSSet setWithArray:@[
        @"locationd",
        @"com.apple.locationd",
        @"com.apple.corelocation",
        @"com.apple.tccd",
        @"tccd",
        @"com.apple.privacyaccounting",
        @"com.apple.routined",
        @"routined",
        @"geoservices",
        @"com.apple.geoservices",
    ]];

    // System/user caches. Only child entries are removed; the cache roots remain.
    removed += clearDirectoryContentsExcluding(@"/var/mobile/Library/Caches", protectedMobileCaches);
    removed += clearDirectoryContents(@"/var/root/Library/Caches");

    // Per-app and shared container caches. Documents and Preferences are never traversed.
    NSArray<NSString *> *containerRoots = @[
        @"/var/mobile/Containers/Data/Application",
        @"/var/mobile/Containers/Data/System",
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/var/mobile/Containers/Shared/SystemGroup",
    ];
    for (NSString *root in containerRoots) {
        removed += clearCachesInsideContainers(root);
    }

    return removed;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (geteuid() != 0) {
            NSLog(@"fontchange-helper must run as root");
            return 77;
        }

        NSString *argument = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        if ([argument isEqualToString:@"--clear-all-caches"]) {
            NSUInteger removed = clearICleanerStyleCaches();
            NSLog(@"Font cache refresh removed %lu cache entries", (unsigned long)removed);
            sync();
            return rebootUserspace();
        }

        NSLog(@"Usage: fontchange-helper --clear-all-caches");
        return 64;
    }
}
