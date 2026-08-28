# OpenUsage on Linux (experimental)

OpenUsage for Linux is a **headless daemon**, not a desktop app. There is no menu bar and no window: the
daemon reads the provider credentials already on your machine, refreshes them on a timer, and serves the
same web dashboard and JSON API the macOS app serves at [`docs/local-http-api.md`](local-http-api.md).

You look at your usage in a browser at **http://127.0.0.1:6736**.

The macOS menu-bar app in `Sources/OpenUsage/` is unchanged. The Linux daemon shares the headless core
under `spikes/windows-core/` with the Windows sidecar — the folder name is historical; the package builds
on macOS, Windows and Linux.

## Status

| Area | State |
|---|---|
| Providers | Claude, Codex, Cursor, Antigravity, Grok, OpenRouter, Z.ai |
| UI | Web dashboard only (`GET /`) — no desktop UI |
| API | Full `/v1/usage` parity with macOS; identical wire format |
| Refresh | Every 5 minutes (`--interval`), no manual trigger yet |
| Service | `systemd --user` unit, restart on failure |
| Packaging | Build from source; no distro packages |
| Copilot / Devin | Not in the shared core yet |

## Install

Requires a **Swift 6.2+** toolchain ([swift.org/install/linux](https://swift.org/install/linux)) and,
optionally, `sqlite3` for Cursor's desktop state DB.

```bash
sudo apt install -y sqlite3          # optional, see "Cursor" below
script/install_linux_daemon.sh
```

That builds a release binary, installs it to `~/.local/share/openusage/`, links
`~/.local/bin/openusage-daemon`, and enables a `systemd --user` service. Nothing needs root.

```bash
systemctl --user status openusage      # is it running
journalctl --user -u openusage -f      # live logs
```

Pass `--no-service` to install only the binary.

**Logging out stops the service** unless user lingering is enabled:

```bash
sudo loginctl enable-linger "$USER"
```

## Running it directly

```bash
openusage-daemon --help
openusage-daemon --port 6736 --interval 300
```

| Option | Default | Meaning |
|---|---|---|
| `--port <n>` | `6736` | TCP port |
| `--listen <ipv4>` | `127.0.0.1` | Address to bind — anything but loopback requires a token |
| `--interval <sec>` | `300` | Seconds between refreshes (minimum 30) |
| `--token <secret>` | none | Require this token on every request |

Unknown, repeated, or malformed options are rejected — the daemon never starts with a silently ignored
typo like `--intrval 30`.

## Reaching it from another machine

Your usage, spend, and plan are personal. On the default loopback bind only processes on this machine can
connect, so no token is needed.

### The safe way: an SSH tunnel

Nothing is exposed, and no token is involved:

```bash
ssh -N -L 6736:127.0.0.1:6736 you@your-server
# then open http://127.0.0.1:6736 on your laptop
```

### Binding a routable address

`--listen 0.0.0.0` (or a specific interface) makes the API reachable from other machines, so the daemon
**refuses to start without a token**:

```bash
OPENUSAGE_TOKEN="$(openssl rand -hex 32)" openusage-daemon --listen 0.0.0.0
```

Prefer the environment variable: command-line arguments are visible to every user on the machine through
`ps` and `/proc`. Then either open `http://<host>:6736/?token=<token>` — the daemon sets an `HttpOnly`,
`SameSite=Strict` cookie so the dashboard's own requests keep working — or send
`Authorization: Bearer <token>`. Anything else gets **401**. Tokens are compared in constant time.

### Exposing it on a public host

If the machine has a public IP and you want the dashboard reachable at `http://<host>:6736`, put the
token in a file only your user can read rather than in the unit or on the command line — unit files and
process arguments are both world-readable:

```bash
mkdir -p ~/.config/openusage
umask 077
printf 'OPENUSAGE_TOKEN=%s\n' "$(openssl rand -hex 24)" > ~/.config/openusage/daemon.env
```

Then point the service at it and bind a routable address:

```ini
# ~/.config/systemd/user/openusage.service
EnvironmentFile=%h/.config/openusage/daemon.env
ExecStart=/home/<user>/.local/share/openusage/openusage-daemon --listen 0.0.0.0
```

```bash
systemctl --user daemon-reload && systemctl --user restart openusage
sudo ufw allow 6736/tcp comment 'OpenUsage dashboard (token required)'
```

Open `http://<host>:6736/?token=<token>` once; the cookie keeps the tab working afterwards.

**Know what this trades away.** The token is the only thing standing between the open internet and your
usage data, and it travels in **cleartext HTTP** — anyone able to observe the connection sees the token
and the data. Tokens never reach the logs (query strings are redacted), but the transport is not
protected. For anything beyond a convenience dashboard, put a TLS reverse proxy in front of the loopback
port, or restrict the firewall rule to known source addresses:

```bash
sudo ufw allow from <your-ip> to any port 6736 proto tcp
```

### No CORS headers

Unlike the macOS app, the Linux daemon never sends `Access-Control-Allow-Origin`. A wildcard CORS header
on a loopback API is an open door: any website you happen to visit could read
`http://127.0.0.1:6736/v1/usage` from your browser. The bundled dashboard is same-origin and does not need
it, and non-browser clients (curl, scripts, native apps) are unaffected. *(The macOS app still sends `*` —
worth revisiting there.)*

## How credentials are discovered

OpenUsage reads credentials already on your machine. Paths only; no secrets are logged.

| Provider | Where the daemon looks |
|---|---|
| **Claude** | `~/.claude/.credentials.json` |
| **Codex** | `~/.codex/auth.json` (respects `CODEX_HOME`) |
| **Cursor** | `~/.config/cursor/auth.json` (the `cursor-agent` CLI), or `~/.config/Cursor/User/globalStorage/state.vscdb` (desktop app, needs `sqlite3`) |
| **Antigravity** | `~/.gemini/antigravity-cli/antigravity-oauth-token`, written by the `agy` CLI |
| **Grok** | `~/.grok/auth.json` and `~/.grok/logs/unified.jsonl` |
| **OpenRouter** | `~/.aider/oauth-keys.env`, `~/.env`, `~/.aider.conf.yml`, `$OPENROUTER_API_KEY`, `~/.config/openusage/openrouter.json`, `~/.config/openrouter/key.json` |
| **Z.ai** | `$ZAI_API_KEY` / `$Z_AI_API_KEY`, or `~/.config/openusage/zai.json` |

A provider with no credentials is simply left out — `/v1/usage/<id>` returns **204**.

The daemon must run as the user who owns those files. Never run it as root, and never point it at another
user's home: a usage viewer is not a credential collector.

### Cursor

`cursor-agent` stores its tokens in plain JSON, so Cursor works without `sqlite3`. The desktop app stores
them in a VS Code SQLite database instead; reading that needs the `sqlite3` binary on `PATH`. OpenUsage
opens it **read-only** and never writes to it. If `sqlite3` is missing, the daemon logs a warning once and
carries on.

### Antigravity

Run `agy` once and sign in. On macOS and Windows the token lives in the OS keyring; on Linux the CLI
writes it to a file, which is what the daemon reads. There is no Secret Service integration.

## Where files go (XDG)

| What | Path |
|---|---|
| Logs | `$XDG_STATE_HOME/OpenUsage/logs/OpenUsage.log` (default `~/.local/state/…`) |
| Pricing cache | `$XDG_DATA_HOME/OpenUsage/pricing/` (default `~/.local/share/…`) |
| Antigravity token cache | `$XDG_STATE_HOME/OpenUsage/antigravity/auth.json` |
| Binary + resources | `~/.local/share/openusage/` |
| systemd unit | `~/.config/systemd/user/openusage.service` |

Like the macOS app, the daemon writes **rotated OAuth tokens back** to `~/.claude`, `~/.codex` and
`~/.grok` so your CLIs stay signed in. The shipped systemd unit therefore does not use
`ProtectSystem=strict` or `ProtectHome`: a read-only home would break token refresh silently as tokens
expire.

## Differences vs macOS

| macOS | Linux |
|---|---|
| Menu bar + popover | Web dashboard only |
| Binds loopback **and** every LAN address | Binds **loopback only** unless `--listen` is passed |
| `Access-Control-Allow-Origin: *` always | Never sends CORS headers |
| No authentication | Token required for any non-loopback bind |
| Settings, Customize, pins, shortcuts | None — `--port` / `--listen` / `--interval` / `--token` |
| Sparkle auto-update | None; rebuild from source |
| Notifications | None |
| 9 providers | 7 (no Copilot, no Devin) |

## Known limitations

- Cursor's rotated access token is not persisted (OpenUsage does not write to `cursor-agent`'s file), so
  an expired token triggers one extra refresh call per cycle.
- When a refresh fails after a provider has succeeded once, the daemon keeps serving the last good
  metrics and appends an error badge so the card is visibly stale rather than silently wrong. The macOS
  app carries that state in a separate channel the shared HTTP API does not expose, so on Linux it rides
  along in `lines`. A dedicated error field on `LocalUsageAPI` would be the cleaner fix on both platforms.
- No auto-update, no packaging, no manual refresh endpoint.
- Copilot and Devin are not wired into the shared core yet.

## Building and testing manually

```bash
cd spikes/windows-core
swift build --product openusage-daemon
swift test
```

Linux-specific regressions (XDG paths, the POSIX HTTP transport, the file-based Cursor and Antigravity
credential sources) live in `Tests/OpenUsageCoreTests/LinuxDaemonTests.swift`.
