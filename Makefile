## flutter-librsync Makefile
##
## Prerequisites:
##   - Go 1.21+  (CGO_ENABLED=1)
##   - For Android: ANDROID_NDK_HOME set, e.g. ~/Android/Sdk/ndk/<version>
##   - For iOS/macOS: must be run on macOS with Xcode installed
##   - For WASM: standard Go installation (wasm_exec.js is at $(go env GOROOT)/misc/wasm/)

GODIR       := $(CURDIR)/go
WASMDIR     := $(CURDIR)/go_wasm
PREBUILT    := $(CURDIR)/prebuilt
GO          := go
GOFLAGS     := -trimpath -ldflags="-s -w"

# Android NDK configuration
NDK_HOME    ?= $(ANDROID_NDK_HOME)
NDK_API     := 21
NDK_HOST    := $(shell uname -s | tr '[:upper:]' '[:lower:]')-x86_64

# Derived NDK toolchain paths (set only when NDK_HOME is known)
ifneq ($(NDK_HOME),)
NDK_TOOLCHAIN := $(NDK_HOME)/toolchains/llvm/prebuilt/$(NDK_HOST)/bin
CC_ARM64    := $(NDK_TOOLCHAIN)/aarch64-linux-android$(NDK_API)-clang
CC_ARM32    := $(NDK_TOOLCHAIN)/armv7a-linux-androideabi$(NDK_API)-clang
CC_X86_64   := $(NDK_TOOLCHAIN)/x86_64-linux-android$(NDK_API)-clang
endif

LIB_NAME    := flutter_librsync

.PHONY: all android android-arm64 android-arm32 android-x86_64 \
        ios macos macos-arm64 macos-amd64 \
        linux windows wasm clean help

all: linux wasm  ## Build for the current host (Linux: linux + wasm)

## ─── Android ──────────────────────────────────────────────────────────────────

android: android-arm64 android-arm32 android-x86_64  ## Build all Android ABIs

