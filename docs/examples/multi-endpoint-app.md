# Example: Multi-Endpoint App with Scope Filtering

A complete working example with two MCP HTTP endpoints — public and admin — each exposing different tools.

## Project Structure

```
my-app/
├── wippy.yaml
└── src/
    ├── _index.yaml
    ├── handlers/
    │   └── admin_mcp.lua
    └── tools/
        ├── echo.lua
        ├── add.lua
        ├── greet.lua
        ├── server_info.lua
        └── reset.lua
```

## wippy.yaml

```yaml
organization: myorg
module: my-app
description: App with public and admin MCP endpoints
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

  # ── Public tools (no scope — visible on ALL endpoints) ──

  - name: echo_tool
    kind: function.lua
    source: file://tools/echo.lua
    method: call
    meta:
      mcp.tool: true
      mcp.name: "echo"
      mcp.description: "Echo back the input text"
      mcp.inputSchema:
        type: "object"
        properties:
          text:
            type: "string"
            description: "Text to echo back"
        required:
          - "text"
      mcp.annotations:
        readOnlyHint: true

  - name: add_tool
    kind: function.lua
    source: file://tools/add.lua
    method: call
    meta:
      mcp.tool: true
      mcp.name: "add"
      mcp.description: "Add two numbers together"
      mcp.inputSchema:
        type: "object"
        properties:
          a:
            type: "number"
            description: "First number"
          b:
            type: "number"
            description: "Second number"
        required:
          - "a"
          - "b"
      mcp.annotations:
        readOnlyHint: true

  - name: greet_tool
    kind: function.lua
    source: file://tools/greet.lua
    method: call
    meta:
      mcp.tool: true
      mcp.name: "greet"
      mcp.description: "Greet someone by name with an optional style"
      mcp.inputSchema:
        type: "object"
        properties:
          name:
            type: "string"
            description: "Name to greet"
          style:
            type: "string"
            description: "Greeting style (formal, casual, pirate)"
            enum: ["formal", "casual", "pirate"]
        required:
          - "name"
      mcp.annotations:
        readOnlyHint: true

  # ── Admin-only tools (scoped — visible only on admin endpoint) ──

  - name: server_info_tool
    kind: function.lua
    source: file://tools/server_info.lua
    method: call
    meta:
      mcp.tool: true
      mcp.name: "server_info"
      mcp.description: "Get server status and version information"
      mcp.scope: "admin"
      mcp.annotations:
        readOnlyHint: true

  - name: reset_tool
    kind: function.lua
    source: file://tools/reset.lua
    method: call
    meta:
      mcp.tool: true
      mcp.name: "reset"
      mcp.description: "Reset application state (admin only)"
      mcp.scope: "admin"
      mcp.inputSchema:
        type: "object"
        properties:
          target:
            type: "string"
            description: "What to reset (cache, sessions, all)"
            enum: ["cache", "sessions", "all"]
      mcp.annotations:
        destructiveHint: true

  # ── Admin MCP handler (scoped to "admin") ─────────────

  - name: admin_mcp_handler
    kind: function.lua
    source: file://handlers/admin_mcp.lua
    method: handler
    modules:
      - http
      - json
    imports:
      handler: mcp:handler_lib
      jsonrpc: mcp:jsonrpc

  - name: admin_mcp_post
    kind: http.endpoint
    meta:
      router: app:api
    method: POST
    path: /admin/mcp
    func: app:admin_mcp_handler

  - name: admin_mcp_delete
    kind: http.endpoint
    meta:
      router: app:api
    method: DELETE
    path: /admin/mcp
    func: app:admin_mcp_handler
```

## Handler Files

### handlers/admin_mcp.lua

A custom handler that creates the MCP handler with `scope = "admin"`. This is the key difference from the default
endpoint — the scope parameter controls which tools are visible.

