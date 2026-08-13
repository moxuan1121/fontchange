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

@interface FCFontSchemeCard : UIControl
@property(nonatomic) NSInteger schemeIndex;
@property(nonatomic, strong) UILabel *sampleLabel;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UIButton *deleteButton;
- (void)setSelectedAppearance:(BOOL)selected;
@end

@implementation FCFontSchemeCard

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.layer.cornerRadius = 18;
    self.layer.borderWidth = 1.0;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.06;
    self.layer.shadowRadius = 8;
    self.layer.shadowOffset = CGSizeMake(0, 3);

    _sampleLabel = [[UILabel alloc] init];
    _sampleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _sampleLabel.text = @"Aa 字";
    _sampleLabel.font = [UIFont systemFontOfSize:29 weight:UIFontWeightMedium];
    _sampleLabel.textColor = UIColor.labelColor;

    _nameLabel = [[UILabel alloc] init];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _nameLabel.textColor = UIColor.labelColor;
    _nameLabel.numberOfLines = 2;

    _detailLabel = [[UILabel alloc] init];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.numberOfLines = 1;

    _deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_deleteButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    _deleteButton.tintColor = UIColor.tertiaryLabelColor;
    _deleteButton.accessibilityLabel = @"删除字体方案";

    [self addSubview:_sampleLabel];
    [self addSubview:_nameLabel];
    [self addSubview:_detailLabel];
    [self addSubview:_deleteButton];
    [NSLayoutConstraint activateConstraints:@[
        [_sampleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [_sampleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
        [_deleteButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [_deleteButton.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [_deleteButton.widthAnchor constraintEqualToConstant:28],
        [_deleteButton.heightAnchor constraintEqualToConstant:28],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
        [_nameLabel.topAnchor constraintEqualToAnchor:_sampleLabel.bottomAnchor constant:5],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
        [_detailLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10],
    ]];
    [self setSelectedAppearance:NO];
    return self;
}

- (void)setSelectedAppearance:(BOOL)selected {
    self.layer.borderColor = (selected ? UIColor.systemOrangeColor : UIColor.separatorColor).CGColor;
    self.layer.borderWidth = selected ? 2.0 : 0.7;
    self.backgroundColor = selected
        ? [UIColor.systemOrangeColor colorWithAlphaComponent:0.10]
        : UIColor.secondarySystemBackgroundColor;
}

@end

@interface ViewController () <UIDocumentPickerDelegate>
@property(nonatomic) NSInteger pickingSlot;
@property(nonatomic, copy) NSString *primaryPath;
@property(nonatomic, copy) NSString *optionalPath;
@property(nonatomic, copy) NSString *primaryDisplayName;
@property(nonatomic, copy) NSString *optionalDisplayName;
@property(nonatomic, copy) NSString *mountMode;
@property(nonatomic, strong) UILabel *mountLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *runButton;
@property(nonatomic, strong) UIButton *importButton;
@property(nonatomic, strong) UIButton *restoreButton;
@property(nonatomic, strong) FCFontPreviewView *previewView;
@property(nonatomic, strong) UIScrollView *schemeScrollView;
@property(nonatomic, strong) UIStackView *schemeStackView;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *fontSchemes;
@property(nonatomic, copy) NSString *selectedSchemeID;
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
    UILabel *sectionLabel = [self label:@"我的字体方案" size:22 color:UIColor.labelColor];
    sectionLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    sectionLabel.textAlignment = NSTextAlignmentLeft;
    self.previewView = [[FCFontPreviewView alloc] init];
    self.previewView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.30 green:0.16 blue:0.11 alpha:1.0]
            : [UIColor colorWithRed:1.0 green:0.78 blue:0.66 alpha:1.0];
    }];
    self.previewView.layer.cornerRadius = 30;
    self.previewView.layer.masksToBounds = YES;
    self.previewView.layer.borderWidth = 0;
    self.schemeScrollView = [[UIScrollView alloc] init];
    self.schemeScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.schemeScrollView.showsHorizontalScrollIndicator = NO;
    self.schemeScrollView.alwaysBounceHorizontal = YES;
    self.schemeStackView = [[UIStackView alloc] init];
    self.schemeStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.schemeStackView.axis = UILayoutConstraintAxisHorizontal;
    self.schemeStackView.alignment = UIStackViewAlignmentFill;
    self.schemeStackView.spacing = 10;
    [self.schemeScrollView addSubview:self.schemeStackView];
    [NSLayoutConstraint activateConstraints:@[
        [self.schemeStackView.leadingAnchor constraintEqualToAnchor:self.schemeScrollView.contentLayoutGuide.leadingAnchor],
        [self.schemeStackView.trailingAnchor constraintEqualToAnchor:self.schemeScrollView.contentLayoutGuide.trailingAnchor],
        [self.schemeStackView.topAnchor constraintEqualToAnchor:self.schemeScrollView.contentLayoutGuide.topAnchor],
        [self.schemeStackView.bottomAnchor constraintEqualToAnchor:self.schemeScrollView.contentLayoutGuide.bottomAnchor],
        [self.schemeStackView.heightAnchor constraintEqualToAnchor:self.schemeScrollView.frameLayoutGuide.heightAnchor],
    ]];

    self.importButton = [self button:@"导入字体" action:@selector(showImportMenu)];
    [self.importButton setImage:[UIImage systemImageNamed:@"plus.circle.fill"] forState:UIControlStateNormal];
    self.importButton.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self.importButton setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    self.importButton.tintColor = UIColor.systemOrangeColor;
    self.importButton.layer.borderWidth = 1.0;
    self.importButton.layer.borderColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.28].CGColor;

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
        header, self.mountLabel, self.previewView, sectionLabel, self.schemeScrollView, self.importButton,
        self.statusLabel, bottomSpacer, self.runButton
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    [stack setCustomSpacing:8 afterView:header];
    [stack setCustomSpacing:10 afterView:self.mountLabel];
    [stack setCustomSpacing:10 afterView:self.previewView];
    [stack setCustomSpacing:5 afterView:sectionLabel];
    [stack setCustomSpacing:7 afterView:self.schemeScrollView];
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
        [self.schemeScrollView.heightAnchor constraintEqualToConstant:106],
        [self.previewView.heightAnchor constraintEqualToConstant:118],
        [self.importButton.heightAnchor constraintEqualToConstant:42],
        [self.statusLabel.heightAnchor constraintEqualToConstant:46],
        [bottomSpacer.heightAnchor constraintGreaterThanOrEqualToConstant:0],
        [self.runButton.heightAnchor constraintEqualToConstant:56],
    ]];
    [self cleanupOldImports];
    [self loadFontSchemes];
    [self rebuildSchemeCards];
    [self detectMountMode];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            self.statusLabel.layer.borderColor = UIColor.separatorColor.CGColor;
            self.importButton.layer.borderColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.28].CGColor;
            for (FCFontSchemeCard *card in self.schemeStackView.arrangedSubviews) {
                if (![card isKindOfClass:FCFontSchemeCard.class]) continue;
                NSDictionary *scheme = card.schemeIndex >= 0 && card.schemeIndex < (NSInteger)self.fontSchemes.count
                    ? self.fontSchemes[(NSUInteger)card.schemeIndex] : nil;
                [card setSelectedAppearance:[scheme[@"id"] isEqualToString:self.selectedSchemeID]];
            }
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
    return [NSString stringWithUTF8String:
        jbroot("/var/mobile/Library/Application Support/FontChange/Imports")];
}

