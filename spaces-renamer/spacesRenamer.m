//
//  spaces-renamer.m
//  spaces-renamer
//
//  Created by Alex Beals
//  Copyright 2017 Alex Beals.
//

@import Foundation;
@import CoreText;
#import "ZKSwizzle.h"
#import <QuartzCore/QuartzCore.h>
#import <Cocoa/Cocoa.h>
#import <unistd.h>
#import <os/log.h>

// `make DEBUG=1` compiles verbose tracing of the layer tree into the unified log:
//   log stream --predicate 'subsystem == "com.alexbeals.spaces-renamer"'
#ifdef SR_DEBUG
#define SRLog(fmt, ...) os_log(os_log_create("com.alexbeals.spaces-renamer", "hook"), fmt, ##__VA_ARGS__)
#else
#define SRLog(fmt, ...) do {} while (0)
#endif

#ifndef SPACES_RENAMER_VERSION
#define SPACES_RENAMER_VERSION "0.0.0-dev"
#endif
#ifndef SPACES_RENAMER_BUILD
#define SPACES_RENAMER_BUILD "unknown"
#endif

// Visible with `strings` so a dylib on disk can always be identified.
__attribute__((used)) static const char kSpacesRenamerVersionTag[] =
    "spaces-renamer " SPACES_RENAMER_VERSION " (" SPACES_RENAMER_BUILD ")";

static char OVERRIDDEN_STRING;
static char OVERRIDDEN_WIDTH;
static char OFFSET;
static char NEW_X;
static char TYPE;
static char PENDING_APPLY;
static char ORIGINAL_STRING;

// Data channel between the app and the plugin: preference domains, not files.
//
// WindowManager (which draws the Spaces bar from macOS 27) runs under
// /System/Library/Sandbox/Profiles/com.apple.WindowManager.sb: `(deny default)`, no file reads
// under ~/Library, but `user-preference-read` for the `com.apple.dock` domain and
// `user-preference-write` for its own `com.apple.WindowManager` domain. Dock is unsandboxed.
// So:
//   - the app publishes names and the current layout as keys of the `com.apple.dock` domain,
//     which every host can read;
//   - the plugin publishes its status marker in the host's own domain, which the host can
//     write and the app can read.
// The hook test redirects both to a throwaway domain through SPACES_RENAMER_DOMAIN; no host
// process ever sets that variable.
static NSString *const kNamesDomain = @"com.apple.dock";
static NSString *const kNamesKey = @"SpacesRenamerNames";       // { space uuid : name }
static NSString *const kMonitorsKey = @"SpacesRenamerMonitors"; // CGSCopyManagedDisplaySpaces array
static NSString *const kStatusKey = @"SpacesRenamerPlugin";     // status marker dictionary

static NSString *testDomain(void) {
  const char *override = getenv("SPACES_RENAMER_DOMAIN");
  return (override && *override) ? [NSString stringWithUTF8String:override] : nil;
}

static NSString *namesDomain(void) {
  return testDomain() ?: kNamesDomain;
}

static NSString *statusDomain(void) {
  return testDomain() ?: [NSBundle mainBundle].bundleIdentifier;
}

static id readPreference(NSString *key, NSString *domain) {
  CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)domain);
  return value ? [(id)value autorelease] : nil;
}

// Status marker read by the app's diagnostics pane. Written once when the dylib loads into
// the host and once more when the Spaces bar hook first fires, so the app can tell
// "installed but never injected" from "injected but the layer tree changed again".
static void writePluginStatus(BOOL hookFired) {
  @autoreleasepool {
    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    if (hookFired) {
      id previous = readPreference(kStatusKey, statusDomain());
      if ([previous isKindOfClass:[NSDictionary class]]) {
        [status addEntriesFromDictionary:previous];
      }
      status[@"FirstHookAt"] = [NSDate date];
    } else {
      status[@"Version"] = @SPACES_RENAMER_VERSION;
      status[@"Build"] = @SPACES_RENAMER_BUILD;
      status[@"HostPID"] = @(getpid());
      status[@"HostBundleID"] = [NSBundle mainBundle].bundleIdentifier ?: @"";
      status[@"LoadedAt"] = [NSDate date];
    }
    CFPreferencesSetAppValue((CFStringRef)kStatusKey, (CFPropertyListRef)status, (CFStringRef)statusDomain());
    CFPreferencesAppSynchronize((CFStringRef)statusDomain());
  }
}

