#import "ViewController.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <spawn.h>
#import <sys/wait.h>
#import <string.h>
#import <roothide.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreText/CoreText.h>

extern char **environ;

@interface FCFontPreviewView : UIView
- (BOOL)loadFontAtPath:(NSString *)path;
- (void)clearFont;
@end

@implementation FCFontPreviewView {
    CTFontRef _previewFont;
}

- (void)dealloc {
    if (_previewFont) CFRelease(_previewFont);
}

- (BOOL)loadFontAtPath:(NSString *)path {
    if (_previewFont) {
        CFRelease(_previewFont);
        _previewFont = NULL;
    }
    CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)[NSURL fileURLWithPath:path]);
    if (descriptors && CFArrayGetCount(descriptors) > 0) {
        NSString *probe = @"中文字体预览";
        NSUInteger length = probe.length;
        UniChar *characters = calloc(length, sizeof(UniChar));
        CGGlyph *glyphs = calloc(length, sizeof(CGGlyph));
        [probe getCharacters:characters range:NSMakeRange(0, length)];
        CFIndex bestCoverage = -1;
        for (CFIndex index = 0; index < CFArrayGetCount(descriptors); index++) {
            CTFontDescriptorRef descriptor = (CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, index);
            CTFontRef candidate = CTFontCreateWithFontDescriptor(descriptor, 27.0, NULL);
            if (!candidate) continue;
            memset(glyphs, 0, length * sizeof(CGGlyph));
            CTFontGetGlyphsForCharacters(candidate, characters, glyphs, length);
            CFIndex coverage = 0;
            for (NSUInteger characterIndex = 0; characterIndex < length; characterIndex++) {
                if (glyphs[characterIndex] != 0) coverage++;
            }
            if (coverage > bestCoverage) {
                if (_previewFont) CFRelease(_previewFont);
                _previewFont = candidate;
                bestCoverage = coverage;
            } else {
                CFRelease(candidate);
            }
            if (coverage == (CFIndex)length) break;
        }
        free(characters);
        free(glyphs);
    }
    if (descriptors) CFRelease(descriptors);
    [self setNeedsDisplay];
    return _previewFont != NULL;
}

- (void)clearFont {
    if (_previewFont) {
        CFRelease(_previewFont);
        _previewFont = NULL;
    }
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, 0, CGRectGetHeight(rect));
    CGContextScaleCTM(context, 1, -1);
    CTFontRef font = _previewFont ?: CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 20.0, NULL);
    NSString *text = _previewFont ? @"中文字体预览  Aa Bb  0123456789" : @"导入字体后将在这里显示预览";
    NSDictionary *attributes = @{
        (__bridge id)kCTFontAttributeName: (__bridge id)font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)UIColor.labelColor.CGColor
    };
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)
        [[NSAttributedString alloc] initWithString:text attributes:attributes]);
    CGFloat ascent = 0, descent = 0;
    double width = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
    CGFloat maximumWidth = MAX(1, CGRectGetWidth(rect) - 28.0);
    CGFloat maximumHeight = MAX(1, CGRectGetHeight(rect) - 20.0);
    CGFloat scale = MIN(1.0, MIN(maximumWidth / MAX(1.0, width), maximumHeight / MAX(1.0, ascent + descent)));
    CTFontRef fittedFont = NULL;
    if (scale < 0.999) {
        fittedFont = CTFontCreateCopyWithAttributes(font, MAX(14.0, CTFontGetSize(font) * scale), NULL, NULL);
        CFRelease(line);
        attributes = @{
            (__bridge id)kCTFontAttributeName: (__bridge id)fittedFont,
            (__bridge id)kCTForegroundColorAttributeName: (__bridge id)UIColor.labelColor.CGColor
        };
        line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)
            [[NSAttributedString alloc] initWithString:text attributes:attributes]);
        width = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
    }
    CGContextSetTextPosition(context, MAX(12, (CGRectGetWidth(rect) - width) / 2.0),
        (CGRectGetHeight(rect) - ascent - descent) / 2.0 + descent);
    CTLineDraw(line, context);
    CFRelease(line);
    if (fittedFont) CFRelease(fittedFont);
    if (!_previewFont && font) CFRelease(font);
    CGContextRestoreGState(context);
}

