#!/bin/bash
# TV-Ledger pairing: TradingView CDP bridge up + Ledger not running -> open Ledger.
# Installed as a LaunchAgent by pair_install.sh. Totally optional.
if curl -s --max-time 2 http://localhost:9222/json/version >/dev/null 2>&1; then
  if ! pgrep -xq "Skulds Ledger"; then
    open "$HOME/Applications/Skulds Ledger.app"
  fi
fi
