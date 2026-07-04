BUNDLE     = PickleballScreensaver.saver
CONTENTS   = $(BUNDLE)/Contents
MACOS_DIR  = $(CONTENTS)/MacOS
RES_DIR    = $(CONTENTS)/Resources
BINARY     = $(MACOS_DIR)/PickleballScreensaver
SOURCES    = $(wildcard PickleballScreensaver/*.swift)
PHOTOSYNC_APP = PickleballPhotoSync.app
PHOTOSYNC_CONTENTS = $(PHOTOSYNC_APP)/Contents
PHOTOSYNC_MACOS_DIR = $(PHOTOSYNC_CONTENTS)/MacOS
PHOTOSYNC_BINARY = $(PHOTOSYNC_MACOS_DIR)/PickleballPhotoSync
PHOTOSYNC_SOURCES = $(wildcard PhotoSync/*.swift) PickleballScreensaver/PhotoSyncShared.swift
PLIST_SRC  = PickleballScreensaver/Info.plist
PHOTOSYNC_PLIST_SRC = PhotoSync/Info.plist
RESOURCES  = PickleballScreensaver/Resources/paddle.png \
             PickleballScreensaver/Resources/thumbnail.png \
             PickleballScreensaver/Resources/thumbnail@2x.png
SDK        = $(shell xcrun --show-sdk-path)
ARCH       = $(shell uname -m)
TARGET     = $(ARCH)-apple-macos14.0
INSTALL_DIR = $(HOME)/Library/Screen\ Savers
PHOTOSYNC_INSTALL_DIR = $(HOME)/Applications

.PHONY: all clean install uninstall photosync install-photosync uninstall-photosync

all: $(BUNDLE)

$(BUNDLE): $(SOURCES) $(PLIST_SRC) $(RESOURCES)
	@mkdir -p $(MACOS_DIR) $(RES_DIR)
	swiftc \
		-sdk "$(SDK)" \
		-target "$(TARGET)" \
		-framework Cocoa \
		-framework ScreenSaver \
		-module-name PickleballScreensaver \
		$(SOURCES) \
		-emit-library \
		-Xlinker -bundle \
		-o "$(BINARY)"
	@cp $(PLIST_SRC) $(CONTENTS)/Info.plist
	@cp $(RESOURCES) $(RES_DIR)/
	@/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable PickleballScreensaver"       $(CONTENTS)/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.pickleball.screensaver"  $(CONTENTS)/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleName PickleballScreensaver"             $(CONTENTS)/Info.plist
	@echo "Built $(BUNDLE)"

photosync: $(PHOTOSYNC_APP)

$(PHOTOSYNC_APP): $(PHOTOSYNC_SOURCES) $(PHOTOSYNC_PLIST_SRC)
	@mkdir -p $(PHOTOSYNC_MACOS_DIR)
	swiftc \
		-sdk "$(SDK)" \
		-target "$(TARGET)" \
		-framework Cocoa \
		-framework Photos \
		-framework ServiceManagement \
		-module-name PickleballPhotoSync \
		$(PHOTOSYNC_SOURCES) \
		-o "$(PHOTOSYNC_BINARY)"
	@cp $(PHOTOSYNC_PLIST_SRC) $(PHOTOSYNC_CONTENTS)/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable PickleballPhotoSync"          $(PHOTOSYNC_CONTENTS)/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.pickleball.photosync"      $(PHOTOSYNC_CONTENTS)/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleName Pickleball Photo Sync"               $(PHOTOSYNC_CONTENTS)/Info.plist
	@echo "Built $(PHOTOSYNC_APP)"

install: $(BUNDLE)
	@mkdir -p $(INSTALL_DIR)
	cp -r $(BUNDLE) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)/$(BUNDLE)"
	@echo "Open System Settings → Screen Saver to enable it."

install-photosync: $(PHOTOSYNC_APP)
	@mkdir -p $(PHOTOSYNC_INSTALL_DIR)
	cp -R $(PHOTOSYNC_APP) $(PHOTOSYNC_INSTALL_DIR)/
	@echo "Installed to $(PHOTOSYNC_INSTALL_DIR)/$(PHOTOSYNC_APP)"

uninstall:
	rm -rf $(INSTALL_DIR)/$(BUNDLE)
	@echo "Uninstalled."

uninstall-photosync:
	rm -rf $(PHOTOSYNC_INSTALL_DIR)/$(PHOTOSYNC_APP)
	@echo "Uninstalled Photo Sync."

clean:
	rm -rf $(BUNDLE) $(PHOTOSYNC_APP)
