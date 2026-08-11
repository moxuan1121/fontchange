#import <Foundation/Foundation.h>

#import <roothide.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <grp.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static NSString *const FCReportPath = @"/var/mobile/Documents/fontchange_last_result.txt";

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

static BOOL validateArchive(NSString *zipPath, NSString **failure) {
    NSString *unzip = [NSString stringWithUTF8String:jbroot("/usr/bin/unzip")];
    int descriptors[2] = {-1, -1};
    if (pipe(descriptors) != 0) {
        if (failure) *failure = @"无法创建 ZIP 检查管道。";
        return NO;
    }
    char *argv[] = {strdup(unzip.UTF8String), strdup("-Z1"), strdup(zipPath.UTF8String), NULL};
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, descriptors[0]);
    posix_spawn_file_actions_addclose(&actions, descriptors[1]);
    pid_t pid = 0;
    int spawnStatus = posix_spawn(&pid, unzip.UTF8String, &actions, NULL, argv, environ);
    free(argv[0]);
    free(argv[1]);
    free(argv[2]);
    posix_spawn_file_actions_destroy(&actions);
    close(descriptors[1]);
    if (spawnStatus != 0) {
        close(descriptors[0]);
        if (failure) *failure = @"未找到 unzip，请先通过软件源安装 unzip。";
        return NO;
    }
    NSFileHandle *readHandle = [[NSFileHandle alloc] initWithFileDescriptor:descriptors[0] closeOnDealloc:YES];
    NSData *output = [readHandle readDataToEndOfFile];
    int processStatus = 0;
    waitpid(pid, &processStatus, 0);
    if (!WIFEXITED(processStatus) || WEXITSTATUS(processStatus) != 0) {
        if (failure) *failure = @"ZIP 无法读取或已经损坏。";
        return NO;
    }
    NSString *listing = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
    if (listing.length == 0) {
        if (failure) *failure = @"ZIP 内容为空。";
        return NO;
    }
    for (NSString *entry in [listing componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (entry.length && unsafeArchiveEntry(entry)) {
            if (failure) *failure = [NSString stringWithFormat:@"ZIP 包含不安全路径：%@", entry];
            return NO;
        }
    }
    return YES;
}

static BOOL extractArchive(NSString *zipPath, NSString *destination, NSString **failure) {
    if (!validateArchive(zipPath, failure)) return NO;
    NSString *unzip = [NSString stringWithUTF8String:jbroot("/usr/bin/unzip")];
    NSString *details = nil;
    int status = runToolCapturingOutput(unzip, @[@"-o", zipPath, @"-d", destination], &details);
    if (status != 0) {
        if (failure) *failure = [NSString stringWithFormat:@"解压失败（%d）：%@", status,
            details.length ? details : @"unzip 没有返回错误详情"];
        return NO;
    }
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:destination];
    for (NSString *relative in enumerator) {
        NSString *path = [destination stringByAppendingPathComponent:relative];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if ([attributes.fileType isEqualToString:NSFileTypeSymbolicLink]) {
            if (failure) *failure = [NSString stringWithFormat:@"ZIP 包含符号链接：%@", relative];
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

static NSString *findPrimaryRoot(NSString *extracted, NSString **failure) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithObject:extracted];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:extracted];
    for (NSString *relative in enumerator) {
        NSString *path = [extracted stringByAppendingPathComponent:relative];
        BOOL directory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && directory) [candidates addObject:path];
    }
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    for (NSString *path in candidates) {
        BOOL valid = YES;
        for (NSString *name in @[@"Core", @"CoreAddition", @"CoreUI"]) {
            BOOL directory = NO;
            valid &= [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:name] isDirectory:&directory] && directory;
        }
        valid &= [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"PingFang.ttc"]];
        if (valid) [matches addObject:path];
    }
    if (matches.count > 1) {
        NSString *versionMatch = matchForCurrentIOS(matches);
        if (versionMatch) return versionMatch;
    }
    if (matches.count != 1) {
        if (failure) *failure = matches.count == 0
            ? @"主要 ZIP 中找不到同时包含 Core、CoreAddition、CoreUI 和 PingFang.ttc 的字体根目录。"
            : [NSString stringWithFormat:@"主要 ZIP 中识别到多个字体根目录，但无法唯一匹配当前 iOS %ld。",
                (long)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion];
        return nil;
    }
    return matches.firstObject;
}

