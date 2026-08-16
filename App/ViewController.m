#import "ViewController.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <spawn.h>
#import <sys/wait.h>
#import <string.h>
#if FONTCHANGE_ROOTLESS
#import <rootless.h>
#define jbroot(path) ROOT_PATH(path)
#else
#import <roothide.h>
#endif
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreText/CoreText.h>

extern char **environ;
typedef void (^FCPreviewCompletion)(NSString *path);

static BOOL FCIsSupportedImportExtension(NSString *extension, BOOL allowsTTC) {
    if ([extension isEqualToString:@"zip"]) return YES;
    return allowsTTC && [extension isEqualToString:@"ttc"];
}

@interface FCFontPreviewView : UIView
- (BOOL)loadFontAtPath:(NSString *)path;
- (void)setDisplayName:(NSString *)name;
- (void)setLockScreenPreview:(BOOL)lockScreenPreview;
- (void)setPreviewKind:(NSString *)previewKind;
- (void)setShowsSwitchHint:(BOOL)showsSwitchHint;
- (void)clearFont;
@end

static NSCache<NSString *, id> *FCMainPreviewFontCache(void) {
    static NSCache<NSString *, id> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.name = @"com.moxuan.fontchange.main-preview-fonts";
        cache.countLimit = 24;
    });
    return cache;
}

@implementation FCFontPreviewView {
    CTFontRef _previewFont;
    NSString *_displayName;
    NSString *_previewKind;
    BOOL _lockScreenPreview;
    BOOL _showsSwitchHint;
}

- (void)dealloc {
    if (_previewFont) CFRelease(_previewFont);
}

- (BOOL)loadFontAtPath:(NSString *)path {
    if (_previewFont) {
        CFRelease(_previewFont);
        _previewFont = NULL;
    }
    if (!path.length) {
        [self setNeedsDisplay];
        return NO;
    }
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", path, _previewKind ?: (_lockScreenPreview ? @"lock" : @"global")];
    CTFontRef cachedFont = (__bridge CTFontRef)[FCMainPreviewFontCache() objectForKey:cacheKey];
    if (cachedFont) {
        _previewFont = CFRetain(cachedFont);
        [self setNeedsDisplay];
        return YES;
    }
    CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)[NSURL fileURLWithPath:path]);
    if (descriptors && CFArrayGetCount(descriptors) > 0) {
        // A lock-screen font may intentionally contain only numerals. Select
        // the best face using the same characters that the preview will draw.
        NSString *probe = _lockScreenPreview ? @"0123456789" :
            ([_previewKind isEqualToString:@"custom-latin"] ? @"Aa·Bb · 0123456789" :
             ([_previewKind isEqualToString:@"custom-chinese"] ? @"字形有温度，阅读更从容" : @"中文字体预览"));
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
    if (_previewFont) [FCMainPreviewFontCache() setObject:(__bridge id)_previewFont forKey:cacheKey];
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

- (void)setLockScreenPreview:(BOOL)lockScreenPreview {
    if (_lockScreenPreview == lockScreenPreview) return;
    _lockScreenPreview = lockScreenPreview;
    [self setNeedsDisplay];
}

- (void)setPreviewKind:(NSString *)previewKind {
    if ([_previewKind isEqualToString:previewKind]) return;
    _previewKind = [previewKind copy];
    [self setNeedsDisplay];
}

- (void)setShowsSwitchHint:(BOOL)showsSwitchHint {
    if (_showsSwitchHint == showsSwitchHint) return;
    _showsSwitchHint = showsSwitchHint;
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

static void FCDrawCenteredPreviewLineVertically(CGContextRef context, NSString *text,
                                                CTFontRef sourceFont, UIColor *color,
                                                CGFloat centerX, CGFloat centerY,
                                                CGFloat maxWidth, CGFloat minimumSize) {
    CTFontRef font = CFRetain(sourceFont);
    CGFloat width = 0;
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)
        [[NSAttributedString alloc] initWithString:text attributes:@{
            (__bridge id)kCTFontAttributeName: (__bridge id)font,
            (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color.CGColor
        }]);
    width = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    if (width > maxWidth) {
        CGFloat size = MAX(minimumSize, CTFontGetSize(font) * maxWidth / MAX(1.0, width));
        CTFontRef fitted = CTFontCreateCopyWithAttributes(font, size, NULL, NULL);
        CFRelease(font);
        font = fitted;
        CFRelease(line);
        line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)
            [[NSAttributedString alloc] initWithString:text attributes:@{
                (__bridge id)kCTFontAttributeName: (__bridge id)font,
                (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color.CGColor
            }]);
        width = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    }
    CGFloat baseline = centerY - (CTFontGetAscent(font) - CTFontGetDescent(font)) * 0.5;
    CGContextSetTextPosition(context, centerX - width * 0.5, baseline);
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
    CGFloat scale = MAX(1.0, CGRectGetHeight(rect) / 118.0);
    UIColor *ink = [UIColor.labelColor resolvedColorWithTraitCollection:self.traitCollection];
    UIColor *detailInk = [UIColor.secondaryLabelColor resolvedColorWithTraitCollection:self.traitCollection];
    CTFontRef badge = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, 12.0 * scale, NULL);
    CGFloat headlineSize = (_lockScreenPreview ? 43.0 : 34.0) * scale;
    CTFontRef headline = _previewFont ? CTFontCreateCopyWithAttributes(_previewFont, headlineSize, NULL, NULL)
                                      : CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, headlineSize, NULL);
    CTFontRef detail = _previewFont ? CTFontCreateCopyWithAttributes(_previewFont, 17.0 * scale, NULL, NULL)
                                    : CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 17.0 * scale, NULL);
    CTFontRef nameFont = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 8.0 * scale, NULL);
    CTFontRef hintFont = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, 8.5 * scale, NULL);
    FCDrawPreviewLine(context, _lockScreenPreview ? @"自定义锁屏时钟" : @"实时预览",
                      badge, ink, 23, 102 * scale, width - 46, 10 * scale);
    if (_showsSwitchHint) {
        NSString *hint = _lockScreenPreview ? @"点击查看全局字体" : @"点击查看自定义锁屏时钟";
        FCDrawPreviewName(context, hint, hintFont, detailInk,
                          width - 23, 102 * scale, width * 0.58);
    }
    if (_previewFont) {
        if (_lockScreenPreview) {
            FCDrawCenteredPreviewLineVertically(context, @"0123456789", headline, ink,
                                                width * 0.5, CGRectGetMidY(rect), width - 40, 22 * scale);
        } else if ([_previewKind isEqualToString:@"custom-chinese"]) {
            FCDrawCenteredPreviewLineVertically(context, @"字形有温度，阅读更从容", headline,
                                                ink, width * 0.5, CGRectGetMidY(rect), width - 40, 18 * scale);
        } else if ([_previewKind isEqualToString:@"custom-latin"]) {
            FCDrawCenteredPreviewLineVertically(context, @"Aa·Bb · 0123456789", headline,
                                                ink, width * 0.5, CGRectGetMidY(rect), width - 40, 18 * scale);
        } else {
            FCDrawPreviewLine(context, @"字形有温度，阅读更从容。", headline, ink, 20, 61 * scale, width - 40, 18 * scale);
            FCDrawPreviewLine(context, @"四季流转 · Aa Bb · 0123456789", detail,
                              detailInk, 20, 29 * scale, width - 40, 12 * scale);
        }
        if (_displayName.length) {
            FCDrawPreviewName(context, _displayName, nameFont,
                              detailInk, width - 20, 9 * scale, width * 0.72);
        }
    }
    CFRelease(badge);
    CFRelease(headline);
    CFRelease(detail);
    CFRelease(nameFont);
    CFRelease(hintFont);
    CGContextRestoreGState(context);
}

@end

@interface FCFontSchemeSampleView : UIView
- (BOOL)loadFontAtPath:(NSString *)path;
- (void)setPreviewText:(NSString *)previewText;
@end

static NSCache<NSString *, id> *FCSchemeSampleFontCache(void) {
    static NSCache<NSString *, id> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.name = @"com.moxuan.fontchange.scheme-sample-fonts";
        cache.countLimit = 48;
    });
    return cache;
}

static void FCEvictPreviewFontAtPath(NSString *path) {
    if (!path.length) return;
    [FCSchemeSampleFontCache() removeObjectForKey:path];
    [FCSchemeSampleFontCache() removeObjectForKey:[path stringByAppendingString:@"|Aa"]];
    [FCSchemeSampleFontCache() removeObjectForKey:[path stringByAppendingString:@"|汉"]];
    [FCSchemeSampleFontCache() removeObjectForKey:[path stringByAppendingString:@"|0123456789"]];
    [FCMainPreviewFontCache() removeObjectForKey:[path stringByAppendingString:@"|global"]];
    [FCMainPreviewFontCache() removeObjectForKey:[path stringByAppendingString:@"|lock"]];
}

@implementation FCFontSchemeSampleView {
    CTFontRef _sampleFont;
    NSString *_previewText;
}

- (void)dealloc {
    if (_sampleFont) CFRelease(_sampleFont);
}

- (BOOL)loadFontAtPath:(NSString *)path {
    if (_sampleFont) {
        CFRelease(_sampleFont);
        _sampleFont = NULL;
    }
    if (!path.length) {
        [self setNeedsDisplay];
        return NO;
    }
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", path, _previewText ?: @"Aa"];
    CTFontRef cachedFont = (__bridge CTFontRef)[FCSchemeSampleFontCache() objectForKey:cacheKey];
    if (cachedFont) {
        _sampleFont = CFRetain(cachedFont);
        [self setNeedsDisplay];
        return YES;
    }
    CFIndex bestCoverage = -1;
    const CFIndex requiredCoverage = 2;
    CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)[NSURL fileURLWithPath:path]);
    if (descriptors && CFArrayGetCount(descriptors) > 0) {
        NSString *probe = _previewText ?: @"Aa";
        NSUInteger length = probe.length;
        UniChar *characters = calloc(length, sizeof(UniChar));
        CGGlyph *glyphs = calloc(length, sizeof(CGGlyph));
        [probe getCharacters:characters range:NSMakeRange(0, length)];
        for (CFIndex index = 0; index < CFArrayGetCount(descriptors); index++) {
            CTFontDescriptorRef descriptor = (CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, index);
            CTFontRef candidate = CTFontCreateWithFontDescriptor(descriptor, 56.0, NULL);
            if (!candidate) continue;
            memset(glyphs, 0, length * sizeof(CGGlyph));
            CTFontGetGlyphsForCharacters(candidate, characters, glyphs, length);
            CFIndex coverage = 0;
            for (NSUInteger characterIndex = 0; characterIndex < length; characterIndex++) {
                if (glyphs[characterIndex] != 0) coverage++;
            }
            if (coverage > bestCoverage) {
                if (_sampleFont) CFRelease(_sampleFont);
                _sampleFont = candidate;
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
    if (_sampleFont && bestCoverage == requiredCoverage) {
        [FCSchemeSampleFontCache() setObject:(__bridge id)_sampleFont forKey:cacheKey];
    } else if (_sampleFont) {
        CFRelease(_sampleFont);
        _sampleFont = NULL;
    }
    [self setNeedsDisplay];
    return _sampleFont != NULL;
}

- (void)setPreviewText:(NSString *)previewText {
    _previewText = [previewText copy];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, 0, CGRectGetHeight(rect));
    CGContextScaleCTM(context, 1, -1);
    if (!_sampleFont) {
        CGContextRestoreGState(context);
        return;
    }
    UIColor *ink = [UIColor.labelColor resolvedColorWithTraitCollection:self.traitCollection];
    CTFontRef font = CTFontCreateCopyWithAttributes(_sampleFont, 56.0, NULL, NULL);
    NSDictionary *attributes = @{
        (__bridge id)kCTFontAttributeName: (__bridge id)font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)ink.CGColor
    };
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)
        [[NSAttributedString alloc] initWithString:_previewText ?: @"Aa" attributes:attributes]);
    // Keep every card at the same 56pt sample size. This intentionally does
    // not follow Dynamic Type or shrink wide faces to fit.
    CGContextSetTextPosition(context, 0, 9);
    CTLineDraw(line, context);
    CFRelease(line);
    CFRelease(font);
    CGContextRestoreGState(context);
}

@end

@interface FCFontSchemeCard : UIControl
@property(nonatomic) NSInteger schemeIndex;
@property(nonatomic, copy) NSString *schemeID;
@property(nonatomic, strong) FCFontSchemeSampleView *sampleView;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UILabel *usageBadge;
@property(nonatomic, strong) UIButton *deleteButton;
@property(nonatomic, strong) UIButton *unlinkButton;
@property(nonatomic, strong) NSLayoutConstraint *detailToBadgeConstraint;
@property(nonatomic, strong) NSLayoutConstraint *detailToEdgeConstraint;
@property(nonatomic, strong) NSLayoutConstraint *sampleTopConstraint;
@property(nonatomic, copy) NSString *lastFittedName;
@property(nonatomic) CGFloat lastFittedNameWidth;
@property(nonatomic) BOOL showsUsage;
- (BOOL)loadFontAtPath:(NSString *)path;
- (void)setSelectedAppearance:(BOOL)selected;
- (void)setUsageAppearance:(BOOL)inUse;
- (void)setEditingAppearance:(BOOL)editing canUnlink:(BOOL)canUnlink;
- (void)startJiggle;
- (void)stopJiggle;
@end

