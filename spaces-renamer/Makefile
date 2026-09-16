# Builds the Dock plugin as a native universal dylib (arm64 + arm64e).
#
#   make            -> build/spaces-renamer.dylib
#   make test       -> build + run the hook-safety test against synthetic layer trees
#   make clean
#
# Only the Command Line Tools are required; never xcodebuild.

DEVELOPER_DIR ?= /Library/Developer/CommandLineTools
export DEVELOPER_DIR

# Resolve clang through xcrun so it works under both the Command Line Tools and a full Xcode
# (whose clang lives in the toolchain, not $(DEVELOPER_DIR)/usr/bin). CI sets DEVELOPER_DIR to Xcode.
CC      := $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun -f clang)
SDK     := $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun --sdk macosx --show-sdk-path)
ARCHS   ?= arm64 arm64e
MIN_OS  ?= 26.0
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo 0.0.0-dev)
BUILD   ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
CODESIGN_IDENTITY ?= -
DEBUG   ?=

BUILD_DIR := build
DYLIB     := $(BUILD_DIR)/spaces-renamer.dylib
TEST_BIN  := $(BUILD_DIR)/hook_test

SRCS      := spacesRenamer.m ZKSwizzle.m
HEADERS   := ZKSwizzle.h

ARCH_FLAGS := $(foreach a,$(ARCHS),-arch $(a))
CFLAGS  := -isysroot $(SDK) -mmacosx-version-min=$(MIN_OS) -fmodules -fno-objc-arc -O2 -Wall \
           -DSPACES_RENAMER_VERSION='"$(VERSION)"' -DSPACES_RENAMER_BUILD='"$(BUILD)"' \
           $(if $(DEBUG),-DSR_DEBUG,)
FRAMEWORKS := -framework Foundation -framework QuartzCore -framework Cocoa -framework CoreGraphics -framework CoreText
LDFLAGS := -dynamiclib -install_name @rpath/spaces-renamer.dylib $(FRAMEWORKS)

.PHONY: all test clean

all: $(DYLIB)

$(DYLIB): $(SRCS) $(HEADERS) Makefile | $(BUILD_DIR)
	$(CC) $(ARCH_FLAGS) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS)
	codesign --force --sign "$(CODESIGN_IDENTITY)" $@
	lipo -info $@

# The test process is plain arm64; dlopen picks the matching slice of the fat dylib.
$(TEST_BIN): tests/hook_test.m Makefile | $(BUILD_DIR)
	$(CC) -arch arm64 $(CFLAGS) $(FRAMEWORKS) -o $@ tests/hook_test.m

# The plugin reads the real com.apple.dock preference domain; the test redirects it to a
# throwaway domain through SPACES_RENAMER_DOMAIN so it never touches real names.
test: $(DYLIB) $(TEST_BIN)
	SPACES_RENAMER_DOMAIN=com.alexbeals.spacesrenamer.test.$$$$ $(TEST_BIN) $(abspath $(DYLIB))

$(BUILD_DIR):
	mkdir -p $@

clean:
	rm -rf $(BUILD_DIR)
