#!/usr/bin/env bash
# Shared helper for the local spike scripts (sl2-run.sh, sl3-run.sh). Source it; don't run it.
# No keys, no network: these spikes are local only.

# make_app_bundle <executable> <app-path> <bundle-id> <name>
# Wraps a built executable in a minimal .app (Info.plist + MacOS/<name>) and ad-hoc signs it,
# so LaunchServices, activation and window restoration treat it as a real app.
make_app_bundle() {
  local exe="$1" app="$2" bundle_id="$3" name="$4"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$exe" "$app/Contents/MacOS/$name"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
  codesign --force --sign - "$app" >/dev/null 2>&1 || true
  # Make sure LaunchServices knows about the (re)built bundle.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" >/dev/null 2>&1 || true
}
