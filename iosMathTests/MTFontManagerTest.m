//
//  MTFontManagerTest.m
//  iosMath
//
//  Tests for MTFontManager.fontWithName:size: error handling.
//  FUN-2: fontWithName: should return nil (not crash) for unknown font names.
//

#import <XCTest/XCTest.h>
#import <CoreText/CoreText.h>
#import "MTFontManager.h"
#import "MTFont.h"
#import "MTFont+Internal.h"

@interface MTFontManagerTest : XCTestCase
@end

@implementation MTFontManagerTest

// Test 1: Unknown font returns nil, no crash.
// Before the fix this crashes via CFRelease(NULL); after, it returns nil.
- (void)testUnknownFontNameReturnsNil
{
    MTFont *font = [MTFontManager.fontManager fontWithName:@"does-not-exist" size:20];
    XCTAssertNil(font, @"Unknown font name should return nil, not crash");
}

// Test 2: Unknown font does not poison the cache.
// After a nil return for an unknown name, a known font must still load correctly.
- (void)testUnknownFontNameDoesNotPoisonCache
{
    // First: unknown name -> nil
    MTFont *bad = [MTFontManager.fontManager fontWithName:@"no-such-font" size:18];
    XCTAssertNil(bad, @"Unknown font should return nil");

    // Then: known font must still load
    MTFont *good = [MTFontManager.fontManager fontWithName:MTFontNameLatinModern size:18];
    XCTAssertNotNil(good, @"Known font should load after an unknown-name miss");
    XCTAssertEqualWithAccuracy(good.fontSize, 18.0, 0.001,
                               @"Known font should have the requested size");
}

// Test 3: A nil font name returns nil instead of throwing.
// Without the guard, self.nameToFontMap[name] raises NSInvalidArgumentException
// (NSDictionary keys cannot be nil).
- (void)testNilFontNameReturnsNil
{
    NSString *nilName = nil;
    MTFont *font = [MTFontManager.fontManager fontWithName:nilName size:20];
    XCTAssertNil(font, @"Nil font name should return nil, not throw");
}

// Test 4: The declared font constant loads successfully (regression guard).
- (void)testAllDeclaredFontConstantsLoadNonNil
{
    NSArray<NSString *> *fontNames = @[
        MTFontNameLatinModern,
    ];
    for (NSString *name in fontNames) {
        MTFont *font = [MTFontManager.fontManager fontWithName:name size:20];
        XCTAssertNotNil(font, @"Bundled font '%@' should load non-nil", name);
        XCTAssertEqualWithAccuracy(font.fontSize, 20.0, 0.001,
                                   @"Font '%@' should have the requested size", name);
    }
}

// Test 5: Size-variant path still works.
// Load a known font at a non-default size; exercises the copyFontWithSize: branch
// with the nil-guard in place.
- (void)testSizeVariantPathReturnsCorrectSize
{
    CGFloat requestedSize = 36.0;
    MTFont *font = [MTFontManager.fontManager fontWithName:MTFontNameLatinModern
                                                      size:requestedSize];
    XCTAssertNotNil(font, @"Font should load at a non-default size");
    XCTAssertEqualWithAccuracy(font.fontSize, requestedSize, 0.001,
                               @"Returned font should have the requested size");
}

// Test 6: THE CASCADE. A character the math font has no glyph for is drawn
// through the font's own cascade — STIX Two Math, a math face macOS ships,
// then Times New Roman — never through the system's, which drew Cyrillic
// from Helvetica. Proven the way the typesetter draws a text run: a CTLine
// over the font, the run's font read back. The root font and a sized copy
// alike, since each CTFont is created on its own.
- (void)testCascadeDrawsCyrillicFromAMathFace
{
    MTFont *font = [MTFontManager.fontManager fontWithName:MTFontNameLatinModern size:20];
    XCTAssertNotNil(font, @"The bundled font should load");
    NSArray<MTFont *> *fonts = @[ font, [font copyFontWithSize:14] ];
    for (MTFont *candidate in fonts) {
        NSAttributedString *text = [[NSAttributedString alloc]
            initWithString:@"Ш"
                attributes:@{ (__bridge NSString *)kCTFontAttributeName : (__bridge id)candidate.ctFont }];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
        NSArray *runs = (__bridge NSArray *)CTLineGetGlyphRuns(line);
        XCTAssertEqual(runs.count, (NSUInteger)1, @"One character, one run");
        CTRunRef run = (__bridge CTRunRef)runs[0];
        NSDictionary *attributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
        CTFontRef drawn = (__bridge CTFontRef)attributes[(__bridge NSString *)kCTFontAttributeName];
        NSString *drawnName = (__bridge_transfer NSString *)CTFontCopyPostScriptName(drawn);
        // Outside the assertion: a literal's comma splits the macro's arguments.
        NSArray<NSString *> *cascade = @[ @"STIXTwoMath-Regular", @"TimesNewRomanPSMT" ];
        XCTAssertTrue([cascade containsObject:drawnName],
                      @"The Cyrillic capital should come from the cascade, not %@", drawnName);
        CFRelease(line);
    }
}

@end
