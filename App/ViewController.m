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
- (void)setDisplayName:(NSString *)name;
- (void)clearFont;
@end

@implementation FCFontPreviewView {
    CTFontRef _previewFont;
    NSString *_displayName;
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
    _displayName = nil;
    [self setNeedsDisplay];
}

- (void)setDisplayName:(NSString *)name {
    _displayName = [name copy];
    [self setNeedsDisplay];
}

static void FCDrawPreviewLine(CGContextRef context, NSString *text, CTFontRef sourceFont,
                              UIColor *color, CGFloat x, CGFloat baseline, CGFloat maxWidth,
                              CGFloat minimumSize) {
    CTFontRef font = CFRetain(sourceFont);
    NSDictionary *attributes = @{
        (__bridge id)kCTFontAttributeName: (__bridge id)font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color.CGColor
    };
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)
        [[NSAttributedString alloc] initWithString:text attributes:attributes]);
    CGFloat width = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    if (width > maxWidth) {
        CGFloat size = MAX(minimumSize, CTFontGetSize(font) * maxWidth / MAX(1.0, width));
        CTFontRef fitted = CTFontCreateCopyWithAttributes(font, size, NULL, NULL);
        CFRelease(font);
        font = fitted;
        CFRelease(line);
        attributes = @{
            (__bridge id)kCTFontAttributeName: (__bridge id)font,
            (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color.CGColor
        };
        line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)
            [[NSAttributedString alloc] initWithString:text attributes:attributes]);
    }
    CGContextSetTextPosition(context, x, baseline);
    CTLineDraw(line, context);
    CFRelease(line);
    CFRelease(font);
}

static void FCDrawPreviewName(CGContextRef context, NSString *text, CTFontRef font,
                              UIColor *color, CGFloat right, CGFloat baseline, CGFloat maxWidth) {
    NSDictionary *attributes = @{
        (__bridge id)kCTFontAttributeName: (__bridge id)font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color.CGColor
    };
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)
        [[NSAttributedString alloc] initWithString:text attributes:attributes]);
    CGFloat width = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    if (width > maxWidth) {
        CGFloat size = MAX(8.0, CTFontGetSize(font) * maxWidth / MAX(1.0, width));
        CTFontRef fitted = CTFontCreateCopyWithAttributes(font, size, NULL, NULL);
        CFRelease(line);
        attributes = @{
            (__bridge id)kCTFontAttributeName: (__bridge id)fitted,
            (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color.CGColor
        };
        line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)
            [[NSAttributedString alloc] initWithString:text attributes:attributes]);
        width = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        CFRelease(fitted);
    }
    CGContextSetTextPosition(context, MAX(20.0, right - width), baseline);
    CTLineDraw(line, context);
    CFRelease(line);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, 0, CGRectGetHeight(rect));
    CGContextScaleCTM(context, 1, -1);
    CGFloat width = CGRectGetWidth(rect);
    UIColor *ink = [UIColor.labelColor resolvedColorWithTraitCollection:self.traitCollection];
    UIColor *detailInk = [UIColor.secondaryLabelColor resolvedColorWithTraitCollection:self.traitCollection];
    CTFontRef badge = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, 13.0, NULL);
    CTFontRef headline = _previewFont ? CTFontCreateCopyWithAttributes(_previewFont, 34.0, NULL, NULL)
                                      : CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 34.0, NULL);
    CTFontRef detail = _previewFont ? CTFontCreateCopyWithAttributes(_previewFont, 17.0, NULL, NULL)
                                    : CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 17.0, NULL);
    CTFontRef nameFont = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 10.0, NULL);
    FCDrawPreviewLine(context, @"实时预览", badge, ink, 20, 104, width - 40, 11);
    if (_previewFont) {
        FCDrawPreviewLine(context, @"字形有温度，阅读更从容。", headline, ink, 20, 61, width - 40, 18);
        FCDrawPreviewLine(context, @"四季流转 · Aa Bb · 0123456789", detail,
                          detailInk, 20, 29, width - 40, 12);
        if (_displayName.length) {
            FCDrawPreviewName(context, _displayName, nameFont,
                              detailInk, width - 20, 9, width * 0.72);
        }
    } else {
        FCDrawPreviewLine(context, @"导入字体后，在这里实时预览。", headline, ink, 20, 55, width - 40, 18);
    }
    CFRelease(badge);
    CFRelease(headline);
    CFRelease(detail);
    CFRelease(nameFont);
    CGContextRestoreGState(context);
}

@end

