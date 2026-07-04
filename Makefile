BUNDLE     = PickleballScreensaver.saver
CONTENTS   = $(BUNDLE)/Contents
MACOS_DIR  = $(CONTENTS)/MacOS
RES_DIR    = $(CONTENTS)/Resources
BINARY     = $(MACOS_DIR)/PickleballScreensaver
SOURCES    = PickleballScreensaver/PickleballScreensaverView.swift
PLIST_SRC  = PickleballScreensaver/Info.plist
RESOURCES  = PickleballScreensaver/Resources/paddle.png
SDK        = $(shell xcrun --show-sdk-path)
ARCH       = $(shell uname -m)
TARGET     = $(ARCH)-apple-macos14.0
INSTALL_DIR = $(HOME)/Library/Screen\ Savers

.PHONY: all clean install uninstall

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

install: $(BUNDLE)
	@mkdir -p $(INSTALL_DIR)
	cp -r $(BUNDLE) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)/$(BUNDLE)"
	@echo "Open System Settings → Screen Saver to enable it."

uninstall:
	rm -rf $(INSTALL_DIR)/$(BUNDLE)
	@echo "Uninstalled."

clean:
	rm -rf $(BUNDLE)