// The hooks are only installed inside the process that draws the Spaces bar: Dock up to
// macOS 26, WindowManager from macOS 27. Injection mechanisms such as DYLD_INSERT_LIBRARIES
// can land the dylib in unrelated processes, which must stay untouched (and must not overwrite
// the status marker). The hook test opts in through the domain override.
__attribute__((constructor)) static void spacesRenamerDidLoad(void) {
  @autoreleasepool {
    NSString *host = [NSBundle mainBundle].bundleIdentifier;
    BOOL isHost = [host isEqualToString:@"com.apple.dock"] || [host isEqualToString:@"com.apple.WindowManager"];
    if (!isHost && !testDomain()) {
      return;
    }
    BOOL swizzled = ZKSwizzleGroup(SpacesRenamer);
    SRLog("loaded into %{public}@ (pid %d), swizzled=%d", host, getpid(), swizzled);
    (void)swizzled;
    writePluginStatus(NO);
  }
}

@interface Monitor : NSObject
@property (nonatomic, strong) NSString *displayUUID;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *spaces;
@end

@implementation Monitor
@end

// Maximum online or active displays.
//
// SpacesRenamer uses the core graphics API to get online/active
// displays by calling CGGetActiveDisplayList() and CGGetOnlineDisplayList(),
// this definition is the count that will be used when calling those functions.
//
// If you have more than 12 monitors, this tweak can't help you with organization, good luck.
#define kMaxDisplays 12

int monitorIndex = 0;

// Recursively re-applies setFrame on the modified children so that they don't change positions
// on swiping between different spaces. Called on the SpacesListLayoutController root layer at
// the end of the override calculations in setFrame (the root itself is skipped to avoid
// recursion). Also forces redraws, which makes the resizing work. This is a hack.
static void refreshFrames(CALayer *frame, CALayer *exception) {
  for (CALayer *layer in frame.sublayers) {
    if (![layer isEqualTo:exception]) {
      [layer setFrame:layer.frame];
    }
    refreshFrames(layer, exception);
  }
}

// Helper method
static void assign(id a, void *key, id assigned) {
  objc_setAssociatedObject(a, key, assigned, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Gets the ECTextLayer child from a starting view
// Good for when you don't care whether it's selected or not
static CATextLayer *getTextLayer(CALayer *view) {
  CATextLayer *layer = nil;
  if (view.class == NSClassFromString(@"ECTextLayer")) {
    layer = (CATextLayer *)view;
  } else {
    for (int i = 0; i < view.sublayers.count; i++) {
      CATextLayer *tempLayer = getTextLayer(view.sublayers[i]);
      if (tempLayer != nil) {
        layer = tempLayer;
        break;
      }
    }
  }
  return layer;
}

// Given a view, sets the OFFSET variable for the text layer's parent, and siblings
// if 'modify' is TRUE, it will add the OFFSET variables, otherwise it will overwrite it
static void setOffset(CALayer *view, double offset, bool modify) {
  CATextLayer *textLayer = getTextLayer(view);

  if (textLayer != nil) {
    CALayer *parent = textLayer.superlayer;
    if (modify) {
      id possibleOffset = objc_getAssociatedObject(parent, &OFFSET);
      if (possibleOffset && [possibleOffset isKindOfClass:[NSNumber class]]) {
        assign(parent, &OFFSET, [NSNumber numberWithDouble:offset + [possibleOffset doubleValue]]);
      }
    } else {
      assign(parent, &OFFSET, [NSNumber numberWithDouble:offset]);
    }
    for (int i = 0; i < parent.sublayers.count; i++) {
      if (modify) {
        id possibleOffset = objc_getAssociatedObject(parent.sublayers[i], &OFFSET);
        if (possibleOffset && [possibleOffset isKindOfClass:[NSNumber class]]) {
          assign(parent.sublayers[i], &OFFSET, [NSNumber numberWithDouble:offset + [possibleOffset doubleValue]]);
        }
      } else {
        assign(parent.sublayers[i], &OFFSET, [NSNumber numberWithDouble:offset]);
      }
    }
  }
}

// Finds the text layer, and sets the overridden string and width properties
// to the text layer, its parent, and its siblings.
// Additionally sets the type for determining centering behavior
static void overrideTextLayer(CALayer *view, NSString *newString, double width, NSString *type) {
  CATextLayer *textLayer = getTextLayer(view);

  if (textLayer != nil) {
    textLayer.string = newString;
    CALayer *parent = textLayer.superlayer;
    assign(parent, &OVERRIDDEN_STRING, newString);
    assign(parent, &TYPE, type);
    if (width != -1) {
      assign(parent, &OVERRIDDEN_WIDTH, [NSNumber numberWithDouble:width]);
    }
    for (int i = 0; i < parent.sublayers.count; i++) {
      assign(parent.sublayers[i], &OVERRIDDEN_STRING, newString);
      assign(parent, &TYPE, type);
      if (width != -1) {
        assign(parent.sublayers[i], &OVERRIDDEN_WIDTH, [NSNumber numberWithDouble:width]);
      }
    }
  }
}

// Resolves the CTFont the text layer renders with. CATextLayer.font may be a CTFontRef, a
// CGFontRef, a font name, or nil; only a CTFontRef can be handed to CoreText for measuring.
static CTFontRef copyMeasuringFont(CATextLayer *textLayer) {
  CFTypeRef font = textLayer.font;
  CGFloat size = textLayer.fontSize > 0 ? textLayer.fontSize : 12;
  if (font && CFGetTypeID(font) == CTFontGetTypeID()) {
    return (CTFontRef)CFRetain(font);
  }
  if (font && CFGetTypeID(font) == CFStringGetTypeID()) {
    return CTFontCreateWithName((CFStringRef)font, size, NULL);
  }
  if (font && CFGetTypeID(font) == CGFontGetTypeID()) {
    return CTFontCreateWithGraphicsFont((CGFontRef)font, size, NULL, NULL);
  }
  return CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL);
}

// Gets the text area, and renders how large it would be with the new dimensions
// Uses this for calculating how far they should be offset by
static double getTextSizeHelper(CATextLayer *textLayer, NSString *string) {
  CFRange textRange = CFRangeMake(0, string.length);
  CFMutableAttributedStringRef attributedString = CFAttributedStringCreateMutable(kCFAllocatorDefault, string.length);
  CFAttributedStringReplaceString(attributedString, CFRangeMake(0, 0), (CFStringRef) string);
  CTFontRef font = copyMeasuringFont(textLayer);
  CFAttributedStringSetAttribute(attributedString, textRange, kCTFontAttributeName, font);
  CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString(attributedString);
  CFRange fitRange;
  CGSize frameSize = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, textRange, NULL, CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX), &fitRange);
  CFRelease(framesetter);
  CFRelease(attributedString);
  CFRelease(font);
  return frameSize.width;
}

