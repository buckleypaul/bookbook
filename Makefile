# Convenience targets. scripts/test.sh remains the green gate.
DERIVED := build/DerivedData
APP     := $(DERIVED)/Build/Products/Debug/BookBook.app
XCB     := xcodebuild -project BookBook.xcodeproj -scheme BookBook \
           -destination 'platform=macOS' -derivedDataPath $(DERIVED) -configuration Debug

.PHONY: build run project clean

build:
	@set -o pipefail; $(XCB) build 2>&1 | (command -v xcbeautify >/dev/null && xcbeautify || cat)

run: build
	open $(APP)

# Regenerate BookBook.xcodeproj after editing project.yml (commit both).
project:
	xcodegen generate --spec project.yml

clean:
	rm -rf $(DERIVED)
