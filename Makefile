# Convenience targets. scripts/test.sh remains the green gate.
DERIVED  := build/DerivedData
PRODUCTS := $(DERIVED)/Build/Products
APP      := $(PRODUCTS)/Debug/BookBook.app

# `make install`: Release build copied to /Applications. Signed with your
# Apple Development identity when App/Config/Local.xcconfig exists (so Keychain
# "Always Allow" survives reinstalls), ad-hoc otherwise.
REL_APP        := $(PRODUCTS)/Release/BookBook.app
INSTALL_DIR    := /Applications
INSTALLED_APP  := $(INSTALL_DIR)/BookBook.app
LOCAL_XCCONFIG := App/Config/Local.xcconfig
LSREGISTER     := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# $(call xcbuild,<configuration>[,<extra xcodebuild args>]): through xcbeautify when installed.
xcbuild = set -o pipefail; xcodebuild -project BookBook.xcodeproj -scheme BookBook \
          -destination 'platform=macOS' -derivedDataPath $(DERIVED) -configuration $(1) $(2) build 2>&1 \
          | (command -v xcbeautify >/dev/null && xcbeautify || cat)

.PHONY: build run project clean install

build:
	@$(call xcbuild,Debug)

run: build
	open $(APP)

install:
	@if pgrep -qf '$(INSTALLED_APP)/Contents/MacOS/BookBook'; then \
	  echo "BookBook is running from $(INSTALL_DIR). Quit it, then re-run make install."; exit 1; fi
	@$(call xcbuild,Release,$(if $(wildcard $(LOCAL_XCCONFIG)),-xcconfig $(LOCAL_XCCONFIG)))
	@/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' $(REL_APP)/Contents/Info.plist >/dev/null \
	  && test -f $(REL_APP)/Contents/Resources/AppIcon.icns \
	  || { echo "Built app has no AppIcon; refusing to install."; exit 1; }
	rm -rf '$(INSTALLED_APP)'
	ditto '$(REL_APP)' '$(INSTALLED_APP)'
	@# Forget the DerivedData copies so the Dock and Finder resolve the bundle ID
	@# to the installed app, then re-register it and bump its mtime so the icon
	@# cache picks up the current icon.
	@for a in $(CURDIR)/$(PRODUCTS)/*/BookBook.app; do $(LSREGISTER) -u "$$a" 2>/dev/null || true; done
	$(LSREGISTER) -f -R -trusted '$(INSTALLED_APP)'
	touch '$(INSTALLED_APP)'
	@echo "Installed $(INSTALLED_APP)"

# Regenerate BookBook.xcodeproj after editing project.yml (commit both).
project:
	xcodegen generate --spec project.yml

clean:
	rm -rf $(DERIVED)
