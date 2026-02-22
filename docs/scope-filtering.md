# Scope Filtering

Scope filtering controls which tools and prompts are visible on each MCP endpoint. This is useful when running multiple
MCP endpoints that expose different sets of tools (e.g., admin vs. public).

## How It Works

Each tool or prompt can optionally declare `mcp.scope` in its metadata. Each MCP handler can optionally be created
with a `scope` parameter. Visibility is determined by these rules:

- Tools/prompts **without** `mcp.scope` are visible on **all** endpoints (both scoped and unscoped)
- Tools/prompts **with** `mcp.scope` are **only** visible on endpoints whose handler has a **matching** scope
- An **unscoped** endpoint (no scope configured) only sees **unscoped** tools/prompts
- Calling a scoped tool on the wrong endpoint returns `"Unknown tool"` (JSON-RPC error -32602)

### Visibility Matrix

| Tool has `mcp.scope`? | Endpoint has scope? | Scopes match? | Visible? |
|-----------------------|---------------------|---------------|----------|
| No                    | No                  | —             | Yes      |
| No                    | Yes (`"admin"`)     | —             | Yes      |
| Yes (`"admin"`)       | No                  | —             | **No**   |
| Yes (`"admin"`)       | Yes (`"admin"`)     | Yes           | Yes      |
| Yes (`"admin"`)       | Yes (`"billing"`)   | No            | **No**   |

## Declaring Scoped Tools

Add `mcp.scope` to the tool's metadata:

```yaml
# Admin-only tool — hidden from unscoped and non-admin endpoints
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
          enum: ["cache", "sessions", "all"]
    mcp.annotations:
      destructiveHint: true

# Public tool — visible on all endpoints
- name: echo_tool
  kind: function.lua
  source: file://tools/echo.lua
  method: call
  meta:
    mcp.tool: true
    mcp.name: "echo"
    mcp.description: "Echo back the input"
    mcp.annotations:
      readOnlyHint: true
```

## Declaring Scoped Prompts

Same pattern applies to prompts:

```yaml
- name: admin_prompt
  kind: function.lua
  source: file://prompts/static.lua
  method: get
  meta:
    mcp.prompt: true
    mcp.prompt.name: "admin_prompt"
    mcp.prompt.description: "Admin-only prompt"
    mcp.scope: "admin"
    mcp.prompt.messages:
      - role: "user"
        content: "You are an admin assistant."
```

## Default MCP Endpoint (Unscoped)

The MCP server module registers a default endpoint at `/mcp` with no scope. This endpoint only sees tools and prompts
that have **no** `mcp.scope` set.

## Creating a Scoped Endpoint

To add a second MCP endpoint with a specific scope, the host application creates a custom handler file that initializes
the MCP handler with `scope`:

### 1. Create the handler file

```lua
-- handlers/admin_mcp.lua
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
        scope = "admin"    -- This is the key line
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

### 2. Register in `_index.yaml`

```yaml
# Admin MCP handler function
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

# Admin MCP endpoints
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

### Result

| Endpoint         | Scope    | Sees                                       |
|------------------|----------|--------------------------------------------|
| `/api/mcp`       | *(none)* | `echo` (unscoped tools only)               |
| `/api/admin/mcp` | `admin`  | `echo` + `reset` (unscoped + admin-scoped) |

## Stdio Transport

The stdio transport has no scope by default — it only sees unscoped tools and prompts. To add scope to the stdio
transport, modify the handler constructor in `server.lua`:

```lua
local h = handler.new({
    name = "wippy-mcp",
    version = "0.1.0",
    capabilities = { tools = true, prompts = true },
    scope = "admin"    -- now sees admin-scoped tools too
})
```

## See Also

- [Multi-Endpoint Example](examples/multi-endpoint-app.md) — complete working example
- [Architecture](architecture.md) — handler library internals
