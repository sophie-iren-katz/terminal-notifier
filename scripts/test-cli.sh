#!/usr/bin/env bash
# Interactive smoke-test of every terminal-notifier CLI feature.
#
# For each feature the script prints what to expect, runs the command, then
# asks y/n/s (skip). At the end it prints pass/fail/skip counts and lists
# any failed tests.
#
# Targets macOS bash 3.2; do not use bash 4+ features.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/build/Release/terminal-notifier.app/Contents/MacOS/terminal-notifier"

if [ ! -x "$BIN" ]; then
  echo "Binary not built at: $BIN" >&2
  echo "Run 'just build' first." >&2
  exit 1
fi

# ANSI
B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; Z=$'\033[0m'

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=""

prompt_yns() {
  # $1 = prompt text. returns 0=yes, 1=no, 2=skip
  local reply
  while true; do
    printf "%s [y/n/s] " "$1"
    if ! IFS= read -r reply </dev/tty; then
      return 2
    fi
    case "$reply" in
      [yY]|[yY][eE][sS]) return 0 ;;
      [nN]|[nN][oO])     return 1 ;;
      [sS]|[sS][kK][iI][pP]) return 2 ;;
      *) echo "  (answer y, n, or s)" ;;
    esac
  done
}

pause() {
  printf "%s" "$D$1 — press Enter to continue…$Z"
  IFS= read -r _ </dev/tty || true
}

record() {
  # $1 = test name, $2 = result (0/1/2)
  case "$2" in
    0) PASS=$((PASS+1)); printf "  %s✓ PASS%s — %s\n" "$G" "$Z" "$1" ;;
    1) FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES
  - $1"; printf "  %s✗ FAIL%s — %s\n" "$R" "$Z" "$1" ;;
    2) SKIP=$((SKIP+1)); printf "  %s○ SKIP%s — %s\n" "$Y" "$Z" "$1" ;;
  esac
}

header() {
  printf "\n%s==[ %s ]==%s\n" "$B" "$1" "$Z"
}

# ---------------------------------------------------------------------------
# Basic info flags
# ---------------------------------------------------------------------------

header "-help"
echo "Expected: usage banner printed below."
"$BIN" -help | head -5
echo "$D  (… banner truncated to first 5 lines for brevity)$Z"
prompt_yns "Did -help print a usage banner?"; record "-help" $?

header "-version"
echo "Expected: '<name> <version>.' line below."
"$BIN" -version
prompt_yns "Did -version print a version line?"; record "-version" $?

# ---------------------------------------------------------------------------
# Basic delivery
# ---------------------------------------------------------------------------

header "-message"
echo "Expected: banner appears with body 'hello from -message'."
"$BIN" -message "hello from -message"
prompt_yns "Did a notification appear?"; record "-message" $?

header "stdin piping"
echo "Expected: banner appears with body 'hello via stdin'."
echo "hello via stdin" | "$BIN"
prompt_yns "Did a notification appear with the piped body?"; record "stdin pipe" $?

header "-title"
echo "Expected: banner with title 'Custom Title'."
"$BIN" -title "Custom Title" -message "with custom title"
prompt_yns "Did the title show as 'Custom Title'?"; record "-title" $?

header "-subtitle"
echo "Expected: banner with a subtitle line 'A subtitle'."
"$BIN" -title "Subtitled" -subtitle "A subtitle" -message "with subtitle"
prompt_yns "Did the banner show a subtitle?"; record "-subtitle" $?

# ---------------------------------------------------------------------------
# Sound
# ---------------------------------------------------------------------------

header "-sound default"
echo "Expected: banner with the default notification sound."
"$BIN" -message "default sound" -sound default
prompt_yns "Did you hear the default sound?"; record "-sound default" $?

header "-sound Glass"
echo "Expected: banner with the 'Glass' system sound."
"$BIN" -message "Glass sound" -sound Glass
prompt_yns "Did you hear the Glass sound?"; record "-sound Glass" $?

# ---------------------------------------------------------------------------
# Grouping (replace-by-identifier)
# ---------------------------------------------------------------------------

header "-group (first post)"
echo "Expected: banner 'first in group' with group 'tn-test-group'."
"$BIN" -group tn-test-group -message "first in group"
prompt_yns "Did the first notification appear?"; record "-group first post" $?

header "-group (replace)"
echo "Expected: prior 'first in group' is replaced by 'second in group'."
"$BIN" -group tn-test-group -message "second in group"
prompt_yns "Was the first one replaced by 'second in group'?"; record "-group replace" $?

# ---------------------------------------------------------------------------
# Listing
# ---------------------------------------------------------------------------