@end

@interface ViewController () <UIDocumentPickerDelegate>
@property(nonatomic) NSInteger pickingSlot;
@property(nonatomic, copy) NSString *primaryPath;
@property(nonatomic, copy) NSString *optionalPath;
@property(nonatomic, copy) NSString *mountMode;
@property(nonatomic, strong) UILabel *primaryLabel;
@property(nonatomic, strong) UILabel *optionalLabel;
@property(nonatomic, strong) UILabel *mountLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *runButton;
@property(nonatomic, strong) UIButton *clearButton;
@property(nonatomic, strong) FCFontPreviewView *previewView;
@property(nonatomic) NSUInteger previewGeneration;
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
    self.mountLabel = [self label:@"当前挂载模式：正在检测…" size:13 color:UIColor.secondaryLabelColor];
    UIButton *primaryButton = [self button:@"主要字体包（全局覆盖，可选）" action:@selector(selectPrimary)];
    self.primaryLabel = [self label:@"尚未选择" size:13 color:UIColor.secondaryLabelColor];
    UIButton *optionalButton = [self button:@"选择用于 SFUISoft 的字体包 / TTC 文件" action:@selector(selectOptional)];
    self.optionalLabel = [self label:@"留空时全部使用主要字体包，并自动读取其中的 SFUISoft.ttc（用于自定义锁屏时钟字体）" size:13 color:UIColor.secondaryLabelColor];
    self.previewView = [[FCFontPreviewView alloc] init];
    self.previewView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.previewView.layer.cornerRadius = 14;
    self.previewView.layer.masksToBounds = YES;
    self.clearButton = [self button:@"清空已选择的字体包" action:@selector(clearSelections)];

    self.statusLabel = [self label:@"执行顺序：创建原生字体副本 → 覆盖字体 → 原生切换语言 → 重启用户空间" size:14 color:UIColor.secondaryLabelColor];
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.statusLabel.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.statusLabel.layer.cornerRadius = 12;
    self.statusLabel.layer.masksToBounds = YES;

    self.runButton = [self button:@"检查并开始执行" action:@selector(confirmRun)];
    self.runButton.backgroundColor = UIColor.systemGreenColor;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel, featureLabel, formatLabel, self.mountLabel, primaryButton, self.primaryLabel, optionalButton, self.optionalLabel,
        self.previewView, self.clearButton,
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
    [stack setCustomSpacing:20 afterView:self.clearButton];
    [stack setCustomSpacing:24 afterView:self.statusLabel];
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [primaryButton.heightAnchor constraintEqualToConstant:56],
        [optionalButton.heightAnchor constraintEqualToConstant:56],
        [self.previewView.heightAnchor constraintEqualToConstant:76],
        [self.clearButton.heightAnchor constraintEqualToConstant:48],
        [self.statusLabel.heightAnchor constraintGreaterThanOrEqualToConstant:58],
        [self.runButton.heightAnchor constraintEqualToConstant:58],
    ]];
    [self cleanupOldImports];
    [self updateClearButtonState];
    [self detectMountMode];
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

- (void)clearSelections {
    self.primaryPath = nil;
    self.optionalPath = nil;
    self.previewGeneration++;
    [self.previewView clearFont];
    self.primaryLabel.text = @"尚未选择";
    self.optionalLabel.text = @"留空时全部使用主要字体包，并自动读取其中的 SFUISoft.ttc（用于自定义锁屏时钟字体）";
    [self cleanupOldImports];
    [self updateClearButtonState];
    self.statusLabel.text = @"已清空所选字体包；系统中已应用的字体不会受到影响。";
}

