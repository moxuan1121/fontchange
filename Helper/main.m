#import <Foundation/Foundation.h>

#import <roothide.h>
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
    NSMutableArray<NSData *> *storage = [NSMutableArray array];
    char **argv = calloc(arguments.count + 2, sizeof(char *));
    NSData *toolData = [path dataUsingEncoding:NSUTF8StringEncoding];
    [storage addObject:toolData];
    argv[0] = (char *)toolData.bytes;
    for (NSUInteger index = 0; index < arguments.count; index++) {
        NSData *data = [arguments[index] dataUsingEncoding:NSUTF8StringEncoding];
        [storage addObject:data];
        argv[index + 1] = (char *)data.bytes;
    }
    pid_t pid = 0;
    int result = posix_spawn(&pid, path.UTF8String, NULL, NULL, argv, environ);
    free(argv);
    if (result != 0) return result;
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return 70;
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
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = unzip;
    task.arguments = @[@"-Z1", zipPath];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    @try { [task launch]; [task waitUntilExit]; } @catch (NSException *exception) {
        if (failure) *failure = @"未找到 unzip，请先通过软件源安装 unzip。";
        return NO;
    }
    if (task.terminationStatus != 0) {
        if (failure) *failure = @"ZIP 无法读取或已经损坏。";
        return NO;
    }
    NSString *listing = [[NSString alloc] initWithData:[pipe.fileHandleForReading readDataToEndOfFile]
        encoding:NSUTF8StringEncoding];
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
    int status = runTool(unzip, @[@"-qq", @"-o", zipPath, @"-d", destination]);
    if (status != 0) {
        if (failure) *failure = [NSString stringWithFormat:@"解压失败（%d）。", status];
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
    if (matches.count != 1) {
        if (failure) *failure = matches.count == 0
            ? @"主要 ZIP 中找不到同时包含 Core、CoreAddition、CoreUI 和 PingFang.ttc 的字体根目录。"
            : @"主要 ZIP 中识别到多个字体根目录，请精简压缩包后重试。";
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
    if (matches.count != 1) {
        if (failure) *failure = matches.count == 0
            ? @"可选 100% ZIP 中找不到 CoreUI/SFUISoft.ttc。"
            : @"可选 100% ZIP 中存在多个 CoreUI/SFUISoft.ttc，无法确定使用哪一个。";
        return nil;
    }
    return matches.firstObject;
}

static NSString *fontsTarget(void) {
    NSArray<NSString *> *relativeCandidates = @[@"/bindfs/System/Library/Fonts", @"/mnt/System/Library/Fonts"];
    NSMutableArray<NSString *> *valid = [NSMutableArray array];
    for (NSString *relative in relativeCandidates) {
        NSString *path = [NSString stringWithUTF8String:jbroot(relative.UTF8String)];
        BOOL directory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && directory &&
            [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"Core"]]) {
            [valid addObject:path];
        }
    }
    if (valid.count == 1) return valid.firstObject;
    if (valid.count > 1) {
        return [valid sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSDate *ad = [[NSFileManager.defaultManager attributesOfItemAtPath:a error:nil] fileModificationDate];
            NSDate *bd = [[NSFileManager.defaultManager attributesOfItemAtPath:b error:nil] fileModificationDate];
            return [bd compare:ad];
        }].firstObject;
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

static int installFonts(NSString *primaryZip, NSString *optionalZip) {
    NSString *work = [@"/var/mobile/Library/Caches" stringByAppendingPathComponent:
        [NSString stringWithFormat:@"com.moxuan1121.fontchange-%@", NSUUID.UUID.UUIDString]];
    NSString *primaryExtract = [work stringByAppendingPathComponent:@"primary"];
    NSString *optionalExtract = [work stringByAppendingPathComponent:@"optional"];
    [NSFileManager.defaultManager createDirectoryAtPath:primaryExtract withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *failure = nil;
    if (!extractArchive(primaryZip, primaryExtract, &failure)) goto fail;
    NSString *primaryRoot = findPrimaryRoot(primaryExtract, &failure);
    if (!primaryRoot) goto fail;

    NSString *optionalSFUI = nil;
    if (![optionalZip isEqualToString:@"-"]) {
        [NSFileManager.defaultManager createDirectoryAtPath:optionalExtract withIntermediateDirectories:YES attributes:nil error:nil];
        if (!extractArchive(optionalZip, optionalExtract, &failure)) goto fail;
        optionalSFUI = findOptionalSFUI(optionalExtract, &failure);
        if (!optionalSFUI) goto fail;
    }

    NSString *mountBindfs = [NSString stringWithUTF8String:jbroot("/usr/bin/mount_bindfs")];
    int mountStatus = runTool(mountBindfs, @[@"--copy", @"/System/Library/Fonts"]);
    if (mountStatus != 0) {
        failure = [NSString stringWithFormat:@"mount_bindfs --copy 执行失败（%d）。", mountStatus];
        goto fail;
    }
    NSString *target = fontsTarget();
    if (!target) {
        failure = @"未找到 mount_bindfs 生成的 bindfs 或 mnt 字体目录。";
        goto fail;
    }

    for (NSString *name in @[@"Core", @"CoreAddition", @"CoreUI"]) {
        if (!mergeDirectory([primaryRoot stringByAppendingPathComponent:name], [target stringByAppendingPathComponent:name], &failure)) goto fail;
    }
    if (!copyFile([primaryRoot stringByAppendingPathComponent:@"PingFang.ttc"],
        [target stringByAppendingPathComponent:@"LanguageSupport/PingFang.ttc"], &failure)) goto fail;
    if (optionalSFUI && !copyFile(optionalSFUI, [target stringByAppendingPathComponent:@"CoreUI/SFUISoft.ttc"], &failure)) goto fail;

    writeReport([NSString stringWithFormat:@"成功：字体已覆盖到 %@%@", target,
        optionalSFUI ? @"；SFUISoft.ttc 使用可选 100% 字体包" : @"；全部字体使用主要字体包"]);
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

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (geteuid() != 0) return 77;
        NSString *mode = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        if ([mode isEqualToString:@"--install"] && argc == 4) {
            return installFonts([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]]);
        }
        if ([mode isEqualToString:@"--reboot-after-delay"] && argc == 3) {
            return rebootAfterDelay((unsigned int)MAX(5, atoi(argv[2])));
        }
        return 64;
    }
}
