# Skuld's Ledger

**A live trading session journal that works like an X feed — with an AI mentor in your corner.**


## What it is

Skuld's Ledger is a native macOS app for futures day traders. It's not a post-hoc trade log — it's a running feed you build **while the session happens**:

1. `cmd+s` a TradingView chart → the screenshot lands in the composer automatically
2. Caption it ("What are you seeing?"), one-tap tags (action / play / level), **Post**
3. An AI mentor replies to every post — checks your read against *your written trading plan*, sanity-checks the level, reminds you where the discipline counter stands
4. Live "poker stats" sidebar: trades vs. daily max, P&L vs. plan, win rate by play type and level strength
5. End of day: one click compiles the full annotated session report

### The mentor

Every post gets a mentor read powered by Claude, through the **Claude Code CLI you already have installed and signed into**. No API keys in the app, no separate billing, no cloud backend. The mentor reads *your* plan file and *your* chart screenshot and answers in seconds. If it's offline, the journal keeps working — entries never block.

### Your data never leaves your machine

- Journal database: local SQLite file in your workspace folder
- Screenshots: local files, moved into a dated archive as you post
- Reports: local markdown
- No telemetry, no sync, no accounts, nothing phones home
- Updates come **to** you: the app checks this GitHub repo, and one click pulls + rebuilds locally

## The system it serves

Built around a level-based futures method (NQ/MNQ, ES/MES): ranked structural levels from volume profile (POC / value area / session extremes), traded toward and away from with fixed tick targets and stops, hard trade-count discipline. The plan lives in a JSON file the app parses live — edit the plan, the app follows.

The companion TradingView indicator ships in this repo too — **[indicator/](indicator/)** — same ranked levels drawn and scored on the chart, one alert covering every play, alert text that pastes straight into the trade sheet. App and indicator update from this single location.

You don't have to trade this exact method — edit `skuld_trading_operation.json` to your own numbers and plays.

## Requirements

- macOS 14+
- Full Xcode (free, App Store) — the app builds locally on your machine
- Homebrew + xcodegen (the installer handles this)
- [Claude Code](https://claude.ai/code) with an active Claude subscription — powers the install AND the mentor

## Install

See **[START_HERE.md](START_HERE.md)**. Short version: install Claude Code, paste one prompt, it does the rest.

## Updating

The app checks this repo on launch. When an update ships, an amber **Update** button appears in the toolbar — one click pulls the latest code, rebuilds locally, and relaunches. Or run `bash scripts/update.sh` yourself. Data untouched either way.

---

*Patience is the edge. The journal is the proof. The mentor is watching.*