@implementation FCFontSchemeCard

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.opaque = YES;
    self.layer.cornerRadius = 18;
    self.layer.borderWidth = 1.0;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0;
    self.layer.shadowRadius = 8;
    self.layer.shadowOffset = CGSizeMake(0, 3);

    _sampleView = [[FCFontSchemeSampleView alloc] init];
    _sampleView.translatesAutoresizingMaskIntoConstraints = NO;
    _sampleView.backgroundColor = UIColor.clearColor;
    _sampleView.userInteractionEnabled = NO;

    _nameLabel = [[UILabel alloc] init];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _nameLabel.textColor = UIColor.labelColor;
    _nameLabel.numberOfLines = 2;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.62;
    _nameLabel.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
    _nameLabel.lineBreakMode = NSLineBreakByCharWrapping;

    _detailLabel = [[UILabel alloc] init];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.numberOfLines = 1;

    _usageBadge = [[UILabel alloc] init];
    _usageBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _usageBadge.text = @"使用中";
    _usageBadge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
    _usageBadge.textAlignment = NSTextAlignmentCenter;
    _usageBadge.textColor = [UIColor colorWithRed:0.12 green:0.58 blue:0.34 alpha:1.0];
    _usageBadge.backgroundColor = [UIColor colorWithRed:0.12 green:0.68 blue:0.38 alpha:0.11];
    _usageBadge.layer.cornerRadius = 9;
    _usageBadge.layer.masksToBounds = YES;
    _usageBadge.hidden = YES;

    _deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *deleteSymbol = [UIImageSymbolConfiguration configurationWithPointSize:13
        weight:UIImageSymbolWeightMedium];
    [_deleteButton setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:deleteSymbol]
                   forState:UIControlStateNormal];
    _deleteButton.tintColor = UIColor.systemOrangeColor;
    _deleteButton.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.08];
    _deleteButton.layer.cornerRadius = 18;
    _deleteButton.layer.borderWidth = 0.6;
    _deleteButton.layer.borderColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.16].CGColor;
    _deleteButton.accessibilityLabel = @"删除字体方案";

    _unlinkButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _unlinkButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_unlinkButton setTitle:@"解除时钟" forState:UIControlStateNormal];
    [_unlinkButton setImage:[UIImage systemImageNamed:@"link.badge.minus"] forState:UIControlStateNormal];
    _unlinkButton.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    _unlinkButton.tintColor = UIColor.systemOrangeColor;
    _unlinkButton.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.10];
    _unlinkButton.layer.cornerRadius = 9;
    _unlinkButton.hidden = YES;
    _unlinkButton.accessibilityLabel = @"从方案移除自定义锁屏时钟";

    [self addSubview:_sampleView];
    [self addSubview:_nameLabel];
    [self addSubview:_detailLabel];
    [self addSubview:_usageBadge];
    [self addSubview:_deleteButton];
    [self addSubview:_unlinkButton];
    _detailToBadgeConstraint = [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_usageBadge.leadingAnchor constant:-6];
    _detailToEdgeConstraint = [_detailLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12];
    _sampleTopConstraint = [_sampleView.topAnchor constraintEqualToAnchor:self.topAnchor constant:14];
    _detailToEdgeConstraint.active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [_sampleView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_sampleView.trailingAnchor constraintEqualToAnchor:_deleteButton.leadingAnchor constant:-8],
        _sampleTopConstraint,
        [_sampleView.heightAnchor constraintEqualToConstant:64],
        [_deleteButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
        [_deleteButton.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [_deleteButton.widthAnchor constraintEqualToConstant:36],
        [_deleteButton.heightAnchor constraintEqualToConstant:36],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_nameLabel.topAnchor constraintEqualToAnchor:_sampleView.bottomAnchor constant:6],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_detailLabel.topAnchor constraintGreaterThanOrEqualToAnchor:_nameLabel.bottomAnchor constant:8],
        [_detailLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
        [_usageBadge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_usageBadge.centerYAnchor constraintEqualToAnchor:_detailLabel.centerYAnchor],
        [_usageBadge.widthAnchor constraintEqualToConstant:42],
        [_usageBadge.heightAnchor constraintEqualToConstant:18],
        [_unlinkButton.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [_unlinkButton.topAnchor constraintEqualToAnchor:self.topAnchor constant:7],
        [_unlinkButton.widthAnchor constraintEqualToConstant:76],
        [_unlinkButton.heightAnchor constraintEqualToConstant:20],
    ]];
    [self setSelectedAppearance:NO];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!self.nameLabel.text.length || CGRectGetWidth(self.nameLabel.bounds) <= 1.0) return;
    CGFloat availableWidth = CGRectGetWidth(self.nameLabel.bounds);
    if ([self.lastFittedName isEqualToString:self.nameLabel.text]
        && fabs(self.lastFittedNameWidth - availableWidth) < 0.5) return;
    CGFloat availableHeight = 36.0;
    CGFloat fittedSize = 14.0;
    while (fittedSize > 8.0) {
        UIFont *font = [UIFont systemFontOfSize:fittedSize weight:UIFontWeightSemibold];
        CGRect measured = [self.nameLabel.text boundingRectWithSize:CGSizeMake(availableWidth, CGFLOAT_MAX)
            options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
            attributes:@{NSFontAttributeName: font} context:nil];
        if (CGRectGetHeight(measured) <= availableHeight + 0.5) break;
        fittedSize -= 0.5;
    }
    if (fabs(self.nameLabel.font.pointSize - fittedSize) > 0.1) {
        self.nameLabel.font = [UIFont systemFontOfSize:fittedSize weight:UIFontWeightSemibold];
    }
    self.lastFittedName = self.nameLabel.text;
    self.lastFittedNameWidth = availableWidth;
}

- (BOOL)loadFontAtPath:(NSString *)path {
    return [self.sampleView loadFontAtPath:path];
}

- (void)setSelectedAppearance:(BOOL)selected {
    self.layer.borderColor = (selected ? UIColor.systemOrangeColor : UIColor.separatorColor).CGColor;
    self.layer.borderWidth = selected ? 2.0 : 0.7;
    // Keep the card surface fully opaque. An alpha-based orange background
    // makes the content behind a lifted card show through while dragging.
    self.backgroundColor = selected
        ? [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithRed:0.20 green:0.15 blue:0.10 alpha:1.0]
                : [UIColor colorWithRed:1.00 green:0.96 blue:0.88 alpha:1.0];
        }]
        : UIColor.secondarySystemBackgroundColor;
    self.alpha = 1.0;
    self.deleteButton.tintColor = selected ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
    self.deleteButton.backgroundColor = selected
        ? [UIColor.systemOrangeColor colorWithAlphaComponent:0.10]
        : [UIColor.secondaryLabelColor colorWithAlphaComponent:0.06];
    self.deleteButton.layer.borderColor = (selected
        ? [UIColor.systemOrangeColor colorWithAlphaComponent:0.18]
        : [UIColor.secondaryLabelColor colorWithAlphaComponent:0.10]).CGColor;
}

- (void)setUsageAppearance:(BOOL)inUse {
    self.showsUsage = inUse;
    self.detailToEdgeConstraint.active = !inUse;
    self.detailToBadgeConstraint.active = inUse;
    self.usageBadge.hidden = !inUse;
}

- (void)setEditingAppearance:(BOOL)editing canUnlink:(BOOL)canUnlink {
    self.unlinkButton.hidden = !(editing && canUnlink);
    self.detailLabel.hidden = NO;
    self.usageBadge.hidden = editing || !self.showsUsage;
    // Keep every card on the same baseline while editing. Combined cards use
    // the newly opened top space for the unlink action; other cards retain it
    // as breathing room so their Aa/name/detail positions remain aligned.
    self.sampleTopConstraint.constant = editing ? 29 : 14;
    self.layer.shadowOpacity = 0;
    if (editing) [self startJiggle];
    else [self stopJiggle];
}

- (void)startJiggle {
    if ([self.layer animationForKey:@"fontchange.jiggle"]) return;
    CAKeyframeAnimation *rotation = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
    rotation.values = @[@(-0.010), @(0.010), @(-0.008)];
    CAKeyframeAnimation *translation = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    translation.values = @[@(-0.45), @(0.45), @(-0.35)];
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[rotation, translation];
    group.duration = 0.17 + ((self.schemeIndex % 3) * 0.012);
    group.repeatCount = HUGE_VALF;
    group.beginTime = CACurrentMediaTime() + ((self.schemeIndex % 4) * 0.018);
    [self.layer addAnimation:group forKey:@"fontchange.jiggle"];
}

- (void)stopJiggle {
    [self.layer removeAnimationForKey:@"fontchange.jiggle"];
}

@end

@interface FCLogLabel : UILabel
@property(nonatomic, copy) void (^textDidChange)(NSString *text);
@end

@implementation FCLogLabel
- (void)setText:(NSString *)text {
    BOOL changed = ![self.text isEqualToString:text];
    [super setText:text];
    if (changed && text.length && self.textDidChange) self.textDidChange(text);
}
@end

@interface ViewController () <UIDocumentPickerDelegate, UIScrollViewDelegate>
@property(nonatomic) NSInteger pickingSlot;
@property(nonatomic, copy) NSString *primaryPath;
@property(nonatomic, copy) NSString *optionalPath;
@property(nonatomic, copy) NSString *primaryDisplayName;
@property(nonatomic, copy) NSString *optionalDisplayName;
@property(nonatomic, strong) UILabel *mountLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *runButton;
@property(nonatomic, strong) UIButton *importButton;
@property(nonatomic, strong) UIButton *restoreButton;
@property(nonatomic, strong) FCFontPreviewView *previewView;
@property(nonatomic, strong) UIScrollView *schemeScrollView;
@property(nonatomic, strong) UIStackView *schemeStackView;
@property(nonatomic, strong) UIPageControl *schemePageControl;
@property(nonatomic, strong) UIButton *schemeEditButton;
@property(nonatomic, strong) UIButton *selectedSummaryButton;
@property(nonatomic, strong) UIButton *logButton;
@property(nonatomic, strong) NSMutableArray<NSString *> *logEntries;
@property(nonatomic, strong) UIView *logOverlay;
@property(nonatomic, strong) UIView *logSheet;
@property(nonatomic, strong) UITextView *logTextView;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *fontSchemes;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *schemePreviewCache;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *pendingPreviewRequests;
@property(nonatomic, strong) NSOperationQueue *previewQueue;
@property(nonatomic, copy) NSString *selectedSchemeID;
@property(nonatomic, copy) NSString *activeSchemeID;
@property(nonatomic, copy) NSString *activeGlobalSchemeID;
@property(nonatomic, copy) NSString *activeChineseSchemeID;
@property(nonatomic, copy) NSString *activeLatinSchemeID;
@property(nonatomic, copy) NSString *activeLockSchemeID;
@property(nonatomic) NSInteger selectedPreviewSlot;
@property(nonatomic, strong) UIView *processingCurtain;
@property(nonatomic) NSUInteger previewGeneration;
@property(nonatomic) BOOL previewTransitioning;
@property(nonatomic) BOOL restoringSystemFonts;
@property(nonatomic) BOOL schemeEditing;
@property(nonatomic, weak) FCFontSchemeCard *draggedSchemeCard;
- (void)continueLanguageRefreshWithLanguage:(NSString *)language
                          originalLanguages:(NSArray<NSString *> *)originalLanguages;
- (void)appendLogEntry:(NSString *)text;
- (NSString *)formattedLogText;
- (NSString *)previewCacheMetadataPath;
- (NSString *)previewFilesDirectory;
- (void)savePreviewCacheMetadata;
- (void)scrollToSchemeIndex:(NSInteger)index animated:(BOOL)animated;
- (NSInteger)schemePageCount;
- (void)updateSchemePageControlForOffset:(CGFloat)offset;
- (void)loadActiveSchemeState;
- (void)refreshUsageAppearance;
- (void)updateActiveStateForScheme:(NSDictionary *)scheme schemeID:(NSString *)schemeID restoring:(BOOL)restoring;
- (void)migratePersistentStorageIfNeeded;
- (NSString *)resolvedPersistentImportPath:(NSString *)storedPath;
- (BOOL)isUsablePersistentFile:(NSString *)path;
- (void)requestPreviewForSchemeID:(NSString *)schemeID
                             kind:(NSString *)kind
                           source:(NSString *)source
                       completion:(FCPreviewCompletion)completion;
@end

@implementation ViewController


