// Hook-safety test for the Dock plugin.
//
// Loads build/spaces-renamer.dylib into this process (which stands in for Dock: it defines an
// `ECTextLayer` class before the dylib's +load swizzles it), builds synthetic layer trees shaped
// like the macOS 26/27 SpacesBar, drives `-[CALayer setFrame:]` through the hook and checks the
// observable results: renamed text layers, untouched text layers, no crash on partial trees,
// and the plugin status marker.
//
// Run through `make test`; it must be launched with SPACES_RENAMER_DOMAIN naming a throwaway
// preference domain, because the plugin otherwise reads the real com.apple.dock domain and
// writes its status marker into the host's domain.

@import Foundation;
@import QuartzCore;
@import CoreText;
#import <dlfcn.h>
#import <unistd.h>
@import ColorSync;
@import CoreGraphics;

// Stand-in for Dock's private CATextLayer subclass. Only the class name matters to the hook.
@interface ECTextLayer : CATextLayer
@end
@implementation ECTextLayer
@end

static int failures = 0;

#define CHECK(cond, ...) do { \
  if (cond) { printf("  ok    " __VA_ARGS__); printf("\n"); } \
  else { failures++; printf("  FAIL  " __VA_ARGS__); printf(" (%s:%d)\n", __FILE__, __LINE__); } \
} while (0)

static CFStringRef domain(void) {
  return (CFStringRef)[NSString stringWithUTF8String:getenv("SPACES_RENAMER_DOMAIN")];
}

static id readPref(NSString *key) {
  CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)key, domain());
  return value ? [(id)value autorelease] : nil;
}

static void writeFixtures(NSDictionary *names, NSArray *monitors) {
  CFPreferencesSetAppValue(CFSTR("SpacesRenamerNames"), (CFPropertyListRef)names, domain());
  CFPreferencesSetAppValue(CFSTR("SpacesRenamerMonitors"), (CFPropertyListRef)monitors, domain());
  CFPreferencesAppSynchronize(domain());
}

static void removeDomain(void) {
  CFPreferencesSetAppValue(CFSTR("SpacesRenamerNames"), NULL, domain());
  CFPreferencesSetAppValue(CFSTR("SpacesRenamerMonitors"), NULL, domain());
  CFPreferencesSetAppValue(CFSTR("SpacesRenamerPlugin"), NULL, domain());
  CFPreferencesAppSynchronize(domain());
  NSString *plist = [NSString stringWithFormat:@"~/Library/Preferences/%@.plist", (NSString *)domain()];
  [[NSFileManager defaultManager] removeItemAtPath:plist.stringByExpandingTildeInPath error:nil];
}

static NSDictionary *monitor(NSString *displayUUID, NSArray<NSString *> *uuids, NSString *current) {
  NSMutableArray *spaces = [NSMutableArray array];
  for (NSString *uuid in uuids) {
    [spaces addObject:@{@"uuid": uuid, @"type": @0}];
  }
  return @{@"Display Identifier": displayUUID,
           @"Current Space": @{@"uuid": current, @"type": @0},
           @"Spaces": spaces};
}

// One space in the bar: a container layer holding (optionally) a highlight layer and, last, the
// ECTextLayer with the default "Desktop N" title. Dock highlights the current space by giving
// its container a second sublayer, which is how the hook detects the selection.
static CALayer *spaceLayer(NSString *title, BOOL selected, CGFloat x) {
  CALayer *container = [CALayer layer];
  container.frame = CGRectMake(x, 0, 120, 40);
  if (selected) {
    CALayer *highlight = [CALayer layer];
    highlight.frame = container.bounds;
    [container addSublayer:highlight];
  }
  ECTextLayer *text = [ECTextLayer layer];
  text.string = title;
  text.fontSize = 13;
  CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 13, NULL);
  text.font = font;
  CFRelease(font);
  text.frame = CGRectMake(10, 10, 100, 20);
  [container addSublayer:text];
  return container;
}

