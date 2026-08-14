#import <Foundation/Foundation.h>

#if FONTCHANGE_ROOTLESS
#import <rootless.h>
#define jbroot(path) ROOT_PATH(path)
#else
#import <roothide.h>
#endif
#import <dlfcn.h>
#import <objc/message.h>
#import <grp.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static NSString *const FCReportPath = @"/var/mobile/Documents/fontchange_last_result.txt";

static BOOL supportedImportExtension(NSString *extension) {
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[
            @"zip", @"zipx", @"rar", @"7z", @"tar", @"tgz", @"gz", @"tbz", @"tbz2",
            @"bz2", @"txz", @"xz", @"tzst", @"zst", @"lha", @"lzh", @"cab", @"ttc"
        ]];
    });
    return [extensions containsObject:extension.lowercaseString];
}

static NSString *systemFontMarkerPath(void) {
    return [NSString stringWithUTF8String:
        jbroot("/var/mobile/Library/Preferences/com.moxuan.fontchange.system-fonts")];
}

static NSString *nativeFontIndexPath(void) {
    return [NSString stringWithUTF8String:
        jbroot("/var/mobile/Library/Preferences/com.moxuan.fontchange.native-font-index.plist")];
}

static void setSystemFontMarker(BOOL original) {
    NSString *path = systemFontMarkerPath();
    if (original) {
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                withIntermediateDirectories:YES attributes:nil error:nil];
        [@"original" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
}

static void writeReport(NSString *message) {
    [message writeToFile:FCReportPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static int runTool(NSString *path, NSArray<NSString *> *arguments) {
    char **argv = calloc(arguments.count + 2, sizeof(char *));
    argv[0] = strdup(path.UTF8String);
    for (NSUInteger index = 0; index < arguments.count; index++) {
        argv[index + 1] = strdup(arguments[index].UTF8String);
    }
    pid_t pid = 0;
    int result = posix_spawn(&pid, path.UTF8String, NULL, NULL, argv, environ);
    for (NSUInteger index = 0; index < arguments.count + 1; index++) free(argv[index]);
    free(argv);
    if (result != 0) return result;
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return 70;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 71;
}

static int runToolCapturingOutput(NSString *path, NSArray<NSString *> *arguments, NSString **output) {
    int descriptors[2] = {-1, -1};
    if (pipe(descriptors) != 0) return 69;
    char **argv = calloc(arguments.count + 2, sizeof(char *));
    argv[0] = strdup(path.UTF8String);
    for (NSUInteger index = 0; index < arguments.count; index++) {
        argv[index + 1] = strdup(arguments[index].UTF8String);
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, descriptors[0]);
    posix_spawn_file_actions_addclose(&actions, descriptors[1]);
    pid_t pid = 0;
    int spawnStatus = posix_spawn(&pid, path.UTF8String, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    for (NSUInteger index = 0; index < arguments.count + 1; index++) free(argv[index]);
    free(argv);
    close(descriptors[1]);
    if (spawnStatus != 0) {
        close(descriptors[0]);
        return spawnStatus;
    }
    NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:descriptors[0] closeOnDealloc:YES];
    NSData *data = [handle readDataToEndOfFile];
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return 70;
    if (output) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        *output = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 71;
}

static BOOL unsafeArchiveEntry(NSString *entry) {
    if ([entry hasPrefix:@"/"] || [entry hasPrefix:@"\\"]) return YES;
    for (NSString *component in [entry componentsSeparatedByString:@"/"]) {
        if ([component isEqualToString:@".."] || [component isEqualToString:@"."]) return YES;
    }
    return NO;
}

static void configureArchiveLocale(void) {
    // launchd/root helpers commonly inherit the POSIX locale. libarchive
    // cannot convert Unicode RAR pathnames (stored as UTF-16BE) in that
    // locale, so give bsdtar an explicit UTF-8 character environment.
    setenv("LANG", "en_US.UTF-8", 1);
    setenv("LC_ALL", "en_US.UTF-8", 1);
}

static NSString *compactArchiveError(NSString *details) {
    if (details.length <= 1200) return details;
    return [[details substringToIndex:1200] stringByAppendingString:@"\n…错误信息过长，已省略后续重复内容"];
}

static BOOL validateArchive(NSString *archivePath, NSString **failure) {
    NSString *bsdtar = [NSString stringWithUTF8String:jbroot("/usr/bin/bsdtar")];
    if (![NSFileManager.defaultManager isExecutableFileAtPath:bsdtar]) {
        if (failure) *failure = @"未找到 bsdtar，请安装或重新安装 libarchive-tools。";
        return NO;
    }
    configureArchiveLocale();
    NSString *listing = nil;
    int status = runToolCapturingOutput(bsdtar, @[@"-tf", archivePath], &listing);
    if (status != 0) {
        if (failure) *failure = [NSString stringWithFormat:@"压缩包无法读取、已经损坏或使用了不支持的加密方式（%d）：%@",
            status, listing.length ? compactArchiveError(listing) : @"bsdtar 没有返回错误详情"];
        return NO;
    }
    if (listing.length == 0) {
        if (failure) *failure = @"压缩包内容为空。";
        return NO;
    }
    for (NSString *entry in [listing componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (entry.length && unsafeArchiveEntry(entry)) {
            if (failure) *failure = [NSString stringWithFormat:@"压缩包包含不安全路径：%@", entry];
            return NO;
        }
    }
    return YES;
}

static BOOL extractArchive(NSString *archivePath, NSString *destination, NSString **failure) {
    if (!validateArchive(archivePath, failure)) return NO;
    NSString *bsdtar = [NSString stringWithUTF8String:jbroot("/usr/bin/bsdtar")];
    NSString *details = nil;
    int status = runToolCapturingOutput(bsdtar,
        @[@"-xf", archivePath, @"-C", destination, @"--no-same-owner", @"--no-same-permissions"], &details);
    if (status != 0) {
        if (failure) *failure = [NSString stringWithFormat:@"解压失败（%d）：%@", status,
            details.length ? compactArchiveError(details) : @"bsdtar 没有返回错误详情"];
        return NO;
    }
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:destination];
    for (NSString *relative in enumerator) {
        NSString *path = [destination stringByAppendingPathComponent:relative];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if ([attributes.fileType isEqualToString:NSFileTypeSymbolicLink]) {
            if (failure) *failure = [NSString stringWithFormat:@"压缩包包含符号链接：%@", relative];
            return NO;
        }
    }
    return YES;
}

static NSString *matchForCurrentIOS(NSArray<NSString *> *paths) {
    NSInteger majorVersion = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    NSString *token = [NSString stringWithFormat:@"ios%ld", (long)majorVersion];
    NSMutableArray<NSString *> *versionMatches = [NSMutableArray array];
    NSCharacterSet *nonAlphanumeric = NSCharacterSet.alphanumericCharacterSet.invertedSet;
    for (NSString *path in paths) {
        NSString *normalized = [[[path lowercaseString] componentsSeparatedByCharactersInSet:nonAlphanumeric]
            componentsJoinedByString:@""];
        if ([normalized containsString:token]) [versionMatches addObject:path];
    }
    return versionMatches.count == 1 ? versionMatches.firstObject : nil;
}

static NSString *matchForNativeRelativePath(NSArray<NSString *> *paths, NSString *extracted,
                                             NSString *nativeRelativePath) {
    if (nativeRelativePath.length == 0) return nil;

    NSString *normalizedTarget = [[nativeRelativePath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"]
        lowercaseString];
    NSString *targetSuffix = [@"/" stringByAppendingString:normalizedTarget];
    NSMutableArray<NSString *> *pathMatches = [NSMutableArray array];

    for (NSString *absolute in paths) {
        NSString *relative = absolute;
        if ([absolute hasPrefix:extracted]) {
            relative = [absolute substringFromIndex:extracted.length];
        }
        NSString *normalizedRelative = [[relative stringByReplacingOccurrencesOfString:@"\\" withString:@"/"]
            lowercaseString];
        while ([normalizedRelative hasPrefix:@"/"]) {
            normalizedRelative = [normalizedRelative substringFromIndex:1];
        }
        if ([normalizedRelative isEqualToString:normalizedTarget] ||
            [normalizedRelative hasSuffix:targetSuffix]) {
            [pathMatches addObject:absolute];
        }
    }

    if (pathMatches.count == 1) return pathMatches.firstObject;
    if (pathMatches.count > 1) return matchForCurrentIOS(pathMatches);
    return nil;
}

static NSDictionary<NSString *, NSString *> *nativeFontIndex(NSString **failure) {
    NSString *indexPath = nativeFontIndexPath();
    NSString *currentVersion = NSProcessInfo.processInfo.operatingSystemVersionString;
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:indexPath];
    NSDictionary *storedPaths = [stored[@"paths"] isKindOfClass:NSDictionary.class] ? stored[@"paths"] : nil;
    if ([stored[@"schema"] integerValue] == 3 &&
        [stored[@"osVersion"] isEqualToString:currentVersion] && storedPaths.count > 0) {
        return storedPaths;
    }

    NSString *nativeRoot = @"/System/Library/Fonts";
    BOOL rootDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:nativeRoot isDirectory:&rootDirectory] || !rootDirectory) {
        if (failure) *failure = @"无法读取 /System/Library/Fonts，不能建立原生字体索引。";
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *paths = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *duplicates = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:nativeRoot];
    for (NSString *relative in enumerator) {
        NSString *absolute = [nativeRoot stringByAppendingPathComponent:relative];
        BOOL directory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:absolute isDirectory:&directory] || directory) continue;
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:absolute error:nil];
        if (![attributes.fileType isEqualToString:NSFileTypeRegular]) continue;
        NSString *key = relative.lastPathComponent.lowercaseString;
        if (key.length == 0) continue;
        if (paths[key] && ![paths[key] isEqualToString:relative]) {
            [duplicates addObject:relative.lastPathComponent];
            continue;
        }
        paths[key] = relative;
    }
    if (duplicates.count > 0) {
        if (failure) *failure = [NSString stringWithFormat:
            @"原生字体目录发现同名文件，已停止建立索引：%@。", [duplicates componentsJoinedByString:@"、"]];
        return nil;
    }
    if (paths.count == 0) {
        if (failure) *failure = @"原生字体目录为空，不能建立字体索引。";
        return nil;
    }

    NSDictionary *payload = @{
        @"schema": @3,
        @"osVersion": currentVersion ?: @"unknown",
        @"createdAt": @([[NSDate date] timeIntervalSince1970]),
        @"paths": paths
    };
    NSError *directoryError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:indexPath.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:&directoryError];
    if (directoryError || ![payload writeToFile:indexPath atomically:YES]) {
        if (failure) *failure = [NSString stringWithFormat:@"无法保存原生字体索引：%@。",
            directoryError.localizedDescription ?: @"写入失败"];
        return nil;
    }
    chmod(indexPath.fileSystemRepresentation, 0644);
    return paths;
}