- (void)viewDidLoad {
    [super viewDidLoad];
    [self migratePersistentStorageIfNeeded];
    NSDictionary *storedPreviewCache = [NSDictionary dictionaryWithContentsOfFile:self.previewCacheMetadataPath];
    self.schemePreviewCache = [storedPreviewCache isKindOfClass:NSDictionary.class]
        ? [storedPreviewCache mutableCopy] : [NSMutableDictionary dictionary];
    self.pendingPreviewRequests = [NSMutableDictionary dictionary];
    self.previewQueue = [[NSOperationQueue alloc] init];
    self.previewQueue.name = @"com.moxuan.fontchange.preview-generation";
    self.previewQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    self.previewQueue.maxConcurrentOperationCount = 2;
    self.logEntries = [NSMutableArray array];
    self.activeSchemeID = [NSUserDefaults.standardUserDefaults stringForKey:@"FontChangeActiveSchemeID"];
    self.selectedPreviewSlot = 0;
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
    self.logButton = [self button:@"" action:@selector(showLog)];
    self.logButton.accessibilityLabel = @"运行日志";
    self.logButton.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.logButton.tintColor = UIColor.systemOrangeColor;
    self.logButton.layer.cornerRadius = 21;
    self.logButton.layer.shadowOpacity = 0.04;
    self.logButton.layer.borderWidth = 0.6;
    self.logButton.layer.borderColor = UIColor.separatorColor.CGColor;
    [self.logButton setImage:[UIImage systemImageNamed:@"doc.text.magnifyingglass"] forState:UIControlStateNormal];
    UIStackView *headerActions = [[UIStackView alloc] initWithArrangedSubviews:@[self.logButton, self.restoreButton]];
    headerActions.axis = UILayoutConstraintAxisHorizontal;
    headerActions.alignment = UIStackViewAlignmentCenter;
    headerActions.spacing = 8;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, headerActions]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.distribution = UIStackViewDistributionEqualSpacing;

    self.mountLabel = [self label:@"● 正在检测挂载模式…" size:12 color:UIColor.secondaryLabelColor];
    self.mountLabel.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.mountLabel.layer.cornerRadius = 14;
    self.mountLabel.layer.masksToBounds = YES;
    [self.mountLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [self.mountLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    UILabel *sectionLabel = [self label:@"字体方案" size:22 color:UIColor.labelColor];
    sectionLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    sectionLabel.textAlignment = NSTextAlignmentLeft;
    self.schemeEditButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.schemeEditButton setTitle:@"完成" forState:UIControlStateNormal];
    self.schemeEditButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.schemeEditButton.tintColor = UIColor.systemOrangeColor;
    self.schemeEditButton.hidden = YES;
    self.schemeEditButton.transform = CGAffineTransformMakeTranslation(0, -2.5);
    [self.schemeEditButton addTarget:self action:@selector(finishSchemeEditing) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *schemeHeader = [[UIStackView alloc] initWithArrangedSubviews:@[sectionLabel, self.schemeEditButton]];
    schemeHeader.axis = UILayoutConstraintAxisHorizontal;
    schemeHeader.alignment = UIStackViewAlignmentCenter;
    schemeHeader.distribution = UIStackViewDistributionEqualSpacing;
    [NSLayoutConstraint activateConstraints:@[
        [self.schemeEditButton.widthAnchor constraintGreaterThanOrEqualToConstant:58],
        [self.schemeEditButton.heightAnchor constraintEqualToConstant:34],
    ]];
    self.previewView = [[FCFontPreviewView alloc] init];
    self.previewView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.30 green:0.16 blue:0.11 alpha:1.0]
            : [UIColor colorWithRed:1.0 green:0.78 blue:0.66 alpha:1.0];
    }];
    self.previewView.layer.cornerRadius = 45;
    self.previewView.layer.masksToBounds = YES;
    self.previewView.layer.borderWidth = 0;
    self.previewView.userInteractionEnabled = YES;
    [self.previewView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleSelectedPreview)]];
    self.schemeScrollView = [[UIScrollView alloc] init];
    self.schemeScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.schemeScrollView.showsHorizontalScrollIndicator = NO;
    self.schemeScrollView.alwaysBounceHorizontal = YES;
    self.schemeScrollView.directionalLockEnabled = YES;
    self.schemeScrollView.decelerationRate = UIScrollViewDecelerationRateFast;
    self.schemeScrollView.delegate = self;
    self.schemeStackView = [[UIStackView alloc] init];
    self.schemeStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.schemeStackView.axis = UILayoutConstraintAxisHorizontal;
    self.schemeStackView.alignment = UIStackViewAlignmentFill;
    self.schemeStackView.spacing = 10;
    self.schemeStackView.layoutMarginsRelativeArrangement = YES;
    // Leave vertical room for the edit-mode jiggle and lifted drag scale so
    // card borders are not clipped by the carousel bounds.
    self.schemeStackView.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(5, 24, 5, 24);
    [self.schemeScrollView addSubview:self.schemeStackView];
    [NSLayoutConstraint activateConstraints:@[
        [self.schemeStackView.leadingAnchor constraintEqualToAnchor:self.schemeScrollView.contentLayoutGuide.leadingAnchor],
        [self.schemeStackView.trailingAnchor constraintEqualToAnchor:self.schemeScrollView.contentLayoutGuide.trailingAnchor],
        [self.schemeStackView.topAnchor constraintEqualToAnchor:self.schemeScrollView.contentLayoutGuide.topAnchor],
        [self.schemeStackView.bottomAnchor constraintEqualToAnchor:self.schemeScrollView.contentLayoutGuide.bottomAnchor],
        [self.schemeStackView.heightAnchor constraintEqualToAnchor:self.schemeScrollView.frameLayoutGuide.heightAnchor],
    ]];
    UIView *schemeCarouselContainer = [[UIView alloc] init];
    schemeCarouselContainer.translatesAutoresizingMaskIntoConstraints = NO;
    schemeCarouselContainer.backgroundColor = UIColor.clearColor;
    [schemeCarouselContainer addSubview:self.schemeScrollView];
    [NSLayoutConstraint activateConstraints:@[
        [self.schemeScrollView.topAnchor constraintEqualToAnchor:schemeCarouselContainer.topAnchor],
        [self.schemeScrollView.bottomAnchor constraintEqualToAnchor:schemeCarouselContainer.bottomAnchor],
    ]];

    self.schemePageControl = [[UIPageControl alloc] init];
    self.schemePageControl.hidesForSinglePage = NO;
    self.schemePageControl.currentPageIndicatorTintColor = UIColor.systemOrangeColor;
    self.schemePageControl.pageIndicatorTintColor = UIColor.tertiaryLabelColor;
    [self.schemePageControl addTarget:self action:@selector(schemePageChanged:) forControlEvents:UIControlEventValueChanged];

    UILabel *schemeHint = [self label:@"左右滑动选择，点按卡片即可预览" size:11 color:UIColor.secondaryLabelColor];

    UIView *importModule = [[UIView alloc] init];
    importModule.translatesAutoresizingMaskIntoConstraints = NO;
    importModule.backgroundColor = UIColor.secondarySystemBackgroundColor;
    importModule.layer.cornerRadius = 18;
    importModule.layer.borderWidth = 0.7;
    importModule.layer.borderColor = UIColor.separatorColor.CGColor;
    UIImageView *importIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"archivebox.fill"]];
    importIcon.translatesAutoresizingMaskIntoConstraints = NO;
    importIcon.tintColor = UIColor.systemOrangeColor;
    importIcon.contentMode = UIViewContentModeScaleAspectFit;
    UILabel *importTitle = [self label:@"导入字体" size:16 color:UIColor.labelColor];
    importTitle.translatesAutoresizingMaskIntoConstraints = NO;
    importTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    importTitle.textAlignment = NSTextAlignmentLeft;
    UILabel *importSubtitle = [self label:@"支持 ZIP 字体包与 TTC 文件" size:11 color:UIColor.secondaryLabelColor];
    importSubtitle.translatesAutoresizingMaskIntoConstraints = NO;
    importSubtitle.textAlignment = NSTextAlignmentLeft;
    UIStackView *importText = [[UIStackView alloc] initWithArrangedSubviews:@[importTitle, importSubtitle]];
    importText.translatesAutoresizingMaskIntoConstraints = NO;
    importText.axis = UILayoutConstraintAxisVertical;
    importText.spacing = 2;
    UIImageView *importChevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    importChevron.translatesAutoresizingMaskIntoConstraints = NO;
    importChevron.tintColor = UIColor.secondaryLabelColor;
    importChevron.contentMode = UIViewContentModeScaleAspectFit;
    [importModule addSubview:importIcon];
    [importModule addSubview:importText];
    [importModule addSubview:importChevron];
    self.importButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.importButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.importButton addTarget:self action:@selector(showImportMenu) forControlEvents:UIControlEventTouchUpInside];
    self.importButton.accessibilityLabel = @"导入字体";
    [importModule addSubview:self.importButton];
    [NSLayoutConstraint activateConstraints:@[
        [importIcon.leadingAnchor constraintEqualToAnchor:importModule.leadingAnchor constant:16],
        [importIcon.centerYAnchor constraintEqualToAnchor:importModule.centerYAnchor],
        [importIcon.widthAnchor constraintEqualToConstant:34],
        [importIcon.heightAnchor constraintEqualToConstant:34],
        [importText.leadingAnchor constraintEqualToAnchor:importIcon.trailingAnchor constant:12],
        [importText.centerYAnchor constraintEqualToAnchor:importModule.centerYAnchor],
        [importText.trailingAnchor constraintLessThanOrEqualToAnchor:importChevron.leadingAnchor constant:-10],
        [importChevron.trailingAnchor constraintEqualToAnchor:importModule.trailingAnchor constant:-16],
        [importChevron.centerYAnchor constraintEqualToAnchor:importModule.centerYAnchor],
        [importChevron.widthAnchor constraintEqualToConstant:12],
        [self.importButton.leadingAnchor constraintEqualToAnchor:importModule.leadingAnchor],
        [self.importButton.trailingAnchor constraintEqualToAnchor:importModule.trailingAnchor],
        [self.importButton.topAnchor constraintEqualToAnchor:importModule.topAnchor],
        [self.importButton.bottomAnchor constraintEqualToAnchor:importModule.bottomAnchor],
    ]];

    FCLogLabel *logLabel = [[FCLogLabel alloc] init];
    logLabel.text = @"准备就绪 · 请选择字体方案";
    logLabel.font = [UIFont systemFontOfSize:13];
    logLabel.textColor = UIColor.secondaryLabelColor;
    logLabel.textAlignment = NSTextAlignmentCenter;
    logLabel.numberOfLines = 0;
    __weak typeof(self) weakSelf = self;
    logLabel.textDidChange = ^(NSString *text) { [weakSelf appendLogEntry:text]; };
    self.statusLabel = logLabel;
    [self appendLogEntry:self.statusLabel.text];

    self.selectedSummaryButton = [self button:@"尚未选择字体方案" action:nil];
    self.selectedSummaryButton.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    [self.selectedSummaryButton setTitleColor:UIColor.secondaryLabelColor forState:UIControlStateNormal];
    UIButtonConfiguration *summaryConfiguration = [UIButtonConfiguration plainButtonConfiguration];
    summaryConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(0, 12, 0, 12);
    summaryConfiguration.baseForegroundColor = UIColor.secondaryLabelColor;
    summaryConfiguration.titleLineBreakMode = NSLineBreakByClipping;
    self.selectedSummaryButton.configuration = summaryConfiguration;
    self.selectedSummaryButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.selectedSummaryButton.titleLabel.numberOfLines = 1;
    self.selectedSummaryButton.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.selectedSummaryButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.selectedSummaryButton.titleLabel.minimumScaleFactor = 0.5;
    self.selectedSummaryButton.titleLabel.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
    self.selectedSummaryButton.titleLabel.lineBreakMode = NSLineBreakByClipping;
    self.selectedSummaryButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    self.selectedSummaryButton.userInteractionEnabled = NO;
    self.selectedSummaryButton.clipsToBounds = YES;
    self.selectedSummaryButton.layer.shadowOpacity = 0;
    self.selectedSummaryButton.layer.borderWidth = 0.6;
    self.selectedSummaryButton.layer.borderColor = UIColor.separatorColor.CGColor;
    [self.selectedSummaryButton setImage:nil forState:UIControlStateNormal];
    self.selectedSummaryButton.tintColor = UIColor.secondaryLabelColor;

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
        header, self.mountLabel, self.previewView, schemeHeader, schemeCarouselContainer,
        self.schemePageControl, schemeHint, importModule, self.selectedSummaryButton, bottomSpacer, self.runButton
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    [stack setCustomSpacing:8 afterView:header];
    [stack setCustomSpacing:10 afterView:self.mountLabel];
    [stack setCustomSpacing:12 afterView:self.previewView];
    [stack setCustomSpacing:5 afterView:schemeHeader];
    [stack setCustomSpacing:3 afterView:schemeCarouselContainer];
    [stack setCustomSpacing:2 afterView:self.schemePageControl];
    [stack setCustomSpacing:9 afterView:schemeHint];
    [stack setCustomSpacing:8 afterView:importModule];
    [stack setCustomSpacing:10 afterView:self.selectedSummaryButton];
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        // Activate these only after the carousel and the controller view share
        // a common ancestor. iOS 15 throws an exception if cross-hierarchy
        // constraints are activated while the carousel is still detached.
        [self.schemeScrollView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.schemeScrollView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:14],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-14],
        [header.heightAnchor constraintEqualToConstant:44],
        [self.logButton.widthAnchor constraintEqualToConstant:42],
        [self.logButton.heightAnchor constraintEqualToConstant:42],
        [self.restoreButton.widthAnchor constraintEqualToConstant:42],
        [self.restoreButton.heightAnchor constraintEqualToConstant:42],
        [self.mountLabel.heightAnchor constraintEqualToConstant:28],
        [schemeCarouselContainer.heightAnchor constraintEqualToConstant:178],
        [self.previewView.heightAnchor constraintEqualToConstant:177],
        [self.schemePageControl.heightAnchor constraintEqualToConstant:14],
        [schemeHint.heightAnchor constraintEqualToConstant:14],
        [importModule.heightAnchor constraintEqualToConstant:62],
        [self.selectedSummaryButton.heightAnchor constraintEqualToConstant:44],
        [bottomSpacer.heightAnchor constraintGreaterThanOrEqualToConstant:0],
        [self.runButton.heightAnchor constraintEqualToConstant:56],
    ]];
    UITapGestureRecognizer *outsideTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSchemeOutsideTap:)];
    outsideTap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:outsideTap];
    [self cleanupOldImports];
    [self loadFontSchemes];
    [self loadActiveSchemeState];
    [self rebuildSchemeCards];
    [self detectMountMode];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            self.importButton.layer.borderColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.28].CGColor;
            self.selectedSummaryButton.layer.borderColor = UIColor.separatorColor.CGColor;
            self.logButton.layer.borderColor = UIColor.separatorColor.CGColor;
            for (FCFontSchemeCard *card in self.schemeStackView.arrangedSubviews) {
                if (![card isKindOfClass:FCFontSchemeCard.class]) continue;
                NSDictionary *scheme = card.schemeIndex >= 0 && card.schemeIndex < (NSInteger)self.fontSchemes.count
                    ? self.fontSchemes[(NSUInteger)card.schemeIndex] : nil;
                [card setSelectedAppearance:[scheme[@"id"] isEqualToString:self.selectedSchemeID]];
                [card.sampleView setNeedsDisplay];
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
    if (action) {
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    }
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
    // User-owned imports must not live below the translated jailbreak root:
    // that mapping can change after a reboot or bootstrap recreation.
    return @"/var/mobile/Library/Application Support/FontChange/Imports";
}