static NSString *findOptionalSFUI(NSString *extracted, NSString **failure) {
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:extracted];
    for (NSString *relative in enumerator) {
        if ([[relative stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] hasSuffix:@"CoreUI/SFUISoft.ttc"]) {
            [matches addObject:[extracted stringByAppendingPathComponent:relative]];
        }
    }
    if (matches.count > 1) {
        NSString *versionMatch = matchForCurrentIOS(matches);
        if (versionMatch) return versionMatch;
    }
    if (matches.count != 1) {
        if (failure) *failure = matches.count == 0
            ? @"可选 100% ZIP 中找不到 CoreUI/SFUISoft.ttc。"
            : [NSString stringWithFormat:@"可选 ZIP 中存在多个 SFUISoft.ttc，但无法唯一匹配当前 iOS %ld。",
                (long)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion];
        return nil;
    }
    return matches.firstObject;
}

static NSString *validFontsTarget(NSString *relative) {
    NSString *path = [NSString stringWithUTF8String:jbroot(relative.UTF8String)];
    BOOL directory = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && directory &&
        [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"Core"]] &&
        [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"CoreUI"]]) {
        return path;
    }
    return nil;
}

static BOOL mergeDirectory(NSString *source, NSString *destination, NSString **failure) {
    NSString *cp = [NSString stringWithUTF8String:jbroot("/bin/cp")];
    int status = runTool(cp, @[@"-Rf", [source stringByAppendingPathComponent:@"."], destination]);
    if (status != 0 && failure) *failure = [NSString stringWithFormat:@"批量覆盖 %@ 失败（%d）。", source.lastPathComponent, status];
    return status == 0;
}

static BOOL copyFile(NSString *source, NSString *destination, NSString **failure) {
    NSString *cp = [NSString stringWithUTF8String:jbroot("/bin/cp")];
    int status = runTool(cp, @[@"-f", source, destination]);
    if (status != 0 && failure) *failure = [NSString stringWithFormat:@"覆盖 %@ 失败（%d）。", destination.lastPathComponent, status];
    return status == 0;
}

static BOOL hasZqbbFontMountPreference(void) {
    NSString *rootHidePath = [NSString stringWithUTF8String:
        jbroot("/var/mobile/Library/RootHide/cn.zqbb.mount.rh.plist")];
    NSDictionary *rootHideConfig = [NSDictionary dictionaryWithContentsOfFile:rootHidePath];
    NSArray *rootHidePaths = [rootHideConfig[@"path"] isKindOfClass:NSArray.class] ? rootHideConfig[@"path"] : nil;
    if ([rootHidePaths containsObject:@"/System/Library/Fonts"]) return YES;

    NSDictionary *rootlessConfig = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/newFakePath.plist"];
    NSArray *rootlessPaths = [rootlessConfig[@"path"] isKindOfClass:NSArray.class] ? rootlessConfig[@"path"] : nil;
    return [rootlessPaths containsObject:@"/System/Library/Fonts"];
}