static NSString *findFileNamed(NSString *extracted, NSString *fileName, NSString **failure) {
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:extracted];
    for (NSString *relative in enumerator) {
        if ([relative.lastPathComponent caseInsensitiveCompare:fileName] != NSOrderedSame) continue;
        NSString *absolute = [extracted stringByAppendingPathComponent:relative];
        BOOL directory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:absolute isDirectory:&directory] && !directory) {
            [matches addObject:absolute];
        }
    }
    if (matches.count > 1) {
        NSString *versionMatch = matchForCurrentIOS(matches);
        if (versionMatch) return versionMatch;
    }
    if (matches.count != 1) {
        if (failure) *failure = matches.count == 0
            ? [NSString stringWithFormat:@"压缩包中找不到 %@。", fileName]
            : [NSString stringWithFormat:@"压缩包中存在多个 %@，但无法唯一匹配当前 iOS %ld。",
                fileName, (long)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion];
        return nil;
    }
    return matches.firstObject;
}

static NSDictionary<NSString *, NSString *> *primarySourcesForIndex(
    NSString *extracted, NSDictionary<NSString *, NSString *> *index, NSString **failure) {
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *candidates = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:extracted];
    for (NSString *relative in enumerator) {
        NSString *absolute = [extracted stringByAppendingPathComponent:relative];
        BOOL directory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:absolute isDirectory:&directory] || directory) continue;
        NSString *key = relative.lastPathComponent.lowercaseString;
        if (!index[key]) continue;
        if (!candidates[key]) candidates[key] = [NSMutableArray array];
        [candidates[key] addObject:absolute];
    }

    NSMutableDictionary<NSString *, NSString *> *selected = [NSMutableDictionary dictionary];
    for (NSString *key in candidates) {
        NSArray<NSString *> *paths = candidates[key];
        if (paths.count == 1) {
            selected[key] = paths.firstObject;
            continue;
        }

        // The native index records the exact destination layout. Prefer a
        // source whose trailing path mirrors that layout (for example,
        // CoreUI/SFUI.ttf) before falling back to an iOS-version-only match.
        // This prevents a same-name file elsewhere in the archive from
        // incorrectly making the valid CoreUI candidate ambiguous.
        NSString *relativePathMatch = matchForNativeRelativePath(paths, extracted, index[key]);
        if (relativePathMatch) {
            selected[key] = relativePathMatch;
            continue;
        }

        NSString *versionMatch = matchForCurrentIOS(paths);
        if (versionMatch) selected[key] = versionMatch;
        // Multiple same-name candidates without one unambiguous current-iOS
        // match are intentionally skipped. Other matched fonts can still be
        // installed safely using the native filename index.
    }
    if (selected.count == 0) {
        if (failure) *failure = @"字体包内没有文件名与原生字体索引匹配。";
        return nil;
    }
    return selected;
}