@interface ViewController () <UIDocumentPickerDelegate>
@property(nonatomic) NSInteger pickingSlot;
@property(nonatomic, copy) NSString *primaryPath;
@property(nonatomic, copy) NSString *optionalPath;
@property(nonatomic, copy) NSString *primaryDisplayName;
@property(nonatomic, copy) NSString *optionalDisplayName;
@property(nonatomic, copy) NSString *mountMode;
@property(nonatomic, strong) UILabel *primaryLabel;
@property(nonatomic, strong) UILabel *optionalLabel;
@property(nonatomic, strong) UILabel *mountLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *runButton;
@property(nonatomic, strong) UIButton *clearButton;
@property(nonatomic, strong) UIButton *restoreButton;
@property(nonatomic, strong) FCFontPreviewView *previewView;
@property(nonatomic, strong) UIView *processingCurtain;
@property(nonatomic) NSUInteger previewGeneration;
@property(nonatomic) BOOL restoringSystemFonts;
- (void)continueLanguageRefreshWithLanguage:(NSString *)language
                          originalLanguages:(NSArray<NSString *> *)originalLanguages;
@end

@implementation ViewController


- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"";
    self.view.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.055 green:0.053 blue:0.047 alpha:1.0]
            : [UIColor colorWithRed:0.976 green:0.969 blue:0.949 alpha:1.0];
    }];

    UILabel *titleLabel = [self label:@"FontChange" size:36 color:UIColor.labelColor];
    titleLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightHeavy];
    titleLabel.textAlignment = NSTextAlignmentLeft;
    self.restoreButton = [self button:@"" action:@selector(confirmRestoreSystemFonts)];
    self.restoreButton.accessibilityLabel = @"恢复系统字体";
    self.restoreButton.backgroundColor = [UIColor colorWithRed:0.94 green:0.32 blue:0.25 alpha:1.0];
    self.restoreButton.layer.cornerRadius = 21;
    self.restoreButton.layer.shadowOpacity = 0.08;
    [self.restoreButton setImage:[UIImage systemImageNamed:@"arrow.counterclockwise"] forState:UIControlStateNormal];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, self.restoreButton]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.distribution = UIStackViewDistributionEqualSpacing;

    self.mountLabel = [self label:@"● 正在检测挂载模式…" size:12 color:UIColor.secondaryLabelColor];
    self.mountLabel.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.mountLabel.layer.cornerRadius = 14;
    self.mountLabel.layer.masksToBounds = YES;
    [self.mountLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [self.mountLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    UILabel *sectionLabel = [self label:@"选择字体方案" size:23 color:UIColor.labelColor];
    sectionLabel.font = [UIFont systemFontOfSize:23 weight:UIFontWeightBold];
    sectionLabel.textAlignment = NSTextAlignmentLeft;
    UIButton *primaryButton = [self button:@"全局字体包" action:@selector(selectPrimary)];
    [primaryButton setImage:[UIImage systemImageNamed:@"archivebox.fill"] forState:UIControlStateNormal];
    self.primaryLabel = [self label:@"尚未选择" size:13 color:UIColor.secondaryLabelColor];
    self.primaryLabel.textAlignment = NSTextAlignmentCenter;
    UIButton *optionalButton = [self button:@"锁屏字体（SFUISoft）" action:@selector(selectOptional)];
    [optionalButton setImage:[UIImage systemImageNamed:@"textformat"] forState:UIControlStateNormal];
    self.optionalLabel = [self label:@"跟随全局字体包 · 自动读取 SFUISoft.ttc" size:12 color:UIColor.secondaryLabelColor];
    self.optionalLabel.textAlignment = NSTextAlignmentCenter;
    self.previewView = [[FCFontPreviewView alloc] init];
    self.previewView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.30 green:0.16 blue:0.11 alpha:1.0]
            : [UIColor colorWithRed:1.0 green:0.78 blue:0.66 alpha:1.0];
    }];
    self.previewView.layer.cornerRadius = 30;
    self.previewView.layer.masksToBounds = YES;
    self.previewView.layer.borderWidth = 0;
    self.clearButton = [self button:@"清空已选择的字体包" action:@selector(clearSelections)];
    [self.clearButton setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal];

    UIView *separator = [[UIView alloc] init];
    separator.backgroundColor = UIColor.separatorColor;
    UIStackView *selectionCard = [[UIStackView alloc] initWithArrangedSubviews:@[
        primaryButton, self.primaryLabel, separator, optionalButton, self.optionalLabel
    ]];
    selectionCard.axis = UILayoutConstraintAxisVertical;
    selectionCard.spacing = 4;
    selectionCard.backgroundColor = UIColor.clearColor;
    selectionCard.layer.cornerRadius = 22;
    selectionCard.layer.masksToBounds = NO;
    selectionCard.layoutMargins = UIEdgeInsetsMake(2, 3, 2, 3);
    selectionCard.layoutMarginsRelativeArrangement = YES;

    self.statusLabel = [self label:@"准备就绪 · 请选择字体方案" size:13 color:UIColor.secondaryLabelColor];
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.statusLabel.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.statusLabel.layer.cornerRadius = 18;
    self.statusLabel.layer.masksToBounds = YES;
    self.statusLabel.layer.borderWidth = 0.5;
    self.statusLabel.layer.borderColor = UIColor.separatorColor.CGColor;
    [self.statusLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [self.statusLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];

    UIView *bottomSpacer = [[UIView alloc] init];
    bottomSpacer.backgroundColor = UIColor.clearColor;
    [bottomSpacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [bottomSpacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];

    self.runButton = [self button:@"检查并开始执行" action:@selector(confirmRun)];
    self.runButton.backgroundColor = UIColor.labelColor;
    [self.runButton setTitleColor:UIColor.systemBackgroundColor forState:UIControlStateNormal];
    self.runButton.tintColor = UIColor.systemBackgroundColor;
    [self.runButton setImage:[UIImage systemImageNamed:@"checkmark.circle.fill"] forState:UIControlStateNormal];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        header, self.mountLabel, self.previewView, sectionLabel, selectionCard, self.clearButton,
        self.statusLabel, bottomSpacer, self.runButton
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    [stack setCustomSpacing:8 afterView:header];
    [stack setCustomSpacing:10 afterView:self.mountLabel];
    [stack setCustomSpacing:10 afterView:self.previewView];
    [stack setCustomSpacing:6 afterView:sectionLabel];
    [stack setCustomSpacing:8 afterView:selectionCard];
    [stack setCustomSpacing:8 afterView:self.statusLabel];
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:14],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-14],
        [header.heightAnchor constraintEqualToConstant:44],
        [self.restoreButton.widthAnchor constraintEqualToConstant:42],
        [self.restoreButton.heightAnchor constraintEqualToConstant:42],
        [self.mountLabel.heightAnchor constraintEqualToConstant:28],
        [primaryButton.heightAnchor constraintEqualToConstant:44],
        [optionalButton.heightAnchor constraintEqualToConstant:44],
        [separator.heightAnchor constraintEqualToConstant:0.5],
        [selectionCard.heightAnchor constraintEqualToConstant:148],
        [self.previewView.heightAnchor constraintEqualToConstant:118],
        [self.clearButton.heightAnchor constraintEqualToConstant:36],
        [self.statusLabel.heightAnchor constraintEqualToConstant:46],
        [bottomSpacer.heightAnchor constraintGreaterThanOrEqualToConstant:0],
        [self.runButton.heightAnchor constraintEqualToConstant:56],
    ]];
    for (UIButton *selectionButton in @[primaryButton, optionalButton]) {
        selectionButton.backgroundColor = UIColor.clearColor;
        [selectionButton setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        selectionButton.tintColor = UIColor.systemOrangeColor;
        selectionButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        selectionButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        selectionButton.backgroundColor = UIColor.secondarySystemBackgroundColor;
        selectionButton.layer.borderWidth = 1.0;
        selectionButton.layer.borderColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.30].CGColor;
        selectionButton.layer.shadowOpacity = 0.05;
        selectionButton.layer.shadowRadius = 5;
        selectionButton.layer.shadowOffset = CGSizeMake(0, 2);
        selectionButton.layer.cornerRadius = 14;
    }
    [self cleanupOldImports];
    [self updateClearButtonState];
    [self detectMountMode];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            self.statusLabel.layer.borderColor = UIColor.separatorColor.CGColor;
            [self.previewView setNeedsDisplay];
        }
    }
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
    button.layer.cornerRadius = 18;
    button.tintColor = UIColor.whiteColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.12;
    button.layer.shadowRadius = 8;
    button.layer.shadowOffset = CGSizeMake(0, 4);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button addTarget:self action:@selector(buttonTouchDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(buttonTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return button;
}

- (void)buttonTouchDown:(UIButton *)button {
    [UIView animateWithDuration:0.12 animations:^{
        button.transform = CGAffineTransformMakeScale(0.975, 0.975);
        button.alpha = 0.9;
    }];
}

- (void)buttonTouchUp:(UIButton *)button {
    [UIView animateWithDuration:0.18 animations:^{
        button.transform = CGAffineTransformIdentity;
        button.alpha = button.enabled ? 1.0 : 0.72;
    }];
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
    self.primaryDisplayName = nil;
    self.optionalDisplayName = nil;
    self.previewGeneration++;
    [self.previewView clearFont];
    self.primaryLabel.text = @"尚未选择";
    self.optionalLabel.text = @"跟随全局字体包 · 自动读取 SFUISoft.ttc";
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
    NSString *displayName = slot == 2 ? self.optionalDisplayName : self.primaryDisplayName;
    [self.previewView setDisplayName:displayName ?: source.lastPathComponent.stringByDeletingPathExtension];
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
    self.clearButton.hidden = !hasSelection;
    self.clearButton.enabled = hasSelection;
    self.clearButton.backgroundColor = hasSelection ? UIColor.systemBlueColor : UIColor.systemGray4Color;
    self.clearButton.tintColor = hasSelection ? UIColor.whiteColor : UIColor.systemGrayColor;
    self.clearButton.layer.shadowOpacity = hasSelection ? 0.12 : 0.0;
    [self.clearButton setTitleColor:hasSelection ? UIColor.whiteColor : UIColor.systemGrayColor
                          forState:UIControlStateNormal];
    self.clearButton.alpha = hasSelection ? 1.0 : 0.72;
}

- (void)detectMountMode {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = [self runHelperArguments:@[@"--detect-mount"] wait:YES];
        NSString *mode = status == 14 ? @"fontchange" : (status == 15 ? @"repair-needed" : @"uninitialized");
        dispatch_async(dispatch_get_main_queue(), ^{
            self.mountMode = mode;
            if ([mode isEqualToString:@"fontchange"]) {
                self.mountLabel.text = @"● 自带挂载 · 已启用";
                self.mountLabel.textColor = UIColor.systemGreenColor;
                self.mountLabel.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.10];
            } else if ([mode isEqualToString:@"repair-needed"]) {
                self.mountLabel.text = @"● 自带挂载 · 等待守护恢复";
                self.mountLabel.textColor = UIColor.systemOrangeColor;
                self.mountLabel.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.10];
            } else {
                self.mountLabel.text = @"● 自带挂载 · 首次执行自动创建";
                self.mountLabel.textColor = UIColor.systemBlueColor;
                self.mountLabel.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.10];
            }
            self.mountLabel.layer.cornerRadius = 12;
            self.mountLabel.layer.masksToBounds = YES;
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
        self.primaryDisplayName = source.lastPathComponent.stringByDeletingPathExtension;
        self.primaryLabel.text = source.lastPathComponent;
        self.statusLabel.text = [NSString stringWithFormat:@"主要字体包导入完成：%@。尚未执行替换。", source.lastPathComponent];
        [self refreshFontPreviewForSlot:1];
    } else {
        self.optionalPath = destination;
        self.optionalDisplayName = source.lastPathComponent.stringByDeletingPathExtension;
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

- (void)confirmRestoreSystemFonts {
    if ([self runHelperArguments:@[@"--system-font-state"] wait:YES] == 0) {
        UIAlertController *alreadyOriginal = [UIAlertController
            alertControllerWithTitle:@"当前已经是系统字体"
                             message:@"上次恢复后尚未通过 FontChange 覆盖其他字体，无需重复恢复、切换语言或重启用户空间。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alreadyOriginal addAction:[UIAlertAction actionWithTitle:@"好"
                                                            style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alreadyOriginal animated:YES completion:nil];
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"恢复系统字体"
                         message:@"将丢弃当前已覆盖的自定义字体，重新生成原生字体目录。随后会刷新语言缓存并重启用户空间。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"确认恢复"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(__unused UIAlertAction *action) {
        weakSelf.restoringSystemFonts = YES;
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

- (void)showProcessingCurtain {
    if (self.processingCurtain) return;
    UIView *curtain = [[UIView alloc] init];
    curtain.translatesAutoresizingMaskIntoConstraints = NO;
    curtain.backgroundColor = UIColor.systemBackgroundColor;
    curtain.userInteractionEnabled = YES;

    UIImage *lightImage = [UIImage imageNamed:@"ProcessingCurtainLight"];
    UIImage *darkImage = [UIImage imageNamed:@"ProcessingCurtainDark"];
    UIImageView *content = [[UIImageView alloc] initWithImage:lightImage];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.contentMode = UIViewContentModeScaleAspectFill;
    content.clipsToBounds = YES;
    if (@available(iOS 13.0, *)) {
        content.image = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? darkImage : lightImage;
    }
    [curtain addSubview:content];
    [self.view addSubview:curtain];
    [NSLayoutConstraint activateConstraints:@[
        [curtain.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [curtain.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [curtain.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [curtain.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:curtain.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:curtain.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:curtain.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:curtain.bottomAnchor],
    ]];
    self.processingCurtain = curtain;
}

- (void)runWithTemporaryLanguage:(NSString *)language originalLanguages:(NSArray<NSString *> *)originalLanguages {
    BOOL restoringSystemFonts = self.restoringSystemFonts;
    self.restoringSystemFonts = NO;
    self.runButton.enabled = NO;
    self.runButton.backgroundColor = UIColor.systemGreenColor;
    [self.runButton setTitle:@"正在执行…" forState:UIControlStateNormal];
    self.statusLabel.text = restoringSystemFonts
        ? @"运行日志\n• 正在恢复原生系统字体\n• 准备刷新字体缓存…"
        : self.primaryPath.length
        ? @"运行日志\n• 正在解压并验证字体包\n• 准备全局覆盖字体…"
        : @"运行日志\n• 正在验证 SFUISoft.ttc\n• 准备替换锁屏字体…";
    BOOL sfuiOnly = self.primaryPath.length == 0;
    NSString *primary = self.primaryPath ?: @"-";
    NSString *optional = self.optionalPath ?: @"-";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *helperArguments = restoringSystemFonts
            ? @[@"--restore-system-fonts"] : @[@"--install", primary, optional];
        int status = [self runHelperArguments:helperArguments wait:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != 0) {
                self.runButton.enabled = YES;
                self.runButton.backgroundColor = UIColor.systemRedColor;
                [self.runButton setTitle:@"执行失败，点击重试" forState:UIControlStateNormal];
                NSString *report = [NSString stringWithContentsOfFile:@"/var/mobile/Documents/fontchange_last_result.txt"
                    encoding:NSUTF8StringEncoding error:nil];
                self.statusLabel.text = report.length ? report : [NSString stringWithFormat:@"字体处理失败（%d）", status];
                return;
            }
            [self cleanupOldImports];
            self.primaryPath = nil;
            self.optionalPath = nil;
            self.primaryDisplayName = nil;
            self.optionalDisplayName = nil;
            self.previewGeneration++;
            [self.previewView clearFont];
            self.primaryLabel.text = @"尚未选择";
            self.optionalLabel.text = @"跟随全局字体包 · 自动读取 SFUISoft.ttc";
            [self updateClearButtonState];
            self.statusLabel.text = restoringSystemFonts
                ? @"运行日志\n✓ 系统原生字体已恢复\n• 正在刷新语言缓存"
                : sfuiOnly
                ? @"运行日志\n✓ SFUISoft 替换完成\n• 正在刷新语言缓存"
                : @"运行日志\n✓ 全局字体覆盖完成\n• 正在刷新语言缓存";
            [self continueLanguageRefreshWithLanguage:language originalLanguages:originalLanguages];
        });
    });
}

- (void)continueLanguageRefreshWithLanguage:(NSString *)language
                          originalLanguages:(NSArray<NSString *> *)originalLanguages {
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

    // Start recovery before invoking the native language transition because
    // iOS may suspend this app as soon as the transition begins.
    int spawnStatus = [self runHelperArguments:@[restoreMode, statePath, @"8"] wait:NO];
    if (spawnStatus != 0) {
        [NSFileManager.defaultManager removeItemAtPath:statePath error:nil];
        self.runButton.enabled = YES;
        self.runButton.backgroundColor = UIColor.systemRedColor;
        [self.runButton setTitle:@"执行失败，点击重试" forState:UIControlStateNormal];
        self.statusLabel.text = [NSString stringWithFormat:
            @"后台语言恢复及用户空间重启任务启动失败（%d），已停止语言切换。", spawnStatus];
        return;
    }

    [self showProcessingCurtain];
    if ([self invokeNativeLanguage:language fallback:fallback]) {
        self.statusLabel.text = @"正在清理字体缓存，即将重启用户空间。";
    } else {
        self.statusLabel.text = @"语言切换接口未响应；后台任务仍会恢复原语言并重启用户空间。";
    }
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