static int installFonts(NSString *primaryZip, NSString *optionalZip) {
    BOOL sfuiOnly = [primaryZip isEqualToString:@"-"];
    NSString *jailbreakTemporary = [NSString stringWithUTF8String:jbroot("/var/tmp")];
    NSString *work = [jailbreakTemporary stringByAppendingPathComponent:
        [NSString stringWithFormat:@"com.moxuan1121.fontchange-%@", NSUUID.UUID.UUIDString]];
    NSString *primaryExtract = [work stringByAppendingPathComponent:@"primary"];
    NSString *optionalExtract = [work stringByAppendingPathComponent:@"optional"];

    NSString *failure = nil;
    NSString *primaryRoot = nil;
    NSString *optionalSFUI = nil;
    NSString *mountBindfs = [NSString stringWithUTF8String:jbroot("/usr/bin/mount_bindfs")];
    NSString *target = nil;
    BOOL usesBindfs = NO;
    BOOL prefersMnt = NO;
    NSString *mntTarget = nil;
    NSString *bindfsTarget = nil;
    int saveStatus = 0;
    NSString *saveDetails = nil;
    NSString *saveNote = @"";
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
        primaryRoot = findPrimaryRoot(primaryExtract, &failure);
        if (!primaryRoot) goto fail;
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

    prefersMnt = hasZqbbFontMountPreference();
    mntTarget = validFontsTarget(@"/mnt/System/Library/Fonts");
    bindfsTarget = validFontsTarget(@"/bindfs/System/Library/Fonts");
    if (prefersMnt && mntTarget) target = mntTarget;
    if (sfuiOnly && !target && bindfsTarget) target = bindfsTarget;
    if (sfuiOnly && !target && mntTarget) target = mntTarget;
    if (!target) {
        NSString *mountDetails = nil;
        NSString *shell = [NSString stringWithUTF8String:jbroot("/bin/sh")];
        NSString *copyCommand = [NSString stringWithFormat:@"\"%@\" --copy  /System/Library/Fonts", mountBindfs];
        int mountStatus = runToolCapturingOutput(shell, @[@"-c", copyCommand], &mountDetails);
        for (NSUInteger attempt = 0; attempt < 10 && !bindfsTarget; attempt++) {
            bindfsTarget = validFontsTarget(@"/bindfs/System/Library/Fonts");
            if (!bindfsTarget) usleep(300000);
        }
        if (bindfsTarget) {
            target = bindfsTarget;
            usesBindfs = YES;
        } else if (mntTarget) {
            target = mntTarget;
        } else {
            failure = [NSString stringWithFormat:@"mount_bindfs --copy 后仍未生成有效字体目录（%d）：%@",
                mountStatus, mountDetails.length ? mountDetails : @"命令没有返回错误详情"];
            goto fail;
        }
    }
    if (!target) {
        failure = @"未找到有效的 mnt 字体目录，mount_bindfs 也未生成有效 bindfs 字体目录。";
        goto fail;
    }

    if (usesBindfs) {
        NSString *shell = [NSString stringWithUTF8String:jbroot("/bin/sh")];
        NSString *saveCommand = [NSString stringWithFormat:@"\"%@\" -s /System/Library/Fonts", mountBindfs];
        saveStatus = runToolCapturingOutput(shell, @[@"-c", saveCommand], &saveDetails);
        if (saveStatus != 0) {
            saveNote = [NSString stringWithFormat:
                @"；警告：mount_bindfs -s 返回 %d（%@），不影响本次字体覆盖", saveStatus,
                saveDetails.length ? saveDetails : @"没有错误详情"];
        }
    }

    if (!sfuiOnly) {
        for (NSString *name in @[@"Core", @"CoreAddition", @"CoreUI"]) {
            if (!mergeDirectory([primaryRoot stringByAppendingPathComponent:name], [target stringByAppendingPathComponent:name], &failure)) goto fail;
        }
        if (!copyFile([primaryRoot stringByAppendingPathComponent:@"PingFang.ttc"],
            [target stringByAppendingPathComponent:@"LanguageSupport/PingFang.ttc"], &failure)) goto fail;
    }
    if (optionalSFUI && !copyFile(optionalSFUI, [target stringByAppendingPathComponent:@"CoreUI/SFUISoft.ttc"], &failure)) goto fail;
    NSString *mountScheme = [target containsString:@"/bindfs/"]
        ? (usesBindfs ? @"bindfs（已执行 --copy 和 -s）" : @"bindfs（复用现有字体目录）")
        : @"mnt（未执行任何挂载指令）";
    writeReport([NSString stringWithFormat:@"成功：字体已覆盖到 %@；检测 zqbb=%@；挂载方案=%@%@%@", target,
        prefersMnt ? @"是（优先 mnt）" : @"否（优先 bindfs）",
        mountScheme,
        sfuiOnly ? @"；仅替换 SFUISoft.ttc" :
            (optionalSFUI ? @"；SFUISoft.ttc 使用可选字体" : @"；全部字体使用主要字体包"),
        saveNote]);
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

static void lockDeviceNow(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        RTLD_LAZY | RTLD_LOCAL);
    if (!handle) return;
    void (*lockDevice)(void) = dlsym(handle, "SBSLockDevice");
    if (lockDevice) lockDevice();
}

static int restoreLanguageAndFinish(NSString *statePath, unsigned int delay, BOOL userspaceReboot) {
    pid_t background = fork();
    if (background < 0) return 72;
    if (background > 0) return 0;
    setsid();
    unsigned int lockDelay = MIN(3, delay);
    sleep(lockDelay);
    lockDeviceNow();
    if (delay > lockDelay) sleep(delay - lockDelay);

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
    if (userspaceReboot) {
        NSString *launchctl = [NSString stringWithUTF8String:jbroot("/bin/launchctl")];
        _exit(runTool(launchctl, @[@"reboot", @"userspace"]));
    }
    NSString *sbreload = [NSString stringWithUTF8String:jbroot("/usr/bin/sbreload")];
    _exit(runTool(sbreload, @[]));
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (geteuid() != 0) return 77;
        NSString *mode = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        if ([mode isEqualToString:@"--install"] && argc == 4) {
            return installFonts([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]]);
        }
        if ([mode isEqualToString:@"--import"] && argc == 4) {
            NSString *source = [NSString stringWithUTF8String:argv[2]];
            NSString *destination = [NSString stringWithUTF8String:argv[3]];
            NSString *extension = source.pathExtension.lowercaseString;
            if (![extension isEqualToString:@"zip"] && ![extension isEqualToString:@"ttc"]) return 65;
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
            return restoreLanguageAndFinish([NSString stringWithUTF8String:argv[2]],
                (unsigned int)MAX(5, atoi(argv[3])), YES);
        }
        if ([mode isEqualToString:@"--restore-language-and-sbreload"] && argc == 4) {
            return restoreLanguageAndFinish([NSString stringWithUTF8String:argv[2]],
                (unsigned int)MAX(5, atoi(argv[3])), NO);
        }
        return 64;
    }
}