static NSString *findOptionalSFUI(NSString *extracted, NSString **failure) {
    return findFileNamed(extracted, @"SFUISoft.ttc", failure);
}

static int preparePreview(NSString *kind, NSString *zipPath, NSString *destination) {
    NSString *temporary = [NSString stringWithUTF8String:jbroot("/var/tmp")];
    NSString *work = [temporary stringByAppendingPathComponent:
        [NSString stringWithFormat:@"com.moxuan.fontchange-preview-%@", NSUUID.UUID.UUIDString]];
    NSString *failure = nil;
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:work
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&directoryError]) return 1;
    if (!extractArchive(zipPath, work, &failure)) {
        [NSFileManager.defaultManager removeItemAtPath:work error:nil];
        return 2;
    }
    NSString *source = nil;
    if ([kind isEqualToString:@"primary"]) {
        source = findFileNamed(work, @"PingFang.ttc", &failure);
    } else if ([kind isEqualToString:@"optional"]) {
        source = findOptionalSFUI(work, &failure);
    }
    if (!source) {
        [NSFileManager.defaultManager removeItemAtPath:work error:nil];
        return 3;
    }
    NSString *parent = destination.stringByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtPath:parent
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    NSString *cp = [NSString stringWithUTF8String:jbroot("/bin/cp")];
    int status = runTool(cp, @[@"-f", source, destination]);
    if (status == 0) {
        chmod(destination.fileSystemRepresentation, 0644);
        chown(destination.fileSystemRepresentation, 501, 501);
    }
    [NSFileManager.defaultManager removeItemAtPath:work error:nil];
    return status;
}