android-arm64: $(PREBUILT)/android/arm64-v8a/lib$(LIB_NAME).so
$(PREBUILT)/android/arm64-v8a/lib$(LIB_NAME).so: $(GODIR)/*.go $(GODIR)/go.sum
	@mkdir -p $(dir $@)
	@[ -n "$(NDK_HOME)" ] || (echo "ERROR: ANDROID_NDK_HOME is not set" && exit 1)
	cd $(GODIR) && CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC=$(CC_ARM64) \
	  $(GO) build $(GOFLAGS) -buildmode=c-shared -o $@ .

android-arm32: $(PREBUILT)/android/armeabi-v7a/lib$(LIB_NAME).so
$(PREBUILT)/android/armeabi-v7a/lib$(LIB_NAME).so: $(GODIR)/*.go $(GODIR)/go.sum
	@mkdir -p $(dir $@)
	@[ -n "$(NDK_HOME)" ] || (echo "ERROR: ANDROID_NDK_HOME is not set" && exit 1)
	cd $(GODIR) && CGO_ENABLED=1 GOOS=android GOARCH=arm GOARM=7 CC=$(CC_ARM32) \
	  $(GO) build $(GOFLAGS) -buildmode=c-shared -o $@ .

android-x86_64: $(PREBUILT)/android/x86_64/lib$(LIB_NAME).so
$(PREBUILT)/android/x86_64/lib$(LIB_NAME).so: $(GODIR)/*.go $(GODIR)/go.sum
	@mkdir -p $(dir $@)
	@[ -n "$(NDK_HOME)" ] || (echo "ERROR: ANDROID_NDK_HOME is not set" && exit 1)
	cd $(GODIR) && CGO_ENABLED=1 GOOS=android GOARCH=amd64 CC=$(CC_X86_64) \
	  $(GO) build $(GOFLAGS) -buildmode=c-shared -o $@ .

## ─── iOS (must run on macOS) ─────────────────────────────────────────────────

ios: $(PREBUILT)/ios/lib$(LIB_NAME).a  ## Build static library for iOS (macOS only)
$(PREBUILT)/ios/lib$(LIB_NAME).a: $(GODIR)/*.go $(GODIR)/go.sum
	@mkdir -p $(dir $@)
	@[ "$$(uname)" = "Darwin" ] || (echo "ERROR: iOS builds require macOS" && exit 1)
	cd $(GODIR) && CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
	  CGO_CFLAGS="-fembed-bitcode -isysroot $$(xcrun --sdk iphoneos --show-sdk-path)" \
	  CC=$$(xcrun --sdk iphoneos --find clang) \
	  $(GO) build $(GOFLAGS) -buildmode=c-archive -o $@ .

## ─── macOS (must run on macOS) ───────────────────────────────────────────────

macos: macos-arm64 macos-amd64 $(PREBUILT)/macos/lib$(LIB_NAME).dylib  ## Build universal macOS dylib

macos-arm64: $(PREBUILT)/macos/lib$(LIB_NAME)_arm64.dylib
$(PREBUILT)/macos/lib$(LIB_NAME)_arm64.dylib: $(GODIR)/*.go $(GODIR)/go.sum
	@mkdir -p $(dir $@)
	@[ "$$(uname)" = "Darwin" ] || (echo "ERROR: macOS builds require macOS" && exit 1)
	cd $(GODIR) && CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
	  $(GO) build $(GOFLAGS) -buildmode=c-shared -o $@ .

macos-amd64: $(PREBUILT)/macos/lib$(LIB_NAME)_amd64.dylib
$(PREBUILT)/macos/lib$(LIB_NAME)_amd64.dylib: $(GODIR)/*.go $(GODIR)/go.sum
	@mkdir -p $(dir $@)
	@[ "$$(uname)" = "Darwin" ] || (echo "ERROR: macOS builds require macOS" && exit 1)
	cd $(GODIR) && CGO_ENABLED=1 GOOS=darwin GOARCH=amd64 \
	  $(GO) build $(GOFLAGS) -buildmode=c-shared -o $@ .

$(PREBUILT)/macos/lib$(LIB_NAME).dylib: macos-arm64 macos-amd64
	lipo -create -output $@ \
	  $(PREBUILT)/macos/lib$(LIB_NAME)_arm64.dylib \
	  $(PREBUILT)/macos/lib$(LIB_NAME)_amd64.dylib

## ─── Linux ───────────────────────────────────────────────────────────────────

linux: $(PREBUILT)/linux/lib$(LIB_NAME).so  ## Build shared library for Linux
$(PREBUILT)/linux/lib$(LIB_NAME).so: $(GODIR)/*.go $(GODIR)/go.sum
	@mkdir -p $(dir $@)
	cd $(GODIR) && CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
	  $(GO) build $(GOFLAGS) -buildmode=c-shared -o $@ .

## ─── Windows ─────────────────────────────────────────────────────────────────

windows: $(PREBUILT)/windows/$(LIB_NAME).dll  ## Build DLL for Windows
$(PREBUILT)/windows/$(LIB_NAME).dll: $(GODIR)/*.go $(GODIR)/go.sum
	@mkdir -p $(dir $@)
	cd $(GODIR) && CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc \
	  $(GO) build $(GOFLAGS) -buildmode=c-shared -o $@ .

## ─── WASM ────────────────────────────────────────────────────────────────────

WEBDIR := $(CURDIR)/web

wasm: $(WEBDIR)/librsync.wasm  ## Build WASM module for Flutter Web
$(WEBDIR)/librsync.wasm: $(WASMDIR)/*.go $(WASMDIR)/go.sum
	@mkdir -p $(WEBDIR)
	cd $(WASMDIR) && GOOS=js GOARCH=wasm \
	  $(GO) build -trimpath -ldflags="-s -w" -o $@ .
	@WASM_EXEC=$$(find "$$($(GO) env GOROOT)" -name wasm_exec.js 2>/dev/null | head -1); \
	  if [ -n "$$WASM_EXEC" ]; then cp "$$WASM_EXEC" $(WEBDIR)/wasm_exec.js; \
	  else echo "NOTE: wasm_exec.js not found – copy it from your Go installation manually"; fi

## ─── Maintenance ─────────────────────────────────────────────────────────────

clean:  ## Remove all prebuilt artifacts and WASM files
	rm -rf $(PREBUILT)/android $(PREBUILT)/ios $(PREBUILT)/macos \
	       $(PREBUILT)/linux $(PREBUILT)/windows \
	       $(WEBDIR)/librsync.wasm $(WEBDIR)/wasm_exec.js

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*##"}; {printf "  %-20s %s\n", $$1, $$2}'
