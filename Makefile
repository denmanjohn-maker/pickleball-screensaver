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

.PHONY: all clean install uninstall dist

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

clean:
	rm -rf $(BUNDLE) $(BUILD_DIR) PickleballScreensaver-*.zip
