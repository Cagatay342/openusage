# OpenCode

Tracks your OpenCode **Go** subscription usage — the rolling 5-hour, weekly, and monthly quota windows
OpenCode itself shows on its dashboard.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Go usage in the rolling 5-hour window (percent) |
| Weekly | Go usage this week (percent) |
| Monthly | Go usage this billing cycle (percent) |

All three meters are **account-wide** — the same percents the OpenCode dashboard shows, including usage
from other machines. A period with no usage yet still shows its real percent from the API.

## Where credentials come from

Use OpenCode as usual. OpenUsage reads the `opencode-go` API key from OpenCode's local data directory and
sends it as a Bearer token to the usage API. There's no login prompt and no token to paste.

| Platform | Data directory |
|---|---|
| macOS / Linux | `~/.local/share/opencode/auth.json` (respects `$OPENCODE_DATA_DIR` and `$XDG_DATA_HOME`) |
| Windows | `%USERPROFILE%\.local\share\opencode\auth.json` |

## Setup

1. Log into OpenCode Go (`opencode auth login`, or the OpenCode console).
2. OpenUsage detects the `opencode-go` key and enables the provider on the next refresh.

## Under the hood

- `GET https://opencode.ai/zen/go/v1/usage` with the `opencode-go` key as `Authorization: Bearer …`.
  The response is `{ usage: { rolling, weekly, monthly } }`, each with `percent` and `resetsAt` — the
  same percents OpenCode's own console shows. A 401 (`AuthError`) is a rejected key; a 403
  (`EntitlementError`) means the key is valid but the account has no Go subscription.

## Troubleshooting

- **"OpenCode not detected"** — no `opencode-go` key was found. Log in with `opencode auth login`.
- **"OpenCode Go key was rejected"** — the local key was not accepted (401). Log into OpenCode Go again
  so `auth.json` is rewritten.
- **"No OpenCode Go subscription on this key"** — the key is valid, but this account isn't on Go.
- **"Couldn't read OpenCode's auth.json"** — the file exists but is unreadable or not valid JSON. Check
  its permissions, or log into OpenCode Go again to rewrite it.