static double getTextSize(CALayer *view, NSString *string) {
  CATextLayer *textLayer = getTextLayer(view);
  if (textLayer != nil) {
    // Works around bug where CTFramesetterSuggestFrameSizeWithConstraints returns 0 for
    // strings entirely composed of whitespace
    return getTextSizeHelper(textLayer, [string stringByAppendingString:@".."]) - getTextSizeHelper(textLayer, @".");
  }
  return -1;
}

// The highlighted space has 2 sublayers, while as a normal space only has 1
static int getSelected(NSArray<CALayer *> *views) {
  NSUInteger selectedIndex = [views indexOfObjectPassingTest:
                              ^(CALayer *layer, NSUInteger idx, BOOL *stop) {
    return (BOOL)(layer.sublayers.count > 1);
  }];

  return selectedIndex == NSNotFound ? -1 : (int)selectedIndex;
}

/*
 1. Load the custom names published by the app
 2. Load the current list of spaces per display published by the app
 3. Crosslist and return the custom names for each display, and whether each space is selected
 */
static NSMutableArray<Monitor *> *loadNamedMonitors() {
  NSDictionary *dict = readPreference(kNamesKey, namesDomain());
  NSArray *listOfMonitors = readPreference(kMonitorsKey, namesDomain());
  if (![dict isKindOfClass:[NSDictionary class]] || ![listOfMonitors isKindOfClass:[NSArray class]]) {
    SRLog("no names/monitors in domain %{public}@ (names=%{public}@ monitors=%{public}@)", namesDomain(), [dict class], [listOfMonitors class]);
    return [NSMutableArray arrayWithCapacity:0];
  }

  NSMutableArray *newNames = [NSMutableArray arrayWithCapacity:listOfMonitors.count];

  for (int i = 0; i < listOfMonitors.count; i++) {
    NSArray *listOfSpaces = [listOfMonitors[i] valueForKeyPath:@"Spaces"];
    NSString *selected = [listOfMonitors[i] valueForKeyPath:@"Current Space.uuid"];
    Monitor *monitor = [[[Monitor alloc] init] autorelease];
    monitor.displayUUID = [listOfMonitors[i] valueForKeyPath:@"Display Identifier"];

    NSMutableArray *spaceNames = [NSMutableArray arrayWithCapacity:listOfSpaces.count];
    for (int j = 0; j < listOfSpaces.count; j++) {
      NSString *uuid = listOfSpaces[j][@"uuid"];
      id name = uuid ? [dict objectForKey:uuid] : nil;
      NSMutableDictionary *screenDict = [NSMutableDictionary dictionary];
      screenDict[@"selected"] = @([uuid isEqualToString:selected]);
      screenDict[@"name"] = [name isKindOfClass:[NSString class]] ? name : @"";
      screenDict[@"type"] = [listOfSpaces[j][@"type"] isKindOfClass:[NSNumber class]] ? listOfSpaces[j][@"type"] : @0;
      spaceNames[j] = screenDict;
    }
    monitor.spaces = spaceNames;
    newNames[i] = monitor;
  }

  return newNames;
}

