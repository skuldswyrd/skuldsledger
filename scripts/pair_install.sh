#!/bin/bash
# Optional: auto-open Skuld's Ledger whenever TradingView (with CDP bridge) is up.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.skuld.ledger.tvpair.plist"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.skuld.ledger.tvpair</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$REPO_DIR/scripts/pair_with_tv.sh</string>
  </array>
  <key>StartInterval</key><integer>45</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "pairing agent installed — TradingView up = Ledger opens"
