#import "ViewController.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <spawn.h>
#import <sys/wait.h>
#import <roothide.h>

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
    self.title = @"一键更换字体";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UILabel *intro = [self label:@"选择主要字体 ZIP；可选的 100% ZIP 只用于最终覆盖 CoreUI/SFUISoft.ttc。" size:16 color:UIColor.secondaryLabelColor];
    UIButton *primaryButton = [self button:@"选择主要字体包（必选）" action:@selector(selectPrimary)];
    self.primaryLabel = [self label:@"尚未选择" size:13 color:UIColor.secondaryLabelColor];
    UIButton *optionalButton = [self button:@"选择 100% 字体包（可选）" action:@selector(selectOptional)];
    self.optionalLabel = [self label:@"留空时完全使用主要字体包" size:13 color:UIColor.secondaryLabelColor];

    self.statusLabel = [self label:@"执行顺序：创建原生字体副本 → 覆盖字体 → 原生切换语言 → 重启用户空间" size:14 color:UIColor.secondaryLabelColor];
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];

    self.runButton = [self button:@"检查并开始执行" action:@selector(confirmRun)];
    self.runButton.backgroundColor = UIColor.systemGreenColor;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        intro, primaryButton, self.primaryLabel, optionalButton, self.optionalLabel,
        self.statusLabel, self.runButton
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [primaryButton.heightAnchor constraintEqualToConstant:50],
        [optionalButton.heightAnchor constraintEqualToConstant:50],
        [self.runButton.heightAnchor constraintEqualToConstant:54],
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
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    button.backgroundColor = UIColor.systemBlueColor;
    button.layer.cornerRadius = 12;
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
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.zip-archive"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *source = urls.firstObject;
    if (!source) return;
    NSString *name = self.pickingSlot == 1 ? @"primary.zip" : @"optional100.zip";
    NSString *destination = [self.importsDirectory stringByAppendingPathComponent:name];
    [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
    NSError *error = nil;
    if (![NSFileManager.defaultManager copyItemAtURL:source toURL:[NSURL fileURLWithPath:destination] error:&error]) {
        self.statusLabel.text = [NSString stringWithFormat:@"导入失败：%@", error.localizedDescription];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择切换后的语言"
        message:@"字体覆盖成功后会调用系统原生语言切换，约 12 秒后重启用户空间。请先保存其他 App 中未保存的内容。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"切换到日语并执行" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf runWithLanguage:@"ja" fallback:@"zh-Hans"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"切换到简体中文并执行" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf runWithLanguage:@"zh-Hans" fallback:@"ja"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = self.runButton;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runWithLanguage:(NSString *)language fallback:(NSString *)fallback {
    self.runButton.enabled = NO;
    self.statusLabel.text = @"正在解压、验证并覆盖字体…";
    NSString *primary = self.primaryPath;
    NSString *optional = self.optionalPath ?: @"-";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = [self runHelperArguments:@[@"--install", primary, optional] wait:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != 0) {
                self.runButton.enabled = YES;
                NSString *report = [NSString stringWithContentsOfFile:@"/var/mobile/Documents/fontchange_last_result.txt"
                    encoding:NSUTF8StringEncoding error:nil];
                self.statusLabel.text = report.length ? report : [NSString stringWithFormat:@"字体处理失败（%d）", status];
                return;
            }
            self.statusLabel.text = @"字体覆盖完成，正在提交原生语言切换…";
            if ([self invokeNativeLanguage:language fallback:fallback]) {
                [self runHelperArguments:@[@"--reboot-after-delay", @"12"] wait:NO];
            }
        });
    });
}

- (int)runHelperArguments:(NSArray<NSString *> *)arguments wait:(BOOL)wait {
    const char *helper = jbroot("/usr/libexec/fontchange-helper");
    NSMutableArray<NSData *> *storage = [NSMutableArray array];
    char **argv = calloc(arguments.count + 2, sizeof(char *));
    argv[0] = (char *)helper;
    for (NSUInteger index = 0; index < arguments.count; index++) {
        NSData *data = [arguments[index] dataUsingEncoding:NSUTF8StringEncoding];
        [storage addObject:data];
        argv[index + 1] = (char *)data.bytes;
    }
    pid_t pid = 0;
    int result = posix_spawn(&pid, helper, NULL, NULL, argv, environ);
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
    self.statusLabel.text = @"语言切换已提交；即将重启用户空间。";
    return YES;
}

@end
