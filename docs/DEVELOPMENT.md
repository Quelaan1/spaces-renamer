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
display, centred in its menu bar.

**Switching desktops.** macOS has no public API to change the Space, and an app cannot post key
events without an Accessibility prompt. The app posts the Darwin notification
`com.alexbeals.spacesrenamer.switch-desktop` with the desktop number as its state. The plugin, in the
Spaces-bar host, presses macOS's own "Switch to Desktop N" symbolic hot key (118–133). WindowManager
carries `com.apple.private.tcc.allow` → `kTCCServicePostEvent`, so no prompt is needed. A shortcut the
user left off is enabled in the window server for just that press, and turned off again 0.3 s later.

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
