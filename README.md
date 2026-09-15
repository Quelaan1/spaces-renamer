# Spaces Renamer

Spaces Renamer gives your macOS Spaces real names in Mission Control instead of "Desktop 1",
"Desktop 2", … It is two pieces:

- **SpacesRenamer.app** — a menu-bar app where you type the names, one row per display, with the
  current Space highlighted. It also has a Diagnostics pane that tells you exactly what is missing
  when renaming does not work.
- **spaces-renamer.dylib** — a plugin that is loaded into the process that draws the Mission
  Control Spaces bar and rewrites the labels. On macOS 27 that process is `WindowManager`; on
  macOS 26 it is `Dock`. The plugin ships inside the app bundle at
  `SpacesRenamer.app/Contents/PlugIns/spaces-renamer.dylib`.

This fork targets **macOS 26 and later on Apple Silicon**. It replaces the MacForge/SIMBL-based
upstream setup: no MacForge, no `LetsMove`, no AppleScript login items.

<p align="center">
  <img src="smallView.jpg" height="45"><br>
  <i>The Spaces bar with custom names (screenshot from the original app; the macOS 26+ bar looks different)</i>
</p>

## Prerequisites

Renaming works by loading third-party code into a system process. macOS only allows that when:

1. **System Integrity Protection is disabled.** macOS only lets you do this from Recovery: reboot
   holding the power button on Apple Silicon, open Terminal, run `csrutil disable`, reboot. The
   Diagnostics pane can copy the command to your clipboard, but the reboot into Recovery is manual —
   Apple provides no way to automate it.
2. **The arm64e preview ABI is enabled**, because `Dock` and `WindowManager` are arm64e binaries.
   The Diagnostics pane has an **Enable & restart…** button that runs this for you (admin prompt,
   keeping any existing boot-args) and offers to reboot; or do it by hand:
   ```sh
   sudo nvram boot-args=-arm64e_preview_abi
   ```
   then reboot.

Open the app's **Diagnostics** pane: it checks both, offers the one-tap fix for each, and — once
they pass — the **Activation** section turns the plugin on. Disabling SIP is the only step that is
unavoidably manual.

## Install