- (NSString *)legacyTranslatedStorageDirectory {
    return [NSString stringWithUTF8String:
        jbroot("/var/mobile/Library/Application Support/FontChange")];
}

- (void)migratePersistentStorageIfNeeded {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *stableBase = @"/var/mobile/Library/Application Support/FontChange";
    NSString *stableImports = [stableBase stringByAppendingPathComponent:@"Imports"];
    NSString *legacyBase = self.legacyTranslatedStorageDirectory;
    NSString *legacyImports = [legacyBase stringByAppendingPathComponent:@"Imports"];
    [manager createDirectoryAtPath:stableImports withIntermediateDirectories:YES attributes:nil error:nil];

    // Perform the RootHide migration once and copy only source files that the
    // scheme database actually references. Copying the whole legacy Imports
    // directory resurrects deleted/orphaned packages on every launch.
    NSString *migrationMarker = [stableBase stringByAppendingPathComponent:@".RootHideMigrationV2.complete"];
    if (![legacyBase isEqualToString:stableBase] && ![manager fileExistsAtPath:migrationMarker]) {
        NSString *stableSchemes = [stableBase stringByAppendingPathComponent:@"Schemes.plist"];
        NSString *legacySchemes = [legacyBase stringByAppendingPathComponent:@"Schemes.plist"];
        if (![manager fileExistsAtPath:stableSchemes] && [manager fileExistsAtPath:legacySchemes]) {
            [manager copyItemAtPath:legacySchemes toPath:stableSchemes error:nil];
        }
        NSArray *migrationSchemes = [NSArray arrayWithContentsOfFile:stableSchemes];
        NSMutableSet<NSString *> *referencedNames = [NSMutableSet set];
        for (NSDictionary *scheme in migrationSchemes ?: @[]) {
            if (![scheme isKindOfClass:NSDictionary.class]) continue;
            for (NSString *key in @[@"primaryPath", @"optionalPath", @"customChinesePath", @"customLatinPath"]) {
                NSString *name = [scheme[key] lastPathComponent];
                if (name.length) [referencedNames addObject:name];
            }
        }
        BOOL migrationComplete = migrationSchemes != nil;
        for (NSString *name in referencedNames) {
            NSString *source = [legacyImports stringByAppendingPathComponent:name];
            NSString *destination = [stableImports stringByAppendingPathComponent:name];
            if (![self isUsablePersistentFile:destination] && [self isUsablePersistentFile:source]) {
                [manager removeItemAtPath:destination error:nil];
                if ([manager copyItemAtPath:source toPath:destination error:nil]) {
                    [manager setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:destination error:nil];
                }
            }
            if (![self isUsablePersistentFile:destination]) migrationComplete = NO;
        }
        if (migrationComplete) {
            [@"complete" writeToFile:migrationMarker atomically:YES
                              encoding:NSUTF8StringEncoding error:nil];
        }
    }

    // Stored scheme paths are absolute. Rebase any surviving legacy paths to
    // the stable Imports directory when the corresponding file is present.
    NSString *schemes = [stableBase stringByAppendingPathComponent:@"Schemes.plist"];
    NSArray *storedSchemes = [NSArray arrayWithContentsOfFile:schemes];
    NSMutableArray *repairedSchemes = [NSMutableArray array];
    BOOL schemesChanged = NO;
    for (NSDictionary *item in storedSchemes ?: @[]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *scheme = item.mutableCopy;
        for (NSString *key in @[@"primaryPath", @"optionalPath", @"customChinesePath", @"customLatinPath"]) {
            NSString *oldPath = scheme[key];
            if (!oldPath.length) continue;
            NSString *candidate = [stableImports stringByAppendingPathComponent:oldPath.lastPathComponent];
            if ([self isUsablePersistentFile:candidate] && ![oldPath isEqualToString:candidate]) {
                scheme[key] = candidate;
                schemesChanged = YES;
            }
        }
        [repairedSchemes addObject:scheme];
    }
    if (schemesChanged) [repairedSchemes writeToFile:schemes atomically:YES];

    NSString *metadata = [stableBase stringByAppendingPathComponent:@"PreviewCache.plist"];
    NSMutableDictionary *cache = [NSMutableDictionary dictionaryWithContentsOfFile:metadata];
    BOOL cacheChanged = NO;
    for (NSString *key in cache.allKeys.copy) {
        NSString *oldPath = cache[key];
        if (!oldPath.length) continue;
        NSString *candidate = [stableImports stringByAppendingPathComponent:oldPath.lastPathComponent];
        if ([self isUsablePersistentFile:candidate] && ![oldPath isEqualToString:candidate]) {
            cache[key] = candidate;
            cacheChanged = YES;
        }
    }
    if (cacheChanged) [cache writeToFile:metadata atomically:YES];
}

- (NSString *)resolvedPersistentImportPath:(NSString *)storedPath {
    if (!storedPath.length) return nil;
    NSString *stable = [self.importsDirectory stringByAppendingPathComponent:storedPath.lastPathComponent];
    if ([self isUsablePersistentFile:stable]) return stable;
    return [self isUsablePersistentFile:storedPath] ? storedPath : nil;
}

- (BOOL)isUsablePersistentFile:(NSString *)path {
    if (!path.length || ![NSFileManager.defaultManager isReadableFileAtPath:path]) return NO;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return [attributes[NSFileType] isEqualToString:NSFileTypeRegular] &&
        [attributes[NSFileSize] unsignedLongLongValue] > 0;
}

- (NSString *)schemesPath {
    return [[self.importsDirectory stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Schemes.plist"];
}

- (NSString *)previewCacheMetadataPath {
    return [[self.importsDirectory stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"PreviewCache.plist"];
}

- (NSString *)previewFilesDirectory {
    // Generated previews are disposable and must be visible to both the app
    // and the privileged helper inside the active jailbreak root.
    return [NSString stringWithUTF8String:
        jbroot("/var/mobile/Library/Caches/FontChange/Previews")];
}

- (void)savePreviewCacheMetadata {
    NSString *parent = [self.previewCacheMetadataPath stringByDeletingLastPathComponent];
    [NSFileManager.defaultManager createDirectoryAtPath:parent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [self.schemePreviewCache writeToFile:self.previewCacheMetadataPath atomically:YES];
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
    [NSFileManager.defaultManager createDirectoryAtPath:self.previewFilesDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    // 1.1 briefly stored generated previews beside persistent imports. They
    // are disposable and use a reserved prefix that imported source files do
    // not use, so remove every migration leftover from the durable directory.
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.importsDirectory error:nil] ?: @[]) {
        if ([name hasPrefix:@"preview-"] && [name.pathExtension.lowercaseString isEqualToString:@"ttc"]) {
            NSString *path = [self.importsDirectory stringByAppendingPathComponent:name];
            FCEvictPreviewFontAtPath(path);
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        }
    }
    // Remove original ZIP/TTC files that are no longer referenced by any
    // scheme. Never run this cleanup if the scheme database cannot be read.
    NSArray *storedSchemes = [NSArray arrayWithContentsOfFile:self.schemesPath];
    if (storedSchemes != nil) {
        NSMutableSet<NSString *> *referencedNames = [NSMutableSet set];
        for (NSDictionary *scheme in storedSchemes) {
            if (![scheme isKindOfClass:NSDictionary.class]) continue;
            for (NSString *key in @[@"primaryPath", @"optionalPath", @"customChinesePath", @"customLatinPath"]) {
                NSString *name = [scheme[key] lastPathComponent];
                if (name.length) [referencedNames addObject:name];
            }
        }
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.importsDirectory error:nil] ?: @[]) {
            NSString *extension = name.pathExtension.lowercaseString;
            if (![@[@"zip", @"ttc"] containsObject:extension] || [referencedNames containsObject:name]) continue;
            [NSFileManager.defaultManager removeItemAtPath:
                [self.importsDirectory stringByAppendingPathComponent:name] error:nil];
        }
    }
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.previewFilesDirectory error:nil] ?: @[]) {
        if ([name hasPrefix:@"source-"] || [name hasPrefix:@"install-"] || [name hasPrefix:@"import-"]) {
            [NSFileManager.defaultManager removeItemAtPath:
                [self.previewFilesDirectory stringByAppendingPathComponent:name] error:nil];
        }
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDate *lastRefresh = [defaults objectForKey:@"FontChangePreviewCacheLastRefresh"];
    NSTimeInterval sevenDays = 7.0 * 24.0 * 60.0 * 60.0;
    BOOL shouldRefresh = [lastRefresh isKindOfClass:NSDate.class]
        && [NSDate.date timeIntervalSinceDate:lastRefresh] >= sevenDays;
    if (![lastRefresh isKindOfClass:NSDate.class]) {
        [defaults setObject:NSDate.date forKey:@"FontChangePreviewCacheLastRefresh"];
    }
    if (!shouldRefresh) {
        BOOL metadataChanged = NO;
        NSMutableSet<NSString *> *referencedPaths = [NSMutableSet set];
        for (NSString *key in self.schemePreviewCache.allKeys.copy) {
            NSString *path = self.schemePreviewCache[key];
            BOOL currentCachePath = [path hasPrefix:[self.previewFilesDirectory stringByAppendingString:@"/"]];
            if (currentCachePath && [NSFileManager.defaultManager fileExistsAtPath:path]) {
                [referencedPaths addObject:path];
            } else {
                [self.schemePreviewCache removeObjectForKey:key];
                if ([path.lastPathComponent hasPrefix:@"preview-"]) {
                    FCEvictPreviewFontAtPath(path);
                    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                }
                metadataChanged = YES;
            }
        }
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.previewFilesDirectory error:nil] ?: @[]) {
            if (![name hasPrefix:@"preview-"] || ![name.pathExtension.lowercaseString isEqualToString:@"ttc"]) continue;
            NSString *path = [self.previewFilesDirectory stringByAppendingPathComponent:name];
            if (![referencedPaths containsObject:path]) {
                FCEvictPreviewFontAtPath(path);
                [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            }
        }
        if (metadataChanged) [self savePreviewCacheMetadata];
        return;
    }
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.previewFilesDirectory error:nil] ?: @[]) {
        if ([name hasPrefix:@"preview-"] && [name.pathExtension.lowercaseString isEqualToString:@"ttc"]) {
            NSString *path = [self.previewFilesDirectory stringByAppendingPathComponent:name];
            FCEvictPreviewFontAtPath(path);
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        }
    }
    [FCMainPreviewFontCache() removeAllObjects];
    [FCSchemeSampleFontCache() removeAllObjects];
    [self.schemePreviewCache removeAllObjects];
    [self savePreviewCacheMetadata];
    [defaults setObject:NSDate.date forKey:@"FontChangePreviewCacheLastRefresh"];
}