// Root layer shaped like Dock's SpacesListLayoutController: sublayers[0] is the compressed
// (unexpanded) list, sublayers[1] the expanded list.
static CALayer *spacesBar(NSUInteger count, NSInteger selected) {
  CALayer *root = [CALayer layer];
  root.name = @"SpacesListLayoutController";
  root.frame = CGRectMake(0, 0, 1000, 120);
  CALayer *unexpanded = [CALayer layer];
  CALayer *expanded = [CALayer layer];
  for (NSUInteger i = 0; i < count; i++) {
    NSString *title = [NSString stringWithFormat:@"Desktop %lu", (unsigned long)(i + 1)];
    [unexpanded addSublayer:spaceLayer(title, (NSInteger)i == selected, 130.0 * i)];
    [expanded addSublayer:spaceLayer(title, (NSInteger)i == selected, 130.0 * i)];
  }
  [root addSublayer:unexpanded];
  [root addSublayer:expanded];
  return root;
}

// ---- WindowManager (macOS 27+) shape ------------------------------------------------------
//
// WindowManager binds each root layer to a CAContext whose displayId names the display. The
// stand-in root layer answers -context with an object exposing the same key.

@interface FakeContext : NSObject
@property (nonatomic) unsigned int displayId;
@end
@implementation FakeContext
@end

@interface FakeRootLayer : CALayer
@property (nonatomic, strong) FakeContext *fakeContext;
@end
@implementation FakeRootLayer
- (id)context { return self.fakeContext; }
@end

static NSString *uuidForDisplay(CGDirectDisplayID display) {
  CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
  NSString *string = CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, uuid));
  CFRelease(uuid);
  return string;
}

// One space: container > holder > (selection pill?) + "PreviewLabel" text layer, laid out the
// way WindowManager does it for its own "Desktop N" title.
static CALayer *wmSpace(NSString *title, BOOL selected, CGFloat x) {
  CALayer *container = [CALayer layer];
  container.name = @"SpacesBarPreviewContainerLayer";
  container.frame = CGRectMake(x, -97, 190, 129);
  CALayer *holder = [CALayer layer];
  holder.frame = CGRectMake(63, 105, 65, 24);
  if (selected) {
    CALayer *pill = [CALayer layer];
    pill.name = @"SpacesBarPreviewLabelSelection";
    pill.frame = CGRectMake(-10, 0, 85, 24);
    [holder addSublayer:pill];
  }
  CATextLayer *label = [CATextLayer layer];
  label.name = @"PreviewLabel";
  label.string = title;
  label.fontSize = 14;
  label.alignmentMode = kCAAlignmentCenter;
  label.truncationMode = kCATruncationEnd;
  CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 14, NULL);
  label.font = font;
  CFRelease(font);
  label.frame = CGRectMake(0, 4, 65, 17);
  [holder addSublayer:label];
  [container addSublayer:holder];
  return container;
}

// Root (with display context) > "SpacesBar" > containers in reverse order plus the chrome
// layers WindowManager adds, so ordering must come from geometry, not sublayer index.
static CALayer *wmBar(CGDirectDisplayID display, NSUInteger count, NSInteger selected) {
  FakeRootLayer *root = [FakeRootLayer layer];
  root.fakeContext = [FakeContext new];
  root.fakeContext.displayId = display;
  CALayer *bar = [CALayer layer];
  bar.name = @"SpacesBar";
  bar.frame = CGRectMake(0, 0, 2560, 40);
  CALayer *material = [CALayer layer];
  material.name = @"Material";
  [bar addSublayer:material];
  for (NSInteger i = (NSInteger)count - 1; i >= 0; i--) {
    NSString *title = count == 1 ? @"Desktop" : [NSString stringWithFormat:@"Desktop %ld", (long)(i + 1)];
    [bar addSublayer:wmSpace(title, i == selected, 960.5 + 88 * i)];
  }
  CALayer *add = [CALayer layer];
  add.name = @"SpacesBarAddSpaceButton";
  [bar addSublayer:add];
  [root addSublayer:bar];
  return bar;
}

static NSArray<CALayer *> *wmContainers(CALayer *bar) {
  NSMutableArray *containers = [NSMutableArray array];
  for (CALayer *layer in bar.sublayers) {
    if ([layer.name isEqualToString:@"SpacesBarPreviewContainerLayer"]) [containers addObject:layer];
  }
  return [containers sortedArrayUsingComparator:^NSComparisonResult(CALayer *a, CALayer *b) {
    return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
  }];
}

static CATextLayer *wmLabel(CALayer *bar, NSUInteger index) {
  return (CATextLayer *)wmContainers(bar)[index].sublayers.firstObject.sublayers.lastObject;
}