// =====================================================================================
// macOS 27+: Mission Control's Spaces bar is drawn by WindowManager, not Dock.
//
// Layer tree (per display):
//   CALayer (root, CAContext bound to one display)
//     CALayer "SpacesBar" (delegate WindowManagerAgent.SpacesBarLayerController)
//       WindowManagerAgent.SpacesBarPreviewContainerLayer "SpacesBarPreviewContainerLayer" ×N
//         CALayer
//           WindowManagerAgent.TextLayer "PreviewLabel"   (CATextLayer, string "Desktop N")
//       CALayer "SpacesBarAddSpaceButton", "Material", "Shadow", ...
// The bar receives -setBounds: on every layout pass and -layoutSublayers once per show.
// =====================================================================================

static NSString *const kSpacesBarLayerName = @"SpacesBar";
static NSString *const kSpacesBarContainerLayerName = @"SpacesBarPreviewContainerLayer";
static NSString *const kSpacesBarLabelLayerName = @"PreviewLabel";

// The display a layer is shown on: WindowManager binds each root layer to a CAContext whose
// (private) displayId is the CGDirectDisplayID. Returns nil while the context is not attached.
static NSString *displayUUIDForLayer(CALayer *layer) {
  CALayer *root = layer;
  while (root.superlayer) {
    root = root.superlayer;
  }
  if (![root respondsToSelector:@selector(context)]) {
    return nil;
  }
  id context = [root performSelector:@selector(context)];
  NSNumber *displayID = nil;
  @try {
    displayID = [context valueForKey:@"displayId"];
  } @catch (NSException *ignored) {
    return nil;
  }
  if (![displayID isKindOfClass:[NSNumber class]] || displayID.unsignedIntValue == 0) {
    return nil;
  }
  CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displayID.unsignedIntValue);
  if (!uuid) {
    return nil;
  }
  NSString *string = (NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
  CFRelease(uuid);
  return [string autorelease];
}

// The names entry for a display. CGSCopyManagedDisplaySpaces reports the display either by
// UUID or as "Main" (the main display); accept both spellings.
static Monitor *monitorForDisplayUUID(NSArray<Monitor *> *names, NSString *displayUUID) {
  if (!displayUUID) {
    return nil;
  }
  NSString *mainUUID = nil;
  CFUUIDRef main = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID());
  if (main) {
    mainUUID = [(NSString *)CFUUIDCreateString(kCFAllocatorDefault, main) autorelease];
    CFRelease(main);
  }
  for (Monitor *monitor in names) {
    if ([monitor.displayUUID isEqualToString:displayUUID]) {
      return monitor;
    }
    if ([monitor.displayUUID isEqualToString:@"Main"] && [mainUUID isEqualToString:displayUUID]) {
      return monitor;
    }
  }
  return nil;
}

static NSString *const kSpacesBarLabelSelectionLayerName = @"SpacesBarPreviewLabelSelection";
static const CGFloat kSpacesBarLabelPillPadding = 10;  // selection pill extends this far past the label
static const CGFloat kSpacesBarLabelMargin = 10;       // keep the label inside the container