- (void)loadFontSchemes {
    NSArray *stored = [NSArray arrayWithContentsOfFile:self.schemesPath];
    self.fontSchemes = [NSMutableArray array];
    for (NSDictionary *item in stored ?: @[]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *scheme = [item mutableCopy];
        NSString *primary = [self resolvedPersistentImportPath:scheme[@"primaryPath"]];
        NSString *optional = [self resolvedPersistentImportPath:scheme[@"optionalPath"]];
        NSString *customChinese = [self resolvedPersistentImportPath:scheme[@"customChinesePath"]];
        NSString *customLatin = [self resolvedPersistentImportPath:scheme[@"customLatinPath"]];
        BOOL hasPrimary = primary.length > 0;
        BOOL hasOptional = optional.length > 0;
        if (hasPrimary) scheme[@"primaryPath"] = primary;
        else [scheme removeObjectForKey:@"primaryPath"];
        if (hasOptional) scheme[@"optionalPath"] = optional;
        else [scheme removeObjectForKey:@"optionalPath"];
        if (customChinese.length) scheme[@"customChinesePath"] = customChinese;
        else [scheme removeObjectForKey:@"customChinesePath"];
        if (customLatin.length) scheme[@"customLatinPath"] = customLatin;
        else [scheme removeObjectForKey:@"customLatinPath"];
        if (hasPrimary || hasOptional || customChinese.length || customLatin.length) [self.fontSchemes addObject:scheme];
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

- (NSString *)previewCacheKeyForSchemeID:(NSString *)schemeID
                                    kind:(NSString *)kind
                                  source:(NSString *)source {
    return [NSString stringWithFormat:@"%@|%@|%@", schemeID ?: @"", kind ?: @"", source ?: @""];
}

- (void)requestPreviewForSchemeID:(NSString *)schemeID
                             kind:(NSString *)kind
                           source:(NSString *)source
                       completion:(FCPreviewCompletion)completion {
    if (!source.length || !completion) return;
    NSString *cacheKey = [self previewCacheKeyForSchemeID:schemeID kind:kind source:source];
    NSString *cached = self.schemePreviewCache[cacheKey];
    if (cached.length && [NSFileManager.defaultManager fileExistsAtPath:cached]) {
        completion(cached);
        return;
    }
    if (cached.length) {
        [self.schemePreviewCache removeObjectForKey:cacheKey];
        [self savePreviewCacheMetadata];
    }
    NSMutableArray *waiting = self.pendingPreviewRequests[cacheKey];
    if (waiting) {
        [waiting addObject:[completion copy]];
        return;
    }
    self.pendingPreviewRequests[cacheKey] = [NSMutableArray arrayWithObject:[completion copy]];
    NSString *destination = [self.previewFilesDirectory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"preview-%@.ttc", NSUUID.UUID.UUIDString]];
    BOOL directTTC = [source.pathExtension.lowercaseString isEqualToString:@"ttc"];
    __weak typeof(self) weakSelf = self;
    [self.previewQueue addOperationWithBlock:^{
        int status = 0;
        if (directTTC) {
            [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
            status = [NSFileManager.defaultManager copyItemAtPath:source toPath:destination error:nil] ? 0 : 1;
        } else {
            NSString *stagedSource = [weakSelf.previewFilesDirectory stringByAppendingPathComponent:
                [NSString stringWithFormat:@"source-%@.%@", NSUUID.UUID.UUIDString,
                    source.pathExtension.length ? source.pathExtension : @"zip"]];
            [NSFileManager.defaultManager removeItemAtPath:stagedSource error:nil];
            BOOL staged = [NSFileManager.defaultManager copyItemAtPath:source toPath:stagedSource error:nil];
            status = staged
                ? [weakSelf runHelperArguments:@[@"--prepare-preview", kind, stagedSource, destination] wait:YES]
                : 1;
            [NSFileManager.defaultManager removeItemAtPath:stagedSource error:nil];
        }
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSString *result = status == 0 && [NSFileManager.defaultManager fileExistsAtPath:destination]
                ? destination : nil;
            NSArray *completions = [strongSelf.pendingPreviewRequests[cacheKey] copy];
            [strongSelf.pendingPreviewRequests removeObjectForKey:cacheKey];
            if (result.length) {
                NSString *replaced = strongSelf.schemePreviewCache[cacheKey];
                strongSelf.schemePreviewCache[cacheKey] = result;
                [strongSelf savePreviewCacheMetadata];
                if (replaced.length && ![replaced isEqualToString:result]) {
                    FCEvictPreviewFontAtPath(replaced);
                    [NSFileManager.defaultManager removeItemAtPath:replaced error:nil];
                }
            }
            for (FCPreviewCompletion callback in completions) callback(result);
        }];
    }];
}

- (void)invalidatePreviewCacheForSchemeID:(NSString *)schemeID {
    if (!schemeID.length) return;
    NSString *prefix = [schemeID stringByAppendingString:@"|"];
    NSArray<NSString *> *keys = self.schemePreviewCache.allKeys.copy;
    for (NSString *key in keys) {
        if (![key hasPrefix:prefix]) continue;
        NSString *path = self.schemePreviewCache[key];
        if (path.length) {
            FCEvictPreviewFontAtPath(path);
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        }
        [self.schemePreviewCache removeObjectForKey:key];
    }
    [self savePreviewCacheMetadata];
}

- (void)applySelectedScheme {
    NSDictionary *scheme = [self selectedScheme];
    BOOL customMode = [scheme[@"schemeType"] isEqualToString:@"custom"];
    NSString *customChinese = [scheme[@"customChinesePath"] length] ? scheme[@"customChinesePath"] : nil;
    NSString *customLatin = [scheme[@"customLatinPath"] length] ? scheme[@"customLatinPath"] : nil;
    self.primaryPath = customMode ? (customChinese ?: scheme[@"primaryPath"]) : scheme[@"primaryPath"];
    self.optionalPath = customMode ? (customLatin ?: scheme[@"optionalPath"]) : scheme[@"optionalPath"];
    self.primaryDisplayName = customMode ? (scheme[@"customChineseDisplayName"] ?: scheme[@"primaryDisplayName"]) : scheme[@"primaryDisplayName"];
    self.optionalDisplayName = customMode ? (scheme[@"customLatinDisplayName"] ?: scheme[@"optionalDisplayName"]) : scheme[@"optionalDisplayName"];
    [self.previewView setShowsSwitchHint:(self.primaryPath.length && self.optionalPath.length)];
    // A newly selected scheme always opens on the global preview. The user can
    // tap the large preview card to switch to the lock-screen preview.
    self.selectedPreviewSlot = self.primaryPath.length ? 1 : (self.optionalPath.length ? 2 : 0);
    if (self.selectedPreviewSlot) [self refreshFontPreviewForSlot:self.selectedPreviewSlot];
    else {
        self.previewGeneration++;
        [self.previewView clearFont];
    }
    [self updateSelectedSummary];
}

- (void)updateSelectedSummary {
    NSDictionary *scheme = [self selectedScheme];
    if (!scheme) {
        [self.selectedSummaryButton setTitle:@"尚未选择字体方案" forState:UIControlStateNormal];
        self.selectedSummaryButton.enabled = NO;
        return;
    }
    BOOL customMode = [scheme[@"schemeType"] isEqualToString:@"custom"];
    BOOL hasGlobal = self.primaryPath.length > 0;
    BOOL hasLock = self.optionalPath.length > 0;
    NSString *mode = nil;
    if (customMode) {
        BOOL hasChinese = [scheme[@"customChinesePath"] length] > 0;
        BOOL hasLatin = [scheme[@"customLatinPath"] length] > 0;
        if (hasChinese && hasLatin) mode = @"自定义中文 + 自定义英数字";
        else if (hasChinese) mode = @"自定义中文";
        else if (hasLatin) mode = @"自定义英数字";
        else mode = @"自定义字体";
    } else {
        mode = hasGlobal && hasLock ? @"全局 + 自定义时钟"
            : (hasGlobal ? @"全局字体" : @"自定义时钟");
    }
    [self.selectedSummaryButton setTitle:[NSString stringWithFormat:@"已选择：%@ · %@",
        scheme[@"name"] ?: @"字体方案", mode] forState:UIControlStateNormal];
    self.selectedSummaryButton.enabled = YES;
}

- (void)loadActiveSchemeState {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.activeGlobalSchemeID = [defaults stringForKey:@"FontChangeActiveGlobalSchemeID"];
    self.activeChineseSchemeID = [defaults stringForKey:@"FontChangeActiveChineseSchemeID"];
    self.activeLatinSchemeID = [defaults stringForKey:@"FontChangeActiveLatinSchemeID"];
    self.activeLockSchemeID = [defaults stringForKey:@"FontChangeActiveLockSchemeID"];

    BOOL hasComponentState = self.activeGlobalSchemeID.length ||
        self.activeChineseSchemeID.length || self.activeLatinSchemeID.length || self.activeLockSchemeID.length;
    if (!hasComponentState && self.activeSchemeID.length) {
        for (NSDictionary *scheme in self.fontSchemes) {
            if (![scheme[@"id"] isEqualToString:self.activeSchemeID]) continue;
            BOOL customMode = [scheme[@"schemeType"] isEqualToString:@"custom"];
            if (customMode) {
                if ([scheme[@"customChinesePath"] length]) self.activeChineseSchemeID = self.activeSchemeID;
                if ([scheme[@"customLatinPath"] length]) self.activeLatinSchemeID = self.activeSchemeID;
            } else if ([scheme[@"primaryPath"] length]) {
                self.activeGlobalSchemeID = self.activeSchemeID;
                if ([scheme[@"optionalPath"] length]) self.activeLockSchemeID = self.activeSchemeID;
            } else if ([scheme[@"optionalPath"] length]) {
                self.activeLockSchemeID = self.activeSchemeID;
            }
            break;
        }
    }
    [self refreshUsageAppearance];
}

- (void)refreshUsageAppearance {
    NSSet<NSString *> *activeIDs = [NSSet setWithObjects:
        self.activeGlobalSchemeID ?: @"", self.activeChineseSchemeID ?: @"",
        self.activeLatinSchemeID ?: @"", self.activeLockSchemeID ?: @"", nil];
    for (FCFontSchemeCard *card in self.schemeStackView.arrangedSubviews) {
        if (![card isKindOfClass:FCFontSchemeCard.class]) continue;
        [card setUsageAppearance:[activeIDs containsObject:card.schemeID]];
    }
}

- (void)updateActiveStateForScheme:(NSDictionary *)scheme
                           schemeID:(NSString *)schemeID
                          restoring:(BOOL)restoring {
    if (restoring) {
        self.activeGlobalSchemeID = nil;
        self.activeChineseSchemeID = nil;
        self.activeLatinSchemeID = nil;
        self.activeLockSchemeID = nil;
        self.activeSchemeID = nil;
    } else if ([scheme[@"schemeType"] isEqualToString:@"custom"]) {
        if ([scheme[@"customChinesePath"] length]) self.activeChineseSchemeID = schemeID;
        if ([scheme[@"customLatinPath"] length]) self.activeLatinSchemeID = schemeID;
    } else if ([scheme[@"primaryPath"] length]) {
        self.activeGlobalSchemeID = schemeID;
        self.activeChineseSchemeID = nil;
        self.activeLatinSchemeID = nil;
        self.activeLockSchemeID = [scheme[@"optionalPath"] length] ? schemeID : nil;
    } else if ([scheme[@"optionalPath"] length]) {
        self.activeLockSchemeID = schemeID;
    }
    self.activeSchemeID = [schemeID copy];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary<NSString *, NSString *> *state = @{
        @"FontChangeActiveGlobalSchemeID": self.activeGlobalSchemeID ?: @"",
        @"FontChangeActiveChineseSchemeID": self.activeChineseSchemeID ?: @"",
        @"FontChangeActiveLatinSchemeID": self.activeLatinSchemeID ?: @"",
        @"FontChangeActiveLockSchemeID": self.activeLockSchemeID ?: @""
    };
    for (NSString *key in state) {
        NSString *value = state[key];
        if (value.length) [defaults setObject:value forKey:key];
        else [defaults removeObjectForKey:key];
    }
    if (self.activeSchemeID.length) [defaults setObject:self.activeSchemeID forKey:@"FontChangeActiveSchemeID"];
    else [defaults removeObjectForKey:@"FontChangeActiveSchemeID"];
    [self refreshUsageAppearance];
}

- (void)toggleSelectedPreview {
    if (![self selectedScheme]) return;
    if (self.primaryPath.length && self.optionalPath.length) {
        if (self.previewTransitioning) return;
        self.selectedPreviewSlot = self.selectedPreviewSlot == 2 ? 1 : 2;
        self.previewTransitioning = YES;
        self.previewView.userInteractionEnabled = NO;
        __weak typeof(self) weakSelf = self;
        [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            weakSelf.previewView.transform = CGAffineTransformMakeScale(0.025, 1.0);
        } completion:^(__unused BOOL finished) {
            [weakSelf refreshFontPreviewForSlot:weakSelf.selectedPreviewSlot];
            weakSelf.previewView.transform = CGAffineTransformMakeScale(-0.025, 1.0);
            [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut
                             animations:^{
                weakSelf.previewView.transform = CGAffineTransformIdentity;
            } completion:^(__unused BOOL expanded) {
                weakSelf.previewTransitioning = NO;
                weakSelf.previewView.userInteractionEnabled = YES;
            }];
        }];
    } else {
        self.selectedPreviewSlot = self.primaryPath.length ? 1 : (self.optionalPath.length ? 2 : 0);
        if (self.selectedPreviewSlot) [self refreshFontPreviewForSlot:self.selectedPreviewSlot];
    }
    [self updateSelectedSummary];
    self.statusLabel.text = self.selectedPreviewSlot == 2
        ? @"已切换到锁屏字体预览。" : @"已切换到全局字体预览。";
}

