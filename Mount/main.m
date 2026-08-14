#import <Foundation/Foundation.h>

#if FONTCHANGE_ROOTLESS
#import <rootless.h>
#define jbroot(path) ROOT_PATH(path)
#else
#import <roothide.h>
#endif
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
    // Never tear down an mnt/mount_bindfs/unknown mount owned by another
    // component. The caller can report the conflict instead of taking over.
    if (!FCOwnMountIsActive()) return 101;
    int status = FCWithKernelCredentials(^int{
        return unmount("/System/Library/Fonts", MNT_FORCE) == 0 ? 0 : errno;
    });
    if (status != 0) return status;
    for (NSUInteger attempt = 0; attempt < 20; attempt++) {
        if (!FCTargetIsMountPoint()) return 0;
        usleep(50000);
    }
    return 102;
}

static int FCDisable(void) {
    int status = FCUnmountTarget();
    if (status != 0) return status;
    [NSFileManager.defaultManager removeItemAtPath:FCEnabledPath() error:nil];
    return 0;
}

static int FCMountSnapshot(void) {
    if (FCOwnMountIsActive()) return 0;
    if (!FCValidFontTree(FCSourcePath())) return 93;
    if (FCTargetIsMountPoint()) return 101;
    int unmountStatus = FCUnmountTarget();
    if (unmountStatus != 0) return unmountStatus;
    int status = FCWithKernelCredentials(^int{
        return mount("bindfs", "/System/Library/Fonts", MNT_RDONLY,
            (void *)FCSourcePath().fileSystemRepresentation) == 0 ? 0 : errno;
    });
    if (status != 0) return status;
    for (NSUInteger attempt = 0; attempt < 20; attempt++) {
        if (FCOwnMountIsActive()) return 0;
        usleep(50000);
    }
    return 99;
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

static BOOL FCWriteEnabledMarker(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSError *error = nil;
    if (![manager createDirectoryAtPath:FCEnabledPath().stringByDeletingLastPathComponent
             withIntermediateDirectories:YES attributes:nil error:&error]) return NO;
    return [@"enabled" writeToFile:FCEnabledPath() atomically:YES
                           encoding:NSUTF8StringEncoding error:&error];
}

static int FCCopyNativeSnapshot(void) {
    int unmountStatus = FCUnmountTarget();
    if (unmountStatus != 0) return unmountStatus;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *source = FCSourcePath();
    NSString *base = source.stringByDeletingLastPathComponent;
    NSString *temporary = [base stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Fonts.new.%@", NSUUID.UUID.UUIDString]];
    NSString *backup = [base stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Fonts.old.%@", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    if (![manager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:&error]) return 94;
    [manager removeItemAtPath:temporary error:nil];
    if (![manager copyItemAtPath:@"/System/Library/Fonts" toPath:temporary error:&error]) return 95;
    if (!FCValidFontTree(temporary)) {
        [manager removeItemAtPath:temporary error:nil];
        return 96;
    }
    BOOL hadExisting = [manager fileExistsAtPath:source];
    if (hadExisting) {
        [manager removeItemAtPath:backup error:nil];
        if (![manager moveItemAtPath:source toPath:backup error:&error]) {
            [manager removeItemAtPath:temporary error:nil];
            return 97;
        }
    }
    if (![manager moveItemAtPath:temporary toPath:source error:&error]) {
        [manager removeItemAtPath:temporary error:nil];
        if (hadExisting) [manager moveItemAtPath:backup toPath:source error:nil];
        return 98;
    }
    if (hadExisting) [manager removeItemAtPath:backup error:nil];
    return 0;
}

static int FCPrepare(void) {
    if (FCOwnMountIsActive() && FCValidFontTree(FCSourcePath())) {
        if (!FCWriteEnabledMarker()) return 103;
        FCDisableLegacyFontMounts();
        return 0;
    }
    if (!FCValidFontTree(FCSourcePath())) {
        int copyStatus = FCCopyNativeSnapshot();
        if (copyStatus != 0) return copyStatus;
    }
    int mountStatus = FCMountSnapshot();
    if (mountStatus != 0) return mountStatus;
    if (!FCWriteEnabledMarker()) return 103;
    FCDisableLegacyFontMounts();
    return FCOwnMountIsActive() ? 0 : 99;
}

static int FCReset(void) {
    int copyStatus = FCCopyNativeSnapshot();
    if (copyStatus != 0) return copyStatus;
    int mountStatus = FCMountSnapshot();
    if (mountStatus != 0) return mountStatus;
    if (!FCWriteEnabledMarker()) return 103;
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
        if ([command isEqualToString:@"mount-if-enabled"]) {
            if (![NSFileManager.defaultManager fileExistsAtPath:FCEnabledPath()]) return 0;
            return FCMountSnapshot();
        }
        if ([command isEqualToString:@"unmount"]) return FCUnmountTarget();
        if ([command isEqualToString:@"disable"]) return FCDisable();
        if ([command isEqualToString:@"reset"]) return FCReset();
        if ([command isEqualToString:@"daemon"]) return FCDaemon();
        return 64;
    }
}