static NSString *validFontsTargetAtPath(NSString *path) {
    BOOL directory = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && directory &&
        [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"Core"]] &&
        [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"CoreUI"]]) {
        return path;
    }
    return nil;
}

static NSString *validFontsTarget(NSString *relative) {
    NSString *path = [NSString stringWithUTF8String:jbroot(relative.UTF8String)];
    return validFontsTargetAtPath(path);
}

static NSString *fontChangeMountTool(void) {
    return [NSString stringWithUTF8String:jbroot("/usr/libexec/fontchange-mount")];
}

static NSString *fontChangeFontsTarget(void) {
    return validFontsTarget(@"/var/lib/fontchange-mount/System/Library/Fonts");
}

static BOOL fontChangeMountWasPrepared(void) {
    NSString *enabled = [NSString stringWithUTF8String:jbroot("/var/lib/fontchange-mount/enabled")];
    return [NSFileManager.defaultManager fileExistsAtPath:enabled] && fontChangeFontsTarget() != nil;
}

static BOOL fontChangeMountIsActive(void) {
    NSString *tool = fontChangeMountTool();
    return fontChangeMountWasPrepared() &&
        [NSFileManager.defaultManager isExecutableFileAtPath:tool] &&
        runTool(tool, @[@"status"]) == 0;
}

static NSString *externalMntTarget(void) {
    return validFontsTarget(@"/mnt/System/Library/Fonts");
}

static NSString *externalBindfsTarget(void) {
    NSString *target = validFontsTarget(@"/bindfs/System/Library/Fonts");
    if (target) return target;
    return validFontsTarget(@"/mount/System/Library/Fonts");
}

static NSString *mountedFontsTarget(NSString **scheme) {
    struct statfs information = {0};
    if (statfs("/System/Library/Fonts", &information) != 0) return nil;

    NSString *mountPoint = [NSString stringWithUTF8String:information.f_mntonname] ?: @"";
    if (![mountPoint isEqualToString:@"/System/Library/Fonts"]) return nil;

    NSString *source = [NSString stringWithUTF8String:information.f_mntfromname] ?: @"";
    NSString *lower = source.lowercaseString;
    NSString *target = nil;
    if ([lower containsString:@"/mnt/system/library/fonts"]) {
        target = validFontsTargetAtPath(source) ?: externalMntTarget();
        if (target && scheme) *scheme = @"mnt（当前生效）";
    } else if ([lower containsString:@"/bindfs/system/library/fonts"] ||
               [lower containsString:@"/mount/system/library/fonts"]) {
        target = validFontsTargetAtPath(source) ?: externalBindfsTarget();
        if (target && scheme) *scheme = @"mount_bindfs（当前生效）";
    } else if ([lower containsString:@"/var/lib/fontchange-mount/system/library/fonts"]) {
        target = validFontsTargetAtPath(source) ?: fontChangeFontsTarget();
        if (target && scheme) *scheme = @"FontChange 自带挂载（当前生效）";
    }
    return target;
}