- (void)prepareSchemePreview:(NSDictionary *)scheme forCard:(FCFontSchemeCard *)card {
    BOOL customMode = [scheme[@"schemeType"] isEqualToString:@"custom"];
    BOOL hasChinese = [scheme[@"customChinesePath"] length] > 0;
    NSString *source = customMode
        ? (hasChinese ? scheme[@"customChinesePath"] : scheme[@"customLatinPath"])
        : ([scheme[@"primaryPath"] length] ? scheme[@"primaryPath"] : scheme[@"optionalPath"]);
    if (!source.length) return;
    NSString *kind = customMode
        ? (hasChinese ? @"custom-chinese" : @"custom-latin")
        : ([scheme[@"primaryPath"] length] ? @"primary-card" : @"optional");
    NSString *sampleText = customMode
        ? (hasChinese ? @"汉" : @"Aa")
        : ([scheme[@"primaryPath"] length] ? @"Aa" : @"123");
    [card.sampleView setPreviewText:sampleText];
    NSString *schemeID = [scheme[@"id"] copy];
    __weak FCFontSchemeCard *weakCard = card;
    [self requestPreviewForSchemeID:schemeID kind:kind source:source completion:^(NSString *path) {
        if (path.length && [weakCard.schemeID isEqualToString:schemeID]) [weakCard loadFontAtPath:path];
    }];
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
        self.schemePageControl.numberOfPages = 0;
        return;
    }
    [self.fontSchemes enumerateObjectsUsingBlock:^(NSMutableDictionary *scheme, NSUInteger index, BOOL *stop) {
        (void)stop;
        FCFontSchemeCard *card = [[FCFontSchemeCard alloc] init];
        card.schemeIndex = (NSInteger)index;
        card.schemeID = scheme[@"id"];
        card.nameLabel.text = scheme[@"name"] ?: @"未命名字体";
        BOOL customMode = [scheme[@"schemeType"] isEqualToString:@"custom"];
        BOOL hasGlobal = customMode ? ([scheme[@"customChinesePath"] length] > 0 || [scheme[@"primaryPath"] length] > 0) : [scheme[@"primaryPath"] length] > 0;
        BOOL hasLock = customMode ? ([scheme[@"customLatinPath"] length] > 0 || [scheme[@"optionalPath"] length] > 0) : [scheme[@"optionalPath"] length] > 0;
        BOOL selected = [scheme[@"id"] isEqualToString:self.selectedSchemeID];
        if (customMode) {
            BOOL hasChinese = [scheme[@"customChinesePath"] length] > 0;
            BOOL hasLatin = [scheme[@"customLatinPath"] length] > 0;
            card.detailLabel.text = hasChinese && hasLatin ? @"自定义中文 + 英数字"
                : (hasChinese ? @"自定义中文" : (hasLatin ? @"自定义英数字" : @"自定义字体"));
        } else {
            card.detailLabel.text = hasGlobal && hasLock ? @"全局 + 自定义时钟"
                : (hasGlobal ? @"全局字体" : @"自定义时钟");
        }
        card.detailLabel.adjustsFontSizeToFitWidth = YES;
        card.detailLabel.minimumScaleFactor = 0.78;
        card.tag = (NSInteger)index;
        card.deleteButton.tag = (NSInteger)index;
        card.unlinkButton.tag = (NSInteger)index;
        [card addTarget:self action:@selector(selectSchemeCard:) forControlEvents:UIControlEventTouchUpInside];
        [card.deleteButton addTarget:self action:@selector(deleteSchemeCard:) forControlEvents:UIControlEventTouchUpInside];
        [card.unlinkButton addTarget:self action:@selector(unlinkClockFromScheme:) forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *reorder = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleSchemeLongPress:)];
        reorder.minimumPressDuration = 0.42;
        [card addGestureRecognizer:reorder];
        [card setSelectedAppearance:selected];
        BOOL active = [scheme[@"id"] isEqualToString:self.activeGlobalSchemeID] ||
            [scheme[@"id"] isEqualToString:self.activeChineseSchemeID] ||
            [scheme[@"id"] isEqualToString:self.activeLatinSchemeID] ||
            [scheme[@"id"] isEqualToString:self.activeLockSchemeID];
        [card setUsageAppearance:active];
        [card setEditingAppearance:self.schemeEditing canUnlink:(hasGlobal && hasLock)];
        [card.widthAnchor constraintEqualToConstant:150].active = YES;
        [self.schemeStackView addArrangedSubview:card];
        [self prepareSchemePreview:scheme forCard:card];
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.view layoutIfNeeded];
        NSInteger selectedIndex = NSNotFound;
        for (NSInteger index = 0; index < (NSInteger)self.fontSchemes.count; index++) {
            if ([self.fontSchemes[(NSUInteger)index][@"id"] isEqualToString:self.selectedSchemeID]) {
                selectedIndex = index;
                break;
            }
        }
        if (selectedIndex != NSNotFound) [self scrollToSchemeIndex:selectedIndex animated:NO];
        else [self updateSchemePageControl];
    });
}

- (void)selectSchemeCard:(FCFontSchemeCard *)card {
    if (self.schemeEditing) return;
    if (card.schemeIndex < 0 || card.schemeIndex >= (NSInteger)self.fontSchemes.count) return;
    NSString *schemeID = self.fontSchemes[(NSUInteger)card.schemeIndex][@"id"];
    self.selectedSchemeID = schemeID;
    [self applySelectedScheme];
    [self saveFontSchemes];
    for (FCFontSchemeCard *schemeCard in self.schemeStackView.arrangedSubviews) {
        if (![schemeCard isKindOfClass:FCFontSchemeCard.class]) continue;
        BOOL selected = [schemeCard.schemeID isEqualToString:self.selectedSchemeID];
        [schemeCard setSelectedAppearance:selected];
        [schemeCard setUsageAppearance:[schemeCard.schemeID isEqualToString:self.activeGlobalSchemeID] ||
            [schemeCard.schemeID isEqualToString:self.activeChineseSchemeID] ||
            [schemeCard.schemeID isEqualToString:self.activeLatinSchemeID] ||
            [schemeCard.schemeID isEqualToString:self.activeLockSchemeID]];
    }
    [self scrollToSchemeIndex:card.schemeIndex animated:YES];
    self.statusLabel.text = [NSString stringWithFormat:@"已切换到“%@”；可直接预览或执行。",
        [self selectedScheme][@"name"] ?: @"字体方案"];
}

- (void)enterSchemeEditing {
    if (self.schemeEditing) return;
    self.schemeEditing = YES;
    self.schemeEditButton.hidden = NO;
    for (FCFontSchemeCard *card in self.schemeStackView.arrangedSubviews) {
        if (![card isKindOfClass:FCFontSchemeCard.class]) continue;
        NSDictionary *scheme = card.schemeIndex >= 0 && card.schemeIndex < (NSInteger)self.fontSchemes.count
            ? self.fontSchemes[(NSUInteger)card.schemeIndex] : nil;
        [card setEditingAppearance:YES
                        canUnlink:([scheme[@"primaryPath"] length] && [scheme[@"optionalPath"] length])];
    }
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    self.statusLabel.text = @"整理模式：长按拖动排序，组合方案可解除自定义时钟。";
}

- (void)finishSchemeEditing {
    if (!self.schemeEditing) return;
    self.schemeEditing = NO;
    self.schemeEditButton.hidden = YES;
    self.schemeScrollView.scrollEnabled = YES;
    self.draggedSchemeCard.transform = CGAffineTransformIdentity;
    self.draggedSchemeCard = nil;
    for (FCFontSchemeCard *card in self.schemeStackView.arrangedSubviews) {
        if (![card isKindOfClass:FCFontSchemeCard.class]) continue;
        [card.layer removeAnimationForKey:@"fontchange.reorder"];
        card.layer.shouldRasterize = NO;
        [card setEditingAppearance:NO canUnlink:NO];
        [card setUsageAppearance:[card.schemeID isEqualToString:self.activeGlobalSchemeID] ||
            [card.schemeID isEqualToString:self.activeChineseSchemeID] ||
            [card.schemeID isEqualToString:self.activeLatinSchemeID] ||
            [card.schemeID isEqualToString:self.activeLockSchemeID]];
    }
    [self saveFontSchemes];
    [self updateSchemePageControl];
    self.statusLabel.text = @"字体方案顺序已保存。";
}

- (void)handleSchemeOutsideTap:(UITapGestureRecognizer *)gesture {
    if (!self.schemeEditing || self.draggedSchemeCard) return;
    CGPoint point = [gesture locationInView:self.view];
    if (CGRectContainsPoint([self.schemeScrollView convertRect:self.schemeScrollView.bounds toView:self.view], point)) return;
    if (CGRectContainsPoint([self.schemeEditButton convertRect:self.schemeEditButton.bounds toView:self.view], point)) return;
    [self finishSchemeEditing];
}

- (void)refreshSchemeCardIndexes {
    [self.schemeStackView.arrangedSubviews enumerateObjectsUsingBlock:^(UIView *view, NSUInteger index, BOOL *stop) {
        (void)stop;
        if (![view isKindOfClass:FCFontSchemeCard.class]) return;
        FCFontSchemeCard *card = (FCFontSchemeCard *)view;
        card.schemeIndex = (NSInteger)index;
        card.tag = (NSInteger)index;
        card.deleteButton.tag = (NSInteger)index;
        card.unlinkButton.tag = (NSInteger)index;
    }];
}

- (void)handleSchemeLongPress:(UILongPressGestureRecognizer *)gesture {
    FCFontSchemeCard *card = (FCFontSchemeCard *)gesture.view;
    if (![card isKindOfClass:FCFontSchemeCard.class]) return;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self enterSchemeEditing];
        self.draggedSchemeCard = card;
        self.schemeScrollView.scrollEnabled = NO;
        // Jiggle and reordering both animate the layer transform. Pause the
        // jiggle for every card for the duration of the drag so it cannot
        // override the follow/spring transforms or trigger repeated restarts.
        for (FCFontSchemeCard *schemeCard in self.schemeStackView.arrangedSubviews) {
            if (![schemeCard isKindOfClass:FCFontSchemeCard.class]) continue;
            [schemeCard stopJiggle];
        }
        card.alpha = 1.0;
        card.layer.zPosition = 100;
        // Cache only the lifted card. Caching every arranged subview causes
        // their textures to be invalidated at the exact slot-swap frame.
        card.layer.shouldRasterize = YES;
        card.layer.rasterizationScale = UIScreen.mainScreen.scale;
        [UIView animateWithDuration:0.16 animations:^{
            card.transform = CGAffineTransformMakeScale(1.045, 1.045);
            card.layer.shadowOpacity = 0;
        }];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged && self.draggedSchemeCard == card) {
        CGPoint scrollPoint = [gesture locationInView:self.schemeScrollView];
        CGFloat maxOffset = MAX(0, self.schemeScrollView.contentSize.width - CGRectGetWidth(self.schemeScrollView.bounds));
        CGFloat offset = self.schemeScrollView.contentOffset.x;
        if (scrollPoint.x < offset + 36) offset = MAX(0, offset - 8);
        else if (scrollPoint.x > offset + CGRectGetWidth(self.schemeScrollView.bounds) - 36) offset = MIN(maxOffset, offset + 8);
        self.schemeScrollView.contentOffset = CGPointMake(offset, 0);

        CGPoint stackPoint = [gesture locationInView:self.schemeStackView];
        CGFloat followDelta = stackPoint.x - card.center.x;
        CGAffineTransform followTransform = CGAffineTransformMakeTranslation(followDelta, 0);
        card.transform = CGAffineTransformScale(followTransform, 1.045, 1.045);
        NSUInteger currentIndex = [self.schemeStackView.arrangedSubviews indexOfObject:card];
        NSUInteger targetIndex = currentIndex;
        NSArray<UIView *> *cards = self.schemeStackView.arrangedSubviews;
        for (NSUInteger index = 0; index < cards.count; index++) {
            if (stackPoint.x < cards[index].center.x) {
                targetIndex = index;
                break;
            }
            targetIndex = index;
        }
        if (currentIndex != NSNotFound && targetIndex != currentIndex) {
            NSMutableDictionary<NSValue *, NSNumber *> *oldVisualCenters = [NSMutableDictionary dictionary];
            for (FCFontSchemeCard *otherCard in cards) {
                if (![otherCard isKindOfClass:FCFontSchemeCard.class] || otherCard == card) continue;
                CALayer *visibleLayer = otherCard.layer.presentationLayer ?: otherCard.layer;
                oldVisualCenters[[NSValue valueWithNonretainedObject:otherCard]] = @(CGRectGetMidX(visibleLayer.frame));
            }
            NSMutableDictionary *scheme = self.fontSchemes[currentIndex];
            [self.fontSchemes removeObjectAtIndex:currentIndex];
            [self.fontSchemes insertObject:scheme atIndex:targetIndex];
            [self.schemeStackView removeArrangedSubview:card];
            [self.schemeStackView insertArrangedSubview:card atIndex:targetIndex];
            [self refreshSchemeCardIndexes];
            [self.schemeStackView layoutIfNeeded];
            followDelta = stackPoint.x - card.center.x;
            followTransform = CGAffineTransformMakeTranslation(followDelta, 0);
            card.transform = CGAffineTransformScale(followTransform, 1.045, 1.045);
            for (FCFontSchemeCard *otherCard in self.schemeStackView.arrangedSubviews) {
                if (![otherCard isKindOfClass:FCFontSchemeCard.class] || otherCard == card) continue;
                CGFloat oldVisualX = [oldVisualCenters[[NSValue valueWithNonretainedObject:otherCard]] doubleValue];
                CGFloat delta = oldVisualX - otherCard.layer.position.x;
                if (fabs(delta) > 0.5) {
                    CASpringAnimation *shift = [CASpringAnimation animationWithKeyPath:@"transform.translation.x"];
                    shift.fromValue = @(delta);
                    shift.toValue = @0;
                    shift.mass = 1.0;
                    shift.stiffness = 310.0;
                    shift.damping = 30.0;
                    shift.initialVelocity = 0.0;
                    shift.duration = shift.settlingDuration;
                    [otherCard.layer addAnimation:shift forKey:@"fontchange.reorder"];
                }
            }
            UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
            [feedback selectionChanged];
        }
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        self.schemeScrollView.scrollEnabled = YES;
        // Let the lifted card settle into its final slot with a restrained
        // spring. BeginFromCurrentState keeps the release continuous even
        // when the finger lets go during an in-flight reorder animation.
        [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.90
            initialSpringVelocity:0.18 options:UIViewAnimationOptionCurveEaseOut |
            UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
            card.transform = CGAffineTransformIdentity;
            card.layer.shadowOpacity = 0;
        } completion:^(__unused BOOL finished) {
            card.layer.zPosition = 0;
            card.alpha = 1.0;
            card.layer.shouldRasterize = NO;
            self.draggedSchemeCard = nil;
            // Adjacent cards can still be finishing their reorder springs.
            // Wait briefly before replacing translation with the jiggle
            // animation so both transforms never compete in the same frame.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.14 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                if (!self.schemeEditing || self.draggedSchemeCard) return;
                for (FCFontSchemeCard *schemeCard in self.schemeStackView.arrangedSubviews) {
                    if (![schemeCard isKindOfClass:FCFontSchemeCard.class]) continue;
                    [schemeCard.layer removeAnimationForKey:@"fontchange.reorder"];
                    [schemeCard startJiggle];
                }
            });
        }];
        [self saveFontSchemes];
        [self updateSchemePageControl];
    }
}

