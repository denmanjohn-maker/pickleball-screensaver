BUNDLE     = PickleballScreensaver.saver
CONTENTS   = $(BUNDLE)/Contents
MACOS_DIR  = $(CONTENTS)/MacOS
RES_DIR    = $(CONTENTS)/Resources
BINARY     = $(MACOS_DIR)/PickleballScreensaver
SOURCES    = $(wildcard PickleballScreensaver/*.swift)
PLIST_SRC  = PickleballScreensaver/Info.plist
RESOURCES  = PickleballScreensaver/Resources/paddle.png \
             PickleballScreensaver/Resources/background.png \
             PickleballScreensaver/Resources/thumbnail.png \
             PickleballScreensaver/Resources/thumbnail@2x.png \
             PickleballScreensaver/Resources/drills.json
SDK        = $(shell xcrun --show-sdk-path)
# Universal binary so the saver runs on both Apple Silicon and Intel Macs.
ARCHS      = arm64 x86_64
BUILD_DIR  = build
ARCH_BINS  = $(foreach arch,$(ARCHS),$(BUILD_DIR)/$(arch)/PickleballScreensaver)
INSTALL_DIR = $(HOME)/Library/Screen\ Savers

VERSION    = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $(PLIST_SRC))
DIST_ZIP   = PickleballScreensaver-$(VERSION).zip
# Override for notarized releases, e.g. make dist SIGN_ID="Developer ID Application: Your Name (TEAMID)"
SIGN_ID   ?= -

PKG        = PickleballScreensaver-$(VERSION).pkg
DMG        = PickleballScreensaver-$(VERSION).dmg
PKG_ROOT   = pkgroot
DMG_ROOT   = dmgroot
PKG_ID     = com.pickleball.screensaver.pkg
PKG_INSTALL_DIR = /Library/Screen\ Savers
# Signing the pkg requires a *Developer ID Installer* certificate (distinct
# from Developer ID Application). Leave unset to build an unsigned pkg.
# e.g. make pkg INSTALLER_SIGN_ID="Developer ID Installer: Your Name (TEAMID)"
INSTALLER_SIGN_ID ?=

.PHONY: all clean install uninstall dist pkg dmg

all: $(BUNDLE)

$(BUILD_DIR)/%/PickleballScreensaver: $(SOURCES)
	@mkdir -p $(dir $@)
	swiftc \
		-sdk "$(SDK)" \
		-target "$*-apple-macos14.0" \
		-framework Cocoa \
		-framework ScreenSaver \
		-module-name PickleballScreensaver \
		$(SOURCES) \
		-emit-library \
		-Xlinker -bundle \
		-o "$@"

$(BUNDLE): $(ARCH_BINS) $(PLIST_SRC) $(RESOURCES)
	@mkdir -p $(MACOS_DIR) $(RES_DIR)
	lipo -create $(ARCH_BINS) -output "$(BINARY)"
	@cp $(PLIST_SRC) $(CONTENTS)/Info.plist
	@cp $(RESOURCES) $(RES_DIR)/
	@/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable PickleballScreensaver"       $(CONTENTS)/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.pickleball.screensaver"  $(CONTENTS)/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleName PickleballScreensaver"             $(CONTENTS)/Info.plist
	@echo "Built $(BUNDLE)"

install: $(BUNDLE)
	@mkdir -p $(INSTALL_DIR)
	cp -r $(BUNDLE) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)/$(BUNDLE)"
	@echo "Open System Settings → Screen Saver to enable it."

uninstall:
	rm -rf $(INSTALL_DIR)/$(BUNDLE)
	@echo "Uninstalled."

# Sign and zip the bundle for distribution. Ad-hoc signed by default;
# pass SIGN_ID="Developer ID Application: ..." to sign for notarization.
dist: $(BUNDLE)
ifeq ($(SIGN_ID),-)
	codesign --force --sign - "$(BUNDLE)"
else
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" "$(BUNDLE)"
endif
	codesign --verify --verbose=2 "$(BUNDLE)"
	ditto -c -k --keepParent "$(BUNDLE)" "$(DIST_ZIP)"
	@echo "Created $(DIST_ZIP)"

# Build a signed .saver and wrap it in a system installer package that
# places it in /Library/Screen Savers (all users) via Installer.app.
pkg: $(BUNDLE)
ifeq ($(SIGN_ID),-)
	codesign --force --sign - "$(BUNDLE)"
else
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" "$(BUNDLE)"
endif
	rm -rf "$(PKG_ROOT)"
	mkdir -p "$(PKG_ROOT)/Library/Screen Savers"
	cp -r "$(BUNDLE)" "$(PKG_ROOT)/Library/Screen Savers/"
ifeq ($(INSTALLER_SIGN_ID),)
	pkgbuild --root "$(PKG_ROOT)" --identifier $(PKG_ID) --version $(VERSION) \
		--install-location / "$(PKG)"
else
	pkgbuild --root "$(PKG_ROOT)" --identifier $(PKG_ID) --version $(VERSION) \
		--install-location / --sign "$(INSTALLER_SIGN_ID)" "$(PKG)"
endif
	rm -rf "$(PKG_ROOT)"
	@echo "Created $(PKG)"

# Wrap the installer package in a disk image for distribution.
dmg: pkg
	rm -rf "$(DMG_ROOT)"
	mkdir -p "$(DMG_ROOT)"
	cp "$(PKG)" "$(DMG_ROOT)/"
	rm -f "$(DMG)"
	hdiutil create -volname "PickleballScreensaver" -srcfolder "$(DMG_ROOT)" \
		-ov -format UDZO "$(DMG)"
	rm -rf "$(DMG_ROOT)"
	@echo "Created $(DMG)"

clean:
	rm -rf $(BUNDLE) $(BUILD_DIR) $(PKG_ROOT) $(DMG_ROOT) \
		PickleballScreensaver-*.zip PickleballScreensaver-*.pkg PickleballScreensaver-*.dmg
