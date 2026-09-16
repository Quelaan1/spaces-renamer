# Spaces Renamer

Give your macOS Spaces real names in Mission Control — "Design", "Comms", "Music" — instead of
"Desktop 1", "Desktop 2", … This is a modern fork of
[dado3212/spaces-renamer](https://github.com/dado3212/spaces-renamer), rebuilt for **macOS 26 and
27 on Apple Silicon**.

<p align="center">
  <img src="smallView.jpg" height="45"><br>
  <i>The Mission Control Spaces bar with custom names (the macOS 26+ bar is styled differently).</i>
</p>

It comes in two pieces:

- **SpacesRenamer.app** — a menu-bar app where you type the names (one row per display, current
  Space highlighted), turn the renamer on or off, and run a Diagnostics pane that tells you exactly
  what is missing when renaming doesn't work.
- **spaces-renamer.dylib** — a small plugin that is loaded into the process that draws the Spaces
  bar and rewrites the labels. On **macOS 27** that process is `WindowManager`; on **macOS 26** it
  is `Dock`. The plugin ships inside the app at `SpacesRenamer.app/Contents/PlugIns/`.

This fork drops the old MacForge/SIMBL setup entirely: no MacForge, no `LetsMove`, no AppleScript
login items — just a native app and a native arm64/arm64e plugin.

---

## Contents

- [Compatibility](#compatibility)
- [Install](#install)
- [First run](#first-run)
- [How activation works](#how-activation-works) — DYLD vs MIP
- [Using the app](#using-the-app)
- [Diagnostics](#diagnostics)
- [How it works and where data lives](#how-it-works-and-where-data-lives)
- [Build from source](#build-from-source)
- [Releasing](#releasing)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [Credits and license](#credits-and-license)

---

## Compatibility

| | |
| --- | --- |
| macOS | 26 (Tahoe) and 27 |
| Chip | Apple Silicon (`arm64` / `arm64e`) |
| Requires | System Integrity Protection **disabled** + the **arm64e preview ABI** |

Renaming works by loading third-party code into a system process, which macOS only permits with SIP
off. The app checks both requirements for you and offers a one-tap fix for each (see
[First run](#first-run)); **disabling SIP is the only step that is unavoidably manual**, because
Apple provides no way to automate a Recovery boot.

## Install

**Homebrew** (recommended, for signed releases):

```sh
brew install --cask Quelaan1/tap/spaces-renamer
```

**DMG:** download `SpacesRenamer-<version>.dmg` from the
[releases page](https://github.com/Quelaan1/spaces-renamer/releases), open it, and drag
`SpacesRenamer.app` to `Applications`. Signed releases are Developer ID signed and notarized and
open normally. An **unsigned** release (built without the signing secrets) is Gatekeeper-quarantined
and needs one command before it will open:

```sh
xattr -dr com.apple.quarantine /Applications/SpacesRenamer.app
```

Launch the app once. It registers itself as a login item via `SMAppService` (toggle it off any time
in the popover).

## First run

Open the menu-bar icon (there's no Dock icon). If the plugin isn't active yet, the popover greets you
with an **Activation** prompt — one click turns renaming on. Under the hood the app walks three gates,
all shown in the **Diagnostics** pane with an inline fix:

1. **System Integrity Protection** must be **disabled**. Reboot into Recovery (hold the power button),
   open Terminal, run `csrutil disable`, reboot. The pane's **Copy command** button copies
   `csrutil disable` for you; the Recovery reboot itself is manual.
2. **The arm64e preview ABI** must be enabled (`Dock`/`WindowManager` are arm64e binaries). The pane's
   **Enable & restart…** button runs it for you (admin prompt, preserving any existing boot-args) and
   offers to reboot; or by hand: `sudo nvram boot-args=-arm64e_preview_abi`, then reboot.
3. **Activate** the plugin (see below). Once it loads, "Plugin version" and "Plugin active" go green.

## How activation works

Activation loads `spaces-renamer.dylib` into the Spaces-bar host and restarts it. Two injectors are
supported; pick one under **Diagnostics ▸ Activation**, or drive the same mechanism from Terminal with
the embedded `injector.sh`. Both require SIP off and the arm64e ABI.

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
immediately in any process that isn't `WindowManager` or `Dock`, so it does nothing there. If you'd
rather it never load into other apps at all, use MIP.

In the app: **Diagnostics ▸ Activation ▸ DYLD_INSERT_LIBRARIES ▸ Activate**. From a checkout:

```sh
make    # builds the app with the plugin, injector.sh and the MIP bundle embedded
APP=SpacesRenamer/build/SpacesRenamer.app
"$APP/Contents/Resources/injector.sh" dyld on "$APP/Contents/PlugIns/spaces-renamer.dylib"
"$APP/Contents/Resources/injector.sh" dyld off   # deactivate
```

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

## Using the app

1. Click the Spaces Renamer menu-bar icon and switch to the **Spaces** tab.
2. Each display shows a row of its Spaces in Mission Control order; the current Space is highlighted
   and focused.
3. Type a name and press Return. Clear a field to fall back to the default "Desktop N" label. Escape
   closes without saving.
4. Open Mission Control — the names show in both the collapsed and the expanded (pointer at the top
   edge) bar, and appear on the very first frame with no "Desktop N" flash. Full-screen app Spaces
   keep their app name.

Names update live while the plugin is active; the app doesn't need to stay open.

## Diagnostics

The **Diagnostics** tab shows four checks, each with the exact fix when it fails, plus the Activation
controls and a **Launch at login** toggle.

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

`DEVELOPER_DIR` defaults to `/Library/Developer/CommandLineTools`; point it at an Xcode's
`Contents/Developer` to use Xcode's toolchain instead. `CODESIGN_IDENTITY` defaults to ad-hoc (`-`);
`CODESIGN_FLAGS` is empty locally and set to `--options runtime --timestamp` by CI for a notarizable
build. The plugin is built for `arm64` and `arm64e`; the app for `arm64`.

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

## Uninstall

1. **Deactivate** the injector — in the app, **Diagnostics ▸ Activation ▸ Deactivate**, or from a
   checkout `injector.sh dyld off` (DYLD) / `make uninstall-mip` (MIP). This removes the LaunchAgent or
   MIP bundle and restarts the host clean.
2. Quit SpacesRenamer (turn off **Launch at login** first if you want the login item gone immediately;
   deleting the app also removes it).
3. Drag `SpacesRenamer.app` to the Trash, or `brew uninstall --cask spaces-renamer`.
4. Optionally remove the stored data:
   ```sh
   defaults delete com.apple.dock SpacesRenamerNames
   defaults delete com.apple.dock SpacesRenamerMonitors
   defaults delete com.apple.WindowManager SpacesRenamerPlugin
   ```
5. If a name still shows, restart the host: `killall WindowManager` (macOS 27) or `killall Dock`
   (macOS 26).

## Troubleshooting

- **Nothing renames after Activate.** Re-run the Diagnostics checks. "Plugin active" stays red if SIP
  is on or the arm64e ABI isn't set (both are required), or if the host hasn't been restarted — open
  Mission Control once to make the plugin hook fire.
- **"Plugin version" is green but "Plugin active" is red.** The plugin loaded into a host that has
  since been replaced; restart the host (`killall WindowManager` / `killall Dock`) or re-activate.
- **Gatekeeper won't open the app.** It's an unsigned build; run
  `xattr -dr com.apple.quarantine /Applications/SpacesRenamer.app`.
- **MIP row is greyed out.** MIP isn't installed — install it first, then reopen the app.
- **Watch what the plugin is doing.** Build the plugin with `DEBUG=1` and read the unified log (see
  [Build from source](#build-from-source)).

## Credits and license

Spaces Renamer was created by [Alex Beals](https://github.com/dado3212/spaces-renamer); donations to
the original author [are always appreciated](https://www.paypal.com/paypalme2/AlexBeals). This fork
modernizes it for macOS 26/27 on Apple Silicon.

Released under the [MIT License](LICENSE) — © 2019 Alex Beals.