static NSString *titleAt(CALayer *root, NSUInteger list, NSUInteger index) {
  CALayer *container = root.sublayers[list].sublayers[index];
  return (NSString *)((CATextLayer *)container.sublayers.lastObject).string;
}

static void drive(CALayer *root) {
  // Dock lays the bar out repeatedly; run the hook twice so the "only change offsets once"
  // path is exercised as well.
  [root setFrame:root.frame];
  [root setFrame:root.frame];
}

int main(int argc, const char *argv[]) {
  if (argc < 2) {
    fprintf(stderr, "usage: hook_test <path-to-spaces-renamer.dylib>\n");
    return 2;
  }
  const char *testDomain = getenv("SPACES_RENAMER_DOMAIN");
  if (!testDomain || strncmp(testDomain, "com.alexbeals.spacesrenamer.test", 32) != 0) {
    fprintf(stderr, "refusing to run against real preferences; set SPACES_RENAMER_DOMAIN to com.alexbeals.spacesrenamer.test.<something>\n");
    return 2;
  }
  removeDomain();

  @autoreleasepool {
    printf("loading %s\n", argv[1]);
    void *handle = dlopen(argv[1], RTLD_NOW);
    CHECK(handle != NULL, "dylib loads (%s)", handle ? "ok" : dlerror());
    if (!handle) return 1;

    NSDictionary *status = readPref(@"SpacesRenamerPlugin");
    CHECK(status != nil, "status marker written on load");
    CHECK([status[@"HostPID"] intValue] == getpid(), "status marker records the host pid");
    CHECK([status[@"Version"] length] > 0 && [status[@"Build"] length] > 0, "status marker records version %s / build %s",
          [status[@"Version"] UTF8String], [status[@"Build"] UTF8String]);
    CHECK([status[@"HostBundleID"] isKindOfClass:[NSString class]], "status marker records the host bundle id");
    CHECK(status[@"FirstHookAt"] == nil, "status marker has no FirstHookAt before the hook fires");

    printf("case: nothing published by the app\n");
    writeFixtures(nil, nil);
    CALayer *bar = spacesBar(3, 1);
    drive(bar);
    CHECK([titleAt(bar, 0, 0) isEqualToString:@"Desktop 1"], "titles untouched without fixtures");
    status = readPref(@"SpacesRenamerPlugin");
    CHECK(status[@"FirstHookAt"] != nil, "status marker gains FirstHookAt once the hook fires");
    CHECK([status[@"HostPID"] intValue] == getpid(), "status marker keeps the load-time fields after the hook fires");

    printf("case: single monitor, mixed names\n");
    writeFixtures(@{@"A": @"Code", @"B": @"", @"C": @"Mail"},
                  @[monitor(@"DISP-1", @[@"A", @"B", @"C"], @"B")]);
    bar = spacesBar(3, 1);
    drive(bar);
    CHECK([titleAt(bar, 1, 0) isEqualToString:@"Code"], "expanded[0] renamed to Code");
    CHECK([titleAt(bar, 1, 1) isEqualToString:@"Desktop 2"], "expanded[1] keeps default title for empty name");
    CHECK([titleAt(bar, 1, 2) isEqualToString:@"Mail"], "expanded[2] renamed to Mail");
    CHECK([titleAt(bar, 0, 0) isEqualToString:@"Code"], "unexpanded[0] renamed to Code");
    CHECK([titleAt(bar, 0, 2) isEqualToString:@"Mail"], "unexpanded[2] renamed to Mail");
    CALayer *renamed = bar.sublayers[1].sublayers[0].sublayers.lastObject;
    CHECK(renamed.frame.size.width > 0, "renamed text layer keeps a positive width (%.1f)", renamed.frame.size.width);

    printf("case: renamed title survives Dock resetting the string\n");
    CATextLayer *text = (CATextLayer *)bar.sublayers[1].sublayers[0].sublayers.lastObject;
    text.string = @"Desktop 1";
    CHECK([(NSString *)text.string isEqualToString:@"Code"], "KVO restores the custom name after Dock overwrites it");

    printf("case: two monitors, same space count, different selection\n");
    writeFixtures(@{@"A": @"Left-1", @"B": @"Left-2", @"C": @"Right-1", @"D": @"Right-2"},
                  @[monitor(@"DISP-L", @[@"A", @"B"], @"A"), monitor(@"DISP-R", @[@"C", @"D"], @"D")]);
    CALayer *left = spacesBar(2, 0);
    CALayer *right = spacesBar(2, 1);
    drive(left);
    drive(right);
    CHECK([titleAt(left, 1, 0) isEqualToString:@"Left-1"], "bar with first space selected gets the left monitor's names");
    CHECK([titleAt(right, 1, 1) isEqualToString:@"Right-2"], "bar with second space selected gets the right monitor's names");

    printf("case: partial trees never crash\n");
    CALayer *empty = [CALayer layer];
    empty.name = @"SpacesListLayoutController";
    [empty setFrame:CGRectMake(0, 0, 100, 10)];
    CHECK(YES, "root with no sublayers");
    CALayer *oneChild = [CALayer layer];
    oneChild.name = @"SpacesListLayoutController";
    [oneChild addSublayer:[CALayer layer]];
    [oneChild setFrame:CGRectMake(0, 0, 100, 10)];
    CHECK(YES, "root with a single container");
    CALayer *noTitles = [CALayer layer];
    noTitles.name = @"SpacesListLayoutController";
    [noTitles addSublayer:[CALayer layer]];
    [noTitles addSublayer:[CALayer layer]];
    [noTitles.sublayers[0] addSublayer:[CALayer layer]];
    [noTitles.sublayers[1] addSublayer:[CALayer layer]];
    drive(noTitles);
    CHECK(YES, "containers whose spaces have no ECTextLayer yet");
    CALayer *unselected = spacesBar(2, -1);
    drive(unselected);
    CHECK(YES, "bar without a highlighted space");
    CALayer *moreSpacesThanNames = spacesBar(5, 0);
    drive(moreSpacesThanNames);
    CHECK(YES, "bar with more spaces than the plist knows about");

    printf("case: WindowManager bar, one display\n");
    CGDirectDisplayID displays[8];
    uint32_t displayCount = 0;
    CGGetActiveDisplayList(8, displays, &displayCount);
    CHECK(displayCount >= 1, "at least one active display (%u)", displayCount);
    NSString *display0 = uuidForDisplay(displays[0]);
    writeFixtures(@{@"A": @"Engineering Notebook", @"B": @"", @"C": @"Chat"},
                  @[monitor(display0, @[@"A", @"B", @"C"], @"A")]);
    CALayer *wm = wmBar(displays[0], 3, 0);
    [wm setBounds:wm.bounds];
    CHECK([(NSString *)wmLabel(wm, 0).string isEqualToString:@"Engineering Notebook"], "first label renamed by bar position, not sublayer index");
    CHECK([(NSString *)wmLabel(wm, 1).string isEqualToString:@"Desktop 2"], "empty name keeps WindowManager's title");
    CHECK([(NSString *)wmLabel(wm, 2).string isEqualToString:@"Chat"], "last label renamed");
    CATextLayer *wide = wmLabel(wm, 0);
    CALayer *holder = wide.superlayer;
    CGFloat expected = ceil([wide preferredFrameSize].width);
    CHECK(wide.bounds.size.width == expected && holder.bounds.size.width == expected, "label and holder grow to the name (%.0f)", expected);
    CHECK(fabs(CGRectGetMidX(holder.frame) - 95) < 1, "holder stays centered in the container (mid %.1f)", CGRectGetMidX(holder.frame));
    CALayer *pill = holder.sublayers.firstObject;
    CHECK(pill.bounds.size.width == expected + 20 && pill.frame.origin.x == -10, "selection pill wraps the label with its padding");
    CATextLayer *narrow = wmLabel(wm, 2);
    CHECK(narrow.bounds.size.width == ceil([narrow preferredFrameSize].width), "short name shrinks its label (%.0f)", narrow.bounds.size.width);
    wmLabel(wm, 0).string = @"Desktop 1";
    CHECK([(NSString *)wmLabel(wm, 0).string isEqualToString:@"Engineering Notebook"], "WindowManager re-applying its title is overridden");
    [wm layoutSublayers];
    CHECK([(NSString *)wmLabel(wm, 0).string isEqualToString:@"Engineering Notebook"], "layoutSublayers pass keeps the name");

    printf("case: WindowManager bar, display mismatch\n");
    writeFixtures(@{@"A": @"Left", @"B": @"Right"},
                  @[monitor(@"00000000-0000-0000-0000-000000000001", @[@"A"], @"A"), monitor(display0, @[@"B"], @"B")]);
    CALayer *wmKnown = wmBar(displays[0], 1, 0);
    [wmKnown setBounds:wmKnown.bounds];
    CHECK([(NSString *)wmLabel(wmKnown, 0).string isEqualToString:@"Right"], "bar on a known display takes that display's names");
    CALayer *wmUnknown = wmBar(0, 1, 0);
    [wmUnknown setBounds:wmUnknown.bounds];
    CHECK([(NSString *)wmLabel(wmUnknown, 0).string isEqualToString:@"Desktop"], "bar with no display context stays untouched when several displays are published");
    writeFixtures(@{@"A": @"Only"}, @[monitor(@"00000000-0000-0000-0000-000000000001", @[@"A"], @"A")]);
    CALayer *wmSingle = wmBar(0, 1, 0);
    [wmSingle setBounds:wmSingle.bounds];
    CHECK([(NSString *)wmLabel(wmSingle, 0).string isEqualToString:@"Only"], "bar with no display context falls back to the only published display");
    CALayer *wmCountMismatch = wmBar(displays[0], 2, 0);
    writeFixtures(@{@"A": @"One"}, @[monitor(display0, @[@"A"], @"A")]);
    [wmCountMismatch setBounds:wmCountMismatch.bounds];
    CHECK([(NSString *)wmLabel(wmCountMismatch, 0).string isEqualToString:@"One"], "labels map by desktop number: Desktop 1 renamed");
    CHECK([(NSString *)wmLabel(wmCountMismatch, 1).string isEqualToString:@"Desktop 2"], "a desktop number the layout does not know stays untouched");

    printf("case: WindowManager expanded bar (each container is its own window)\n");
    writeFixtures(@{@"A": @"Solo", @"F": @"Full", @"B": @"Second"},
                  @[monitor(display0, @[@"A", @"F", @"B"], @"A")]);
    // Full-screen app space between two desktops: its label is the app name and has no number.
    NSDictionary *layoutWithApp = @{@"Display Identifier": display0,
                                     @"Current Space": @{@"uuid": @"A", @"type": @0},
                                     @"Spaces": @[@{@"uuid": @"A", @"type": @0}, @{@"uuid": @"F", @"type": @4}, @{@"uuid": @"B", @"type": @0}]};
    writeFixtures(@{@"A": @"Solo", @"F": @"Full", @"B": @"Second"}, @[layoutWithApp]);
    NSArray *titles = @[@"Desktop 1", @"Safari", @"Desktop 2"];
    NSMutableArray<CATextLayer *> *rootLabels = [NSMutableArray array];
    for (NSString *title in titles) {
      FakeRootLayer *rootContainer = [FakeRootLayer layer];
      rootContainer.fakeContext = [FakeContext new];
      rootContainer.fakeContext.displayId = displays[0];
      rootContainer.name = @"SpacesBarPreviewContainerLayer";
      rootContainer.frame = CGRectMake(0, 0, 190, 129);
      CALayer *holder = [CALayer layer];
      holder.frame = CGRectMake(63, 105, 65, 24);
      CATextLayer *label = [CATextLayer layer];
      label.name = @"PreviewLabel";
      label.fontSize = 14;
      CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 14, NULL);
      label.font = font;
      CFRelease(font);
      label.frame = CGRectMake(0, 4, 65, 17);
      label.string = title;               // WindowManager titles the label before attaching it
      [holder addSublayer:label];
      [rootContainer addSublayer:holder];
      [rootLabels addObject:label];
    }
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    CHECK([(NSString *)rootLabels[0].string isEqualToString:@"Solo"], "root container: Desktop 1 renamed without any bar layout pass");
    CHECK([(NSString *)rootLabels[1].string isEqualToString:@"Safari"], "root container: full-screen app label untouched");
    CHECK([(NSString *)rootLabels[2].string isEqualToString:@"Second"], "root container: Desktop 2 skips the full-screen space when counting desktops");
    rootLabels[0].string = @"Desktop 1";
    CHECK([(NSString *)rootLabels[0].string isEqualToString:@"Solo"], "root container: WindowManager re-titling is overridden");
    writeFixtures(@{@"A": @"Only"}, @[monitor(display0, @[@"A"], @"A")]);
    FakeRootLayer *single = [FakeRootLayer layer];
    single.fakeContext = [FakeContext new];
    single.fakeContext.displayId = displays[0];
    single.name = @"SpacesBarPreviewContainerLayer";
    CALayer *singleHolder = [CALayer layer];
    CATextLayer *singleLabel = [CATextLayer layer];
    singleLabel.name = @"PreviewLabel";
    singleLabel.string = @"Desktop";
    [singleHolder addSublayer:singleLabel];
    [single addSublayer:singleHolder];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    CHECK([(NSString *)singleLabel.string isEqualToString:@"Only"], "the unnumbered \"Desktop\" title is the display's single desktop");
    // A localized desktop word is learned from a numbered title, so the bare word is recognised too.
    CATextLayer *german = [CATextLayer layer];
    german.name = @"PreviewLabel";
    german.string = @"Schreibtisch 2";
    FakeRootLayer *germanSingle = [FakeRootLayer layer];
    germanSingle.fakeContext = [FakeContext new];
    germanSingle.fakeContext.displayId = displays[0];
    germanSingle.name = @"SpacesBarPreviewContainerLayer";
    CALayer *germanHolder = [CALayer layer];
    CATextLayer *germanLabel = [CATextLayer layer];
    germanLabel.name = @"PreviewLabel";
    germanLabel.string = @"Schreibtisch";
    [germanHolder addSublayer:germanLabel];
    [germanSingle addSublayer:germanHolder];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    CHECK([(NSString *)germanLabel.string isEqualToString:@"Only"], "a localized bare desktop word learned from a numbered title is recognised");
    if (displayCount >= 2) {
      printf("case: WindowManager bars on two displays\n");
      NSString *display1 = uuidForDisplay(displays[1]);
      writeFixtures(@{@"A": @"Left-1", @"B": @"Left-2", @"C": @"Right-1", @"D": @"Right-2"},
                    @[monitor(display0, @[@"A", @"B"], @"A"), monitor(display1, @[@"C", @"D"], @"C")]);
      CALayer *left = wmBar(displays[0], 2, 0);
      CALayer *right = wmBar(displays[1], 2, 0);
      [left setBounds:left.bounds];
      [right setBounds:right.bounds];
      CHECK([(NSString *)wmLabel(left, 1).string isEqualToString:@"Left-2"], "identical bars: first display gets its own names");
      CHECK([(NSString *)wmLabel(right, 1).string isEqualToString:@"Right-2"], "identical bars: second display gets its own names");
    } else {
      printf("skip: only one active display, two-display case not exercised\n");
    }

    printf("case: Dock bars resolved by display, not by shape\n");
    if (displayCount >= 2) {
      NSString *display1 = uuidForDisplay(displays[1]);
      // Same space count and the same highlighted index on both displays: shape alone is ambiguous.
      writeFixtures(@{@"A": @"Left-1", @"B": @"Left-2", @"C": @"Right-1", @"D": @"Right-2"},
                    @[monitor(display0, @[@"A", @"B"], @"A"), monitor(display1, @[@"C", @"D"], @"C")]);
      CALayer *dockRight = spacesBar(2, 0);
      FakeRootLayer *rightRoot = [FakeRootLayer layer];
      rightRoot.fakeContext = [FakeContext new];
      rightRoot.fakeContext.displayId = displays[1];
      [rightRoot addSublayer:dockRight];
      drive(dockRight);
      CHECK([titleAt(dockRight, 1, 1) isEqualToString:@"Right-2"], "ambiguous Dock bar takes its own display's names");
      CALayer *dockLeft = spacesBar(2, 0);
      FakeRootLayer *leftRoot = [FakeRootLayer layer];
      leftRoot.fakeContext = [FakeContext new];
      leftRoot.fakeContext.displayId = displays[0];
      [leftRoot addSublayer:dockLeft];
      drive(dockLeft);
      CHECK([titleAt(dockLeft, 1, 1) isEqualToString:@"Left-2"], "the other ambiguous Dock bar takes the other display's names");
    } else {
      printf("skip: only one active display, Dock two-display case not exercised\n");
    }

    printf("case: unrelated layers pass through\n");
    CALayer *plain = [CALayer layer];
    plain.name = @"SomethingElse";
    [plain setFrame:CGRectMake(1, 2, 3, 4)];
    CHECK(CGRectEqualToRect(plain.frame, CGRectMake(1, 2, 3, 4)), "setFrame on an unrelated layer is untouched");
  }

  removeDomain();
  printf("%s: %d failure(s)\n", failures ? "FAILED" : "PASSED", failures);
  return failures ? 1 : 0;
}
