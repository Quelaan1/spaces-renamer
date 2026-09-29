# Spaces Renamer

Give your macOS desktops real names — "Design", "Comms", "Music" — instead of "Desktop 1",
"Desktop 2", … A modern fork of [dado3212/spaces-renamer](https://github.com/dado3212/spaces-renamer)
for **macOS 26 and 27 on Apple Silicon**.

<p align="center">
  <img src="smallView.jpg" height="45"><br>
  <i>The Mission Control Spaces bar with custom names (the macOS 26+ bar is styled differently).</i>
</p>

- **Names in Mission Control**, on every display.
- **Names in the menu bar**: each display shows its own named desktops, with the current one
  highlighted. Click a name to switch to that desktop.
- **A glass HUD** that shows the desktop's name when you switch.

## Requirements

- macOS 26 (Tahoe) or 27, on Apple Silicon.
- **System Integrity Protection (SIP) turned off.** Renaming works by loading a small plugin into the
  system process that draws Mission Control, which macOS only allows with SIP off. The app walks you
  through it.

## Install

```sh
brew install --cask Quelaan1/tap/spaces-renamer
```

Or download the DMG from the [releases page](https://github.com/Quelaan1/spaces-renamer/releases) and
drag `SpacesRenamer.app` to Applications. If macOS refuses to open an unsigned build, run:

```sh
xattr -dr com.apple.quarantine /Applications/SpacesRenamer.app
```

## Set up

Open the app from its menu-bar icon (there is no Dock icon). The **Diagnostics** tab shows three
checks, each with its fix:

1. **Turn off SIP.** Restart into Recovery (hold the power button), open Terminal, run
   `csrutil disable`, and restart. This is the one step you must do by hand.
2. **Enable the arm64e preview ABI.** Click **Enable & restart…** (it asks for your password).
3. **Activate** the plugin. Once it loads, the plugin rows turn green.

Activation needs no admin rights by default. For an alternative that only touches the system process
and survives reboots without a login item, see [MIP in the developer notes](docs/DEVELOPMENT.md#mip-targeted-survives-reboot).

## Use

1. Click the menu-bar icon. Each display has a row of its desktops.
2. Type a name and press Return. Clear a name to go back to "Desktop N".
3. Open Mission Control: your names are there. Full-screen apps keep their own names.
4. Look at the menu bar: each display shows its own named desktops in the middle. Click one to go
   there. No shortcut setup or permission is needed, and it works for desktops 1–16.

The names can cover an app's menus when those reach the middle of the menu bar. Turn the menu-bar
names or the HUD off in the popover.

## Uninstall

1. **Diagnostics ▸ Activation ▸ Deactivate.**
2. Quit the app and drag it to the Trash, or run `brew uninstall --cask spaces-renamer`.
3. Optionally delete the stored names:
   ```sh
   defaults delete com.apple.dock SpacesRenamerNames
   defaults delete com.apple.dock SpacesRenamerMonitors
   defaults delete com.apple.WindowManager SpacesRenamerPlugin
   ```

## Troubleshooting

- **Nothing renames after Activate.** Check Diagnostics: SIP must be off and the arm64e ABI on. Then
  open Mission Control once.
- **"Plugin version" is green but "Plugin active" is red.** Restart the host with
  `killall WindowManager` (macOS 27) or `killall Dock` (macOS 26), or activate again.
- **A name still shows after uninstalling.** Restart the host the same way.
- **The MIP option is greyed out.** MIP isn't installed.

## Developers

Architecture, activation internals, where data lives, building from source and releasing are in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Credits and license

Created by [Alex Beals](https://github.com/dado3212/spaces-renamer); donations to the original author
[are always appreciated](https://www.paypal.com/paypalme2/AlexBeals). This fork modernizes it for
macOS 26/27 on Apple Silicon. Released under the [MIT License](LICENSE) — © 2019 Alex Beals.
