#include "CGSPrivate.h"

// SwiftPM requires at least one compilation unit in a C target.
// The symbols declared in the header are resolved from the system frameworks at link time.
void CGSPrivate_anchor(void) {}
