#import <Foundation/Foundation.h>

#import <roothide.h>
#import <dlfcn.h>
#import <errno.h>
#import <sys/mount.h>
#import <sys/param.h>
#import <sys/stat.h>
#import <unistd.h>

typedef int (*FCStealUcredFunction)(uint64_t, uint64_t *);
typedef int (*FCInitPPLRWFunction)(void);

static NSString *FCSourcePath(void) {
    return [NSString stringWithUTF8String:jbroot("/var/lib/fontchange-mount/System/Library/Fonts")];
}

static NSString *FCEnabledPath(void) {
    return [NSString stringWithUTF8String:jbroot("/var/lib/fontchange-mount/enabled")];
}

static BOOL FCValidFontTree(NSString *path) {
    BOOL directory = NO;
    NSFileManager *manager = NSFileManager.defaultManager;
    return [manager fileExistsAtPath:path isDirectory:&directory] && directory &&
        [manager fileExistsAtPath:[path stringByAppendingPathComponent:@"Core"]] &&
        [manager fileExistsAtPath:[path stringByAppendingPathComponent:@"CoreUI"]];
}

static BOOL FCTargetIsMountPoint(void) {
    struct statfs info = {0};
    if (statfs("/System/Library/Fonts", &info) != 0) return NO;
    return strcmp(info.f_mntonname, "/System/Library/Fonts") == 0;
}

static BOOL FCOwnMountIsActive(void) {
    struct statfs info = {0};
    if (statfs("/System/Library/Fonts", &info) != 0) return NO;
    NSString *source = FCSourcePath().stringByStandardizingPath;
    NSString *mountedSource = [NSString stringWithUTF8String:info.f_mntfromname].stringByStandardizingPath;
    return strcmp(info.f_fstypename, "bindfs") == 0 &&
        strcmp(info.f_mntonname, "/System/Library/Fonts") == 0 &&
        ([mountedSource isEqualToString:source] ||
         [mountedSource hasSuffix:@"/var/lib/fontchange-mount/System/Library/Fonts"]);
}

static void *FCOpenLibjailbreak(void) {
    const char *translatedBasebin = jbroot("/basebin/libjailbreak.dylib");
    const char *translatedUsrLib = jbroot("/usr/lib/libjailbreak.dylib");
    const char *candidates[] = {
        translatedBasebin,
        translatedUsrLib,
        "/var/jb/basebin/libjailbreak.dylib",
        "/var/jb/usr/lib/libjailbreak.dylib",
        NULL
    };
    for (NSUInteger index = 0; candidates[index]; index++) {
        if (access(candidates[index], R_OK) != 0) continue;
        void *handle = dlopen(candidates[index], RTLD_NOW | RTLD_LOCAL);
        if (handle) return handle;
    }
    return NULL;
}

static int FCWithKernelCredentials(int (^operation)(void)) {
    void *handle = FCOpenLibjailbreak();
    if (!handle) return 90;

    FCInitPPLRWFunction initialize = (FCInitPPLRWFunction)dlsym(handle, "jbdInitPPLRW");
    if (initialize) initialize();
    FCStealUcredFunction steal = (FCStealUcredFunction)dlsym(handle, "jbclient_root_steal_ucred");
    if (!steal) {
        dlclose(handle);
        return 91;
    }

    uint64_t originalCredential = 0;
    int status = steal(0, &originalCredential);
    if (status == 0) {
        status = operation();
        int restoreStatus = steal(originalCredential, NULL);
        if (status == 0 && restoreStatus != 0) status = 92;
    }
    dlclose(handle);
    return status;
}

static int FCUnmountTarget(void) {
    if (!FCTargetIsMountPoint()) return 0;
    return FCWithKernelCredentials(^int{
        return unmount("/System/Library/Fonts", MNT_FORCE) == 0 ? 0 : errno;
    });
}

static int FCMountSnapshot(void) {
    if (FCOwnMountIsActive()) return 0;
    if (!FCValidFontTree(FCSourcePath())) return 93;
    int unmountStatus = FCUnmountTarget();
    if (unmountStatus != 0) return unmountStatus;
    return FCWithKernelCredentials(^int{
        return mount("bindfs", "/System/Library/Fonts", MNT_RDONLY,
            (void *)FCSourcePath().fileSystemRepresentation) == 0 ? 0 : errno;
    });
}

