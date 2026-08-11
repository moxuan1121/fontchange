#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#import <fcntl.h>
#import <sys/file.h>
#import <unistd.h>

static NSString *const FCLogPath = @"/var/mobile/Documents/fontchange_language_trace.log";
static __thread BOOL FCIsWritingLog = NO;

static void FCAppendLog(NSString *event) {
    if (FCIsWritingLog || event.length == 0) return;
    FCIsWritingLog = YES;

    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", NSDate.date, event];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    int fd = open(FCLogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        flock(fd, LOCK_EX);
        write(fd, data.bytes, data.length);
        fsync(fd);
        flock(fd, LOCK_UN);
        close(fd);
    }

    FCIsWritingLog = NO;
}

static NSString *FCDescribeCF(CFTypeRef value) {
    if (!value) return @"<null>";
    return CFBridgingRelease(CFCopyDescription(value));
}

static BOOL FCRelevantNotification(const char *name) {
    if (!name) return NO;
    NSString *lower = [[NSString stringWithUTF8String:name] lowercaseString];
    NSArray<NSString *> *terms = @[@"language", @"locale", @"international", @"font", @"sharing", @"uikit", @"springboard", @"preferences"];
    for (NSString *term in terms) {
        if ([lower containsString:term]) return YES;
    }
    return NO;
}

%hookf(void, CFPreferencesSetValue, CFStringRef key, CFPropertyListRef value, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    FCAppendLog([NSString stringWithFormat:@"CFPreferencesSetValue key=%@ value=%@ app=%@ user=%@ host=%@",
        FCDescribeCF(key), FCDescribeCF(value), FCDescribeCF(applicationID), FCDescribeCF(userName), FCDescribeCF(hostName)]);
    %orig;
}

%hookf(Boolean, CFPreferencesSynchronize, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    FCAppendLog([NSString stringWithFormat:@"CFPreferencesSynchronize app=%@ user=%@ host=%@",
        FCDescribeCF(applicationID), FCDescribeCF(userName), FCDescribeCF(hostName)]);
    return %orig;
}

%hookf(uint32_t, notify_post, const char *name) {
    if (FCRelevantNotification(name)) {
        FCAppendLog([NSString stringWithFormat:@"notify_post %s", name]);
    }
    return %orig;
}

%hook NSUserDefaults

- (void)setObject:(id)value forKey:(NSString *)key {
    FCAppendLog([NSString stringWithFormat:@"NSUserDefaults setObject key=%@ value=%@", key, value]);
    %orig;
}

- (void)removeObjectForKey:(NSString *)key {
    FCAppendLog([NSString stringWithFormat:@"NSUserDefaults removeObject key=%@", key]);
    %orig;
}

%end

%hook NSFileManager

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
    FCAppendLog([NSString stringWithFormat:@"NSFileManager remove path=%@", path]);
    return %orig;
}

- (BOOL)removeItemAtURL:(NSURL *)URL error:(NSError **)error {
    FCAppendLog([NSString stringWithFormat:@"NSFileManager remove URL=%@", URL.path]);
    return %orig;
}

- (BOOL)moveItemAtPath:(NSString *)source toPath:(NSString *)destination error:(NSError **)error {
    FCAppendLog([NSString stringWithFormat:@"NSFileManager move source=%@ destination=%@", source, destination]);
    return %orig;
}

%end

%hook NSDictionary

- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)atomically {
    FCAppendLog([NSString stringWithFormat:@"NSDictionary write path=%@ keys=%@", path, self.allKeys]);
    return %orig;
}

%end

%hook FBSSystemService

- (void)sendActions:(NSSet *)actions withResult:(id)result {
    FCAppendLog([NSString stringWithFormat:@"FBSSystemService sendActions=%@ result=%@", actions, result]);
    %orig;
}

%end

%hook SBSRelaunchAction

+ (id)actionWithReason:(NSString *)reason options:(NSUInteger)options targetURL:(NSURL *)targetURL {
    FCAppendLog([NSString stringWithFormat:@"SBSRelaunchAction reason=%@ options=%lu targetURL=%@", reason, (unsigned long)options, targetURL]);
    return %orig;
}

%end

%ctor {
    @autoreleasepool {
        FCAppendLog(@"=== FontLanguageDiagnostics loaded into Settings ===");
    }
}
