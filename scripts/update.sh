#!/bin/bash
# Skuld's Ledger — self-update: pull latest code, rebuild, reinstall, relaunch.
# Journal data (DB, screenshots, reports, plan) is never touched.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

echo "== Skuld's Ledger update $(date) =="

# Wait for the app to finish quitting so the bundle can be replaced.
for _ in $(seq 1 20); do
  pgrep -xq "Skulds Ledger" || break
  sleep 1
done

git pull --ff-only
bash "$REPO_DIR/scripts/install.sh" --relaunch
echo "== update complete =="
