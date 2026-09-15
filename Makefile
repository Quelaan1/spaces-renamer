# Top-level build for Spaces Renamer: the menu-bar app (SpacesRenamer/) and the Dock/WindowManager
# plugin (spaces-renamer/).
#
#   make            build both
#   make test       run the plugin hook test
#   make dmg        build/SpacesRenamer-<version>.dmg with the plugin embedded in the app bundle
#   make clean
#
# Builds with the Command Line Tools by default; CI sets DEVELOPER_DIR to its Xcode.

DEVELOPER_DIR ?= /Library/Developer/CommandLineTools
export DEVELOPER_DIR

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo 0.0.0-dev)
CODESIGN_IDENTITY ?= -
export VERSION CODESIGN_IDENTITY

APP    := SpacesRenamer/build/SpacesRenamer.app
DYLIB  := spaces-renamer/build/spaces-renamer.dylib
DMG    := build/SpacesRenamer-$(VERSION:v%=%).dmg
STAGE  := build/dmg

.PHONY: all app plugin test dmg clean

all: app plugin

app $(APP):
	$(MAKE) -C SpacesRenamer

plugin $(DYLIB):
	$(MAKE) -C spaces-renamer

test:
	$(MAKE) -C spaces-renamer test

# The plugin ships inside the app bundle so one artifact carries both halves; the app's
# activation flow (issue #2) loads it from Contents/PlugIns. The bundle is re-signed after the
# copy so the seal covers the plugin.
dmg: $(APP) $(DYLIB)
	rm -rf $(STAGE) $(DMG)
	mkdir -p $(STAGE)
	cp -R $(APP) $(STAGE)/
	mkdir -p $(STAGE)/SpacesRenamer.app/Contents/PlugIns
	cp $(DYLIB) $(STAGE)/SpacesRenamer.app/Contents/PlugIns/
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_FLAGS) \
	  --entitlements SpacesRenamer/SpacesRenamer.entitlements $(STAGE)/SpacesRenamer.app
	ln -s /Applications $(STAGE)/Applications
	hdiutil create -volname "Spaces Renamer" -srcfolder $(STAGE) -ov -format UDZO $(DMG)
	rm -rf $(STAGE)

clean:
	rm -rf build
	$(MAKE) -C SpacesRenamer clean
	$(MAKE) -C spaces-renamer clean
