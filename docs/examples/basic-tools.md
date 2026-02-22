# Example: Basic Tools

A minimal app that exposes three simple tools to MCP clients.

## Project Structure

```
my-app/
├── wippy.yaml
└── src/
    ├── _index.yaml
    └── tools/
        ├── echo.lua
        ├── add.lua
        └── greet.lua
```

## wippy.yaml

```yaml
organization: myorg
module: my-app
description: App with MCP tools
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

  # ── Infrastructure ────────────────────────────────────

  - name: terminal
    kind: terminal.host
    lifecycle:
      auto_start: true

  # ── Tools ─────────────────────────────────────────────

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
            description: "Greeting style"
            enum: ["formal", "casual", "pirate"]
        required:
          - "name"
      mcp.annotations:
        readOnlyHint: true
```

## tools/echo.lua

```lua
local function call(arguments)
    local text = arguments.text or ""
    return "Echo: " .. text
end

return { call = call }
```

## tools/add.lua

```lua
local function call(arguments)
    local a = tonumber(arguments.a) or 0
    local b = tonumber(arguments.b) or 0
    return tostring(a + b)
end

return { call = call }
```

## tools/greet.lua

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

## Running

**Stdio** (for Claude Desktop, MCP Inspector):

```bash
wippy run -s -x mcp:server
```

**Testing with MCP Inspector:**

```bash
npx @modelcontextprotocol/inspector wippy run -s -x mcp:server
```

## Expected Output

```
tools/list → {"tools": [
  {"name": "echo", "description": "Echo back the input text", ...},
  {"name": "add", "description": "Add two numbers together", ...},
  {"name": "greet", "description": "Greet someone by name with an optional style", ...}
]}

tools/call {"name": "echo", "arguments": {"text": "hello"}}
→ {"content": [{"type": "text", "text": "Echo: hello"}], "isError": false}

tools/call {"name": "add", "arguments": {"a": 17, "b": 25}}
→ {"content": [{"type": "text", "text": "42"}], "isError": false}

tools/call {"name": "greet", "arguments": {"name": "Alice", "style": "pirate"}}
→ {"content": [{"type": "text", "text": "Ahoy, Alice! Welcome aboard, matey!"}], "isError": false}
```
