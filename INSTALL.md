# INSTALL.md — agent runbook

You are Claude Code setting up **Skuld's Ledger** (native macOS SwiftUI trading journal) on this machine. Follow in order. The user is likely non-technical — explain what you're doing in one line per step, and show exact errors when something fails.

## Preconditions (check, don't assume)

1. macOS 14+ (`sw_vers -productVersion`). Below 14 → stop, the app won't run.
2. **Full Xcode** at `/Applications/Xcode.app` (`ls /Applications/Xcode.app`). Command Line Tools alone are NOT enough. Missing → tell the user to install Xcode from the App Store and open it once, then resume. Do not try to install Xcode yourself.
3. First build: run `sudo xcodebuild -license accept` if the license blocks (needs the user's password — have THEM run it).
4. Homebrew (`command -v brew`). Missing → give the user the official install command from https://brew.sh to run themselves (it needs their password), then continue.

## Install

From the repo root (`~/skuldsledger`):

```bash
bash scripts/install.sh --launch
```

The script: checks Xcode, installs xcodegen via brew if missing, generates the Xcode project, builds Release (first build pulls the GRDB package — a few minutes), installs to `~/Applications/Skulds Ledger.app`, registers the repo path for self-updates, creates the `~/Desktop/Trading` workspace, copies the sample trading plan if none exists, and opens the app.

If the build fails, read the xcodebuild errors from the output, fix, and re-run the script. Do not hand the user a broken install.

## Verify

- `pgrep -x "Skulds Ledger"` → running
- `~/Desktop/Trading/Records/` exists; `skuld_journal.sqlite` appears after the app opens
- App shows the pre-session setup screen (dark theme, "PRE-SESSION SETUP")

## Walk the user through (manual, their hands)

1. **TradingView screenshot folder**: TradingView chart → save-image settings → point downloads/chart-grabs at `~/ChartGrabsTradingView` (create the folder: `mkdir -p ~/ChartGrabsTradingView`). Different folder is fine: `defaults write com.skuld.SkuldsLedger tvInboxDir "<absolute path>"`, then relaunch the app.
2. **Trading plan**: open `~/Desktop/Trading/skuld_trading_operation.json`. It's a SAMPLE. Have them set: instruments, target/stop ticks, max trades per day, starting capital. The app and the AI mentor read this file live — it is the single source of truth.
3. **Mentor check**: the mentor uses the `claude` CLI this very session is running on — it's already installed and authenticated. Confirm `command -v claude` from a normal shell (not just this session). If the app later shows "claude CLI not found," the binary isn't on a standard path — symlink it: `ln -s "$(command -v claude)" /usr/local/bin/claude` (or /opt/homebrew/bin).
4. **Optional pairing**: `bash scripts/pair_install.sh` — auto-opens the Ledger whenever TradingView (with its debug bridge) is running. Skip if they don't use the TradingView bridge.

## Privacy rules (tell the user, and obey them yourself)

- All journal data is local: `~/Desktop/Trading` (SQLite + screenshots + reports). Never commit, upload, or sync it anywhere.
- The repo contains code only. `git pull` brings updates in; nothing goes out.
- Never add API keys to this app. The mentor rides the user's own Claude Code login.

## Updates (for later sessions)

`bash scripts/update.sh` — or the in-app amber Update button, which runs the same script. Pull, rebuild, relaunch. Data untouched.
