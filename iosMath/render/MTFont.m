//
//  MTFont.m
//  iosMath
//
//  Created by Kostub Deshmukh on 5/18/16.
//
//  This software may be modified and distributed under the terms of the
//  MIT license. See the LICENSE file for details.
//

#import "MTFont.h"
#import "MTFont+Internal.h"
#import <os/lock.h>

@interface MTFont ()

@property (nonatomic, assign) CGFontRef defaultCGFont;
@property (nonatomic, assign) CTFontRef ctFont;
@property (nonatomic, strong) MTFontMathTable* mathTable;
@property (nonatomic, strong) NSDictionary* rawMathTable;
/// The loaded font every copy descends from, which owns the caches below.
/// Weak: the root holds its copies, so a strong reference back would be a
/// cycle; a copy whose root has been released falls back to the uncached
/// behaviour it always had.
@property (nonatomic, weak) MTFont* rootFont;

@end

@implementation MTFont {
    // Owned by the loaded font and shared by every copy, since the CGFont
    // and the plist behind them are the same objects at every size. Lock
    // guarded: renders may run in parallel off the main thread.
    os_unfair_lock _cacheLock;
    /// Copies by size. The typesetter copies its font for every style
    /// change — a new CTFont and math table per fraction, script, radicand,
    /// and inner list, a dozen per formula — and sizes repeat forever.
    NSMutableDictionary<NSNumber*, MTFont*>* _sizedCopies;
    /// Glyph → name and name → glyph. The math table is keyed by glyph name,
    /// so italic corrections, accents, variants, and assemblies each cost a
    /// CoreGraphics name copy per lookup; a font's names never change.
    NSMutableDictionary<NSNumber*, NSString*>* _glyphNames;
    NSMutableDictionary<NSString*, NSNumber*>* _glyphsByName;
}

- (instancetype)initFontWithName:(NSString *)name size:(CGFloat)size
{
    self = [super init];
    if (self != nil) {
        _cacheLock = OS_UNFAIR_LOCK_INIT;
        _sizedCopies = [NSMutableDictionary dictionary];
        _glyphNames = [NSMutableDictionary dictionary];
        _glyphsByName = [NSMutableDictionary dictionary];
        // CTFontCreateWithName does not load the complete math font, it only has about half the glyphs of the full math font.
        // In particular it does not have the math italic characters which breaks our variable rendering.
        // So we first load a CGFont from the file and then convert it to a CTFont.

        NSBundle* bundle = [MTFont fontBundle];
        NSString* fontPath = [bundle pathForResource:name ofType:@"otf" inDirectory:@"fonts"];
        if (!fontPath) { return nil; }
        CGDataProviderRef fontDataProvider = CGDataProviderCreateWithFilename(fontPath.UTF8String);
        if (!fontDataProvider) { return nil; }
        _defaultCGFont = CGFontCreateWithDataProvider(fontDataProvider);
        CFRelease(fontDataProvider);
        if (!_defaultCGFont) { return nil; }

        _ctFont = CTFontCreateWithGraphicsFont(self.defaultCGFont, size, nil, nil);

        NSString* mathTablePlist = [bundle pathForResource:name ofType:@"plist" inDirectory:@"fonts"];
        NSDictionary* dict = mathTablePlist ? [NSDictionary dictionaryWithContentsOfFile:mathTablePlist] : nil;
        if (!dict) { return nil; }
        self.rawMathTable = dict;
        self.mathTable = [[MTFontMathTable alloc] initWithFont:self mathTable:_rawMathTable];
    }
    return self;
}

- (void)setDefaultCGFont:(CGFontRef)defaultCGFont
{
    if (_defaultCGFont != nil) {
        CFRelease(_defaultCGFont);
    }
    if (defaultCGFont != nil) {
        CFRetain(defaultCGFont);
    }
    _defaultCGFont = defaultCGFont;
}

- (void)setCtFont:(CTFontRef)ctFont {
    if (_ctFont != nil) {
        CFRelease(_ctFont);
    }
    if (ctFont != nil) {
        CFRetain(ctFont);
    }
    _ctFont = ctFont;
}

