#ifndef CGSPrivate_h
#define CGSPrivate_h

#include <CoreFoundation/CoreFoundation.h>

// Private SkyLight/CoreGraphics symbols used to read the Spaces layout.
typedef int CGSConnectionID;

CGSConnectionID _CGSDefaultConnection(void);
CGSConnectionID CGSMainConnectionID(void);

// Array of monitor dictionaries: `Display Identifier`, `Current Space`, `Spaces`.
CF_RETURNS_RETAINED CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID cid);

// ManagedSpaceID of the space currently shown on the display with the given UUID.
uint64_t CGSManagedDisplayGetCurrentSpace(CGSConnectionID cid, CFStringRef displayUUID);

#endif /* CGSPrivate_h */
