# MCP Server for Wippy

A [Model Context Protocol](https://modelcontextprotocol.io/) server that runs as a Wippy process, communicates over
stdio, and exposes tools to LLM clients (Claude Desktop, MCP Inspector, etc.).

Tools are **registry-native** — declared as standard Wippy `function.lua` entries with metadata and discovered
automatically. Adding a tool requires only a YAML entry and a Lua handler. No server code changes.

## Quick Start

```bash
wippy run -s -x mcp:server
```

Test with MCP Inspector:

```bash
npx @modelcontextprotocol/inspector wippy run -s -x mcp:server
```

### Claude Desktop Configuration

**Linux / macOS:**

```json
{
  "mcpServers": {
    "wippy": {
      "command": "wippy",
      "args": [
        "run",
        "-s",
        "-x",
        "mcp:server"
      ],
      "cwd": "/path/to/project"
    }
  }
}
```

**Windows (via WSL / bash):**

```json
{
  "mcpServers": {
    "wippy": {
      "command": "bash.exe",
      "args": [
        "-c",
        "cd /root/repos/wippy/gen3 && ./wippy run -s -x mcp:server"
      ]
    }
  }
}
```

### CLI Flags

| Flag              | Purpose                                                                                     |
|-------------------|---------------------------------------------------------------------------------------------|
| `-s` / `--silent` | **Required.** Suppresses runtime logs from stdout so they don't corrupt the JSON-RPC stream |
| `-x mcp:server`   | Execute the server process on the terminal host                                             |

### Supported MCP Methods

| Method                      | Type         | Description                            |
|-----------------------------|--------------|----------------------------------------|
| `initialize`                | request      | Handshake, returns server capabilities |
| `notifications/initialized` | notification | Client confirms initialization         |
| `ping`                      | request      | Health check, returns `{}`             |
| `tools/list`                | request      | List all discovered tools              |
| `tools/call`                | request      | Invoke a tool by name                  |

---

## Adding Tools

Tools are standard Wippy `function.lua` entries. The server discovers them automatically via registry metadata — no
server code changes required.

### 1. Create the handler

```lua
-- src/mytools/tools/greet.lua
local function call(arguments)
    local name = arguments.name or "World"
    return "Hello, " .. name .. "!"
end

return { call = call }
```

The function receives an `arguments` table and returns either:

- A **string** — wrapped in `{type: "text", text: "..."}` automatically
- A **table with `.content`** — passed through as-is (for multi-content responses)

### 2. Register in `_index.yaml`

```yaml
# src/mytools/_index.yaml
version: "1.0"
namespace: mytools

entries:
  - name: greet
    kind: function.lua
    source: file://tools/greet.lua
    method: call
    meta:
      mcp.tool: true
      mcp.name: "greet"
      mcp.description: "Greet someone by name"
      mcp.inputSchema:
        type: "object"
        properties:
          name:
            type: "string"
            description: "Name to greet"
        required:
          - "name"
      mcp.annotations:
        readOnlyHint: true
```

### 3. Done

The tool appears in `tools/list` and is callable via `tools/call`. It runs in Wippy's function execution context with
pool management and security.

### Metadata Reference

| Meta field        | Required | Description                                                                 |
|-------------------|----------|-----------------------------------------------------------------------------|
| `mcp.tool`        | yes      | Must be `true` for discovery                                                |
| `mcp.name`        | yes      | Tool name exposed to clients                                                |
| `mcp.description` | no       | Human-readable description                                                  |
| `mcp.inputSchema` | no       | JSON Schema for `arguments` validation                                      |
| `mcp.annotations` | no       | Hints: `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint` |

### Example Tools

Two demo tools are included in `src/examples/`:

**get_weather** — returns mock weather data for Paris, New York, Tokyo, London, Batumi (unknown locations get defaults):

```
tools/call → {"name": "get_weather", "arguments": {"location": "Paris"}}
         ← "Weather in Paris: 18°C, Partly Cloudy, Humidity: 72%"
```

**echo** — returns the input text:

```
tools/call → {"name": "echo", "arguments": {"text": "hello"}}
         ← "Echo: hello"
```

---

## Architecture

### Dispatch Flow

```
stdin ──▶ server.lua ──▶ jsonrpc.decode() ──▶ protocol.handle()
                                                 │
                                          ┌──────┴──────┐
                                          │ handled?    │
                                          │ (initialize,│
                                          │  ping)      │
                                          └──────┬──────┘
                                            no   │   yes ──▶ stdout
                                                 ▼
                                            tools.handle()
                                                 │
                                          ┌──────┴──────┐
                                          │ handled?    │
                                          │ (tools/list,│
                                          │  tools/call)│
                                          └──────┬──────┘
                                            no   │   yes ──▶ stdout
                                                 ▼
                                          METHOD_NOT_FOUND ──▶ stdout
```

The server uses a blocking `io.readline()` loop — one line in, one response out. When stdin closes (client disconnects),
the process exits cleanly with code 0.

### Module Dependency Graph

```
server.lua (process.lua)
├── imports: jsonrpc   ← mcp:jsonrpc
├── imports: protocol  ← mcp:protocol  ── imports: jsonrpc
└── imports: tools     ← mcp:tools_lib ── imports: jsonrpc
                                          modules: registry, funcs
```

All shared code uses Wippy's `library.lua` entries wired through `imports`. Each library declares only the modules it
needs.

### Project Structure

```
src/mcp/
├── _index.yaml      Registry: terminal.host, libraries, server process
├── jsonrpc.lua      JSON-RPC 2.0 codec (encode/decode/error helpers)
├── protocol.lua     MCP handshake state machine (initialize → ready)
├── tools.lua        Tool discovery via registry + tools/list & tools/call dispatch
├── server.lua       Main process: stdin loop → dispatch chain → stdout
└── README.md

src/examples/        Demo tools (separate namespace, zero coupling to server)
├── _index.yaml      Tool entries with MCP metadata
└── tools/
    ├── weather.lua
    └── echo.lua
```

### Modules

**jsonrpc.lua** — JSON-RPC 2.0 codec. No MCP-specific logic.

Encoding (all return JSON strings):

- `encode_response(id, result)` — success response
- `encode_error(id, code, message, data?)` — error response
- `encode_notification(method, params?)` — notification (no `id`)

Decoding — `decode(line)` parses and classifies into `kind="request"`, `kind="notification"`, or `kind="invalid"`. Never
throws.

Error helpers with pre-filled codes: `parse_error`, `invalid_request`, `method_not_found`, `invalid_params`,
`internal_error`, `server_error`.

**protocol.lua** — MCP connection lifecycle. State machine: `disconnected` → `ready`.

`new_server(config)` creates a handler. `server.handle(msg)` dispatches `initialize`, `ping`,
`notifications/initialized`. Returns `nil` for unknown methods so the caller can try tools.

**tools.lua** — Tool discovery and dispatch via Wippy's registry.

`discover()` finds all `function.lua` entries where `meta["mcp.tool"] == true`. `handle(msg)` dispatches `tools/list`and
`tools/call`, invoking tools via `funcs.call()`. Tool errors are returned as `isError: true` in the result (per MCP
spec), not as JSON-RPC errors.

**server.lua** — Main process. Reads stdin line by line, runs through jsonrpc → protocol → tools dispatch chain, writes
responses to stdout.

### Protocol Details

- **MCP version**: `2025-06-18`
- **Transport**: stdio (newline-delimited JSON)
- **Capabilities advertised**: `tools` (with `listChanged: false`)
- **Tool errors**: Returned as `isError: true` in `CallToolResult`, not as JSON-RPC errors
- **Empty object encoding**: Wippy's `json.encode({})` produces `[]`. The jsonrpc module applies a `string.gsub`
  workaround to fix `"result":[]` → `"result":{}` for ping and capabilities.