- (NSString *)schemesPath {
    return [[self.importsDirectory stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Schemes.plist"];
}

- (void)cleanupOldImports {
    // Remove import caches created by older releases in the user-visible
    // Documents directory. Applied system fonts and the native mirror live
    // elsewhere and are not affected.
    for (NSString *legacyName in @[@"FontChangeImports", @"FontChangeSelfContainedImports"]) {
        NSString *legacyPath = [@"/var/mobile/Documents" stringByAppendingPathComponent:legacyName];
        [NSFileManager.defaultManager removeItemAtPath:legacyPath error:nil];
    }
    [NSFileManager.defaultManager createDirectoryAtPath:self.importsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.importsDirectory error:nil] ?: @[]) {
        if ([name hasPrefix:@"preview-"] && [name.pathExtension.lowercaseString isEqualToString:@"ttc"]) {
            [NSFileManager.defaultManager removeItemAtPath:[self.importsDirectory stringByAppendingPathComponent:name] error:nil];
        }
    }
}

- (void)loadFontSchemes {
    NSArray *stored = [NSArray arrayWithContentsOfFile:self.schemesPath];
    self.fontSchemes = [NSMutableArray array];
    for (NSDictionary *item in stored ?: @[]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *scheme = [item mutableCopy];
        NSString *primary = scheme[@"primaryPath"];
        NSString *optional = scheme[@"optionalPath"];
        BOOL hasPrimary = primary.length && [NSFileManager.defaultManager fileExistsAtPath:primary];
        BOOL hasOptional = optional.length && [NSFileManager.defaultManager fileExistsAtPath:optional];
        if (!hasPrimary) [scheme removeObjectForKey:@"primaryPath"];
        if (!hasOptional) [scheme removeObjectForKey:@"optionalPath"];
        if (hasPrimary || hasOptional) [self.fontSchemes addObject:scheme];
    }
    NSString *savedID = [[NSUserDefaults standardUserDefaults] stringForKey:@"FontChangeSelectedSchemeID"];
    BOOL found = NO;
    for (NSDictionary *scheme in self.fontSchemes) {
        if ([scheme[@"id"] isEqualToString:savedID]) { found = YES; break; }
    }
    self.selectedSchemeID = found ? savedID : [self.fontSchemes.firstObject objectForKey:@"id"];
    [self applySelectedScheme];
    [self saveFontSchemes];
}

- (void)saveFontSchemes {
    NSString *parent = [self.schemesPath stringByDeletingLastPathComponent];
    [NSFileManager.defaultManager createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    [self.fontSchemes writeToFile:self.schemesPath atomically:YES];
    if (self.selectedSchemeID.length) {
        [[NSUserDefaults standardUserDefaults] setObject:self.selectedSchemeID forKey:@"FontChangeSelectedSchemeID"];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"FontChangeSelectedSchemeID"];
    }
}

- (NSMutableDictionary *)selectedScheme {
    for (NSMutableDictionary *scheme in self.fontSchemes) {
        if ([scheme[@"id"] isEqualToString:self.selectedSchemeID]) return scheme;
    }
    return nil;
}

- (void)applySelectedScheme {
    NSDictionary *scheme = [self selectedScheme];
    self.primaryPath = scheme[@"primaryPath"];
    self.optionalPath = scheme[@"optionalPath"];
    self.primaryDisplayName = scheme[@"primaryDisplayName"];
    self.optionalDisplayName = scheme[@"optionalDisplayName"];
    if (self.optionalPath.length) [self refreshFontPreviewForSlot:2];
    else if (self.primaryPath.length) [self refreshFontPreviewForSlot:1];
    else {
        self.previewGeneration++;
        [self.previewView clearFont];
    }
}

- (void)rebuildSchemeCards {
    for (UIView *view in self.schemeStackView.arrangedSubviews.copy) {
        [self.schemeStackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    if (self.fontSchemes.count == 0) {
        UIButton *empty = [UIButton buttonWithType:UIButtonTypeSystem];
        [empty setTitle:@"＋ 还没有字体方案\n点击这里导入第一款字体" forState:UIControlStateNormal];
        [empty setTitleColor:UIColor.secondaryLabelColor forState:UIControlStateNormal];
        empty.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        empty.titleLabel.numberOfLines = 2;
        empty.titleLabel.textAlignment = NSTextAlignmentCenter;
        empty.backgroundColor = UIColor.secondarySystemBackgroundColor;
        empty.layer.cornerRadius = 18;
        empty.layer.borderWidth = 0.7;
        empty.layer.borderColor = UIColor.separatorColor.CGColor;
        [empty addTarget:self action:@selector(showImportMenu) forControlEvents:UIControlEventTouchUpInside];
        [empty.widthAnchor constraintEqualToConstant:210].active = YES;
        [self.schemeStackView addArrangedSubview:empty];
        return;
    }
    [self.fontSchemes enumerateObjectsUsingBlock:^(NSMutableDictionary *scheme, NSUInteger index, BOOL *stop) {
        (void)stop;
        FCFontSchemeCard *card = [[FCFontSchemeCard alloc] init];
        card.schemeIndex = (NSInteger)index;
        card.nameLabel.text = scheme[@"name"] ?: @"未命名字体";
        BOOL hasGlobal = [scheme[@"primaryPath"] length] > 0;
        BOOL hasLock = [scheme[@"optionalPath"] length] > 0;
        card.detailLabel.text = hasGlobal && hasLock ? @"全局 + 自定义锁屏" : (hasGlobal ? @"全局字体" : @"仅锁屏字体");
        card.sampleLabel.text = hasGlobal ? @"Aa 字" : @"Aa 时";
        card.tag = (NSInteger)index;
        card.deleteButton.tag = (NSInteger)index;
        [card addTarget:self action:@selector(selectSchemeCard:) forControlEvents:UIControlEventTouchUpInside];
        [card.deleteButton addTarget:self action:@selector(deleteSchemeCard:) forControlEvents:UIControlEventTouchUpInside];
        [card setSelectedAppearance:[scheme[@"id"] isEqualToString:self.selectedSchemeID]];
        [card.widthAnchor constraintEqualToConstant:154].active = YES;
        [self.schemeStackView addArrangedSubview:card];
    }];
}

- (void)selectSchemeCard:(FCFontSchemeCard *)card {
    if (card.schemeIndex < 0 || card.schemeIndex >= (NSInteger)self.fontSchemes.count) return;
    self.selectedSchemeID = self.fontSchemes[(NSUInteger)card.schemeIndex][@"id"];
    [self applySelectedScheme];
    [self saveFontSchemes];
    [self rebuildSchemeCards];
    self.statusLabel.text = [NSString stringWithFormat:@"已切换到“%@”；可直接预览或执行。",
        [self selectedScheme][@"name"] ?: @"字体方案"];
}

- (void)deleteSchemeCard:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.fontSchemes.count) return;
    NSDictionary *scheme = self.fontSchemes[(NSUInteger)index];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除字体方案"
        message:[NSString stringWithFormat:@"将从 FontChange 中删除“%@”及其导入文件，不会改变系统当前已应用的字体。", scheme[@"name"] ?: @"此方案"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSString *primary = scheme[@"primaryPath"];
        NSString *optional = scheme[@"optionalPath"];
        if (primary.length) [NSFileManager.defaultManager removeItemAtPath:primary error:nil];
        if (optional.length && ![optional isEqualToString:primary]) [NSFileManager.defaultManager removeItemAtPath:optional error:nil];
        [weakSelf.fontSchemes removeObjectAtIndex:(NSUInteger)index];
        weakSelf.selectedSchemeID = [weakSelf.fontSchemes.firstObject objectForKey:@"id"];
        [weakSelf applySelectedScheme];
        [weakSelf saveFontSchemes];
        [weakSelf rebuildSchemeCards];
        weakSelf.statusLabel.text = @"字体方案已删除；系统中已应用的字体不会受到影响。";
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showImportMenu {
    BOOL hasCurrentScheme = [self selectedScheme] != nil;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"导入字体"
        message:hasCurrentScheme
            ? @"导入全局字体会新建方案；锁屏字体可加入当前方案，也可单独建立方案。"
            : @"导入全局字体或建立一个仅锁屏字体方案。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"导入全局字体 ZIP" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self presentPickerForSlot:1];
    }]];
    if (hasCurrentScheme) {
        [menu addAction:[UIAlertAction actionWithTitle:@"为当前方案设置锁屏字体" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self presentPickerForSlot:2];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"新建仅锁屏字体方案" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self presentPickerForSlot:3];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = self.importButton;
    menu.popoverPresentationController.sourceRect = self.importButton.bounds;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)refreshFontPreviewForSlot:(NSInteger)slot {
    self.previewGeneration++;
    NSUInteger generation = self.previewGeneration;
    NSString *source = slot >= 2 ? self.optionalPath : self.primaryPath;
    if (!source.length) {
        [self.previewView clearFont];
        return;
    }
    NSString *displayName = slot >= 2 ? self.optionalDisplayName : self.primaryDisplayName;
    [self.previewView setDisplayName:displayName ?: source.lastPathComponent.stringByDeletingPathExtension];
    NSString *kind = slot >= 2 ? @"optional" : @"primary";
    NSString *destination = [self.importsDirectory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"preview-%@.ttc", NSUUID.UUID.UUIDString]];
    BOOL directTTC = [source.pathExtension.lowercaseString isEqualToString:@"ttc"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = 0;
        if (directTTC) {
            NSError *copyError = nil;
            [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
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

- (void)detectMountMode {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = [self runHelperArguments:@[@"--detect-mount"] wait:YES];
        NSString *mode = status == 10 ? @"mnt" :
            (status == 11 ? @"mount-bindfs" :
            (status == 14 ? @"fontchange" : (status == 15 ? @"repair-needed" : @"uninitialized")));
        dispatch_async(dispatch_get_main_queue(), ^{
            self.mountMode = mode;
            if ([mode isEqualToString:@"mnt"]) {
                self.mountLabel.text = @"● 外部挂载 · mnt（当前生效）";
                self.mountLabel.textColor = UIColor.systemGreenColor;
                self.mountLabel.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.10];
            } else if ([mode isEqualToString:@"mount-bindfs"]) {
                self.mountLabel.text = @"● 外部挂载 · mount_bindfs（当前生效）";
                self.mountLabel.textColor = UIColor.systemGreenColor;
                self.mountLabel.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.10];
            } else if ([mode isEqualToString:@"fontchange"]) {
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
            BOOL hasCurrentScheme = [self selectedScheme] != nil;
            UIAlertController *ttcAlert = [UIAlertController
                alertControllerWithTitle:@"导入锁屏字体"
                                 message:hasCurrentScheme
                                     ? @"请选择将这个 TTC 加入当前方案，或新建一个仅锁屏字体方案。"
                                     : @"当前没有字体方案，将创建一个仅锁屏字体方案。"
                          preferredStyle:UIAlertControllerStyleAlert];
            [ttcAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            if (hasCurrentScheme) {
                [ttcAlert addAction:[UIAlertAction actionWithTitle:@"加入当前方案" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    self.pickingSlot = 2;
                    [self importPickedURL:url];
                }]];
            }
            [ttcAlert addAction:[UIAlertAction actionWithTitle:@"新建仅锁屏方案" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                self.pickingSlot = 3;
                [self importPickedURL:url];
            }]];
            [self presentViewController:ttcAlert animated:YES completion:nil];
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
        BOOL hasCurrentScheme = [self selectedScheme] != nil;
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"作为主要字体包"
                                                style:UIAlertActionStyleDefault
                                              handler:^(__unused UIAlertAction *action) {
            self.pickingSlot = 1;
            [self importPickedURL:url];
        }]];
        if (hasCurrentScheme) {
            [alert addAction:[UIAlertAction actionWithTitle:@"加入当前方案的锁屏字体"
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(__unused UIAlertAction *action) {
                self.pickingSlot = 2;
                [self importPickedURL:url];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"新建仅锁屏方案"
                                                style:UIAlertActionStyleDefault
                                              handler:^(__unused UIAlertAction *action) {
            self.pickingSlot = 3;
            [self importPickedURL:url];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)presentPickerForSlot:(NSInteger)slot {
    self.pickingSlot = slot;
    NSArray<UTType *> *types = @[UTTypeZIP];
    if (slot >= 2) {
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
    BOOL acceptsTTC = self.pickingSlot >= 2 && [extension isEqualToString:@"ttc"];
    if (!acceptsZIP && !acceptsTTC) {
        self.statusLabel.text = self.pickingSlot == 1
            ? @"主要字体包必须是 .zip 文件。"
            : @"请选择字体 ZIP 或单个 .ttc 文件。";
        return;
    }
    NSMutableDictionary *targetScheme = self.pickingSlot == 2 ? [self selectedScheme] : nil;
    NSString *schemeID = targetScheme[@"id"];
    if (!schemeID.length) schemeID = NSUUID.UUID.UUIDString;
    NSString *role = self.pickingSlot == 1 ? @"global" : @"sfui";
    NSString *name = [NSString stringWithFormat:@"%@-%@.%@", schemeID, role, extension];
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
        targetScheme = [@{
            @"id": schemeID,
            @"name": source.lastPathComponent.stringByDeletingPathExtension ?: @"全局字体",
            @"primaryPath": destination,
            @"primaryDisplayName": source.lastPathComponent.stringByDeletingPathExtension ?: @"全局字体",
        } mutableCopy];
        [self.fontSchemes addObject:targetScheme];
        self.selectedSchemeID = schemeID;
        self.statusLabel.text = [NSString stringWithFormat:@"主要字体包导入完成：%@。尚未执行替换。", source.lastPathComponent];
    } else {
        if (!targetScheme) {
            targetScheme = [@{
                @"id": schemeID,
                @"name": source.lastPathComponent.stringByDeletingPathExtension ?: @"锁屏字体",
            } mutableCopy];
            [self.fontSchemes addObject:targetScheme];
        }
        NSString *oldOptional = targetScheme[@"optionalPath"];
        if (oldOptional.length && ![oldOptional isEqualToString:destination]) {
            [NSFileManager.defaultManager removeItemAtPath:oldOptional error:nil];
        }
        targetScheme[@"optionalPath"] = destination;
        targetScheme[@"optionalDisplayName"] = source.lastPathComponent.stringByDeletingPathExtension ?: @"锁屏字体";
        if (![targetScheme[@"primaryPath"] length]) targetScheme[@"name"] = targetScheme[@"optionalDisplayName"];
        self.selectedSchemeID = targetScheme[@"id"];
        self.statusLabel.text = [NSString stringWithFormat:@"SFUISoft 字体文件导入完成：%@。尚未执行替换。", source.lastPathComponent];
    }
    [self applySelectedScheme];
    [self saveFontSchemes];
    [self rebuildSchemeCards];
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
                         message:@"将解除当前字体挂载，让系统直接使用原生字体。随后会刷新语言缓存并重启用户空间。"
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
