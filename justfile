set shell := ["bash", "-cu"]

project := "Terminal Notifier.xcodeproj"
build_dir := justfile_directory() / "build"
app := build_dir / "Release/terminal-notifier.app"
bin := app / "Contents/MacOS/terminal-notifier"

default:
    @just --list

# Minimum macOS the built binary will run on. Bumped from the project's
# baked-in 10.10 because modern Xcode SDKs no longer ship libarclite for
# pre-10.13 deployment targets, which breaks linking.
macos_deployment_target := "10.13"

# Give the dev build a distinct bundle ID so it doesn't collide with a
# Homebrew install (both ship 'fr.julienxx.oss.terminal-notifier'). Without
# this, clicking a notification posted by the dev build can launch the
# Homebrew copy via Launch Services and the click handler never runs.
dev_bundle_id := "fr.julienxx.oss.terminal-notifier.dev"

# Build the app in Release configuration
build:
    xcodebuild -project "{{project}}" -configuration Release \
        SYMROOT="{{build_dir}}" \
        MACOSX_DEPLOYMENT_TARGET={{macos_deployment_target}} \
        OTHER_LDFLAGS='$(inherited) -framework UserNotifications'
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier {{dev_bundle_id}}" "{{app}}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName terminal-notifier (dev)" "{{app}}/Contents/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleName string terminal-notifier (dev)" "{{app}}/Contents/Info.plist"
    codesign --force --sign - "{{app}}"
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "{{app}}"

# Remove build artifacts
clean:
    rm -rf "{{build_dir}}"

# Run the freshly built binary; forwards args, e.g. `just run -message hi`
run *ARGS: build
    "{{bin}}" {{ARGS}}

# Send a quick smoke-test notification
smoke: build
    "{{bin}}" -title "terminal-notifier (dev)" -message "build OK"

# Print the absolute path to the built binary (useful for aliasing)
which: build
    @echo "{{bin}}"