- (void)performUnlinkClockAtIndex:(NSInteger)index deleteFile:(BOOL)deleteFile {
    if (index < 0 || index >= (NSInteger)self.fontSchemes.count) return;
    NSMutableDictionary *scheme = self.fontSchemes[(NSUInteger)index];
    NSString *optionalPath = scheme[@"optionalPath"];
    NSString *schemeID = scheme[@"id"];
    [self invalidatePreviewCacheForSchemeID:schemeID];
    [scheme removeObjectForKey:@"optionalPath"];
    [scheme removeObjectForKey:@"optionalDisplayName"];
    if (deleteFile && optionalPath.length) [NSFileManager.defaultManager removeItemAtPath:optionalPath error:nil];
    if ([schemeID isEqualToString:self.activeLockSchemeID]) {
        self.activeLockSchemeID = nil;
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"FontChangeActiveLockSchemeID"];
        [self refreshUsageAppearance];
    }
    if ([schemeID isEqualToString:self.selectedSchemeID]) [self applySelectedScheme];
    [self saveFontSchemes];
    [self rebuildSchemeCards];
    self.statusLabel.text = @"已从方案移除自定义锁屏时钟；设备当前字体不会立即改变。";
}

- (void)unlinkClockFromScheme:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.fontSchemes.count) return;
    NSDictionary *scheme = self.fontSchemes[(NSUInteger)index];
    NSString *optionalPath = scheme[@"optionalPath"];
    if (![scheme[@"primaryPath"] length] || !optionalPath.length) return;
    BOOL referencedElsewhere = NO;
    for (NSUInteger otherIndex = 0; otherIndex < self.fontSchemes.count; otherIndex++) {
        if ((NSInteger)otherIndex == index) continue;
        if ([self.fontSchemes[otherIndex][@"optionalPath"] isEqualToString:optionalPath]) {
            referencedElsewhere = YES;
            break;
        }
    }
    BOOL active = [scheme[@"id"] isEqualToString:self.activeLockSchemeID];
    NSString *message = active
        ? @"解除此方案与自定义锁屏时钟的绑定，不会立即改变设备当前锁屏字体；“使用中”标记将清除，再次执行方案后生效。"
        : @"解除此方案与自定义锁屏时钟的绑定，不会立即改变设备当前字体。";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"解除时钟绑定"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    NSString *unlinkTitle = referencedElsewhere
        ? @"解除绑定（文件仍被其他方案使用）"
        : @"解除绑定并删除字体文件";
    UIAlertActionStyle unlinkStyle = referencedElsewhere
        ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive;
    [alert addAction:[UIAlertAction actionWithTitle:unlinkTitle style:unlinkStyle handler:^(__unused UIAlertAction *action) {
        [weakSelf performUnlinkClockAtIndex:index deleteFile:!referencedElsewhere];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)scrollToSchemeIndex:(NSInteger)index animated:(BOOL)animated {
    NSArray<UIView *> *cards = self.schemeStackView.arrangedSubviews;
    CGFloat width = CGRectGetWidth(self.schemeScrollView.bounds);
    if (index < 0 || index >= (NSInteger)cards.count || width <= 1.0) return;
    UIView *card = cards[(NSUInteger)index];
    CGPoint center = [card.superview convertPoint:card.center toView:self.schemeScrollView];
    CGFloat maxOffset = MAX(0, self.schemeScrollView.contentSize.width - width);
    CGFloat target = MAX(0, MIN(maxOffset, center.x - width * 0.5));
    [self.schemeScrollView setContentOffset:CGPointMake(target, 0) animated:animated];
    [self updateSchemePageControlForOffset:target];
}

- (NSInteger)schemePageCount {
    CGFloat width = CGRectGetWidth(self.schemeScrollView.bounds);
    CGFloat contentWidth = self.schemeScrollView.contentSize.width;
    if (self.schemeStackView.arrangedSubviews.count == 0 || width <= 1.0 || contentWidth <= 1.0) return 0;
    return MAX(1, (NSInteger)ceil(contentWidth / width));
}

- (void)updateSchemePageControlForOffset:(CGFloat)offset {
    NSInteger pageCount = [self schemePageCount];
    self.schemePageControl.numberOfPages = pageCount;
    if (pageCount <= 1) {
        self.schemePageControl.currentPage = 0;
        return;
    }
    CGFloat width = CGRectGetWidth(self.schemeScrollView.bounds);
    CGFloat maxOffset = MAX(0, self.schemeScrollView.contentSize.width - width);
    CGFloat progress = maxOffset > 0 ? MAX(0, MIN(1, offset / maxOffset)) : 0;
    self.schemePageControl.currentPage = (NSInteger)lround(progress * (pageCount - 1));
}

- (void)updateSchemePageControl {
    [self updateSchemePageControlForOffset:self.schemeScrollView.contentOffset.x];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == self.schemeScrollView) [self updateSchemePageControl];
}

- (void)schemePageChanged:(UIPageControl *)sender {
    NSInteger pageCount = [self schemePageCount];
    if (pageCount <= 1) return;
    NSInteger page = MAX(0, MIN(sender.currentPage, pageCount - 1));
    CGFloat width = CGRectGetWidth(self.schemeScrollView.bounds);
    CGFloat maxOffset = MAX(0, self.schemeScrollView.contentSize.width - width);
    CGFloat target = maxOffset * page / (CGFloat)(pageCount - 1);
    [self.schemeScrollView setContentOffset:CGPointMake(target, 0) animated:YES];
}

- (void)appendLogEntry:(NSString *)text {
    if (!text.length) return;
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    NSString *entry = [NSString stringWithFormat:@"[%@]\n%@", [formatter stringFromDate:NSDate.date], text];
    [self.logEntries addObject:entry];
    if (self.logEntries.count > 200) {
        [self.logEntries removeObjectsInRange:NSMakeRange(0, self.logEntries.count - 200)];
    }
    if (self.logTextView) {
        self.logTextView.text = [self formattedLogText];
        [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length, 0)];
    }
}

- (NSString *)formattedLogText {
    return self.logEntries.count ? [self.logEntries componentsJoinedByString:@"\n\n"] : @"暂无运行日志";
}

- (void)copyLog {
    if (!self.logEntries.count) return;
    UIPasteboard.generalPasteboard.string = [self formattedLogText];
}

- (void)clearLog {
    [self.logEntries removeAllObjects];
    self.logTextView.text = [self formattedLogText];
}