- (void)refreshFontPreviewForSlot:(NSInteger)slot {
    self.previewGeneration++;
    NSUInteger generation = self.previewGeneration;
    NSString *source = slot == 2 ? self.optionalPath : self.primaryPath;
    if (!source.length) {
        [self.previewView clearFont];
        return;
    }
    NSString *kind = slot == 2 ? @"optional" : @"primary";
    NSString *destination = [self.importsDirectory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"preview-%lu.ttc", (unsigned long)generation]];
    BOOL directTTC = [source.pathExtension.lowercaseString isEqualToString:@"ttc"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = 0;
        if (directTTC) {
            NSError *copyError = nil;
            if (![NSFileManager.defaultManager copyItemAtPath:source toPath:destination error:&copyError]) status = 1;
        } else {
            status = [self runHelperArguments:@[@"--prepare-preview", kind, source, destination] wait:YES];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.previewGeneration) return;
            if (status != 0 || ![self.previewView loadFontAtPath:destination]) {
                self.statusLabel.text = @"字体已导入，但未能生成字体预览；不影响正常替换。";
            }
        });
    });
}

- (void)updateClearButtonState {
    BOOL hasSelection = self.primaryPath.length > 0 || self.optionalPath.length > 0;
    self.clearButton.enabled = hasSelection;
    self.clearButton.backgroundColor = hasSelection ? UIColor.systemBlueColor : UIColor.systemGray4Color;
    [self.clearButton setTitleColor:hasSelection ? UIColor.whiteColor : UIColor.systemGrayColor
                          forState:UIControlStateNormal];
    self.clearButton.alpha = hasSelection ? 1.0 : 0.72;
}

- (void)detectMountMode {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = [self runHelperArguments:@[@"--detect-mount"] wait:YES];
        NSString *mode = status == 10 ? @"mnt" : (status == 11 ? @"bindfs" : @"unknown");
        dispatch_async(dispatch_get_main_queue(), ^{
            self.mountMode = mode;
            if ([mode isEqualToString:@"mnt"]) {
                self.mountLabel.text = @"当前挂载模式：mnt";
                self.mountLabel.textColor = UIColor.systemOrangeColor;
            } else if ([mode isEqualToString:@"bindfs"]) {
                self.mountLabel.text = @"当前挂载模式：bindfs（mount_bindfs）";
                self.mountLabel.textColor = UIColor.systemGreenColor;
            } else {
                self.mountLabel.text = @"当前挂载模式：未识别（执行时将再次检测）";
                self.mountLabel.textColor = UIColor.secondaryLabelColor;
            }
        });
    });
}