```lua
local http = require("http")
local json = require("json")
local jsonrpc = require("jsonrpc")
local handler = require("handler")

local h = nil
local session_counter = 0

local function new_session_id()
    session_counter = session_counter + 1
    return string.format("admin-%x%x", os.time(), session_counter)
end

local function get_handler()
    if h then return h end
    h = handler.new({
        name = "wippy-mcp-admin",
        version = "0.1.0",
        capabilities = { tools = true, prompts = true },
        scope = "admin"
    })
    return h
end

local function handle_post(req, res)
    local mcp = get_handler()

    local data, parse_err = req:body_json()
    if parse_err or not data or type(data) ~= "table" then
        res:set_status(400)
        return res:write_json({error = "Invalid JSON body"})
    end

    local msg = jsonrpc.classify(data)
    local session_id

    if msg.kind == "request" and msg.method == "initialize" then
        session_id = new_session_id()
        mcp:create_session(session_id)
    else
        session_id = req:header("Mcp-Session-Id")
        if not session_id or not mcp:get_session(session_id) then
            res:set_status(400)
            return res:write_json({error = "Missing or invalid Mcp-Session-Id header"})
        end
    end

    local response = mcp:dispatch(session_id, msg)

    if response then
        if msg.kind == "request" and msg.method == "initialize" then
            res:set_header("Mcp-Session-Id", session_id)
        end
        res:set_header("Content-Type", "application/json")
        res:write(response)
    else
        res:set_status(204)
    end
end

local function handle_delete(req, res)
    local mcp = get_handler()
    local session_id = req:header("Mcp-Session-Id")
    if not session_id then
        res:set_status(400)
        return res:write_json({error = "Missing Mcp-Session-Id header"})
    end
    if not mcp:get_session(session_id) then
        res:set_status(404)
        return res:write_json({error = "Session not found"})
    end
    mcp:delete_session(session_id)
    res:set_status(200)
end

local function handler_fn()
    local req = http.request()
    local res = http.response()
    local method = req:method()

    if method == "POST" then
        handle_post(req, res)
    elseif method == "DELETE" then
        handle_delete(req, res)
    else
        res:set_status(405)
        res:write_json({error = "Method not allowed"})
    end
end

return { handler = handler_fn }
```

## Tool Files

### tools/echo.lua

```lua
local function call(arguments)
    local text = arguments.text or ""
    return "Echo: " .. text
end

return { call = call }
```

### tools/add.lua

```lua
local function call(arguments)
    local a = tonumber(arguments.a) or 0
    local b = tonumber(arguments.b) or 0
    return tostring(a + b)
end

return { call = call }
```

### tools/greet.lua

```lua
local function call(arguments)
    local name = arguments.name or "World"
    local style = arguments.style or "casual"

    if style == "formal" then
        return "Good day, " .. name .. ". It is a pleasure to make your acquaintance."
    elseif style == "pirate" then
        return "Ahoy, " .. name .. "! Welcome aboard, matey!"
    else
        return "Hey, " .. name .. "!"
    end
end

return { call = call }
```

### tools/server_info.lua

```lua
local function call(arguments)
    return "Server: wippy-mcp v0.1.0 | uptime: running | status: healthy"
end

return { call = call }
```

### tools/reset.lua

```lua
local function call(arguments)
    local target = arguments.target or "cache"
    return "Reset completed for: " .. target
end

return { call = call }
```

## Running

```bash
wippy run
```

Starts HTTP server on `:8085` with two MCP endpoints.

## Endpoint Visibility

| Endpoint         | Scope    | Tools visible                                  |
|------------------|----------|------------------------------------------------|
| `/api/mcp`       | *(none)* | `echo`, `add`, `greet`                         |
| `/api/admin/mcp` | `admin`  | `echo`, `add`, `greet`, `server_info`, `reset` |

## Testing

### Public endpoint

```bash
# Initialize
curl -s -D - -X POST http://localhost:8085/api/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"public"},"protocolVersion":"2025-06-18"}}'

# List tools (returns: echo, add, greet)
curl -s -X POST http://localhost:8085/api/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# Calling admin tool on public endpoint → error
curl -s -X POST http://localhost:8085/api/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"reset","arguments":{"target":"cache"}}}'
# → {"error":{"code":-32602,"message":"Unknown tool: reset"}}
```

### Admin endpoint

```bash
# Initialize
curl -s -D - -X POST http://localhost:8085/api/admin/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"admin"},"protocolVersion":"2025-06-18"}}'

# List tools (returns: echo, add, greet, server_info, reset)
curl -s -X POST http://localhost:8085/api/admin/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# Call admin-only tool
curl -s -X POST http://localhost:8085/api/admin/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"reset","arguments":{"target":"cache"}}}'
# → {"content":[{"type":"text","text":"Reset completed for: cache"}],"isError":false}

# Call server_info
curl -s -X POST http://localhost:8085/api/admin/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"server_info","arguments":{}}}'
# → {"content":[{"type":"text","text":"Server: wippy-mcp v0.1.0 | uptime: running | status: healthy"}],"isError":false}
```

## Key Takeaways

1. **Unscoped tools are always visible** — `echo`, `add`, `greet` appear on both endpoints
2. **Scoped tools are restricted** — `server_info` and `reset` only appear on the admin endpoint
3. **Enforcement is at dispatch level** — calling `reset` on the public endpoint returns `"Unknown tool"`
4. **Sessions are independent** — each endpoint has its own handler instance and session pool
5. **Custom handler is a thin wrapper** — only difference from the default is `scope = "admin"` in `handler.new()`
