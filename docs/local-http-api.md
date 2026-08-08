# Local HTTP API

OpenUsage exposes a read-only HTTP API on the loopback interface so other local apps can consume the same usage data shown in the menu bar.

**Base URL:** `http://127.0.0.1:6736` (same machine) or `http://<your-lan-ip>:6736` from phones/tablets on your Wi‑Fi.

The server binds to localhost and every active IPv4 address on your machine. On Windows the shell also tries to add a firewall rule for TCP 6736.

The server starts automatically with the app. If the port is already in use, the feature is silently disabled for that session.

## Routes

### `GET /` or `GET /dashboard`

Serves a built-in web dashboard that shows the same usage data as the menu bar, in a card layout with
progress bars. The page auto-refreshes every 30 seconds and updates the browser tab title with a compact
summary of your top metrics.

Open **http://127.0.0.1:6736/** on this PC, or **http://&lt;your-lan-ip&gt;:6736/** from another device on the same network (e.g. `http://192.168.1.108:6736/`).

### `GET /v1/usage`

Returns the latest snapshots for all **enabled** providers, in your dashboard order.

- **200 OK** — JSON array (may be empty `[]` if nothing has been fetched yet).

### `GET /v1/usage/:providerId`

Returns the latest snapshot for one provider. Works for disabled providers too.

- **200 OK** — JSON object.
- **204 No Content** — provider is known but has no snapshot yet.
- **404 Not Found** — provider ID is unknown.

### Everything else

Methods other than `GET`/`OPTIONS` return **405**; unknown routes return **404**. When the server is already handling its maximum of 16 concurrent connections, requests get **503** — back off and retry.

## Response shape

```jsonc
{
  "providerId": "claude",
  "displayName": "Claude",
  "plan": "Team 5x",
  "lines": [
    {
      "type": "progress",
      "label": "Session",
      "used": 42.0,
      "limit": 100.0,
      "format": { "kind": "percent" },          // or "dollars", or "count" (+ "suffix")
      "resetsAt": "2026-03-26T13:00:00.161Z",   // optional
      "periodDurationMs": 18000000,             // optional
      "color": null
    },
    {
      "type": "text",
      "label": "Today",
      "value": "$5.17 · 9.2M tokens",
      "color": null,
      "subtitle": null
    },
    {
      "type": "badge",
      "label": "Pay as you go",
      "text": "2500 cap",
      "color": "#22c55e",
      "subtitle": null
    },
    {
      "type": "barChart",
      "label": "Usage Trend",
      "points": [
        { "label": "Mar 25", "value": 1200000.0, "valueLabel": "1.2M tokens" },
        { "label": "Mar 26", "value": 2400000.0, "valueLabel": "2.4M tokens" }
      ],
      "note": "Estimated from local Claude logs at API rates.",
      "color": null
    }
  ],
  "fetchedAt": "2026-03-26T11:16:29.000Z"
}
```

Line types are `progress`, `text`, `badge`, and `barChart`. A `barChart` line carries a `points` array — one `{ label, value, valueLabel? }` per day, oldest first — plus an optional `note`; `value` is the day's token count, `valueLabel` its pre-formatted readout, and `label` a localized month/day (e.g. "Mar 25"). `fetchedAt` is when the snapshot was last fetched successfully (ISO 8601).

The in-app model breakdown shown when hovering spend rows is not included in this API yet. Spend rows continue to serialize as the same `text` lines so existing local integrations keep their current shape.

## Errors

```json
{ "error": "provider_not_found" }
```

Codes: `provider_not_found`, `not_found`, `method_not_allowed`, `server_busy`.

## CORS and privacy

All responses include permissive CORS headers (`Access-Control-Allow-Origin: *`, methods `GET, OPTIONS`). `OPTIONS` requests return **204** for preflight.

The server listens on localhost and your machine's LAN IPv4 addresses. Anyone on the same network who can reach port 6736 can read your usage snapshots (the same numbers shown in the menu bar) — no credentials are served, but treat this like sharing your dashboard on Wi‑Fi. CORS is permissive (`Access-Control-Allow-Origin: *`) so a browser tab can call the API from any origin.

## Caching behavior

The API serves whatever the app is showing: only successful fetches replace data, so a failed refresh never blanks the API — you keep getting the last good snapshot. See [Refreshing & caching](refreshing.md).
