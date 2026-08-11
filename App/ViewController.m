#import "ViewController.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface ViewController ()
@property(nonatomic, strong) UITextView *resultView;
@property(nonatomic, strong) UIButton *scanButton;
@property(nonatomic, strong) UIButton *shareButton;
@property(nonatomic, strong) UIButton *japaneseButton;
@property(nonatomic, strong) UIButton *chineseButton;
@property(nonatomic, copy) NSString *reportPath;
@end

@implementation ViewController

static BOOL FCContainsKeyword(NSString *value) {
    if (value.length == 0) return NO;
    NSString *lower = value.lowercaseString;
    NSArray<NSString *> *keywords = @[@"language", @"localization", @"locale", @"intl",
        @"linguistic", @"preferredlanguages", @"applelanguages", @"switch",
        @"apply", @"commit", @"migrate", @"relaunch", @"restart", @"daemon"];
    for (NSString *keyword in keywords) {
        if ([lower containsString:keyword]) return YES;
    }
    return NO;
}

static void FCAppendMethods(NSMutableString *report, Class cls, BOOL includeAll) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int index = 0; index < count; index++) {
        NSString *name = NSStringFromSelector(method_getName(methods[index]));
        if (includeAll || FCContainsKeyword(name)) {
            [report appendFormat:@"    - %@    %s\n", name, method_getTypeEncoding(methods[index]) ?: ""];
        }
    }
    free(methods);

    Class meta = object_getClass(cls);
    methods = class_copyMethodList(meta, &count);
    for (unsigned int index = 0; index < count; index++) {
        NSString *name = NSStringFromSelector(method_getName(methods[index]));
        if (includeAll || FCContainsKeyword(name)) {
            [report appendFormat:@"    + %@    %s\n", name, method_getTypeEncoding(methods[index]) ?: ""];
        }
    }
    free(methods);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"语言接口诊断";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UILabel *notice = [[UILabel alloc] init];
    notice.translatesAutoresizingMaskIntoConstraints = NO;
    notice.text = @"扫描功能只读取接口。下方语言按钮会调用设置 App 使用的 PSLanguageSelector；不会清缓存或重启用户空间。";
    notice.font = [UIFont systemFontOfSize:15];
    notice.textColor = UIColor.secondaryLabelColor;
    notice.numberOfLines = 0;

    self.resultView = [[UITextView alloc] init];
    self.resultView.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultView.editable = NO;
    self.resultView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.resultView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.resultView.layer.cornerRadius = 12;
    self.resultView.text = @"点击“开始扫描”。扫描通常需要数秒。";

    self.scanButton = [self buttonWithTitle:@"开始扫描" action:@selector(startScan)];
    self.shareButton = [self buttonWithTitle:@"分享结果文件" action:@selector(shareReport)];
    self.shareButton.enabled = NO;
    self.shareButton.alpha = 0.5;

    self.japaneseButton = [self buttonWithTitle:@"原生切换到日语" action:@selector(confirmJapanese)];
    self.chineseButton = [self buttonWithTitle:@"原生切换到简体中文" action:@selector(confirmChinese)];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.scanButton, self.shareButton]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 12;
    buttons.distribution = UIStackViewDistributionFillEqually;

    UIStackView *languageButtons = [[UIStackView alloc] initWithArrangedSubviews:@[self.japaneseButton, self.chineseButton]];
    languageButtons.translatesAutoresizingMaskIntoConstraints = NO;
    languageButtons.axis = UILayoutConstraintAxisVertical;
    languageButtons.spacing = 10;
    languageButtons.distribution = UIStackViewDistributionFillEqually;

    [self.view addSubview:notice];
    [self.view addSubview:self.resultView];
    [self.view addSubview:languageButtons];
    [self.view addSubview:buttons];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [notice.topAnchor constraintEqualToAnchor:guide.topAnchor constant:14],
        [notice.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16],
        [notice.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16],
        [buttons.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16],
        [buttons.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16],
        [buttons.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-12],
        [buttons.heightAnchor constraintEqualToConstant:50],
        [languageButtons.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16],
        [languageButtons.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16],
        [languageButtons.bottomAnchor constraintEqualToAnchor:buttons.topAnchor constant:-10],
        [languageButtons.heightAnchor constraintEqualToConstant:110],
        [self.resultView.topAnchor constraintEqualToAnchor:notice.bottomAnchor constant:12],
        [self.resultView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:12],
        [self.resultView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-12],
        [self.resultView.bottomAnchor constraintEqualToAnchor:languageButtons.topAnchor constant:-12],
    ]];
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    button.backgroundColor = UIColor.systemBlueColor;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button setTitle:title forState:UIControlStateNormal];
    button.layer.cornerRadius = 12;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)startScan {
    self.scanButton.enabled = NO;
    self.resultView.text = @"正在加载 IntlPreferences.framework 并枚举接口…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *report = [self buildReport];
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *path = [documents stringByAppendingPathComponent:@"localization_runtime_interfaces.txt"];
        NSError *writeError = nil;
        BOOL written = [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanButton.enabled = YES;
            self.resultView.text = report;
            if (written) {
                self.reportPath = path;
                self.shareButton.enabled = YES;
                self.shareButton.alpha = 1.0;
            } else {
                self.resultView.text = [report stringByAppendingFormat:@"\n\n保存失败：%@", writeError.localizedDescription];
            }
        });
    });
}

