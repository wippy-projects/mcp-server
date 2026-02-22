# Example: HTTP App with MCP Endpoint

An app that runs an HTTP server and exposes MCP tools over both stdio and HTTP transports.

## Project Structure

```
my-http-app/
├── wippy.yaml
└── src/
    ├── _index.yaml
    └── tools/
        └── time.lua
```

## wippy.yaml

```yaml
organization: myorg
module: my-http-app
description: HTTP app with MCP endpoint
license: MIT
```

## src/_index.yaml

```yaml
version: "1.0"
namespace: app

entries:
  # ── Dependencies ──────────────────────────────────────

  - name: dep.mcp
    kind: ns.dependency
    component: butschster/mcp-server
    version: "*"
    parameters:
      - name: router
        value: app:api

  # ── Infrastructure ────────────────────────────────────

  - name: terminal
    kind: terminal.host
    lifecycle:
      auto_start: true

  - name: gateway
    kind: http.service
    addr: ":8085"
    lifecycle:
      auto_start: true

  - name: api
    kind: http.router
    meta:
      server: app:gateway
    prefix: /api

  # ── Tools ─────────────────────────────────────────────

  - name: time_tool
    kind: function.lua
    source: file://tools/time.lua
    method: call
    modules: [time]
    meta:
      mcp.tool: true
      mcp.name: "current_time"
      mcp.description: "Returns the current date and time"
      mcp.annotations:
        readOnlyHint: true
```

## tools/time.lua

```lua
local time = require("time")

local function call(arguments)
    local now = time.now()
    return "Current time: " .. tostring(now)
end

return { call = call }
```

## Running

```bash
wippy run
```

This starts:

- HTTP server on `:8085`
- MCP endpoint at `/api/mcp` (POST, GET, DELETE)
- Stdio transport via `wippy run -s -x mcp:server`

## Testing the HTTP Endpoint

**1. Initialize a session:**

```bash
curl -s -D - -X POST http://localhost:8085/api/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "clientInfo": {"name": "curl-test", "version": "1.0"},
      "protocolVersion": "2025-06-18"
    }
  }'
```

Response headers include `Mcp-Session-Id: <id>`.

Response body:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "tools": {"listChanged": false},
      "prompts": {"listChanged": false}
    },
    "serverInfo": {"name": "wippy-mcp", "version": "0.1.0"}
  }
}
```

**2. Send initialized notification:**

```bash
curl -s -X POST http://localhost:8085/api/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc": "2.0", "method": "notifications/initialized"}'
```

Returns 204 No Content.

**3. List tools:**

```bash
curl -s -X POST http://localhost:8085/api/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}'
```

**4. Call a tool:**

```bash
curl -s -X POST http://localhost:8085/api/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "current_time", "arguments": {}}}'
```

**5. Close the session:**

```bash
curl -s -X DELETE http://localhost:8085/api/mcp \
  -H "Mcp-Session-Id: <SESSION_ID>"
```

Returns 200 OK. Subsequent requests with the same session ID are rejected with 400.

## Key Points

- The `parameters: [{name: router, value: app:api}]` on the dependency wires the MCP HTTP endpoints to your router
- The router prefix (`/api`) is prepended to the MCP path (`/mcp`), giving you `/api/mcp`
- Both transports (stdio and HTTP) discover the same tools from the registry
