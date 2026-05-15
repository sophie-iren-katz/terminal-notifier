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

# Build the app in Release configuration
build:
    xcodebuild -project "{{project}}" -configuration Release \
        SYMROOT="{{build_dir}}" \
        MACOSX_DEPLOYMENT_TARGET={{macos_deployment_target}}

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

# Install Ruby gem deps
ruby-setup:
    cd Ruby && bundle install

# Run the Ruby gem's RSpec suite
test:
    cd Ruby && bundle exec rake spec