- (NSString *)buildReport {
    NSMutableString *report = [NSMutableString string];
    [report appendString:@"FontChange localization runtime diagnostics\n"];
    [report appendFormat:@"Generated: %@\nSystem: %@ %@\n\n", NSDate.date,
        UIDevice.currentDevice.systemName, UIDevice.currentDevice.systemVersion];

    NSArray<NSString *> *paths = @[
        @"/System/Library/PrivateFrameworks/IntlPreferences.framework/IntlPreferences",
        @"/System/Library/PrivateFrameworks/Preferences.framework/Preferences",
        @"/System/Library/PreferenceBundles/InternationalSettings.bundle/InternationalSettings",
        @"/System/Library/PreferenceBundles/GeneralSettingsUI.bundle/GeneralSettingsUI",
        @"/System/Library/PreferenceBundles/LocalizationSettings.bundle/LocalizationSettings"
    ];
    for (NSString *path in paths) {
        dlerror();
        void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_LOCAL);
        const char *error = dlerror();
        [report appendFormat:@"dlopen %@: %@", path, handle ? @"SUCCESS" : @"FAILED"];
        if (error) [report appendFormat:@" (%s)", error];
        [report appendString:@"\n"];
    }
    [report appendString:@"\n"];

    int classCount = objc_getClassList(NULL, 0);
    __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    classCount = objc_getClassList(classes, classCount);
    NSUInteger classMatches = 0;
    NSUInteger selectorMatches = 0;
    for (int index = 0; index < classCount; index++) {
        Class cls = classes[index];
        NSString *className = NSStringFromClass(cls);
        const char *imageCString = class_getImageName(cls);
        NSString *image = imageCString ? [NSString stringWithUTF8String:imageCString] : @"";
        BOOL classMatch = FCContainsKeyword(className) || FCContainsKeyword(image);
        NSMutableString *methods = [NSMutableString string];
        FCAppendMethods(methods, cls, classMatch);
        if (classMatch || methods.length > 0) {
            [report appendFormat:@"CLASS %@\nIMAGE %@\n%@\n", className,
                image.length ? image : @"(unknown)", methods];
            if (classMatch) classMatches++; else selectorMatches++;
        }
    }
    free(classes);
    [report appendFormat:@"SUMMARY classes=%d classMatches=%lu selectorOnlyMatches=%lu\n",
        classCount, (unsigned long)classMatches, (unsigned long)selectorMatches];
    return report;
}

