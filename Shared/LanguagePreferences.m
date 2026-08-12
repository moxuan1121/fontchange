#import "LanguagePreferences.h"

#import <CoreFoundation/CoreFoundation.h>
#import <roothide.h>

static NSString *const FCErrorDomain = @"FontChange";

NSString *FCStatePath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/com.moxuan1121.fontchange.selfcontained.restore-pending.plist");
}

static NSError *FCError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:FCErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static CFPropertyListRef FCCopyPreference(CFStringRef key, CFStringRef user) {
    return CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, user, kCFPreferencesAnyHost);
}

static BOOL FCSetPreference(CFStringRef key, CFPropertyListRef value, CFStringRef user) {
    CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication, user, kCFPreferencesAnyHost);
    return CFPreferencesSynchronize(kCFPreferencesAnyApplication, user, kCFPreferencesAnyHost);
}

BOOL FCBeginTemporaryJapanese(NSError **error) {
    CFPropertyListRef currentLanguages = FCCopyPreference(CFSTR("AppleLanguages"), kCFPreferencesCurrentUser);
    CFPropertyListRef currentLocale = FCCopyPreference(CFSTR("AppleLocale"), kCFPreferencesCurrentUser);

    if (!currentLanguages) {
        if (currentLocale) CFRelease(currentLocale);
        if (error) *error = FCError(1, @"无法读取当前系统语言");
        return NO;
    }

    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"languages"] = CFBridgingRelease(currentLanguages);
    if (currentLocale) state[@"locale"] = CFBridgingRelease(currentLocale);
    state[@"createdAt"] = NSDate.date;

    if (![state writeToFile:FCStatePath() atomically:YES]) {
        if (error) *error = FCError(2, @"无法保存语言恢复状态");
        return NO;
    }

    NSArray *japanese = @[@"ja"];
    BOOL languageOK = FCSetPreference(CFSTR("AppleLanguages"), (__bridge CFArrayRef)japanese, kCFPreferencesCurrentUser);
    BOOL localeOK = FCSetPreference(CFSTR("AppleLocale"), CFSTR("ja_JP"), kCFPreferencesCurrentUser);
    if (!languageOK || !localeOK) {
        FCRestoreSavedLanguage(NULL);
        if (error) *error = FCError(3, @"系统拒绝切换至日语");
        return NO;
    }
    return YES;
}

BOOL FCRestoreSavedLanguage(NSError **error) {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:FCStatePath()];
    if (!state) {
        if (error) *error = FCError(4, @"没有找到待恢复的语言状态");
        return NO;
    }

    id languages = state[@"languages"];
    id locale = state[@"locale"];
    if (![languages isKindOfClass:NSArray.class]) {
        if (error) *error = FCError(5, @"保存的语言状态无效");
        return NO;
    }

    BOOL languageOK = FCSetPreference(CFSTR("AppleLanguages"), (__bridge CFPropertyListRef)languages, kCFPreferencesCurrentUser);
    BOOL localeOK = YES;
    if ([locale isKindOfClass:NSString.class]) {
        localeOK = FCSetPreference(CFSTR("AppleLocale"), (__bridge CFPropertyListRef)locale, kCFPreferencesCurrentUser);
    }

    if (!languageOK || !localeOK) {
        if (error) *error = FCError(6, @"恢复原语言失败，状态已保留以便重试");
        return NO;
    }

    if (![NSFileManager.defaultManager removeItemAtPath:FCStatePath() error:error]) {
        return NO;
    }
    return YES;
}
