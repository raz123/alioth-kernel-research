#!/usr/bin/env bash
# Basic post-boot probe: kernel sanity, network, Android responsiveness.
# Returns 0 on pass.
set -uo pipefail

fail() { echo "PROBE FAIL: $*"; exit 1; }

# /proc/version embeds KBUILD_BUILD_USER (uname -a does not). Confirm our build.
adb shell cat /proc/version 2>/dev/null | grep -q "claude@research" || fail "/proc/version does not show 'claude@research' (rebuild marker)"

# Basic adb features
adb shell id | grep -q "uid=0" || fail "adb not root"
adb shell getprop sys.boot_completed | grep -q "1" || fail "boot not completed"

# No kernel BUG/oops in dmesg.
# Use word boundaries to avoid matching "debug" / "ramoops" / "mtdoops".
if adb shell 'dmesg 2>/dev/null | grep -E "BUG: |Unable to handle kernel|Kernel panic|\\bOops\\b"' | grep -q .; then
  echo "WARNING: dmesg shows potential kernel issues:"
  adb shell 'dmesg 2>/dev/null | grep -E "BUG: |Unable to handle kernel|Kernel panic|\\bOops\\b"' | head -5
  fail "dmesg shows kernel issues"
fi

echo "PROBE PASS: boot-smoke"