+ (NSBundle*) fontBundle
{
    // SwiftPM exposes processed resources via the generated module bundle.
#if SWIFT_PACKAGE
    return SWIFTPM_MODULE_BUNDLE;
#else
    // For Xcode builds: fonts are added directly to the app/test bundle.
    return [NSBundle bundleForClass:[self class]];
#endif
}

/// The font whose caches serve this one: the root, or this font when it is
/// the loaded one — or when its root is gone, in which case the caches are
/// nil and every path below computes uncached.
- (MTFont *)cacheOwner
{
    return self.rootFont ?: self;
}

- (MTFont *)copyFontWithSize:(CGFloat)size
{
    MTFont* owner = [self cacheOwner];
    if (owner->_sizedCopies == nil) {
        return [self makeCopyWithSize:size root:nil];
    }
    NSNumber* key = @(size);
    os_unfair_lock_lock(&owner->_cacheLock);
    MTFont* copy = owner->_sizedCopies[key];
    if (copy == nil) {
        copy = [owner makeCopyWithSize:size root:owner];
        owner->_sizedCopies[key] = copy;
    }
    os_unfair_lock_unlock(&owner->_cacheLock);
    return copy;
}

- (MTFont *)makeCopyWithSize:(CGFloat)size root:(MTFont *)root
{
    MTFont* copyFont = [[[self class] alloc] init];
    copyFont.defaultCGFont = self.defaultCGFont;
    CTFontRef newCtFont = CTFontCreateWithGraphicsFont(self.defaultCGFont, size, nil, nil);
    copyFont.ctFont = newCtFont;
    copyFont.rawMathTable = self.rawMathTable;
    copyFont.rootFont = root;
    copyFont.mathTable = [[MTFontMathTable alloc] initWithFont:copyFont mathTable:copyFont.rawMathTable];
    CFRelease(newCtFont);
    return copyFont;
}

-(NSString*) getGlyphName:(CGGlyph) glyph
{
    MTFont* owner = [self cacheOwner];
    if (owner->_glyphNames == nil) {
        return CFBridgingRelease(CGFontCopyGlyphNameForGlyph(self.defaultCGFont, glyph));
    }
    NSNumber* key = @(glyph);
    os_unfair_lock_lock(&owner->_cacheLock);
    NSString* cached = owner->_glyphNames[key];
    os_unfair_lock_unlock(&owner->_cacheLock);
    if (cached != nil) {
        // The empty string stands in for a glyph the font does not name.
        return cached.length > 0 ? cached : nil;
    }
    // Computed outside the lock: a race costs one duplicate copy, never a
    // wrong answer, and the CoreGraphics call is the slow part.
    NSString* name = CFBridgingRelease(CGFontCopyGlyphNameForGlyph(self.defaultCGFont, glyph));
    os_unfair_lock_lock(&owner->_cacheLock);
    owner->_glyphNames[key] = name ?: @"";
    os_unfair_lock_unlock(&owner->_cacheLock);
    return name;
}

- (CGGlyph)getGlyphWithName:(NSString *)glyphName
{
    MTFont* owner = [self cacheOwner];
    if (owner->_glyphsByName == nil || glyphName == nil) {
        return CGFontGetGlyphWithGlyphName(self.defaultCGFont, (__bridge CFStringRef) glyphName);
    }
    os_unfair_lock_lock(&owner->_cacheLock);
    NSNumber* cached = owner->_glyphsByName[glyphName];
    os_unfair_lock_unlock(&owner->_cacheLock);
    if (cached != nil) {
        return cached.unsignedShortValue;
    }
    CGGlyph glyph = CGFontGetGlyphWithGlyphName(self.defaultCGFont, (__bridge CFStringRef) glyphName);
    os_unfair_lock_lock(&owner->_cacheLock);
    owner->_glyphsByName[[glyphName copy]] = @(glyph);
    os_unfair_lock_unlock(&owner->_cacheLock);
    return glyph;
}

- (CGFloat)fontSize
{
    return CTFontGetSize(self.ctFont);
}

- (void)dealloc
{
    self.defaultCGFont=nil;
    self.ctFont=nil;
}
@end