- (void)handleExternalURL:(NSURL *)url {
    if (!url) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *extension = url.pathExtension.lowercaseString;
        if ([extension isEqualToString:@"ttc"]) {
            self.pickingSlot = 2;
            [self importPickedURL:url];
            return;
        }
        if (![extension isEqualToString:@"zip"]) {
            self.statusLabel.text = @"外部导入仅支持 ZIP 或 TTC 文件。";
            return;
        }
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"导入字体文件"
                             message:@"请选择这个 ZIP 的用途。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"作为主要字体包"
                                                style:UIAlertActionStyleDefault
                                              handler:^(__unused UIAlertAction *action) {
            self.pickingSlot = 1;
            [self importPickedURL:url];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"用于 SFUISoft"
                                                style:UIAlertActionStyleDefault
                                              handler:^(__unused UIAlertAction *action) {
            self.pickingSlot = 2;
            [self importPickedURL:url];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

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
        self.statusLabel.text = [NSString stringWithFormat:@"主要字体包导入完成：%@。尚未执行替换。", source.lastPathComponent];
        [self refreshFontPreviewForSlot:1];
    } else {
        self.optionalPath = destination;
        self.optionalLabel.text = source.lastPathComponent;
        self.statusLabel.text = [NSString stringWithFormat:@"SFUISoft 字体文件导入完成：%@。尚未执行替换。", source.lastPathComponent];
        [self refreshFontPreviewForSlot:2];
    }
    [self updateClearButtonState];
}

- (void)confirmRun {
    if (self.primaryPath.length == 0 && self.optionalPath.length == 0) {
        self.statusLabel.text = @"请至少选择主要字体包，或选择用于 SFUISoft 的字体包 / TTC 文件。";
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"执行前请注意"
                         message:@"执行过程中会自动进入锁屏界面。请勿解锁、切换应用或进行其他操作，请耐心等待系统完成语言恢复及用户空间重启。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"继续执行"
                                            style:UIAlertActionStyleDefault
                                          handler:^(__unused UIAlertAction *action) {
        [weakSelf beginConfirmedRun];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)beginConfirmedRun {
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
    self.statusLabel.text = self.primaryPath.length
        ? @"正在解压、验证并全局覆盖字体…"
        : @"正在验证并单独替换 SFUISoft.ttc…";
    BOOL sfuiOnly = self.primaryPath.length == 0;
    NSString *primary = self.primaryPath ?: @"-";
    NSString *optional = self.optionalPath ?: @"-";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = [self runHelperArguments:@[@"--install", primary, optional] wait:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self cleanupOldImports];
            self.primaryPath = nil;
            self.optionalPath = nil;
            self.previewGeneration++;
            [self.previewView clearFont];
            self.primaryLabel.text = @"尚未选择";
            self.optionalLabel.text = @"留空时全部使用主要字体包，并自动读取其中的 SFUISoft.ttc（用于自定义锁屏时钟字体）";
            [self updateClearButtonState];
            if (status != 0) {
                self.runButton.enabled = YES;
                self.runButton.backgroundColor = UIColor.systemRedColor;
                [self.runButton setTitle:@"执行失败，点击重试" forState:UIControlStateNormal];
                NSString *report = [NSString stringWithContentsOfFile:@"/var/mobile/Documents/fontchange_last_result.txt"
                    encoding:NSUTF8StringEncoding error:nil];
                self.statusLabel.text = report.length ? report : [NSString stringWithFormat:@"字体处理失败（%d）", status];
                return;
            }
            self.statusLabel.text = sfuiOnly
                ? @"SFUISoft 替换完成，正在清理字体缓存，即将重启用户空间…"
                : @"字体覆盖完成，正在清理字体缓存，即将重启用户空间…";
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
            NSString *restoreMode = @"--restore-language-and-reboot";
            int preflightStatus = [self runHelperArguments:@[@"--preflight", @"userspace"] wait:YES];
            if (preflightStatus != 0) {
                [NSFileManager.defaultManager removeItemAtPath:statePath error:nil];
                self.runButton.enabled = YES;
                self.runButton.backgroundColor = UIColor.systemRedColor;
                [self.runButton setTitle:@"执行失败，点击重试" forState:UIControlStateNormal];
                self.statusLabel.text = [NSString stringWithFormat:
                    @"后台语言恢复任务自检失败（%d），已停止切换。", preflightStatus];
                return;
            }
            if ([self invokeNativeLanguage:language fallback:fallback]) {
                int spawnStatus = [self runHelperArguments:@[restoreMode, statePath, @"8"] wait:NO];
                if (spawnStatus != 0) {
                    [self invokeNativeLanguage:fallback fallback:fallback];
                    [NSFileManager.defaultManager removeItemAtPath:statePath error:nil];
                    self.runButton.enabled = YES;
                    self.runButton.backgroundColor = UIColor.systemRedColor;
                    [self.runButton setTitle:@"执行失败，点击重试" forState:UIControlStateNormal];
                    self.statusLabel.text = [NSString stringWithFormat:
                        @"后台语言恢复任务启动失败（%d），已尝试立即恢复原语言。", spawnStatus];
                    return;
                }
                self.statusLabel.text = @"正在清理字体缓存，即将重启用户空间。";
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
