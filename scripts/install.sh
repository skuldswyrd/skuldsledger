#!/bin/bash
# Skuld's Ledger — build + install. Safe to re-run any time.
# Usage: bash scripts/install.sh [--launch]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

echo "== Skuld's Ledger installer =="

# Full Xcode is required (SwiftUI app build) — Command Line Tools alone won't cut it.
if [ ! -d "/Applications/Xcode.app" ]; then
  echo "ERROR: Xcode not found at /Applications/Xcode.app."
  echo "Install Xcode from the App Store, open it once to accept the license, then re-run."
  exit 1
fi
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "-- installing xcodegen via Homebrew"
    brew install xcodegen
  else
    echo "ERROR: xcodegen missing and Homebrew not installed."
    echo "Install Homebrew (https://brew.sh) then re-run, or: brew install xcodegen"
    exit 1
  fi
fi

echo "-- generating Xcode project"
xcodegen generate

echo "-- building Release (first build resolves GRDB via SPM — takes a few minutes)"
xcodebuild -project SkuldsLedger.xcodeproj -scheme SkuldsLedger \
  -configuration Release -derivedDataPath build build | grep -E "error:|BUILD" || true

APP_SRC="build/Build/Products/Release/Skulds Ledger.app"
if [ ! -d "$APP_SRC" ]; then
  echo "ERROR: build did not produce the app. Scroll up for xcodebuild errors."
  exit 1
fi

echo "-- installing to ~/Applications"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Skulds Ledger.app"
cp -R "$APP_SRC" "$HOME/Applications/Skulds Ledger.app"

# The app finds its own repo clone here for self-updates.
defaults write com.skuld.SkuldsLedger repoPath "$REPO_DIR"

# Workspace: everything the app writes lives here, locally, forever.
WORKSPACE="$HOME/Desktop/Trading"
mkdir -p "$WORKSPACE/Records" "$WORKSPACE/Reports"
if [ ! -f "$WORKSPACE/skuld_trading_operation.json" ]; then
  cp "$REPO_DIR/skuld_trading_operation.sample.json" "$WORKSPACE/skuld_trading_operation.json"
  echo "-- sample trading plan copied to $WORKSPACE/skuld_trading_operation.json (EDIT IT — it's YOUR plan)"
fi

echo "== installed: ~/Applications/Skulds Ledger.app =="
if [ "${1:-}" = "--launch" ] || [ "${1:-}" = "--relaunch" ]; then
  open "$HOME/Applications/Skulds Ledger.app"
fi