- (void)shareReport {
    if (self.reportPath.length == 0) return;
    NSURL *url = [NSURL fileURLWithPath:self.reportPath];
    UIActivityViewController *controller = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    controller.popoverPresentationController.sourceView = self.shareButton;
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)confirmJapanese {
    [self confirmLanguage:@"ja" fallback:@"zh-Hans" displayName:@"日语"];
}

- (void)confirmChinese {
    [self confirmLanguage:@"zh-Hans" fallback:@"ja" displayName:@"简体中文"];
}

- (void)confirmLanguage:(NSString *)language fallback:(NSString *)fallback displayName:(NSString *)displayName {
    NSString *message = [NSString stringWithFormat:
        @"将调用系统 PSLanguageSelector 切换到%@。若接口有效，当前 App、SpringBoard 和分享界面等会被系统快速重建。请先保存其他 App 中未保存的内容。", displayName];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"测试系统原生语言切换"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"确认切换" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [weakSelf invokeSystemLanguage:language fallback:fallback];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)invokeSystemLanguage:(NSString *)language fallback:(NSString *)fallback {
    self.japaneseButton.enabled = NO;
    self.chineseButton.enabled = NO;
    self.resultView.text = [NSString stringWithFormat:@"正在请求系统切换到 %@…", language];

    void *handle = dlopen("/System/Library/PreferenceBundles/InternationalSettings.bundle/InternationalSettings",
        RTLD_LAZY | RTLD_LOCAL);
    Class controllerClass = NSClassFromString(@"InternationalSettingsController");
    SEL setPreferredLanguages = NSSelectorFromString(@"setPreferredLanguages:");
    SEL setLanguage = NSSelectorFromString(@"setLanguage:");
    SEL syncPreferences = NSSelectorFromString(@"syncPreferencesAndPostNotificationForLanguageChange");
    SEL writeConfiguration = NSSelectorFromString(@"writeLanguageAndLocaleConfigurationIfNeededWithCompletion:");
    BOOL methodsAvailable = [controllerClass respondsToSelector:setPreferredLanguages]
        && [controllerClass respondsToSelector:setLanguage]
        && [controllerClass respondsToSelector:syncPreferences]
        && [controllerClass respondsToSelector:writeConfiguration];
    if (!handle || !controllerClass || !methodsAvailable) {
        const char *error = dlerror();
        self.resultView.text = [NSString stringWithFormat:@"无法加载系统语言提交接口%s%s",
            error ? "：" : "", error ?: ""];
        self.japaneseButton.enabled = YES;
        self.chineseButton.enabled = YES;
        return;
    }

    NSMutableArray<NSString *> *languages = [NSMutableArray arrayWithObject:language];
    for (NSString *existing in NSLocale.preferredLanguages) {
        if (![existing isEqualToString:language] && ![languages containsObject:existing]) {
            [languages addObject:existing];
        }
    }
    if (fallback.length > 0 && ![languages containsObject:fallback]) {
        [languages addObject:fallback];
    }

    ((void (*)(id, SEL, id))objc_msgSend)(controllerClass, setPreferredLanguages, languages);
    ((void (*)(id, SEL, id))objc_msgSend)(controllerClass, setLanguage, language);
    ((void (*)(id, SEL))objc_msgSend)(controllerClass, syncPreferences);
    void (^completion)(void) = ^{
        NSLog(@"International language configuration write completed");
    };
    ((void (*)(id, SEL, id))objc_msgSend)(controllerClass, writeConfiguration, completion);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.japaneseButton.enabled = YES;
        self.chineseButton.enabled = YES;
        self.resultView.text = [NSString stringWithFormat:
            @"完整提交链路已返回，但系统没有开始切换。当前首选语言：%@", NSLocale.preferredLanguages.firstObject ?: @"未知"];
    });
}

@end