static NSString *rebuildExternalFontsTarget(NSString *activeTarget, NSString *activeScheme,
                                             NSString **scheme, NSString **failure) {
    if ([activeScheme hasPrefix:@"mnt"]) {
        NSString *lowerTarget = activeTarget.lowercaseString;
        if (![lowerTarget containsString:@"/mnt/system/library/fonts"] ||
            [activeTarget isEqualToString:@"/System/Library/Fonts"]) {
            if (failure) *failure = @"当前 mnt 字体快照路径校验失败，已停止操作。";
            return nil;
        }

        NSString *jbctl = [NSString stringWithUTF8String:jbroot("/basebin/jbctl")];
        if (![NSFileManager.defaultManager isExecutableFileAtPath:jbctl]) {
            if (failure) *failure = @"当前为 mnt 挂载，但未找到 jbctl，无法重建原生字体快照。";
            return nil;
        }

        int fontUnmount = runTool(jbctl, @[@"internal", @"font_unmount"]);
        int pathUnmount = runTool(jbctl, @[@"internal", @"unmount", @"/System/Library/Fonts"]);
        NSString *umount = @"/sbin/umount";
        if (![NSFileManager.defaultManager isExecutableFileAtPath:umount]) {
            umount = [NSString stringWithUTF8String:jbroot("/sbin/umount")];
        }
        int directUnmount = [NSFileManager.defaultManager isExecutableFileAtPath:umount]
            ? runTool(umount, @[@"-f", @"/System/Library/Fonts"]) : 127;
        usleep(400000);

        NSString *rm = [NSString stringWithUTF8String:jbroot("/bin/rm")];
        int removeStatus = runTool(rm, @[@"-rf", @"--", activeTarget]);
        if ([NSFileManager.defaultManager fileExistsAtPath:activeTarget]) {
            if (failure) *failure = [NSString stringWithFormat:
                @"mnt 原字体快照仍被占用，无法重建。font_unmount=%d，path_unmount=%d，umount=%d，rm=%d。",
                fontUnmount, pathUnmount, directUnmount, removeStatus];
            return nil;
        }

        int mountStatus = runTool(jbctl, @[@"internal", @"font_mount"]);
        NSString *rebuiltScheme = nil;
        NSString *rebuiltTarget = nil;
        for (NSUInteger attempt = 0; attempt < 25; attempt++) {
            rebuiltTarget = mountedFontsTarget(&rebuiltScheme);
            if (rebuiltTarget && [rebuiltScheme hasPrefix:@"mnt"]) break;
            usleep(300000);
        }
        if (!rebuiltTarget) {
            mountStatus = runTool(jbctl, @[@"internal", @"mount", @"/System/Library/Fonts"]);
            for (NSUInteger attempt = 0; attempt < 25; attempt++) {
                rebuiltTarget = mountedFontsTarget(&rebuiltScheme);
                if (rebuiltTarget && [rebuiltScheme hasPrefix:@"mnt"]) break;
                usleep(300000);
            }
        }
        if (!rebuiltTarget || ![rebuiltScheme hasPrefix:@"mnt"]) {
            if (failure) *failure = [NSString stringWithFormat:@"mnt 原生字体快照重建失败（%d）。", mountStatus];
            return nil;
        }
        if (scheme) *scheme = @"mnt（已重建完整原生字体快照）";
        return rebuiltTarget;
    }

    if ([activeScheme hasPrefix:@"mount_bindfs"]) {
        NSString *mountBindfs = [NSString stringWithUTF8String:jbroot("/usr/bin/mount_bindfs")];
        if (![NSFileManager.defaultManager isExecutableFileAtPath:mountBindfs]) {
            if (failure) *failure = @"当前为 mount_bindfs 挂载，但未找到 mount_bindfs。";
            return nil;
        }
        int copyStatus = runTool(mountBindfs, @[@"--copy", @"/System/Library/Fonts"]);
        NSString *rebuiltScheme = nil;
        NSString *rebuiltTarget = mountedFontsTarget(&rebuiltScheme);
        if (copyStatus != 0 || !rebuiltTarget || ![rebuiltScheme hasPrefix:@"mount_bindfs"]) {
            if (failure) *failure = [NSString stringWithFormat:@"mount_bindfs 原生字体复制失败（%d）。", copyStatus];
            return nil;
        }
        if (scheme) *scheme = @"mount_bindfs（已重新复制完整原生字体）";
        return rebuiltTarget;
    }

    if (scheme) *scheme = activeScheme;
    return activeTarget;
}

static NSString *preferredFontsTarget(BOOL sfuiOnly, NSString **scheme, NSString **failure) {
    NSString *target = nil;
    NSString *activeScheme = nil;

    // The live mount table is authoritative. A stale mnt/bindfs directory
    // must never decide where new fonts are written.
    target = mountedFontsTarget(&activeScheme);
    if (target) {
        if (!sfuiOnly) {
            if ([activeScheme hasPrefix:@"mnt"] || [activeScheme hasPrefix:@"mount_bindfs"]) {
                return rebuildExternalFontsTarget(target, activeScheme, scheme, failure);
            }
            if ([activeScheme hasPrefix:@"FontChange"]) {
                NSString *ownedTool = fontChangeMountTool();
                int status = runTool(ownedTool, @[@"reset"]);
                NSString *rebuiltScheme = nil;
                NSString *rebuiltTarget = mountedFontsTarget(&rebuiltScheme);
                if (status != 0 || !rebuiltTarget || ![rebuiltScheme hasPrefix:@"FontChange"]) {
                    if (failure) *failure = [NSString stringWithFormat:
                        @"FontChange 原生字体镜像重建失败（%d）。", status];
                    return nil;
                }
                if (scheme) *scheme = @"FontChange 自带挂载（已重建完整原生字体镜像）";
                return rebuiltTarget;
            }
        }
        if (scheme) *scheme = activeScheme;
        return target;
    }

    if (sfuiOnly) {
        if (failure) *failure = @"当前没有生效的字体挂载；仅替换 SFUISoft 时不会自动创建或重建挂载。";
        return nil;
    }

    NSString *ownedTool = fontChangeMountTool();
    if ([NSFileManager.defaultManager isExecutableFileAtPath:ownedTool]) {
        int ownedStatus = runTool(ownedTool, @[@"prepare"]);
        target = fontChangeFontsTarget();
        if (ownedStatus == 0 && target) {
            if (scheme) *scheme = @"FontChange 自带挂载";
            return target;
        }
        if (failure) *failure = [NSString stringWithFormat:@"FontChange 自带挂载失败（%d）。", ownedStatus];
    } else if (failure) {
        *failure = @"当前没有生效的外部字体挂载，且 FontChange 自带挂载组件不存在。";
    }
    return nil;
}

