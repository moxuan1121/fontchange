#import "ViewController.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <spawn.h>
#import <sys/wait.h>
#import <roothide.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

extern char **environ;

@interface ViewController () <UIDocumentPickerDelegate>
@property(nonatomic) NSInteger pickingSlot;
@property(nonatomic, copy) NSString *primaryPath;
@property(nonatomic, copy) NSString *optionalPath;
@property(nonatomic, strong) UILabel *primaryLabel;
@property(nonatomic, strong) UILabel *optionalLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *runButton;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UILabel *titleLabel = [self label:@"一键更换字体" size:32 color:UIColor.labelColor];
    titleLabel.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    UILabel *featureLabel = [self label:@"通过原生切换语言环境，深度刷新系统字体缓存。" size:15 color:UIColor.secondaryLabelColor];
    UILabel *formatLabel = [self label:@"压缩包仅支持 ZIP 格式，暂不支持 7z、RAR。" size:13 color:UIColor.tertiaryLabelColor];
    UIButton *primaryButton = [self button:@"主要字体包（全局覆盖，可选）" action:@selector(selectPrimary)];
    self.primaryLabel = [self label:@"尚未选择" size:13 color:UIColor.secondaryLabelColor];
    UIButton *optionalButton = [self button:@"选择用于 SFUISoft 的字体包 / TTC 文件" action:@selector(selectOptional)];
    self.optionalLabel = [self label:@"留空时全部使用主要字体包，并自动读取其中的 SFUISoft.ttc（用于自定义锁屏时钟字体）" size:13 color:UIColor.secondaryLabelColor];

    self.statusLabel = [self label:@"执行顺序：创建原生字体副本 → 覆盖字体 → 原生切换语言 → 重启用户空间" size:14 color:UIColor.secondaryLabelColor];
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.statusLabel.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.statusLabel.layer.cornerRadius = 12;
    self.statusLabel.layer.masksToBounds = YES;

    self.runButton = [self button:@"检查并开始执行" action:@selector(confirmRun)];
    self.runButton.backgroundColor = UIColor.systemGreenColor;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel, featureLabel, formatLabel, primaryButton, self.primaryLabel, optionalButton, self.optionalLabel,
        self.statusLabel, self.runButton
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    [stack setCustomSpacing:8 afterView:titleLabel];
    [stack setCustomSpacing:6 afterView:featureLabel];
    [stack setCustomSpacing:26 afterView:formatLabel];
    [stack setCustomSpacing:8 afterView:primaryButton];
    [stack setCustomSpacing:8 afterView:optionalButton];
    [stack setCustomSpacing:24 afterView:self.statusLabel];
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [primaryButton.heightAnchor constraintEqualToConstant:56],
        [optionalButton.heightAnchor constraintEqualToConstant:56],
        [self.statusLabel.heightAnchor constraintGreaterThanOrEqualToConstant:58],
        [self.runButton.heightAnchor constraintEqualToConstant:58],
    ]];
    [self cleanupOldImports];
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size];
    label.textColor = color;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    return label;
}

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    button.backgroundColor = UIColor.systemBlueColor;
    button.layer.cornerRadius = 16;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (NSString *)importsDirectory {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:@"FontChangeImports"];
}