// WindowManager sizes the label, its holder and the selection pill for its own "Desktop N"
// string and centers the holder in the container; a custom name needs the same geometry
// recomputed for its own width, capped at the container width.
//
//   container (190×129)
//     CALayer holder {x, 105, w, 24}            centered: x = (190 - w) / 2
//       CALayer "SpacesBarPreviewLabelSelection" {-10, 0, w + 20, 24}   (only when selected)
//       TextLayer "PreviewLabel" {0, 4, w, 17}  truncationMode=end, alignment=center
static void fitSpacesBarLabel(CATextLayer *label, CALayer *container) {
  CALayer *holder = label.superlayer;
  if (!holder || holder.superlayer != container) {
    return;
  }
  CGFloat maxWidth = container.bounds.size.width - 2 * kSpacesBarLabelMargin;
  CGFloat width = MIN(ceil([label preferredFrameSize].width), maxWidth);
  if (width <= 0 || fabs(width - label.bounds.size.width) < 0.5) {
    return;
  }
  CGRect holderFrame = holder.frame;
  holderFrame.origin.x = floor((container.bounds.size.width - width) / 2);
  holderFrame.size.width = width;
  holder.frame = holderFrame;
  CGRect labelFrame = label.frame;
  labelFrame.origin.x = 0;
  labelFrame.size.width = width;
  label.frame = labelFrame;
  for (CALayer *sibling in holder.sublayers) {
    if ([sibling.name isEqualToString:kSpacesBarLabelSelectionLayerName]) {
      CGRect pill = sibling.frame;
      pill.origin.x = -kSpacesBarLabelPillPadding;
      pill.size.width = width + 2 * kSpacesBarLabelPillPadding;
      sibling.frame = pill;
    }
  }
}

static CATextLayer *findLabelLayer(CALayer *layer) {
  if ([layer.name isEqualToString:kSpacesBarLabelLayerName] && [layer isKindOfClass:[CATextLayer class]]) {
    return (CATextLayer *)layer;
  }
  for (CALayer *sublayer in layer.sublayers) {
    CATextLayer *found = findLabelLayer(sublayer);
    if (found) {
      return found;
    }
  }
  return nil;
}

// The localized word WindowManager uses for a desktop ("Desktop", "Schreibtisch", ...), learned
// from the first numbered title seen so the unnumbered single-desktop title can be told apart
// from a full-screen app's name. English until something is learned.
static NSString *desktopWord = @"Desktop";