static void FCRemoveLegacyFontPathFromPlist(NSString *relativePath) {
    NSString *path = [NSString stringWithUTF8String:jbroot(relativePath.UTF8String)];
    NSMutableDictionary *configuration = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!configuration) return;
    NSArray *storedPaths = [configuration[@"path"] isKindOfClass:NSArray.class] ? configuration[@"path"] : nil;
    if (![storedPaths containsObject:@"/System/Library/Fonts"]) return;
    NSMutableArray *updatedPaths = storedPaths.mutableCopy;
    [updatedPaths removeObject:@"/System/Library/Fonts"];
    configuration[@"path"] = updatedPaths;
    [configuration writeToFile:path atomically:YES];
}

static void FCDisableLegacyFontMounts(void) {
    // Remove only the Fonts entry; unrelated GenericMount/zqbb mounts remain intact.
    FCRemoveLegacyFontPathFromPlist(@"/var/mobile/Library/RootHide/com.moxuan1121.genericmount.plist");
    FCRemoveLegacyFontPathFromPlist(@"/var/mobile/Library/RootHide/cn.zqbb.mount.rh.plist");
    FCRemoveLegacyFontPathFromPlist(@"/var/mobile/Library/Preferences/com.nan.auto-bindfs.plist");
}

static int FCCopyNativeSnapshot(BOOL replaceExisting) {
    int unmountStatus = FCUnmountTarget();
    if (unmountStatus != 0) return unmountStatus;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *source = FCSourcePath();
    NSString *base = source.stringByDeletingLastPathComponent;
    NSString *temporary = [base stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Fonts.new.%@", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    if (![manager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:&error]) return 94;
    if (replaceExisting) [manager removeItemAtPath:source error:nil];
    [manager removeItemAtPath:temporary error:nil];
    if (![manager copyItemAtPath:@"/System/Library/Fonts" toPath:temporary error:&error]) return 95;
    if (!FCValidFontTree(temporary)) {
        [manager removeItemAtPath:temporary error:nil];
        return 96;
    }
    if ([manager fileExistsAtPath:source] && ![manager removeItemAtPath:source error:&error]) {
        [manager removeItemAtPath:temporary error:nil];
        return 97;
    }
    if (![manager moveItemAtPath:temporary toPath:source error:&error]) {
        [manager removeItemAtPath:temporary error:nil];
        return 98;
    }
    return 0;
}

static int FCPrepare(void) {
    if (FCOwnMountIsActive() && FCValidFontTree(FCSourcePath())) {
        FCDisableLegacyFontMounts();
        return 0;
    }
    if (!FCValidFontTree(FCSourcePath())) {
        int copyStatus = FCCopyNativeSnapshot(NO);
        if (copyStatus != 0) return copyStatus;
    }
    int mountStatus = FCMountSnapshot();
    if (mountStatus != 0) return mountStatus;
    [NSFileManager.defaultManager createDirectoryAtPath:FCEnabledPath().stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [@"enabled" writeToFile:FCEnabledPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    FCDisableLegacyFontMounts();
    return FCOwnMountIsActive() ? 0 : 99;
}

static int FCReset(void) {
    int copyStatus = FCCopyNativeSnapshot(YES);
    if (copyStatus != 0) return copyStatus;
    int mountStatus = FCMountSnapshot();
    if (mountStatus != 0) return mountStatus;
    [@"enabled" writeToFile:FCEnabledPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    FCDisableLegacyFontMounts();
    return FCOwnMountIsActive() ? 0 : 99;
}

static int FCDaemon(void) {
    if (![NSFileManager.defaultManager fileExistsAtPath:FCEnabledPath()]) return 0;
    for (NSUInteger attempt = 0; attempt < 90; attempt++) {
        int status = FCMountSnapshot();
        if (status == 0 && FCOwnMountIsActive()) return 0;
        sleep(1);
    }
    return 100;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (geteuid() != 0 || argc != 2) return 64;
        NSString *command = [NSString stringWithUTF8String:argv[1]];
        if ([command isEqualToString:@"status"]) return FCOwnMountIsActive() ? 0 : 1;
        if ([command isEqualToString:@"prepare"]) return FCPrepare();
        if ([command isEqualToString:@"mount"]) return FCMountSnapshot();
        if ([command isEqualToString:@"unmount"]) return FCUnmountTarget();
        if ([command isEqualToString:@"reset"]) return FCReset();
        if ([command isEqualToString:@"daemon"]) return FCDaemon();
        return 64;
    }
}
