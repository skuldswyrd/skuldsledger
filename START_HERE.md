# START HERE — get Skuld's Ledger running in ~15 minutes

Three steps. Step 3 is copy-paste and the machine does the work.

## Step 0 — one manual thing first

Install **Xcode** from the Mac App Store (free, big download — start it now). Open it once after install and accept the license. Everything else is automated.

## Step 1 — install Claude Code

Open Terminal (⌘-space, type "Terminal") and run:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Then run `claude` once and sign in with your Claude account when it asks. (You need a Claude subscription — this also powers the in-app mentor.)

## Step 2 — nothing. There is no step 2.

## Step 3 — paste this prompt into Claude Code

Run `claude` in Terminal and paste this whole block:

```
Clone https://github.com/skuldswyrd/skuldsledger.git into ~/skuldsledger (install git via the Xcode command line tools prompt if needed). Then read ~/skuldsledger/INSTALL.md and follow it exactly to set up Skuld's Ledger on this Mac: verify Xcode and Homebrew, run scripts/install.sh --launch, and confirm the app opened. Walk me through the two manual settings at the end of INSTALL.md (my TradingView screenshot folder and editing my trading plan file). If anything fails, show me the exact error and fix it.
```

That's it. Claude Code installs dependencies, builds the app locally, puts **Skulds Ledger** in `~/Applications`, creates your `~/Desktop/Trading` workspace with a sample trading plan, and launches it.

## After install — 2 minutes of setup (+ the chart indicator)

0. **TradingView indicator**: open `~/skuldsledger/indicator/Skuld_Unified.pine`, paste it into TradingView's Pine Editor, add to chart, and create one alert on "Any alert() function call". Full guide: [indicator/README.md](indicator/README.md). When the repo updates the indicator, re-paste the same file.

1. **TradingView screenshots**: in TradingView, set your chart-image save folder to `~/ChartGrabsTradingView` (or any folder — tell the app via `defaults write com.skuld.SkuldsLedger tvInboxDir "<path>"`). Every `cmd+s` then lands straight in the composer.
2. **Your plan**: edit `~/Desktop/Trading/skuld_trading_operation.json` — targets, stops, max trades, plays. The app and the mentor read it live. It ships as a sample; make it yours.

## Daily use

Open the app (or install the optional TradingView pairing: `bash ~/skuldsledger/scripts/pair_install.sh` — the Ledger opens itself whenever TradingView is up). Start the session, post your reads, log your trades, generate the report at the close.

## Updates

When Skuld ships an update you'll see an amber **Update** button in the toolbar. Click it — pulls from GitHub, rebuilds on your machine, relaunches. Your journal data is never touched, and never leaves your Mac.

## Something broke?

In Terminal: `cd ~/skuldsledger && claude` and paste: `Skuld's Ledger is broken. Here's what happened: <describe it>. Read the repo, diagnose, and fix my local install.`
