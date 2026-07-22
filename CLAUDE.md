# Skuld's Ledger — repo instructions

Native macOS SwiftUI trading journal. macOS 14+, GRDB via SPM, xcodegen project.

- **Fresh machine setup**: follow `INSTALL.md` exactly — it is the runbook.
- **Build**: `bash scripts/install.sh` (handles DEVELOPER_DIR, xcodegen, packaging to ~/Applications). Don't hand-roll xcodebuild invocations; the script is the source of truth.
- **Update an existing install**: `bash scripts/update.sh`.
- **User data is sacred and local**: `~/Desktop/Trading` (SQLite DB, screenshots, reports, the user's trading plan JSON). NEVER commit it, never copy it into the repo, never send it anywhere. The repo is code only.
- **No API keys, ever.** The in-app mentor shells out to the user's own authenticated `claude` CLI.
- **Plan values live in the user's `skuld_trading_operation.json`** (workspace, not repo) — parse live, never hardcode plan numbers into Swift.
- The word "fade" is banned in all UI/prompt text — use "reversal."
- Architecture notes for contributors: `CONTRACTS.md`.