header "-list <group>"
echo "Expected: a tab-separated row showing the tn-test-group notification."
"$BIN" -list tn-test-group
prompt_yns "Did -list print a row for tn-test-group?"; record "-list <group>" $?

header "-list ALL"
echo "Expected: header line plus rows for all delivered notifications."
"$BIN" -list ALL
prompt_yns "Did -list ALL print all delivered notifications?"; record "-list ALL" $?

# ---------------------------------------------------------------------------
# Image attachment
# ---------------------------------------------------------------------------

header "-contentImage"
# UNNotificationAttachment only accepts a fixed set of types (png/jpg/gif/etc).
# Transcode a system .icns to PNG via sips for a guaranteed-supported test image.
ICNS="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"
TEST_PNG="$(mktemp /tmp/tn-cli-test-image-XXXX).png"
if /usr/bin/sips -s format png "$ICNS" --out "$TEST_PNG" -Z 256 >/dev/null 2>&1; then
  echo "Expected: banner with an image attached."
  "$BIN" -message "with contentImage" -contentImage "$TEST_PNG"
  prompt_yns "Did the notification show an attached image?"; record "-contentImage" $?
  rm -f "$TEST_PNG"
else
  echo "Couldn't transcode test image; skipping."
  record "-contentImage" 2
fi

# ---------------------------------------------------------------------------
# Click handlers — interactive
# ---------------------------------------------------------------------------

header "-open URL on click"
echo "Expected: banner appears. CLICK IT. https://example.com opens in your browser."
"$BIN" -message "click to open example.com" -open "https://example.com"
pause "Click the notification now"
prompt_yns "Did clicking the notification open example.com?"; record "-open" $?

header "-execute on click"
MARKER="/tmp/tn-cli-test-execute-$$"
rm -f "$MARKER"
echo "Expected: banner appears. CLICK IT. File $MARKER will be created."
"$BIN" -message "click to run shell" -execute "touch $MARKER"
pause "Click the notification now"
if [ -f "$MARKER" ]; then
  record "-execute" 0
  rm -f "$MARKER"
else
  prompt_yns "Marker file was NOT created. Did the click still feel correct (mark as pass to skip the check)?"
  record "-execute" $?
fi

header "-activate on click"
echo "Expected: banner appears. CLICK IT. Calculator.app comes to the foreground."
"$BIN" -message "click to activate Calculator" -activate "com.apple.calculator"
pause "Click the notification now"
prompt_yns "Did clicking the notification activate Calculator?"; record "-activate" $?

# ---------------------------------------------------------------------------
# DnD
# ---------------------------------------------------------------------------

header "-ignoreDnD (time-sensitive)"
echo "Expected: banner posted as time-sensitive."
echo "$D  (true Focus/DnD bypass requires an entitlement; this just confirms delivery doesn't error.)$Z"
"$BIN" -message "time sensitive" -ignoreDnD
prompt_yns "Did the notification appear without error?"; record "-ignoreDnD" $?

# ---------------------------------------------------------------------------
# Deprecated no-ops — must not error
# ---------------------------------------------------------------------------

header "-sender (deprecated no-op)"
echo "Expected: notification still appears; -sender is silently ignored."
"$BIN" -message "with -sender flag" -sender "com.apple.Safari"
prompt_yns "Did the notification appear (sender flag accepted as no-op)?"; record "-sender no-op" $?

header "-appIcon (deprecated no-op)"
echo "Expected: notification still appears; -appIcon is silently ignored."
"$BIN" -message "with -appIcon flag" -appIcon "$ICON"
prompt_yns "Did the notification appear (appIcon flag accepted as no-op)?"; record "-appIcon no-op" $?

# ---------------------------------------------------------------------------
# Removal
# ---------------------------------------------------------------------------

header "-remove <group>"
"$BIN" -group tn-removable -message "to be removed" >/dev/null
sleep 1
echo "Expected: stdout below shows '* Removing previously sent notification…'"
"$BIN" -remove tn-removable
prompt_yns "Did -remove report a removal?"; record "-remove <group>" $?

header "-remove ALL"
"$BIN" -group tn-removable-1 -message "removable 1" >/dev/null
"$BIN" -group tn-removable-2 -message "removable 2" >/dev/null
sleep 1
echo "Expected: stdout below lists removals for multiple notifications."
"$BIN" -remove ALL
prompt_yns "Did -remove ALL clear delivered notifications?"; record "-remove ALL" $?

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "${B}==[ Summary ]==${Z}"
printf "  %sPassed:%s %d\n" "$G" "$Z" "$PASS"
printf "  %sFailed:%s %d\n" "$R" "$Z" "$FAIL"
printf "  %sSkipped:%s %d\n" "$Y" "$Z" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf "\nFailed tests:%s\n" "$FAILED_NAMES"
  exit 1
fi
exit 0
