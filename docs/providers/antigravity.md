# Antigravity

Tracks pool quotas for Antigravity (Google's AI IDE) and the headless **`agy` CLI** using credentials the app or CLI already stored on your machine. (Google ships the binary as **`agy`**, not `agt`.)

## What it tracks

Antigravity has two shared quota pools, and each pool has two windows — a rolling 5-hour window and a weekly window:

| Metric | Meaning |
|---|---|
| Session | The shared Gemini pool (Pro and Flash draw from the same quota), rolling 5-hour window |
| Weekly | The same Gemini pool's weekly window |
| Claude | The shared non-Gemini pool (Claude, GPT-OSS, …), rolling 5-hour window |
| Claude Weekly | The same non-Gemini pool's weekly window |
| Plan | Your subscription tier, e.g. `Pro` or `Ultra` (optional widget) |

Gemini Pro and Gemini Flash are one pool: using either model drains the same quota, so OpenUsage shows one meter per window instead of separate Pro and Flash meters. That pair is named Session and Weekly to match the other providers' rows. Every non-Gemini model shares the second pool, shown under the Claude name (like Codex's Spark pair). Quotas are reported as a fraction (full = 0% used), so there are no token or dollar spend tiles.

While a pool's rolling 5-hour window has no usage yet, that meter reads **Not started** on the trailing label instead of a reset countdown; hover explains that the session begins after your first message. The weekly meters always show a normal reset countdown.

## Where credentials come from

OpenUsage never asks for a token — it reads what Antigravity already has:

- **macOS — Antigravity running** — OpenUsage talks to the app's local language server (the richest source, and where the plan name comes from).
- **macOS — App closed** — it falls back to the OAuth token Antigravity / `agy` store in your macOS Keychain and queries Google's Cloud Code API. An expired token is refreshed automatically (OpenUsage never writes back to Antigravity's own keychain item).
- **Windows (experimental spike)** — Credential Manager entry `gemini:antigravity`, written when you sign in to the Antigravity IDE or run **`agy`** locally. OpenUsage reads that token and calls Cloud Code over HTTPS. Install `agy` from [google-antigravity/antigravity-cli](https://github.com/google-antigravity/antigravity-cli); the Windows installer puts it at `%LOCALAPPDATA%\agy\bin\agy.exe`. No extra environment variables are required — just run `agy` once and complete the browser sign-in.

If neither is available you'll see *Start Antigravity or run `agy` and try again.*

## Troubleshooting

- **"Start Antigravity or run `agy`…"** — sign in to the Antigravity app (or run `agy`) so a usable token exists, then refresh.
- **The weekly meters show "No data"** — your Antigravity build doesn't expose the quota-summary endpoint yet (only newer builds do). The 5-hour meters still work from the older endpoints; updating Antigravity brings the weekly meters back.
- **A meter shows "No data"** — that pool/window wasn't in the latest response (some tiers only report certain windows). The other meters still update.
- **Where did the Gemini Pro and Flash meters go?** — merged: both models draw from the one shared Gemini pool, which is now the single Session meter.
- **Quotas look full after heavy use** — the 5-hour windows reset on a rolling basis and the weekly windows once a week; the reset time is shown on each meter.

## Under the hood

Best source first: the local language server discovered by scanning for the `language_server` / `agy` process and reading its CSRF token and listening ports; then Google Cloud Code using the Keychain token, refreshed via Google OAuth when needed. On each source OpenUsage asks the quota-summary endpoint first (`RetrieveUserQuotaSummary` on the language server, `v1internal:retrieveUserQuotaSummary` on Cloud Code) — the only endpoint that reports the merged pools and the weekly windows. Newer builds may return per-model bucket IDs (e.g. `gemini-3.5-flash-low`, `claude-sonnet-4-6`) instead of the older merged keys (`gemini-5h`, `3p-weekly`); OpenUsage rolls those into the same four Session / Weekly / Claude meters. Builds without it fall back to the legacy per-model endpoints (`GetUserStatus` / `GetCommandModelConfigs` locally, `fetchAvailableModels` / `retrieveUserQuota` remotely), whose per-model quotas are merged into the two pools by keeping each pool's worst remaining fraction; those endpoints only know the 5-hour windows. The plan name prefers Antigravity's own `userTier` over the inherited Windsurf plan field.

> Reverse-engineered from the app and language-server binary; endpoints and storage may change without notice.