- **DMG**: download `SpacesRenamer-<version>.dmg` from the
  [releases page](https://github.com/Quelaan1/spaces-renamer/releases), open it and drag
  `SpacesRenamer.app` to `Applications`. Releases are Developer ID signed and notarized once the
  signing secrets are configured for the pipeline; a release built without them says
  "Unsigned build" in its notes and needs `xattr -d com.apple.quarantine <dmg>` before it opens.
- **Homebrew** (published for signed releases only):
  ```sh
  brew install --cask Quelaan1/tap/spaces-renamer
  ```

Then launch SpacesRenamer once. It registers itself as a login item through `SMAppService` (you
can turn that off in the popover).

## Activate the plugin

Activation loads `spaces-renamer.dylib` into the Spaces-bar host (`WindowManager` on macOS 27,
`Dock` on macOS 26) and restarts it. There are two injectors; both need SIP disabled and the
arm64e preview ABI (above). Pick one in the app's **Diagnostics ▸ Activation** section, or drive
the same mechanism from Terminal with the embedded `injector.sh`.

### DYLD (default, no root)

A per-user LaunchAgent publishes `DYLD_INSERT_LIBRARIES` and restarts the host, so the plugin
reloads at every login. No password, nothing written outside your home folder, and it is what the
app uses by default. The variable is global, so the library is loaded into every app you launch
afterwards — but its constructor immediately returns in anything that is not the host, so this is
harmless. Removing it is one click (or `injector.sh dyld off`) plus a host restart.

In the app: open the menu-bar popover, **Diagnostics**, choose **DYLD_INSERT_LIBRARIES**, click
**Activate**. From a checkout:

```sh
make                                            # builds the app with the injector embedded
SpacesRenamer/build/SpacesRenamer.app/Contents/Resources/injector.sh \
  dyld on SpacesRenamer/build/SpacesRenamer.app/Contents/PlugIns/spaces-renamer.dylib
```

### MIP (survives reboot with no login agent)

[MIP](https://github.com/LIJI32/MIP) is a system-wide injection platform. It loads the plugin
only into the executables named in the bundle's `Info.plist` (`WindowManager`, `Dock`) and needs
no login agent, but it requires a one-time privileged install and an admin password to drop the
bundle in place. MIP is upstream-tested only up to macOS Sonoma; on macOS 26/27 it works with the
arm64e preview ABI but is unsupported by its author, and a bad injector can require a
[Recovery-boot fix](https://github.com/LIJI32/MIP#disclaimer) (`rm /Library/LaunchDaemons/local.lsdinjector.plist`).

1. Install MIP once, following its README: disable SIP, `sudo nvram boot-args=-arm64e_preview_abi`,
   then `make SIGN_IDENTITY=<identity> && sudo make install` in the MIP checkout. It installs to
   `/Library/Apple/System/Library/Frameworks/mip` with a boot LaunchDaemon.
2. Drop our bundle in. In the app: **Diagnostics ▸ Activation ▸ MIP ▸ Activate** (admin prompt).
   From a checkout: `make install-mip` (copies `build/SpacesRenamer.mip.bundle` into MIP's
   `Bundles/` as root and restarts the host). Remove it with `make uninstall-mip` or
   **Deactivate**.

The Diagnostics pane detects whether MIP is installed and whether our bundle is present, and
greys out MIP activation until MIP is there.

> The archived [ammonia](https://github.com/CthulhuGraphics/Ammonia) loader (and its forks) is a
> possible alternative injector but is unmaintained and untested here; it is not supported.

## Use the app

1. Click the Spaces Renamer icon in the menu bar.
2. Each display gets a row of its Spaces in Mission Control order; the current Space is
   highlighted and focused.
3. Type a name and press Return, or click **Update Names**. Clear a field to go back to the
   default "Desktop N" label. Escape closes without saving.
4. Open Mission Control: the bar shows the names, both collapsed and expanded (pointer at the
   top edge). Full-screen app spaces keep their app name.

The popover also has **Launch at login** and a **Diagnostics** pane with these rows, each with
the exact fix when it fails:

| Row | Passes when |
| --- | --- |
| System Integrity Protection | `csrutil status` reports `disabled` |
| Boot arguments | `nvram boot-args` contains `-arm64e_preview_abi` |
| Plugin version | the plugin has loaded at least once and published its version and build |
| Plugin active | the plugin's recorded host pid is the running `WindowManager` (macOS 27) or `Dock` (macOS 26) |

## How it works and where data lives

Names and the current Spaces layout are published by the app as keys of the `com.apple.dock`
preference domain, and the plugin reports its status in its host's domain:

| Domain | Key | Written by | Content |
| --- | --- | --- | --- |
| `com.apple.dock` | `SpacesRenamerNames` | app | `{ <space uuid>: <name> }` |
| `com.apple.dock` | `SpacesRenamerMonitors` | app | the `CGSCopyManagedDisplaySpaces` array (display UUID, current Space, Spaces) |
| `com.apple.WindowManager` or `com.apple.dock` | `SpacesRenamerPlugin` | plugin | `Version`, `Build`, `HostPID`, `HostBundleID`, `LoadedAt`, `FirstHookAt` |

Preferences rather than files because `WindowManager` runs under a sandbox
(`/System/Library/Sandbox/Profiles/com.apple.WindowManager.sb`) that denies every file read
under `~/Library` but allows reading the `com.apple.dock` domain and writing its own. Inspect
with `defaults read com.apple.dock SpacesRenamerNames`.

Inside the host the plugin swizzles `CALayer`/`CATextLayer`: on macOS 27 it watches
WindowManager's per-space `PreviewLabel` text layers, reads the display from the layer's
`CAContext`, maps the "Desktop N" title to the Nth desktop of that display, and rewrites and
resizes the label; on macOS 26 it anchors on Dock's `SpacesListLayoutController` layer. Each
bar is matched to its display by identity, so two displays with the same resolution keep their
own names.

Names written by the original app (in
`~/Library/Containers/com.alexbeals.SpacesRenamer/com.alexbeals.spacesrenamer.plist`) are
imported the first time the new app runs.

## Build from source

Only the Command Line Tools are needed (Xcode is not used):

```sh
xcode-select --install          # once
make                            # app with plugin, injector.sh and the MIP bundle embedded
make test                       # plugin hook test against synthetic Dock and WindowManager layer trees
make dmg                        # build/SpacesRenamer-<version>.dmg from the embedded app
make install-mip                # drop build/SpacesRenamer.mip.bundle into MIP's Bundles dir (root)
make -C SpacesRenamer run       # launch the app
```

`DEVELOPER_DIR` defaults to `/Library/Developer/CommandLineTools`; set it to an Xcode's
`Contents/Developer` to build with Xcode's toolchain instead. `CODESIGN_IDENTITY` defaults to
ad-hoc (`-`). The plugin is built for `arm64` and `arm64e`; the app for `arm64`.

Debugging the plugin: `make -C spaces-renamer clean && make -C spaces-renamer DEBUG=1` compiles
tracing into the unified log, readable with
`log stream --predicate 'subsystem == "com.alexbeals.spaces-renamer"'`.

## Release pipeline

- Every push runs `.github/workflows/ci.yml` on `macos-26`: hook tests, universal plugin, app,
  unsigned DMG artifact.
- A `v*` tag runs `.github/workflows/release.yml`: same build, then — when the
  `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `NOTARY_KEY_P8`, `NOTARY_KEY_ID` and
  `NOTARY_ISSUER_ID` secrets exist — Developer ID signing with the hardened runtime, notarization
  with `notarytool`, stapling, and a cask pushed to the tap named by the `HOMEBREW_TAP_REPO`
  variable (default `Quelaan1/homebrew-tap`) using `HOMEBREW_TAP_TOKEN`. Without the secrets the
  release is published with an unsigned DMG and no cask.

## Uninstall

1. Deactivate the injector: in the app, **Diagnostics ▸ Activation ▸ Deactivate**, or from a
   checkout `injector.sh dyld off` (DYLD) / `make uninstall-mip` (MIP). This removes the LaunchAgent
   or MIP bundle and restarts the host clean.
2. Quit SpacesRenamer, turn off "Launch at login" first if you want the login item gone
   immediately (deleting the app also removes it).
3. Drag `SpacesRenamer.app` to the Trash (or `brew uninstall --cask spaces-renamer`).
4. Optionally remove the published names:
   ```sh
   defaults delete com.apple.dock SpacesRenamerNames
   defaults delete com.apple.dock SpacesRenamerMonitors
   defaults delete com.apple.WindowManager SpacesRenamerPlugin
   ```
5. If anything still shows, restart the host so the plugin unloads: `killall WindowManager`
   (macOS 27) or `killall Dock` (macOS 26).

---

Spaces Renamer was created by [Alex Beals](https://github.com/dado3212/spaces-renamer); donations
to the original author [are always appreciated](https://www.paypal.com/paypalme2/AlexBeals).
