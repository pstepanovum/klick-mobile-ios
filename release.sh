#!/usr/bin/env bash
# Delegates to the canonical release script in klic-mobile-android, which
# builds both the Android APK and the iOS IPA, tags both repos, and publishes
# GitHub releases for each.
#
# Usage:
#   ./release.sh            # auto-bump patch version
#   ./release.sh 0.4.0      # explicit version
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "${SCRIPT_DIR}/../klic-mobile-android/release.sh" "$@"