static void learnDesktopWord(NSString *title) {
  NSUInteger end = title.length;
  while (end > 0 && isdigit([title characterAtIndex:end - 1])) {
    end--;
  }
  if (end == title.length || end == 0) {
    return;
  }
  NSString *word = [[title substringToIndex:end] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (word.length && ![word isEqualToString:desktopWord]) {
    [desktopWord release];
    desktopWord = [word copy];
  }
}

// The desktop number WindowManager put in a label ("Desktop 3" -> 3). A display with a single
// desktop is labelled with the bare word (-> 1). Full-screen app spaces carry the app name and
// have no number; they are left alone (0).
static NSInteger desktopNumberFromTitle(NSString *title) {
  if (title.length == 0) {
    return 0;
  }
  NSUInteger end = title.length, start = end;
  while (start > 0 && isdigit([title characterAtIndex:start - 1])) {
    start--;
  }
  if (start < end) {
    return [[title substringFromIndex:start] integerValue];
  }
  return [title isEqualToString:desktopWord] ? 1 : 0;
}

// The space a desktop number refers to: the Nth desktop-type space (type 0) of the display,
// or, if the display does not have that many, the Nth desktop across all displays in order
// (macOS numbers desktops per display when each display has its own Spaces, globally otherwise).
static NSDictionary *spaceForDesktopNumber(NSArray<Monitor *> *names, Monitor *monitor, NSInteger number) {
  if (number <= 0) {
    return nil;
  }
  NSInteger remaining = number;
  for (NSDictionary *space in monitor.spaces) {
    if ([space[@"type"] integerValue] == 0 && --remaining == 0) {
      return space;
    }
  }
  remaining = number;
  for (Monitor *candidate in names) {
    for (NSDictionary *space in candidate.spaces) {
      if ([space[@"type"] integerValue] == 0 && --remaining == 0) {
        return space;
      }
    }
  }
  return nil;
}

// Applies the custom name to one "PreviewLabel". The label sits in a per-space container,
// which is either a child of the collapsed bar (pointer away from the top edge) or the root of
// its own window when Mission Control opens with the bar expanded (pointer at the top edge);
// the display comes from the container's root context either way.
static void applySpacesBarLabel(CATextLayer *label) {
  CALayer *container = label.superlayer.superlayer;
  if (![container.name isEqualToString:kSpacesBarContainerLayerName]) {
    return;
  }
  NSString *original = objc_getAssociatedObject(label, &ORIGINAL_STRING);
  NSInteger number = desktopNumberFromTitle(original);
  if (number == 0) {
    return;
  }
  NSArray<Monitor *> *names = loadNamedMonitors();
  if (names.count == 0) {
    return;
  }
  NSString *displayUUID = displayUUIDForLayer(container);
  Monitor *monitor = monitorForDisplayUUID(names, displayUUID) ?: (names.count == 1 ? names[0] : nil);
  if (!monitor) {
    SRLog("label %{public}@ on unknown display %{public}@", original, displayUUID);
    return;
  }

  static BOOL hookReported = NO;
  if (!hookReported) {
    hookReported = YES;
    writePluginStatus(YES);
  }

  NSString *name = spaceForDesktopNumber(names, monitor, number)[@"name"];
  if (name.length == 0) {
    // Names are read fresh on every pass, so a cleared name must also clear the override;
    // WindowManager keeps re-applying its own title on its own.
    assign(label, &OVERRIDDEN_STRING, nil);
    return;
  }
  assign(label, &OVERRIDDEN_STRING, name);
  if (![label.string isEqual:name]) {
    label.string = name;
  }
  fitSpacesBarLabel(label, container);
  SRLog("display %{public}@ %{public}@ -> %{public}@ (label %{public}@)", monitor.displayUUID, original, label.string, NSStringFromRect(label.frame));
}

// Applies the names to every container currently attached to the collapsed bar.
static void applySpacesBarNames(CALayer *bar) {
  for (CALayer *sublayer in bar.sublayers) {
    if ([sublayer.name isEqualToString:kSpacesBarContainerLayerName]) {
      CATextLayer *label = findLabelLayer(sublayer);
      if (label) {
        applySpacesBarLabel(label);
      }
    }
  }
}

ZKSwizzleInterfaceGroup(_SRCALayer, CALayer, CALayer, SpacesRenamer);
@implementation _SRCALayer
- (void)setFrame:(CGRect)arg1 {
  id possibleWidth = objc_getAssociatedObject(self, &OVERRIDDEN_WIDTH);
  if (possibleWidth && [possibleWidth isKindOfClass:[NSNumber class]] && self.class == NSClassFromString(@"CALayer")) {
    arg1.size.width = [possibleWidth doubleValue] + 20;
  }

  int textIndex = self.sublayers.lastObject.class == NSClassFromString(@"ECTextLayer")
  ? (int)self.sublayers.count - 1
  : -1;

  if (textIndex != -1) {
    id possibleWidth = objc_getAssociatedObject(self.sublayers[textIndex], &OVERRIDDEN_WIDTH);
    if (possibleWidth && [possibleWidth isKindOfClass:[NSNumber class]]) {
      arg1.size.width = [possibleWidth doubleValue];
    }

    id possibleType = objc_getAssociatedObject(self, &TYPE);
    if (possibleType && [possibleType isEqualToString:@"expanded"]) {
      // Always just center in the parent view
      arg1.origin.x = self.superlayer.frame.size.width / 2 - arg1.size.width / 2;
    } else {
      id possibleOffset = objc_getAssociatedObject(self.sublayers[textIndex], &OFFSET);
      id newX = objc_getAssociatedObject(self, &NEW_X);
      // Only change the offsets once
      if (possibleOffset && [possibleOffset isKindOfClass:[NSNumber class]] && (newX == nil || [newX doubleValue] != arg1.origin.x)) {
        arg1.origin.x += [possibleOffset doubleValue];

        assign(self, &NEW_X, @(arg1.origin.x));
      }
    }
  }


  // Name is enough to determine that it's the SpacesBar, and it is also the root layer.
  // Its first sublayer holds the compressed (unexpanded) spaces, the second the expanded ones.
  if ([self.name isEqual:@"SpacesListLayoutController"] && self.sublayers.count >= 2) {
    NSArray<CALayer *> *unexpandedViews = self.sublayers[0].sublayers;
    NSArray<CALayer *> *expandedViews = self.sublayers[1].sublayers;

    // Wait for the per-space layers (and their ECTextLayers) to be initialized
    if (!(expandedViews.count || unexpandedViews.count)) {
      ZKOrig(void, arg1);
      return;
    }
    int numSpaces = MAX((int)unexpandedViews.count, (int)expandedViews.count);

    // Get which of the spaces in the current bar is selected (-1 while nothing is highlighted)
    int selected = getSelected(unexpandedViews.count ? unexpandedViews : expandedViews);

    SRLog("SpacesListLayoutController setFrame %{public}@ delegate=%{public}@ super=%{public}@ unexpanded=%lu expanded=%lu selected=%d",
          NSStringFromRect(arg1), self.delegate, self.superlayer, (unsigned long)unexpandedViews.count, (unsigned long)expandedViews.count, selected);
    static BOOL hookReported = NO;
    if (!hookReported) {
      hookReported = YES;
      writePluginStatus(YES);
    }

    // Get all of the names
    NSMutableArray<Monitor *> *names = loadNamedMonitors();

    if (names.count == 0) {
      ZKOrig(void, arg1);
      return;
    }

    // Take a best guess at which monitor it is
    NSMutableArray *possibleMonitors = [[NSMutableArray alloc] init];
    for (int i = 0; i < names.count; i++) {
      if (
          names[i].spaces.count == numSpaces && // Same number of spaces
          selected >= 0 && selected < names[i].spaces.count &&
          [names[i].spaces[selected][@"selected"] boolValue] // Same index is selected
          ) {
        [possibleMonitors addObject:[NSNumber numberWithInt:i]];
      }
    }
    // If only one monitor, good to go
    // If more than one monitor, but the sizes are different we can usually identify it
    // Otherwise just go with the same cycling as it appears to have been last time it was good to go
    if (possibleMonitors.count == 1) {
      monitorIndex = [possibleMonitors[0] intValue];
    } else {
      // If the size of the bar only matches one of the monitors, then use that one
      NSString *displayUUID = [self getDisplayUUID:arg1];
      if (displayUUID != nil) {
        for (int i = 0; i < names.count; i++) {
          if ([names[i].displayUUID isEqualToString:displayUUID]) {
            monitorIndex = i;
          }
        }
      }
    }
    [possibleMonitors release];

    monitorIndex = monitorIndex % names.count;

    double unexpandedOffset = 0;
    for (int i = 0; i < names[monitorIndex].spaces.count; i++) {
      NSString *name = names[monitorIndex].spaces[i][@"name"];
      // It's overridden
      if (name != nil && ![name isEqualToString:@""]) {
        // Expanded
        if (i < expandedViews.count) {
          double textSize = getTextSize(expandedViews[i], name);
          // Don't have the expanded view string overlap other ones
          overrideTextLayer(expandedViews[i], name, MIN(textSize, expandedViews[i].frame.size.width), @"expanded");
        }
        // Unexpanded
        if (i < unexpandedViews.count) {
          double textSize = getTextSize(unexpandedViews[i], name);
          overrideTextLayer(unexpandedViews[i], name, textSize, @"unexpanded");
          setOffset(unexpandedViews[i], unexpandedOffset, false);
          unexpandedOffset += (textSize - getTextLayer(unexpandedViews[i]).bounds.size.width);
        }
      } else {
        if (i < unexpandedViews.count) {
          setOffset(unexpandedViews[i], unexpandedOffset, false);
        }
      }
    }

    // Make sure that it's centered in the bar when unexpanded
    for (int i = 0; i < names[monitorIndex].spaces.count; i++) {
      if (i < unexpandedViews.count) {
        setOffset(unexpandedViews[i], -unexpandedOffset/2, true);
      }
    }

    monitorIndex += 1;

    // So that it doesn't change sizes on switching spaces
    refreshFrames(self, self);
  }

  return ZKOrig(void, arg1);
}

// This checks the same monitors we already fetched in
// probablyDesktopSwitcher, but this is only fallback code if both
// screens have the same number of spaces and the same ones selected
// which is unlikely. Therefore it's better to eat that rare double
// cost than fetch the UUID when it's not needed.
- (NSString *)getDisplayUUID:(CGRect)rect {
  // Get all of the monitors
  CGDirectDisplayID displayArray[kMaxDisplays];
  uint32_t displayCount;
  CGGetActiveDisplayList(kMaxDisplays, displayArray, &displayCount);

  // This is only evaluated after probablyDesktopSwitcher is truthy
  // so one of them is guaranteed to match. We only want ONE to match
  // to feel confident using this signal though. So if we've already
  // matched we just return nil
  CGDirectDisplayID matchingScreen = 0;
  for (int i = 0; i < displayCount; i++) {
    if (CGDisplayPixelsWide(displayArray[i]) == rect.size.width) {
      if (matchingScreen != 0) {
        return nil;
      } else {
        matchingScreen = displayArray[i];
      }
    }
  }
  // Go from the CGDirectDisplayID to the Display Identifier using private APIs
  CFUUIDRef screenUuid = CGDisplayCreateUUIDFromDisplayID(matchingScreen);
  CFStringRef uuid = CFUUIDCreateString(nil, screenUuid);
  return (__bridge NSString *)uuid;
}

// WindowManager (macOS 27+) lays the Spaces bar out through bounds, never frame.
- (void)setBounds:(CGRect)bounds {
  ZKOrig(void, bounds);
  if ([self.name isEqualToString:kSpacesBarLayerName]) {
    applySpacesBarNames(self);
  }
}

- (void)layoutSublayers {
  ZKOrig(void);
  if ([self.name isEqualToString:kSpacesBarLayerName]) {
    applySpacesBarNames(self);
  }
}

@end

// WindowManager's per-space labels: remember the title WindowManager wants ("Desktop N", which
// identifies the space), apply the custom name once the label is in its container, and keep
// the custom name when WindowManager re-applies its own title on later passes.
ZKSwizzleInterfaceGroup(_SRCATextLayer, CATextLayer, CATextLayer, SpacesRenamer);
@implementation _SRCATextLayer
- (void)setString:(id)string {
  if ([self.name isEqualToString:kSpacesBarLabelLayerName]) {
    id overridden = objc_getAssociatedObject(self, &OVERRIDDEN_STRING);
    if ([string isKindOfClass:[NSString class]] && ![string isEqual:overridden]) {
      assign(self, &ORIGINAL_STRING, string);
      learnDesktopWord(string);
      if (!objc_getAssociatedObject(self, &PENDING_APPLY)) {
        // WindowManager sets the title before attaching the label to its container; apply on
        // the next main-queue turn, once the tree is complete.
        assign(self, &PENDING_APPLY, @YES);
        dispatch_async(dispatch_get_main_queue(), ^{
          assign(self, &PENDING_APPLY, nil);
          applySpacesBarLabel(self);
        });
      }
    }
    if ([overridden isKindOfClass:[NSString class]]) {
      string = overridden;
    }
  }
  ZKOrig(void, string);
}
@end

ZKSwizzleInterfaceGroup(_SRECTextLayer, ECTextLayer, CATextLayer, SpacesRenamer);
@implementation _SRECTextLayer
- (void)setFrame:(CGRect)arg1 {
  //  os_log(OS_LOG_DEFAULT, "[ECTextLayer setFrame:] string=%{public}@", self.string);
  @try {
    [self removeObserver:self forKeyPath:@"propertiesChanged" context:nil];
  } @catch (id anException) {
  }
  [self addObserver:self forKeyPath:@"propertiesChanged" options:NSKeyValueObservingOptionNew context:nil];

  id possibleWidth = objc_getAssociatedObject(self, &OVERRIDDEN_WIDTH);
  if (possibleWidth && [possibleWidth isKindOfClass:[NSNumber class]]) {
    arg1.size.width = [possibleWidth doubleValue];
  }
  ZKOrig(void, arg1);
}

// ZKOrig forwards to the original -dealloc, which is what the missing-super warning asks for.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-missing-super-calls"
- (void)dealloc {
  @try {
    [self removeObserver:self forKeyPath:@"propertiesChanged" context:nil];
  } @catch (id anException) {
  }
  ZKOrig(void);
}
#pragma clang diagnostic pop

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  id overridden = objc_getAssociatedObject(self, &OVERRIDDEN_STRING);
  if ([overridden isKindOfClass:[NSString class]] && ![self.string isEqualToString:overridden]) {
    self.string = overridden;
  }
}

- (id)propertiesChanged {
  return nil;
}

+ (NSSet *)keyPathsForValuesAffectingPropertiesChanged {
  return [NSSet setWithObjects:@"string", nil];
}

// ===============
// DEBUG FUNCTIONS
// ===============
//- (void)printLayer:(CALayer *)layer {
//  [self recursivePrint:layer withPrefix:@""];
//}
//
//- (void)recursivePrint:(CALayer *)layer withPrefix:(NSString *)prefix {
//  NSLog(@"spaces-renamer: %@%@", prefix, layer);
//  for (int i = 0; i < layer.sublayers.count; i++) {
//    [self recursivePrint:layer.sublayers[i] withPrefix:[NSString stringWithFormat:@"  %@", prefix]];
//  }
//}

@end
