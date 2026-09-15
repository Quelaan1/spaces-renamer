# Top-level build for Spaces Renamer: the menu-bar app (SpacesRenamer/) and the Dock/WindowManager
# plugin (spaces-renamer/).
#
#   make            build the app with the plugin, mechanism script and MIP bundle embedded
#   make test       run the plugin hook test
#   make dmg        build/SpacesRenamer-<version>.dmg from the embedded app
#   make install-mip / uninstall-mip   drop/remove the MIP bundle in MIP's Bundles dir (root)
#   make clean
#
# Builds with the Command Line Tools by default; CI sets DEVELOPER_DIR to its Xcode.

DEVELOPER_DIR ?= /Library/Developer/CommandLineTools
export DEVELOPER_DIR

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo 0.0.0-dev)
BUILD ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
CODESIGN_IDENTITY ?= -
export VERSION BUILD CODESIGN_IDENTITY

APP    := SpacesRenamer/build/SpacesRenamer.app
DYLIB  := spaces-renamer/build/spaces-renamer.dylib
BUNDLE := build/SpacesRenamer.mip.bundle
SCRIPT := scripts/injector.sh
DMG    := build/SpacesRenamer-$(VERSION:v%=%).dmg
STAGE  := build/dmg

.PHONY: all app plugin bundle embed test dmg install-mip uninstall-mip clean

# `all` yields a self-contained app: the plugin, the mechanism script and the MIP bundle are
# embedded so activation works straight from SpacesRenamer.app.
all: embed

app $(APP):
	$(MAKE) -C SpacesRenamer

plugin $(DYLIB):
	$(MAKE) -C spaces-renamer

test:
	$(MAKE) -C spaces-renamer test

# The MIP tweak bundle: the plugin dylib as the bundle executable, plus the injection filter
# (WindowManager/Dock) from packaging/mip/Info.plist. Consumed by the app and by `make install-mip`.
bundle $(BUNDLE): $(DYLIB) packaging/mip/Info.plist | build-dir
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	sed -e 's/__VERSION__/$(VERSION)/' -e 's/__BUILD__/$(BUILD)/' packaging/mip/Info.plist > $(BUNDLE)/Contents/Info.plist
	cp $(DYLIB) $(BUNDLE)/Contents/MacOS/SpacesRenamer
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(BUNDLE)/Contents/MacOS/SpacesRenamer

# Everything the app needs to activate either injector lives inside the bundle: the plugin at
# Contents/PlugIns, the mechanism script and the MIP bundle in Contents/Resources. Embedding runs
# after SpacesRenamer/Makefile has (re)built the app bundle, then re-signs so the seal covers it.
embed: app plugin bundle
	mkdir -p $(APP)/Contents/PlugIns $(APP)/Contents/Resources
	cp $(DYLIB) $(APP)/Contents/PlugIns/
	cp $(SCRIPT) $(APP)/Contents/Resources/
	rm -rf $(APP)/Contents/Resources/SpacesRenamer.mip.bundle
	cp -R $(BUNDLE) $(APP)/Contents/Resources/
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" \
	  --entitlements SpacesRenamer/SpacesRenamer.entitlements $(APP)

# The DMG ships the embedded app as-is.
dmg: embed
	rm -rf $(STAGE) $(DMG)
	mkdir -p $(STAGE)
	cp -R $(APP) $(STAGE)/
	ln -s /Applications $(STAGE)/Applications
	hdiutil create -volname "Spaces Renamer" -srcfolder $(STAGE) -ov -format UDZO $(DMG)
	rm -rf $(STAGE)

# Convenience wrappers around the MIP injector (root). The app offers the same via an admin prompt.
install-mip: bundle
	sudo $(SCRIPT) mip on $(abspath $(BUNDLE))

uninstall-mip:
	sudo $(SCRIPT) mip off

build-dir:
	mkdir -p build

clean:
	rm -rf build
	$(MAKE) -C SpacesRenamer clean
	$(MAKE) -C spaces-renamer clean
