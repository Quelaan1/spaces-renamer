# Developing Spaces Renamer

How the pieces fit together, how to build and release, and what to watch out for. For installing and
using the app, see the [README](../README.md).

## The two pieces

- **SpacesRenamer.app** — the menu-bar app (SwiftUI, `SpacesRenamer/`). It stores the names, shows
  the per-display menu-bar strip and the Space-change HUD, and runs activation and diagnostics.
- **spaces-renamer.dylib** — the plugin (`spaces-renamer/`), loaded into the process that draws the
  Spaces bar: `WindowManager` on macOS 27, `Dock` on macOS 26. It ships inside the app at
  `SpacesRenamer.app/Contents/PlugIns/`.

## How activation works

Activation loads `spaces-renamer.dylib` into the Spaces-bar host and restarts it. Two injectors are
supported; pick one under **Diagnostics ▸ Activation**, or drive the same mechanism from Terminal with
the embedded `injector.sh`. Both require SIP off and the arm64e preview ABI.

| | **DYLD** (default) | **MIP** |
| --- | --- | --- |
| Root needed | No | Yes (one-time install + admin prompt) |
| Mechanism | Per-user LaunchAgent sets `DYLD_INSERT_LIBRARIES`, restarts the host | A filtered bundle in [MIP](https://github.com/LIJI32/MIP)'s system `Bundles/` |
| Scope | Loaded into every app you launch; no-ops in anything but the host | Injected **only** into `WindowManager`/`Dock` |
| Persistence | Reloads at each login (the agent) | Survives reboot with no login agent |
| Removal | One click / `injector.sh dyld off` | One click / `make uninstall-mip` |

### DYLD (default, no root)

A per-user LaunchAgent publishes `DYLD_INSERT_LIBRARIES` and restarts the host, so the plugin reloads
at every login. Nothing is written outside your home folder. Because the variable is global, the
library is loaded into every app you launch while it's on — but the plugin's constructor returns
immediately in any process that isn't `WindowManager` or `Dock`, so it does nothing there.

From a checkout:

```sh
make    # builds the app with the plugin, injector.sh and the MIP bundle embedded
APP=SpacesRenamer/build/SpacesRenamer.app
"$APP/Contents/Resources/injector.sh" dyld on "$APP/Contents/PlugIns/spaces-renamer.dylib"
"$APP/Contents/Resources/injector.sh" dyld off   # deactivate
```

> **Never copy over the installed plugin in place.** Every process launched while DYLD is on loads
> `~/Library/Application Support/SpacesRenamer/spaces-renamer.dylib`, and the kernel keeps the old
> file's code signature for that inode. Writing new contents into the same file makes dyld refuse it
> (`F_ADDFILESIGS_RETURN failed with errno=37`), and from then on every app, Terminal window and
> shell dies at launch until you reboot. `injector.sh dyld on` installs through a temp file and a
> rename (#13); do the same by hand, or just use `dyld on`.

### MIP (targeted, survives reboot)

[MIP](https://github.com/LIJI32/MIP) is a system-wide injection platform that loads a bundle only
into the executables named in its `Info.plist` — here `WindowManager` and `Dock`. It needs a one-time
privileged install and an admin password to place the bundle, but no login agent.

> **Heads up:** MIP is upstream-tested only up to macOS Sonoma. It works on macOS 26/27 with the
> arm64e preview ABI but is unsupported by its author, and a bad injector can require a
> [Recovery-boot fix](https://github.com/LIJI32/MIP#disclaimer)
> (`rm /Library/LaunchDaemons/local.lsdinjector.plist`).

1. Install MIP once per its README (SIP off, `sudo nvram boot-args=-arm64e_preview_abi`, then
   `make SIGN_IDENTITY=<identity> && sudo make install`). It installs to
   `/Library/Apple/System/Library/Frameworks/mip` with a boot LaunchDaemon.
2. Drop our bundle in — **Diagnostics ▸ Activation ▸ MIP ▸ Activate** (admin prompt), or from a
   checkout `make install-mip` / `make uninstall-mip`.

The Diagnostics pane detects whether MIP is installed and whether our bundle is present, and greys
out MIP activation until MIP is there.

> The archived [ammonia](https://github.com/CthulhuGraphics/Ammonia) loader (and its forks) is a
> possible alternative injector, but it is unmaintained and untested here — it is not supported.

## Diagnostics checks

| Row | Passes when |
| --- | --- |
| System Integrity Protection | `csrutil status` reports `disabled` |
| Boot arguments | `nvram boot-args` contains `-arm64e_preview_abi` |
| Plugin version | the plugin has loaded at least once and published its version and build |
| Plugin active in host | the plugin's recorded host pid is the running `WindowManager` (macOS 27) or `Dock` (macOS 26) |

## How it works and where data lives

The app and the plugin talk through **preference domains**, not files — `WindowManager` runs under a
sandbox (`/System/Library/Sandbox/Profiles/com.apple.WindowManager.sb`) that denies every file read
under `~/Library` but allows reading the `com.apple.dock` domain and writing its own.

| Domain | Key | Written by | Content |
| --- | --- | --- | --- |
| `com.apple.dock` | `SpacesRenamerNames` | app | `{ <space uuid>: <name> }` |
| `com.apple.dock` | `SpacesRenamerMonitors` | app | the `CGSCopyManagedDisplaySpaces` array (display UUID, current Space, Spaces) |
| `com.apple.WindowManager` or `com.apple.dock` | `SpacesRenamerPlugin` | plugin | `Version`, `Build`, `HostPID`, `HostBundleID`, `LoadedAt`, `FirstHookAt` |

Inspect any of them with e.g. `defaults read com.apple.dock SpacesRenamerNames`.

Inside the host the plugin swizzles `CALayer` / `CATextLayer`: on macOS 27 it watches WindowManager's
per-Space `PreviewLabel` text layers, reads the display from the layer's `CAContext`, maps the
"Desktop N" title to the Nth desktop of that display, and rewrites and resizes the label; on macOS 26
it anchors on Dock's `SpacesListLayoutController` layer. Each bar is matched to its display by
identity, so two displays with the same resolution keep their own names.

**Menu-bar strip.** macOS mirrors a status item onto every display's menu bar at one shared width
(one real `NSStatusBarWindow` plus `NSStatusItemReplicantView` copies), so a status item cannot show
different names per display without leaving a gap. The app instead draws one borderless panel per
display, centred in its menu bar. On macOS 27 the panel still shows over full-screen apps although it
lacks `.fullScreenAuxiliary`, so the app hides a display's panel itself while that display's current
Space is a full-screen app (#22).

The panel's text colour follows the menu bar, not the system theme. On macOS 26/27 the menu bar's
colour follows the wallpaper, so a Mac in light mode can have a black menu bar, and text drawn in the
app's own appearance was black on black. The panel takes the appearance of the app's real
`NSStatusBarWindow` and redraws when it changes (#25). That one window stands for every display, so
two displays whose wallpapers give their menu bars different colours still share one text colour.

The panels are thrown away and made again whenever the displays change or the Mac wakes (#27). Sleep
and wake re-enumerate external displays under new display IDs, and the window server then keeps an
existing panel on one Space only, although its collection behaviour still says `.canJoinAllSpaces`;
`orderFrontRegardless()` does not move it to the current Space. Measured on macOS 27.0.1 with
`SLSCopySpacesForWindows`: the panel was ordered in, listed on one Space, while another was active.

The same loss happens without any wake or display change (#31), so on every render the app also asks
the window server whether each panel is on the Space its display shows (`CGSCopySpacesForWindows`)
and replaces a panel that is not. AppKit cannot answer this: it still believes the panel is on every
Space. The event that causes the loss is not known. Measured on macOS 27.0.1: another app's
all-desktops window went from every Space to Space 1 only in an interval in which a full-screen Space
was closed, with no lock, sleep or display change; a panel made new at that moment was on every Space.

**Popover size.** The popover is a `MenuBarExtra` window. Its window grows when the content needs
more room but does not shrink while the content's size is flexible; the unused part stays as a
see-through outline around the content, visible over a light window (#28). Measured on macOS 27.0.1:
window 856×437 after visiting Diagnostics, Spaces content 421 tall. So the content has one exact
size per pane (`.fixedSize()`, a fixed Diagnostics width) and the scene uses
`.windowResizability(.contentSize)`. Keep new popover content non-flexible.

**Switching desktops.** macOS has no public API to change the Space. The app posts the Darwin
notification `com.alexbeals.spacesrenamer.switch-space` with the clicked desktop's `ManagedSpaceID`
as its state, and the plugin, in the Spaces-bar host, does the switch:

- **macOS 27 (WindowManager)** — the plugin shows the new Space, makes it current on its display and
  hides the old one (`CGSShowSpaces`, `CGSManagedDisplaySetCurrentSpace`, `CGSHideSpaces`), calls
  WindowManager itself imports for Mission Control. No key is pressed, and the switch is immediate,
  without the slide animation.
- **macOS 26 (Dock)** — the plugin presses macOS's own "Switch to Desktop N" symbolic hot key
  (118–133), turning a shortcut the user left off on for just that press and off again 0.3 s later.

The hot-key method was dropped on macOS 27 because the window server honoured the plugin's press
only for desktop 1: for any other desktop it delivered Control-N to the front app as an ordinary
keystroke (#21). Why is unknown. The notification was renamed from `switch-desktop` (a desktop
number) at the same time, so a plugin loaded before the change ignores requests instead of misreading
a Space id as a desktop number.

Names written by the original app (in
`~/Library/Containers/com.alexbeals.SpacesRenamer/com.alexbeals.spacesrenamer.plist`) are imported the
first time this app runs.

## Build from source

Only the Command Line Tools are required (Xcode is not used):

```sh
xcode-select --install          # once
make                            # app with the plugin, injector.sh and the MIP bundle embedded
make test                       # plugin hook tests against synthetic Dock and WindowManager layer trees
make dmg                        # build/SpacesRenamer-<version>.dmg from the embedded app
make install-mip                # drop build/SpacesRenamer.mip.bundle into MIP's Bundles/ (root)
make -C SpacesRenamer run       # build and launch the app
```

While the plugin is active through DYLD it is injected into the test process too, which aborts the
hook test. Run it without the variable: `env -u DYLD_INSERT_LIBRARIES make test`.

`DEVELOPER_DIR` defaults to `/Library/Developer/CommandLineTools`; point it at an Xcode's
`Contents/Developer` to use Xcode's toolchain instead. `CODESIGN_IDENTITY` defaults to ad-hoc (`-`);
`CODESIGN_FLAGS` is empty locally and set to `--options runtime --timestamp` by CI for a notarizable
build. The plugin is built for `arm64` and `arm64e`; the app for `arm64`.

An ad-hoc signed app gets a new identity on every build, so macOS privacy permissions granted to one
build do not carry to the next. Sign local builds with a real identity
(`make CODESIGN_IDENTITY="Apple Development: …"`) when a permission has to persist.

Debug the plugin with tracing in the unified log:

```sh
make -C spaces-renamer clean && make -C spaces-renamer DEBUG=1
log stream --predicate 'subsystem == "com.alexbeals.spaces-renamer"'
```

## Releasing

- **CI** — every push runs `.github/workflows/ci.yml` on `macos-26`: hook tests, the universal
  plugin, the app, and an unsigned DMG artifact.
- **Release** — pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`: the same build, then a
  GitHub release with the DMG. When these repository secrets are present the DMG is Developer ID
  signed (hardened runtime), notarized with `notarytool`, stapled, and a Homebrew cask is pushed to
  the tap:

  | Secret | Purpose |
  | --- | --- |
  | `DEVELOPER_ID_CERT_P12` | base64 of the *Developer ID Application* `.p12` |
  | `DEVELOPER_ID_CERT_PASSWORD` | that `.p12`'s password |
  | `NOTARY_KEY_P8` | App Store Connect API key (`.p8` contents) |
  | `NOTARY_KEY_ID` / `NOTARY_ISSUER_ID` | that key's id and issuer |
  | `HOMEBREW_TAP_TOKEN` | PAT with `contents:write` on the tap repo (for the cask) |

  The tap repo defaults to `Quelaan1/homebrew-tap` (override with the `HOMEBREW_TAP_REPO` variable).
  Without the signing secrets the release publishes an unsigned DMG and skips the cask.
