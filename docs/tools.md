# Adding Tools

Tools are standard Wippy `function.lua` entries. The MCP server discovers them automatically via registry metadata — no
server code changes required.

## 1. Create the Handler

A tool handler is a Lua function that receives an `arguments` table and returns a result.

```lua
-- tools/greet.lua
local function call(arguments)
    local name = arguments.name or "World"
    return "Hello, " .. name .. "!"
end

return { call = call }
```

### Return Values

| Return type             | Behavior                                               |
|-------------------------|--------------------------------------------------------|
| `string`                | Wrapped automatically as `{type: "text", text: "..."}` |
| `table` with `.content` | Passed through as-is (for multi-content responses)     |
| anything else           | Converted to string via `tostring()`                   |

### Multi-content Response

```lua
local function call(arguments)
    return {
        content = {
            {type = "text", text = "Here is the result:"},
            {type = "text", text = arguments.data}
        }
    }
end
```

### Error Handling

Tool errors are returned as `isError: true` in the MCP result (not as JSON-RPC errors). If your handler function
returns an error as the second value from `funcs.call()`, it is automatically wrapped:

```json
{"content": [{"type": "text", "text": "error message"}], "isError": true}
```

## 2. Register in `_index.yaml`

```yaml
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

## Metadata Reference

| Meta field        | Required | Description                                                                                                                                          |
|-------------------|----------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| `mcp.tool`        | yes      | Must be `true` for discovery                                                                                                                         |
| `mcp.name`        | yes      | Tool name exposed to clients                                                                                                                         |
| `mcp.description` | no       | Human-readable description                                                                                                                           |
| `mcp.inputSchema` | no       | JSON Schema for `arguments` validation                                                                                                               |
| `mcp.annotations` | no       | Hints: `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`                                                                          |
| `mcp.scope`       | no       | Scope tag — tool is only visible on endpoints with matching scope. Unscoped tools are visible everywhere. See [scope filtering](scope-filtering.md). |

## Annotations

Annotations provide hints to MCP clients about tool behavior:

```yaml
mcp.annotations:
  readOnlyHint: true        # Tool does not modify state
  destructiveHint: false     # Tool is not destructive
  idempotentHint: true       # Safe to call multiple times
  openWorldHint: false       # Tool has no external side effects
```

## Using Wippy Modules

Tools can use any Wippy module declared in `_index.yaml`:

```yaml
- name: db_query
  kind: function.lua
  source: file://tools/db_query.lua
  method: call
  modules: [sql, json, logger]
  imports:
    db: app:database
  meta:
    mcp.tool: true
    mcp.name: "db_query"
    mcp.description: "Run a read-only SQL query"
```

```lua
local sql = require("sql")
local db = require("db")
local json = require("json")

local function call(arguments)
    local query = arguments.query
    local rows, err = sql.query(db, query)
    if err then
        return {
            content = {{type = "text", text = "Query error: " .. tostring(err)}},
            isError = true
        }
    end
    return json.encode(rows)
end

return { call = call }
```
