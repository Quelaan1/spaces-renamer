# Builds SpacesRenamer.app with SwiftPM only (no Xcode project).
#   make            build and assemble build/SpacesRenamer.app
#   make run        build and launch it
#   make clean      remove build/ and .build/
#
# Override CODESIGN_IDENTITY to sign with a real certificate, e.g.
#   make CODESIGN_IDENTITY="Apple Development"

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo 0.0.0-dev)
BUILD ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
CODESIGN_IDENTITY ?= -
ARCH ?= arm64

APP := build/SpacesRenamer.app
CONTENTS := $(APP)/Contents
SIGNATURE := $(CONTENTS)/_CodeSignature/CodeResources
SWIFT_BUILD := swift build -c release --arch $(ARCH)
BINARY := $(shell $(SWIFT_BUILD) --show-bin-path)/SpacesRenamer
SOURCES := Package.swift $(wildcard Sources/*/*.swift Sources/*/*.c Sources/*/include/*.h)
RESOURCES := $(wildcard Resources/*)

.PHONY: all app run clean

all: app

app: $(SIGNATURE)

$(BINARY): $(SOURCES)
	$(SWIFT_BUILD)

$(SIGNATURE): $(BINARY) Info.plist SpacesRenamer.entitlements $(RESOURCES)
	rm -rf $(APP)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BINARY) $(CONTENTS)/MacOS/SpacesRenamer
	cp $(RESOURCES) $(CONTENTS)/Resources/
	sed -e 's/__VERSION__/$(VERSION)/' -e 's/__BUILD__/$(BUILD)/' Info.plist > $(CONTENTS)/Info.plist
	printf 'APPL????' > $(CONTENTS)/PkgInfo
	codesign --force --sign "$(CODESIGN_IDENTITY)" --entitlements SpacesRenamer.entitlements $(APP)

run: app
	open $(APP)

clean:
	rm -rf build .build