- (void)cleanupOldImports {
    [NSFileManager.defaultManager removeItemAtPath:self.importsDirectory error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:self.importsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)selectPrimary { [self presentPickerForSlot:1]; }
- (void)selectOptional { [self presentPickerForSlot:2]; }

- (void)presentPickerForSlot:(NSInteger)slot {
    self.pickingSlot = slot;
    NSArray<UTType *> *types = @[UTTypeZIP];
    if (slot == 2) {
        UTType *ttcType = [UTType typeWithFilenameExtension:@"ttc"] ?: UTTypeFont;
        types = @[UTTypeZIP, ttcType];
    }
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:types asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *source = urls.firstObject;
    if (!source) return;
    [self importPickedURL:source];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    (void)controller;
    if (url) [self importPickedURL:url];
}

- (void)importPickedURL:(NSURL *)source {
    NSString *extension = source.pathExtension.lowercaseString;
    BOOL acceptsZIP = [extension isEqualToString:@"zip"];
    BOOL acceptsTTC = self.pickingSlot == 2 && [extension isEqualToString:@"ttc"];
    if (!acceptsZIP && !acceptsTTC) {
        self.statusLabel.text = self.pickingSlot == 1
            ? @"主要字体包必须是 .zip 文件。"
            : @"请选择字体 ZIP 或单个 .ttc 文件。";
        return;
    }
    NSString *name = self.pickingSlot == 1 ? @"primary.zip"
        : (acceptsTTC ? @"optional-SFUISoft.ttc" : @"optional100.zip");
    NSString *destination = [self.importsDirectory stringByAppendingPathComponent:name];
    [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
    BOOL scoped = [source startAccessingSecurityScopedResource];
    __block BOOL copied = NO;
    __block NSError *copyError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:source
                                    options:NSFileCoordinatorReadingWithoutChanges
                                      error:&copyError
                                 byAccessor:^(NSURL *coordinatedURL) {
        copied = [NSFileManager.defaultManager copyItemAtURL:coordinatedURL
                                                       toURL:[NSURL fileURLWithPath:destination]
                                                      error:&copyError];
    }];
    int importStatus = 0;
    if (!copied && !scoped) {
        importStatus = [self runHelperArguments:@[@"--import", source.path, destination] wait:YES];
        copied = importStatus == 0;
    }
    if (scoped) [source stopAccessingSecurityScopedResource];
    if (!copied) {
        NSString *detail = copyError.localizedDescription ?: @"文件提供器拒绝读取";
        self.statusLabel.text = [NSString stringWithFormat:
            @"导入失败：%@（安全作用域=%@，helper=%d）。", detail, scoped ? @"已获得" : @"未获得", importStatus];
        return;
    }
    if (self.pickingSlot == 1) {
        self.primaryPath = destination;
        self.primaryLabel.text = source.lastPathComponent;
    } else {
        self.optionalPath = destination;
        self.optionalLabel.text = source.lastPathComponent;
    }
}

- (void)confirmRun {
    if (self.primaryPath.length == 0) {
        self.statusLabel.text = @"请先选择主要字体 ZIP。";
        return;
    }
    NSArray<NSString *> *originalLanguages = NSLocale.preferredLanguages;
    NSString *current = originalLanguages.firstObject ?: @"zh-Hans";
    NSString *temporary = [current hasPrefix:@"ja"] ? @"zh-Hans" : @"ja";
    [self runWithTemporaryLanguage:temporary originalLanguages:originalLanguages];
}

- (void)turnScreenOff {
    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        RTLD_LAZY | RTLD_LOCAL);
    if (!handle) return;
    void (*lockDevice)(void) = dlsym(handle, "SBSLockDevice");
    if (lockDevice) lockDevice();
}