static BOOL copyFile(NSString *source, NSString *destination, NSString **failure) {
    NSString *cp = [NSString stringWithUTF8String:jbroot("/bin/cp")];
    int status = runTool(cp, @[@"-f", source, destination]);
    if (status != 0 && failure) *failure = [NSString stringWithFormat:@"覆盖 %@ 失败（%d）。", destination.lastPathComponent, status];
    return status == 0;
}

static int restoreSystemFonts(void) {
    NSString *resultPath = @"/var/mobile/Documents/fontchange_last_result.txt";
    [NSFileManager.defaultManager removeItemAtPath:resultPath error:nil];
    NSString *activeScheme = nil;
    NSString *activeTarget = mountedFontsTarget(&activeScheme);

    if (activeTarget && [activeScheme hasPrefix:@"mnt"]) {
        NSString *jbctl = [NSString stringWithUTF8String:jbroot("/basebin/jbctl")];
        if (![NSFileManager.defaultManager isExecutableFileAtPath:jbctl]) {
            [@"恢复失败：当前为 mnt 挂载，但未找到 jbctl。"
                writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return 81;
        }

        int genericUnmount = runTool(jbctl, @[@"internal", @"font_unmount"]);
        int pathUnmount = runTool(jbctl, @[@"internal", @"unmount", @"/System/Library/Fonts"]);
        NSString *umount = @"/sbin/umount";
        if (![NSFileManager.defaultManager isExecutableFileAtPath:umount]) {
            umount = [NSString stringWithUTF8String:jbroot("/sbin/umount")];
        }
        int directUnmount = [NSFileManager.defaultManager isExecutableFileAtPath:umount]
            ? runTool(umount, @[@"-f", @"/System/Library/Fonts"]) : 127;
        usleep(500000);
        if (!mountedFontsTarget(NULL)) {
            setSystemFontMarker(YES);
            [@"恢复成功：已解除 mnt 字体挂载，系统将直接使用原生字体。"
                writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return 0;
        }
        NSString *message = [NSString stringWithFormat:
            @"恢复失败：mnt 字体挂载仍然生效。font_unmount=%d，path_unmount=%d，umount=%d。",
            genericUnmount, pathUnmount, directUnmount];
        [message writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return 83;
    }

    if (activeTarget && [activeScheme hasPrefix:@"mount_bindfs"]) {
        NSString *ownedMountTool = fontChangeMountTool();
        int status = runTool(ownedMountTool, @[@"unmount"]);
        usleep(500000);
        if (status == 0 && !mountedFontsTarget(NULL)) {
            setSystemFontMarker(YES);
            [@"恢复成功：已解除 mount_bindfs 字体挂载，系统将直接使用原生字体。"
                writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return 0;
        }
        NSString *message = [NSString stringWithFormat:@"恢复失败：mount_bindfs 字体挂载仍然生效（%d）。", status];
        [message writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return status != 0 ? status : 85;
    }

    NSString *ownedMountTool = fontChangeMountTool();
    if (![NSFileManager.defaultManager isExecutableFileAtPath:ownedMountTool]) {
        [@"恢复失败：FontChange 内置挂载组件不存在，请重新安装完整软件包。"
            writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return 83;
    }
    if (!fontChangeMountWasPrepared()) {
        [@"当前尚未创建原生字体镜像，无需执行恢复。"
            writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return 85;
    }
    {
        int ownedStatus = runTool(ownedMountTool, @[@"disable"]);
        if (ownedStatus == 0 && !mountedFontsTarget(NULL)) {
            setSystemFontMarker(YES);
            [@"恢复成功：已解除并禁用 FontChange 字体挂载，系统将直接使用原生字体。"
                writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return 0;
        }
        NSString *message = [NSString stringWithFormat:@"恢复失败：FontChange 内置字体挂载仍然生效（%d）。", ownedStatus];
        [message writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return ownedStatus != 0 ? ownedStatus : 86;
    }
}

static int detectMountMode(void) {
    NSString *scheme = nil;
    if (mountedFontsTarget(&scheme)) {
        if ([scheme hasPrefix:@"mnt"]) return 10;
        if ([scheme hasPrefix:@"mount_bindfs"]) return 11;
        if ([scheme hasPrefix:@"FontChange"]) return 14;
    }
    if (fontChangeMountIsActive()) return 14;
    if (fontChangeMountWasPrepared()) {
        NSString *tool = fontChangeMountTool();
        if ([NSFileManager.defaultManager isExecutableFileAtPath:tool]) {
            runTool(tool, @[@"mount-if-enabled"]);
            if (fontChangeMountIsActive()) return 14;
        }
        return 15;
    }
    return 12;
}

static int installFonts(NSString *primaryZip, NSString *optionalZip) {
    BOOL sfuiOnly = [primaryZip isEqualToString:@"-"];
    NSString *jailbreakTemporary = [NSString stringWithUTF8String:jbroot("/var/tmp")];
    NSString *work = [jailbreakTemporary stringByAppendingPathComponent:
        [NSString stringWithFormat:@"com.moxuan.fontchange-%@", NSUUID.UUID.UUIDString]];
    NSString *primaryExtract = [work stringByAppendingPathComponent:@"primary"];
    NSString *optionalExtract = [work stringByAppendingPathComponent:@"optional"];

    NSString *failure = nil;
    NSDictionary<NSString *, NSString *> *fontIndex = nil;
    NSDictionary<NSString *, NSString *> *primarySources = nil;
    NSString *optionalSFUI = nil;
    NSString *mountScheme = nil;
    NSString *target = nil;
    NSUInteger replacedFileCount = 0;
    NSError *directoryError = nil;

    if (!sfuiOnly) {
        if (![NSFileManager.defaultManager createDirectoryAtPath:primaryExtract
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:&directoryError]) {
            failure = [NSString stringWithFormat:@"无法创建临时解压目录 %@：%@", primaryExtract,
                directoryError.localizedDescription ?: @"未知错误"];
            goto fail;
        }
        if (!extractArchive(primaryZip, primaryExtract, &failure)) goto fail;
    }

    if (sfuiOnly && [optionalZip isEqualToString:@"-"]) {
        failure = @"单独替换模式必须选择 SFUISoft 字体包或 TTC 文件。";
        goto fail;
    }

    if (![optionalZip isEqualToString:@"-"]) {
        if ([optionalZip.pathExtension.lowercaseString isEqualToString:@"ttc"]) {
            if (![NSFileManager.defaultManager fileExistsAtPath:optionalZip]) {
                failure = @"所选 SFUISoft.ttc 文件不存在或无法读取。";
                goto fail;
            }
            optionalSFUI = optionalZip;
        } else {
            directoryError = nil;
            if (![NSFileManager.defaultManager createDirectoryAtPath:optionalExtract
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:&directoryError]) {
                failure = [NSString stringWithFormat:@"无法创建可选包解压目录 %@：%@", optionalExtract,
                    directoryError.localizedDescription ?: @"未知错误"];
                goto fail;
            }
            if (!extractArchive(optionalZip, optionalExtract, &failure)) goto fail;
            optionalSFUI = findOptionalSFUI(optionalExtract, &failure);
            if (!optionalSFUI) goto fail;
        }
    }

    // Reuse the source that is really mounted on /System/Library/Fonts.
    // If no compatible mount is active, create FontChange's own mount.
    target = preferredFontsTarget(sfuiOnly, &mountScheme, &failure);
    if (!target) goto fail;

    // Build this once from the original filename layout after migration.
    fontIndex = nativeFontIndex(&failure);
    if (!fontIndex) goto fail;
    if (!sfuiOnly) {
        primarySources = primarySourcesForIndex(primaryExtract, fontIndex, &failure);
        if (!primarySources) goto fail;
    }

    if (!sfuiOnly) {
        for (NSString *key in primarySources) {
            NSString *relative = fontIndex[key];
            NSString *source = primarySources[key];
            if (relative.length == 0 || source.length == 0) {
                failure = [NSString stringWithFormat:@"字体索引条目无效：%@。", key];
                goto fail;
            }
            NSString *destination = [target stringByAppendingPathComponent:relative];
            NSString *destinationParent = destination.stringByDeletingLastPathComponent;
            BOOL destinationDirectory = NO;
            if (![NSFileManager.defaultManager fileExistsAtPath:destinationParent
                                                     isDirectory:&destinationDirectory] || !destinationDirectory) {
                failure = [NSString stringWithFormat:@"目标字体目录不存在：%@。", relative.stringByDeletingLastPathComponent];
                goto fail;
            }
            if (!copyFile(source, destination, &failure)) goto fail;
            replacedFileCount++;
        }
    }
    if (optionalSFUI && !copyFile(optionalSFUI, [target stringByAppendingPathComponent:@"CoreUI/SFUISoft.ttc"], &failure)) goto fail;
    writeReport([NSString stringWithFormat:@"成功：字体已覆盖到 %@；原生索引=%lu 项；全局匹配覆盖=%lu 项；挂载方案=%@%@", target,
        (unsigned long)fontIndex.count,
        (unsigned long)replacedFileCount,
        mountScheme ?: @"未知",
        sfuiOnly ? @"；仅替换 SFUISoft.ttc" :
            (optionalSFUI ? @"；SFUISoft.ttc 使用可选字体" : @"；全部字体使用主要字体包")]);
    setSystemFontMarker(NO);
    [NSFileManager.defaultManager removeItemAtPath:work error:nil];
    return 0;

fail:
    writeReport([NSString stringWithFormat:@"失败：%@", failure ?: @"未知错误"]);
    [NSFileManager.defaultManager removeItemAtPath:work error:nil];
    return 1;
}

static int rebootAfterDelay(unsigned int seconds) {
    pid_t child = fork();
    if (child < 0) return 72;
    if (child > 0) return 0;
    setsid();
    sleep(seconds);
    sync();
    NSString *launchctl = [NSString stringWithUTF8String:jbroot("/bin/launchctl")];
    _exit(runTool(launchctl, @[@"reboot", @"userspace"]));
}

static BOOL commitLanguages(NSArray<NSString *> *languages) {
    if (languages.count == 0) return NO;
    void *handle = dlopen("/System/Library/PreferenceBundles/InternationalSettings.bundle/InternationalSettings",
        RTLD_LAZY | RTLD_LOCAL);
    Class cls = NSClassFromString(@"InternationalSettingsController");
    if (!handle || !cls) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(cls, NSSelectorFromString(@"setPreferredLanguages:"), languages);
    ((void (*)(id, SEL, id))objc_msgSend)(cls, NSSelectorFromString(@"setLanguage:"), languages.firstObject);
    ((void (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"syncPreferencesAndPostNotificationForLanguageChange"));
    void (^completion)(void) = ^{};
    ((void (*)(id, SEL, id))objc_msgSend)(cls,
        NSSelectorFromString(@"writeLanguageAndLocaleConfigurationIfNeededWithCompletion:"), completion);
    return YES;
}

static int restoreLanguageAndReboot(NSString *statePath, unsigned int delay) {
    pid_t background = fork();
    if (background < 0) return 72;
    if (background > 0) return 0;
    setsid();
    sleep(delay);

    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:statePath];
    NSArray<NSString *> *languages = [state[@"Languages"] isKindOfClass:NSArray.class] ? state[@"Languages"] : nil;
    if (languages.count == 0) _exit(73);

    pid_t mobileChild = fork();
    if (mobileChild < 0) _exit(74);
    if (mobileChild == 0) {
        setgroups(0, NULL);
        if (setgid(501) != 0 || setuid(501) != 0) _exit(75);
        _exit(commitLanguages(languages) ? 0 : 76);
    }
    int restoreStatus = 0;
    if (waitpid(mobileChild, &restoreStatus, 0) < 0 || !WIFEXITED(restoreStatus) || WEXITSTATUS(restoreStatus) != 0) {
        _exit(77);
    }
    sleep(10);
    [NSFileManager.defaultManager removeItemAtPath:statePath error:nil];
    sync();
    NSString *launchctl = [NSString stringWithUTF8String:jbroot("/bin/launchctl")];
    _exit(runTool(launchctl, @[@"reboot", @"userspace"]));
}

static int preflight(void) {
    pid_t child = fork();
    if (child < 0) return 78;
    if (child == 0) _exit(0);
    int status = 0;
    if (waitpid(child, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) return 79;

    return 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (geteuid() != 0) return 77;
        NSString *mode = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        if ([mode isEqualToString:@"--install"] && argc == 4) {
            return installFonts([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]]);
        }
        if ([mode isEqualToString:@"--restore-system-fonts"] && argc == 2) {
            return restoreSystemFonts();
        }
        if ([mode isEqualToString:@"--system-font-state"] && argc == 2) {
            return [NSFileManager.defaultManager fileExistsAtPath:systemFontMarkerPath()] ? 0 : 1;
        }
        if ([mode isEqualToString:@"--detect-mount"] && argc == 2) {
            return detectMountMode();
        }
        if ([mode isEqualToString:@"--prepare-preview"] && argc == 5) {
            return preparePreview([NSString stringWithUTF8String:argv[2]],
                [NSString stringWithUTF8String:argv[3]], [NSString stringWithUTF8String:argv[4]]);
        }
        if ([mode isEqualToString:@"--preflight"] && argc == 3) {
            return preflight();
        }
        if ([mode isEqualToString:@"--import"] && argc == 4) {
            NSString *source = [NSString stringWithUTF8String:argv[2]];
            NSString *destination = [NSString stringWithUTF8String:argv[3]];
            NSString *extension = source.pathExtension.lowercaseString;
            if (!supportedImportExtension(extension)) return 65;
            NSString *parent = destination.stringByDeletingLastPathComponent;
            [NSFileManager.defaultManager createDirectoryAtPath:parent
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:nil];
            NSString *cp = [NSString stringWithUTF8String:jbroot("/bin/cp")];
            return runTool(cp, @[@"-f", source, destination]);
        }
        if ([mode isEqualToString:@"--reboot-after-delay"] && argc == 3) {
            return rebootAfterDelay((unsigned int)MAX(5, atoi(argv[2])));
        }
        if ([mode isEqualToString:@"--restore-language-and-reboot"] && argc == 4) {
            return restoreLanguageAndReboot([NSString stringWithUTF8String:argv[2]],
                (unsigned int)MAX(5, atoi(argv[3])));
        }
        return 64;
    }
}
