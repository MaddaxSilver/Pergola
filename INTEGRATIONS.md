# Showing your apps in Pergola

Any app, script or AI agent on this Mac can put a **live activity** in the notch: an icon, a title,
a status line and a progress ring. Closed, the notch shows the icon and ring beside it; open, the
Files page lists everything running (click a task to jump to its app).

Switch it on or off in **Settings › Integrations**.

## The API

Pergola listens on `http://127.0.0.1:47600` (this Mac only). If that port is taken it uses the next
free one and writes it to `~/Library/Application Support/Pergola/api.json`.

| Request | What it does |
| --- | --- |
| `POST /activity` | Create or update. Only `id` is required; fields you leave out keep their last value. |
| `DELETE /activity/<id>` | Remove straight away. |
| `GET /activities` | List what's showing. |
| `GET /health` | Check Pergola is running. |

Fields for `POST /activity` (send `Content-Type: application/json`):

| Field | Meaning |
| --- | --- |
| `id` | Your name for the task. Reuse it for every update. |
| `app`, `title`, `detail` | Who, what, and what's happening right now. |
| `progress` | 0 to 1 (or 0 to 100). Leave out, or send `null`, for a spinner. |
| `step`, `total_steps` | Alternative to `progress`: steps finished out of a total. |
| `state` | `running` (default), `waiting` (needs the user), `done`, `failed`. Done and failed show for 5 seconds, then go. |
| `symbol` | SF Symbol name for the icon. |
| `bundle_id` | Show this app's own icon instead of a symbol. |
| `tint` | Ring colour as hex, e.g. `#34C759`. |
| `ttl` | Seconds without an update before a running activity is dropped (default 600). |
| `rings` | Up to four goals drawn as concentric rings instead of one progress ring: `[{"label": "Crypto", "value": "$4.20 / $10", "progress": 0.42, "tint": "#5BBF6A"}]`. `progress` 1 is the goal; below 0 the ring runs backwards in red. An activity with rings is standing information: it gives way to real tasks beside the closed notch. |
| `quiet` | `true` to arrive and change without a caption under the notch. |

```bash
curl -s http://127.0.0.1:47600/activity -H 'Content-Type: application/json' \
  -d '{"id":"export-1","app":"CamCam","title":"Exporting video","detail":"Rendering","progress":0.4,"symbol":"film"}'
```

Requests from web pages are refused (anything with an `Origin` header).

## From a Swift app

Copy [`integrations/PergolaActivity.swift`](integrations/PergolaActivity.swift) into the app:

```swift
let export = PergolaActivity(id: "export-\(UUID())", app: "CamCam", title: "Exporting video",
                             bundleID: Bundle.main.bundleIdentifier)
export.update(detail: "Rendering", progress: 0.4)
export.finish()
```

Sandboxed apps need the **Outgoing Connections (Client)** capability.

## From a script

```bash
/Applications/Pergola.app/Contents/MacOS/Pergola --activity '{"id":"backup","title":"Backing up","progress":0.2}'
/Applications/Pergola.app/Contents/MacOS/Pergola --end-activity backup
```

## Claude

**Claude Code progress (automatic).** Settings › Integrations › *Claude Code Progress* › Connect adds
hooks to `~/.claude/settings.json`. From then on each Claude Code session shows what Claude is doing
("Editing NotchViews.swift", "Running tests"), fills the ring as it works through its task list,
turns orange when it needs you, and ticks when it finishes.

**Other AI tools (ChatGPT, Codex, Gemini, Cursor, Copilot…).** Each gets its own mark in the notch:
its real app icon when that app is installed, otherwise a symbol in its colour. Pergola works out
who is calling from the MCP client's name, or from `app` when a tool posts through the API or CLI:

```bash
/Applications/Pergola.app/Contents/MacOS/Pergola --activity '{"id":"gpt-1","app":"ChatGPT","title":"Drafting the report","progress":0.3}'
```

Recognised names: Claude, ChatGPT / Codex / OpenAI, Gemini, Copilot, Cursor, Windsurf, Grok, Perplexity,
Mistral, DeepSeek, Ollama / LM Studio. Sending your own `symbol`, `tint` or `bundle_id` overrides the mark.
To connect one over MCP, give it the stdio command below (for example `codex mcp add pergola -- /Applications/Pergola.app/Contents/MacOS/Pergola --mcp`).

**MCP (Claude posts its own activities).** Pergola is an MCP server with three tools:
`show_activity`, `end_activity`, `list_activities`.

- Claude Code: `claude mcp add --transport http --scope user pergola http://127.0.0.1:47600/mcp`
- Claude Desktop and other stdio clients: command `/Applications/Pergola.app/Contents/MacOS/Pergola`, argument `--mcp`
