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

1. **System Integrity Protection is disabled.** Reboot into Recovery (hold the power button on
   Apple Silicon), open Terminal, run `csrutil disable`, reboot.
2. **The arm64e preview ABI is enabled**, because `Dock` and `WindowManager` are arm64e binaries:
   ```sh
   sudo nvram boot-args=-arm64e_preview_abi
   ```
   then reboot.

The app's Diagnostics pane checks both and prints the exact command to run when one is missing.

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

> **TODO** — the activation flow (installing and loading `spaces-renamer.dylib` into
> `WindowManager`/`Dock`, and restarting that process) is being built in
> [issue #2](https://github.com/Quelaan1/spaces-renamer/issues/2). Until it lands this section is
> a placeholder, and the Diagnostics pane shows the same placeholder in its "plugin active" row.

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
make                            # SpacesRenamer/build/SpacesRenamer.app + spaces-renamer/build/spaces-renamer.dylib
make test                       # plugin hook test against synthetic Dock and WindowManager layer trees
make dmg                        # build/SpacesRenamer-<version>.dmg with the plugin embedded
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

1. Quit SpacesRenamer, turn off "Launch at login" first if you want the login item gone
   immediately (deleting the app also removes it).
2. Drag `SpacesRenamer.app` to the Trash (or `brew uninstall --cask spaces-renamer`).
3. Optionally remove the published names:
   ```sh
   defaults delete com.apple.dock SpacesRenamerNames
   defaults delete com.apple.dock SpacesRenamerMonitors
   defaults delete com.apple.WindowManager SpacesRenamerPlugin
   ```
4. Restart the host so the plugin unloads: `killall WindowManager` (macOS 27) or `killall Dock`
   (macOS 26).

---

Spaces Renamer was created by [Alex Beals](https://github.com/dado3212/spaces-renamer); donations
to the original author [are always appreciated](https://www.paypal.com/paypalme2/AlexBeals).