- (void)dismissLog {
    if (!self.logOverlay) return;
    UIView *overlay = self.logOverlay;
    UIView *sheet = self.logSheet;
    self.logOverlay = nil;
    self.logSheet = nil;
    self.logTextView = nil;
    [UIView animateWithDuration:0.25 animations:^{
        overlay.backgroundColor = UIColor.clearColor;
        sheet.transform = CGAffineTransformMakeTranslation(0, CGRectGetHeight(sheet.bounds) + 24);
    } completion:^(__unused BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

- (void)showLog {
    if (self.logOverlay || !self.view.window) return;
    UIWindow *window = self.view.window;
    UIControl *overlay = [[UIControl alloc] init];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = UIColor.clearColor;
    [overlay addTarget:self action:@selector(dismissLog) forControlEvents:UIControlEventTouchUpInside];
    [window addSubview:overlay];

    UIView *sheet = [[UIView alloc] init];
    sheet.translatesAutoresizingMaskIntoConstraints = NO;
    sheet.backgroundColor = UIColor.secondarySystemBackgroundColor;
    sheet.layer.cornerRadius = 26;
    sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    sheet.layer.shadowColor = UIColor.blackColor.CGColor;
    sheet.layer.shadowOpacity = 0.18;
    sheet.layer.shadowRadius = 20;
    sheet.layer.shadowOffset = CGSizeMake(0, -5);
    [overlay addSubview:sheet];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"运行日志";
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;

    UIButton *clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    clearButton.translatesAutoresizingMaskIntoConstraints = NO;
    [clearButton setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal];
    [clearButton setTitle:@" 清理" forState:UIControlStateNormal];
    clearButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    clearButton.tintColor = UIColor.systemRedColor;
    clearButton.accessibilityLabel = @"清理日志";
    [clearButton addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];

    UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    copyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [copyButton setImage:[UIImage systemImageNamed:@"doc.on.doc"] forState:UIControlStateNormal];
    [copyButton setTitle:@" 复制" forState:UIControlStateNormal];
    copyButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    copyButton.tintColor = UIColor.systemOrangeColor;
    copyButton.accessibilityLabel = @"复制日志";
    [copyButton addTarget:self action:@selector(copyLog) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[clearButton, copyButton]];
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.spacing = 14;

    UITextView *textView = [[UITextView alloc] init];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.editable = NO;
    textView.selectable = YES;
    textView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    textView.textColor = UIColor.labelColor;
    textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    textView.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    textView.layer.cornerRadius = 14;
    textView.text = [self formattedLogText];

    [sheet addSubview:title];
    [sheet addSubview:actions];
    [sheet addSubview:textView];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:window.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:window.trailingAnchor],
        [overlay.topAnchor constraintEqualToAnchor:window.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:window.bottomAnchor],
        [sheet.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor],
        [sheet.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor],
        [sheet.bottomAnchor constraintEqualToAnchor:overlay.bottomAnchor],
        [sheet.heightAnchor constraintEqualToAnchor:overlay.heightAnchor multiplier:0.26],
        [title.leadingAnchor constraintEqualToAnchor:sheet.leadingAnchor constant:20],
        [title.topAnchor constraintEqualToAnchor:sheet.topAnchor constant:16],
        [actions.trailingAnchor constraintEqualToAnchor:sheet.trailingAnchor constant:-20],
        [actions.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [actions.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:12],
        [textView.leadingAnchor constraintEqualToAnchor:sheet.leadingAnchor constant:16],
        [textView.trailingAnchor constraintEqualToAnchor:sheet.trailingAnchor constant:-16],
        [textView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [textView.bottomAnchor constraintEqualToAnchor:sheet.safeAreaLayoutGuide.bottomAnchor constant:-10],
    ]];
    self.logOverlay = overlay;
    self.logSheet = sheet;
    self.logTextView = textView;
    [window layoutIfNeeded];
    sheet.transform = CGAffineTransformMakeTranslation(0, CGRectGetHeight(sheet.bounds) + 24);
    [UIView animateWithDuration:0.32 delay:0
         usingSpringWithDamping:0.88 initialSpringVelocity:0.35 options:UIViewAnimationOptionCurveEaseOut
                      animations:^{
        overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.24];
        sheet.transform = CGAffineTransformIdentity;
    } completion:nil];
    [textView scrollRangeToVisible:NSMakeRange(textView.text.length, 0)];
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
        NSString *customChinese = scheme[@"customChinesePath"];
        NSString *customLatin = scheme[@"customLatinPath"];
        [weakSelf invalidatePreviewCacheForSchemeID:scheme[@"id"]];
        if (primary.length) [NSFileManager.defaultManager removeItemAtPath:primary error:nil];
        if (optional.length && ![optional isEqualToString:primary]) [NSFileManager.defaultManager removeItemAtPath:optional error:nil];
        if (customChinese.length && ![customChinese isEqualToString:primary] && ![customChinese isEqualToString:optional]) {
            [NSFileManager.defaultManager removeItemAtPath:customChinese error:nil];
        }
        if (customLatin.length && ![customLatin isEqualToString:primary] &&
            ![customLatin isEqualToString:optional] && ![customLatin isEqualToString:customChinese]) {
            [NSFileManager.defaultManager removeItemAtPath:customLatin error:nil];
        }
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
            ? @"导入全局字体会新建方案；锁屏字体可加入当前方案，也可单独建立方案。\n\n⚠️ 请先将字体文件保存到“我的 iPhone”，不要直接从 iCloud 云盘导入。也支持从其他 App 通过系统分享菜单导入。"
            : @"导入全局字体或建立一个仅锁屏字体方案。\n\n⚠️ 请先将字体文件保存到“我的 iPhone”，不要直接从 iCloud 云盘导入。也支持从其他 App 通过系统分享菜单导入。"
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
    [menu addAction:[UIAlertAction actionWithTitle:@"高级自定义：中文字体" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self presentPickerForSlot:4];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"高级自定义：英数字体" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self presentPickerForSlot:5];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = self.importButton;
    menu.popoverPresentationController.sourceRect = self.importButton.bounds;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)refreshFontPreviewForSlot:(NSInteger)slot {
    self.previewGeneration++;
    NSUInteger generation = self.previewGeneration;
    NSDictionary *scheme = [self selectedScheme];
    BOOL customMode = [scheme[@"schemeType"] isEqualToString:@"custom"];
    BOOL customChinesePreview = customMode && slot == 1 && [scheme[@"customChinesePath"] length] > 0;
    BOOL customLatinPreview = customMode && [scheme[@"customLatinPath"] length] > 0 &&
        (slot >= 2 || ![scheme[@"customChinesePath"] length]);
    [self.previewView setLockScreenPreview:slot >= 2 && !customMode];
    [self.previewView setPreviewKind:customChinesePreview ? @"custom-chinese" :
        (customLatinPreview ? @"custom-latin" : (slot >= 2 ? @"lock" : @"global"))];
    NSString *source = slot >= 2 ? self.optionalPath : self.primaryPath;
    if (!source.length) {
        [self.previewView clearFont];
        return;
    }
    NSString *displayName = slot >= 2 ? self.optionalDisplayName : self.primaryDisplayName;
    [self.previewView setDisplayName:displayName ?: source.lastPathComponent.stringByDeletingPathExtension];
    NSString *kind = slot >= 2 ? @"optional" : @"primary";
    NSString *schemeID = [self.selectedSchemeID copy];
    __weak typeof(self) weakSelf = self;
    [self requestPreviewForSchemeID:schemeID kind:kind source:source completion:^(NSString *path) {
        if (generation != weakSelf.previewGeneration) return;
        if (!path.length || ![weakSelf.previewView loadFontAtPath:path]) {
            weakSelf.statusLabel.text = @"字体已导入，但未能生成字体预览；不影响正常替换。";
        }
    }];
}

- (void)detectMountMode {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = [self runHelperArguments:@[@"--detect-mount"] wait:YES];
        NSString *mode = status == 10 ? @"mnt" :
            (status == 11 ? @"mount-bindfs" :
            (status == 14 ? @"fontchange" : (status == 15 ? @"repair-needed" : @"uninitialized")));
        dispatch_async(dispatch_get_main_queue(), ^{
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
        UTType *ttcType = [UTType typeWithFilenameExtension:@"ttc"];
        if (ttcType) types = @[UTTypeZIP, ttcType];
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
    BOOL allowsTTC = self.pickingSlot >= 2 && self.pickingSlot <= 5;
    if (!FCIsSupportedImportExtension(extension, allowsTTC)) {
        self.statusLabel.text = self.pickingSlot == 1
            ? @"主要字体包必须是 .zip 文件。"
            : @"请选择字体 ZIP 或单个 .ttc 文件。";
        return;
    }
    NSMutableDictionary *targetScheme = nil;
    if (self.pickingSlot == 2) {
        targetScheme = [self selectedScheme];
    } else if (self.pickingSlot == 4 || self.pickingSlot == 5) {
        NSString *newID = NSUUID.UUID.UUIDString;
        targetScheme = [@{
            @"id": newID,
            @"name": self.pickingSlot == 4 ? @"自定义中文字体" : @"自定义英数字体",
            @"schemeType": @"custom",
        } mutableCopy];
        [self.fontSchemes addObject:targetScheme];
        self.selectedSchemeID = newID;
    }
    NSString *schemeID = targetScheme[@"id"];
    if (!schemeID.length) schemeID = NSUUID.UUID.UUIDString;
    NSString *role = self.pickingSlot == 1 ? @"global" : (self.pickingSlot == 4 ? @"custom-zh" : (self.pickingSlot == 5 ? @"custom-latin" : @"sfui"));
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
        NSString *bridgeDestination = [self.previewFilesDirectory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"import-%@.%@", NSUUID.UUID.UUIDString,
                extension.length ? extension : @"zip"]];
        [NSFileManager.defaultManager removeItemAtPath:bridgeDestination error:nil];
        importStatus = [self runHelperArguments:@[@"--import", source.path, bridgeDestination] wait:YES];
        if (importStatus == 0 && [self isUsablePersistentFile:bridgeDestination]) {
            [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
            copied = [NSFileManager.defaultManager copyItemAtPath:bridgeDestination
                                                            toPath:destination error:&copyError];
        }
        [NSFileManager.defaultManager removeItemAtPath:bridgeDestination error:nil];
    }
    if (scoped) [source stopAccessingSecurityScopedResource];
    if (!copied) {
        NSString *detail = copyError.localizedDescription ?: @"文件提供器拒绝读取";
        self.statusLabel.text = [NSString stringWithFormat:
            @"导入失败：%@（安全作用域=%@，helper=%d）。", detail, scoped ? @"已获得" : @"未获得", importStatus];
        return;
    }
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0644}
                                    ofItemAtPath:destination error:nil];
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
    } else if (self.pickingSlot == 4 || self.pickingSlot == 5) {
        if (!targetScheme) {
            targetScheme = [@{
                @"id": schemeID,
                @"name": self.pickingSlot == 4 ? @"自定义中文字体" : @"自定义英数字体",
                @"schemeType": @"custom",
            } mutableCopy];
            [self.fontSchemes addObject:targetScheme];
        }
        [self invalidatePreviewCacheForSchemeID:targetScheme[@"id"]];
        if (self.pickingSlot == 4) {
            NSString *oldChinese = targetScheme[@"customChinesePath"];
            if (oldChinese.length && ![oldChinese isEqualToString:destination]) {
                [NSFileManager.defaultManager removeItemAtPath:oldChinese error:nil];
            }
            targetScheme[@"customChinesePath"] = destination;
            targetScheme[@"customChineseDisplayName"] = source.lastPathComponent.stringByDeletingPathExtension ?: @"自定义中文字体";
            if (![targetScheme[@"customLatinPath"] length]) {
                targetScheme[@"name"] = targetScheme[@"customChineseDisplayName"];
            } else {
                targetScheme[@"name"] = @"自定义中文 + 自定义英数字";
            }
        } else {
            NSString *oldLatin = targetScheme[@"customLatinPath"];
            if (oldLatin.length && ![oldLatin isEqualToString:destination]) {
                [NSFileManager.defaultManager removeItemAtPath:oldLatin error:nil];
            }
            targetScheme[@"customLatinPath"] = destination;
            targetScheme[@"customLatinDisplayName"] = source.lastPathComponent.stringByDeletingPathExtension ?: @"自定义英数字体";
            if (![targetScheme[@"customChinesePath"] length]) {
                targetScheme[@"name"] = targetScheme[@"customLatinDisplayName"];
            } else {
                targetScheme[@"name"] = @"自定义中文 + 自定义英数字";
            }
        }
        self.selectedSchemeID = targetScheme[@"id"];
        self.statusLabel.text = [NSString stringWithFormat:@"高级自定义字体导入完成：%@。尚未执行替换。", source.lastPathComponent];
    } else {
        if (!targetScheme) {
            targetScheme = [@{
                @"id": schemeID,
                @"name": source.lastPathComponent.stringByDeletingPathExtension ?: @"锁屏字体",
            } mutableCopy];
            [self.fontSchemes addObject:targetScheme];
        }
        [self invalidatePreviewCacheForSchemeID:targetScheme[@"id"]];
        NSString *oldOptional = targetScheme[@"optionalPath"];
        if (oldOptional.length && ![oldOptional isEqualToString:destination]) {
            [NSFileManager.defaultManager removeItemAtPath:oldOptional error:nil];
        }
        targetScheme[@"optionalPath"] = destination;
        targetScheme[@"optionalDisplayName"] = source.lastPathComponent.stringByDeletingPathExtension ?: @"锁屏字体";
        if (![targetScheme[@"primaryPath"] length]) targetScheme[@"name"] = targetScheme[@"optionalDisplayName"];
        self.selectedSchemeID = targetScheme[@"id"];
        self.statusLabel.text = [NSString stringWithFormat:@"锁屏时钟字体文件导入完成：%@。尚未执行替换。", source.lastPathComponent];
    }
    [self applySelectedScheme];
    [self saveFontSchemes];
    [self rebuildSchemeCards];
}

- (void)confirmRun {
    if (self.primaryPath.length == 0 && self.optionalPath.length == 0) {
        self.statusLabel.text = @"请至少选择主要字体包，或选择锁屏时钟字体包 / TTC 文件。";
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
        [self updateActiveStateForScheme:nil schemeID:nil restoring:YES];
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
        : @"运行日志\n• 正在验证锁屏时钟字体文件\n• 准备替换锁屏字体…";
    BOOL sfuiOnly = self.primaryPath.length == 0;
    NSString *primary = self.primaryPath ?: @"-";
    NSString *optional = self.optionalPath ?: @"-";
    BOOL customScheme = [[self selectedScheme][@"schemeType"] isEqualToString:@"custom"];
    NSString *appliedSchemeID = [self.selectedSchemeID copy];
    NSDictionary *appliedScheme = [[self selectedScheme] copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = 0;
        NSMutableArray<NSString *> *stagedPaths = [NSMutableArray array];
        NSString *helperPrimary = primary;
        NSString *helperOptional = optional;
        if (!restoringSystemFonts) {
            NSString *bridge = self.previewFilesDirectory;
            [NSFileManager.defaultManager createDirectoryAtPath:bridge
                                    withIntermediateDirectories:YES attributes:nil error:nil];
            if (![primary isEqualToString:@"-"]) {
                helperPrimary = [bridge stringByAppendingPathComponent:[NSString stringWithFormat:
                    @"install-%@.%@", NSUUID.UUID.UUIDString,
                    primary.pathExtension.length ? primary.pathExtension : @"zip"]];
                if ([NSFileManager.defaultManager copyItemAtPath:primary toPath:helperPrimary error:nil]) {
                    [stagedPaths addObject:helperPrimary];
                } else {
                    status = 65;
                }
            }
            if (status == 0 && ![optional isEqualToString:@"-"]) {
                helperOptional = [bridge stringByAppendingPathComponent:[NSString stringWithFormat:
                    @"install-%@.%@", NSUUID.UUID.UUIDString,
                    optional.pathExtension.length ? optional.pathExtension : @"ttc"]];
                if ([NSFileManager.defaultManager copyItemAtPath:optional toPath:helperOptional error:nil]) {
                    [stagedPaths addObject:helperOptional];
                } else {
                    status = 65;
                }
            }
        }
        if (status == 0) {
            NSArray<NSString *> *helperArguments = restoringSystemFonts
                ? @[@"--restore-system-fonts"]
                : customScheme
                    ? @[@"--install", helperPrimary, helperOptional, @"custom"]
                    : @[@"--install", helperPrimary, helperOptional];
            status = [self runHelperArguments:helperArguments wait:YES];
        } else {
            [@"失败：无法将持久化字体包复制到 RootHide 临时处理目录。"
                writeToFile:@"/var/mobile/Documents/fontchange_last_result.txt"
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        for (NSString *stagedPath in stagedPaths) {
            [NSFileManager.defaultManager removeItemAtPath:stagedPath error:nil];
        }
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
            [self updateActiveStateForScheme:appliedScheme
                                     schemeID:appliedSchemeID
                                    restoring:restoringSystemFonts];
            self.statusLabel.text = restoringSystemFonts
                ? @"运行日志\n✓ 系统原生字体已恢复\n• 正在刷新语言缓存"
                : sfuiOnly
                ? @"运行日志\n✓ 锁屏时钟字体替换完成\n• 正在刷新语言缓存"
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