- (void)runWithTemporaryLanguage:(NSString *)language originalLanguages:(NSArray<NSString *> *)originalLanguages {
    self.runButton.enabled = NO;
    self.runButton.backgroundColor = UIColor.systemGreenColor;
    [self.runButton setTitle:@"正在执行…" forState:UIControlStateNormal];
    self.statusLabel.text = @"正在解压、验证并覆盖字体…";
    NSString *primary = self.primaryPath;
    NSString *optional = self.optionalPath ?: @"-";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = [self runHelperArguments:@[@"--install", primary, optional] wait:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self cleanupOldImports];
            self.primaryPath = nil;
            self.optionalPath = nil;
            self.primaryLabel.text = @"尚未选择";
            self.optionalLabel.text = @"留空时全部使用主要字体包，并自动读取其中的 SFUISoft.ttc（用于自定义锁屏时钟字体）";
            if (status != 0) {
                self.runButton.enabled = YES;
                self.runButton.backgroundColor = UIColor.systemRedColor;
                [self.runButton setTitle:@"执行失败，点击重试" forState:UIControlStateNormal];
                NSString *report = [NSString stringWithContentsOfFile:@"/var/mobile/Documents/fontchange_last_result.txt"
                    encoding:NSUTF8StringEncoding error:nil];
                self.statusLabel.text = report.length ? report : [NSString stringWithFormat:@"字体处理失败（%d）", status];
                return;
            }
            self.statusLabel.text = @"字体覆盖完成，正在清理字体缓存，即将重启用户空间…";
            NSString *statePath = @"/var/mobile/Documents/fontchange_language_state.plist";
            NSDictionary *state = @{ @"Languages": originalLanguages, @"TemporaryLanguage": language };
            if (![state writeToFile:statePath atomically:YES]) {
                self.runButton.enabled = YES;
                self.runButton.backgroundColor = UIColor.systemRedColor;
                [self.runButton setTitle:@"执行失败，点击重试" forState:UIControlStateNormal];
                self.statusLabel.text = @"字体已覆盖，但无法保存原语言恢复状态；已停止后续操作。";
                return;
            }
            NSString *fallback = originalLanguages.firstObject ?: @"zh-Hans";
            if ([self invokeNativeLanguage:language fallback:fallback]) {
                [self runHelperArguments:@[@"--restore-language-and-reboot", statePath, @"8"] wait:NO];
                // Give the language-change UI enough time to become visible before locking.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        [self turnScreenOff];
                    });
            } else {
                [NSFileManager.defaultManager removeItemAtPath:statePath error:nil];
            }
        });
    });
}

- (int)runHelperArguments:(NSArray<NSString *> *)arguments wait:(BOOL)wait {
    const char *helper = jbroot("/usr/libexec/fontchange-helper");
    char **argv = calloc(arguments.count + 2, sizeof(char *));
    argv[0] = strdup(helper);
    for (NSUInteger index = 0; index < arguments.count; index++) {
        argv[index + 1] = strdup(arguments[index].UTF8String);
    }
    pid_t pid = 0;
    int result = posix_spawn(&pid, helper, NULL, NULL, argv, environ);
    for (NSUInteger index = 0; index < arguments.count + 1; index++) free(argv[index]);
    free(argv);
    if (result != 0 || !wait) return result;
    int processStatus = 0;
    if (waitpid(pid, &processStatus, 0) < 0) return 70;
    return WIFEXITED(processStatus) ? WEXITSTATUS(processStatus) : 71;
}

- (BOOL)invokeNativeLanguage:(NSString *)language fallback:(NSString *)fallback {
    void *handle = dlopen("/System/Library/PreferenceBundles/InternationalSettings.bundle/InternationalSettings", RTLD_LAZY | RTLD_LOCAL);
    Class cls = NSClassFromString(@"InternationalSettingsController");
    if (!handle || !cls) {
        self.runButton.enabled = YES;
        self.runButton.backgroundColor = UIColor.systemRedColor;
        [self.runButton setTitle:@"执行失败，点击重试" forState:UIControlStateNormal];
        self.statusLabel.text = @"字体已覆盖，但无法加载系统语言切换接口；已取消自动重启。";
        return NO;
    }
    NSMutableArray *languages = [NSMutableArray arrayWithObject:language];
    for (NSString *item in NSLocale.preferredLanguages) if (![languages containsObject:item]) [languages addObject:item];
    if (![languages containsObject:fallback]) [languages addObject:fallback];
    ((void (*)(id, SEL, id))objc_msgSend)(cls, NSSelectorFromString(@"setPreferredLanguages:"), languages);
    ((void (*)(id, SEL, id))objc_msgSend)(cls, NSSelectorFromString(@"setLanguage:"), language);
    ((void (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"syncPreferencesAndPostNotificationForLanguageChange"));
    void (^completion)(void) = ^{};
    ((void (*)(id, SEL, id))objc_msgSend)(cls,
        NSSelectorFromString(@"writeLanguageAndLocaleConfigurationIfNeededWithCompletion:"), completion);
    self.statusLabel.text = @"正在清理字体缓存，即将重启用户空间。";
    return YES;
}

@end
