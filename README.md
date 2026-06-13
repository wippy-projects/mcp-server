# MCP Server for Wippy

A [Model Context Protocol](https://modelcontextprotocol.io/) server that runs as a Wippy module, communicates over
stdio or HTTP, and exposes tools and prompts to LLM clients (Claude Desktop, MCP Inspector, etc.).

Tools and prompts are **registry-native** — declared as standard Wippy `function.lua` entries with metadata and
discovered automatically. Adding a tool or prompt requires only a YAML entry and (optionally) a Lua handler. No server
code changes.

## Quick Start

### Stdio Transport

```bash
wippy run -s -x mcp:server
```

The `-s` (silent) flag is **required** — it suppresses runtime logs so they don't corrupt the JSON-RPC stream.

Test with MCP Inspector:

```bash
npx @modelcontextprotocol/inspector wippy run -s -x mcp:server
```

### HTTP Transport

Add the MCP server as a dependency and wire it to your HTTP router:

```yaml
- name: dep.mcp
  kind: ns.dependency
  component: butschster/mcp-server
  version: "*"
  parameters:
    - name: router
      value: app:api
```

The MCP endpoint is registered at `/mcp` on your router (e.g., `/api/mcp` if your router has `prefix: /api`).

See [HTTP Transport docs](docs/http-transport.md) for session lifecycle and curl examples.

## Adding Tools

Create a Lua handler and register it in `_index.yaml`:

```lua
-- tools/greet.lua
local function call(arguments)
    local name = arguments.name or "World"
    return "Hello, " .. name .. "!"
end

return { call = call }
```

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
```

See [Tools docs](docs/tools.md) for metadata reference, annotations, error handling, and using Wippy modules.

## Adding Prompts

Prompts support three modes: static (YAML messages), dynamic (Lua handler), and template inheritance.

```yaml
- name: greeting
  kind: function.lua
  source: file://prompts/static.lua
  method: get
  meta:
    mcp.prompt: true
    mcp.prompt.name: "greeting"
    mcp.prompt.description: "Generate a personalized greeting"
    mcp.prompt.arguments:
      - name: "name"
        description: "Name of the person to greet"
        required: true
    mcp.prompt.messages:
      - role: "user"
        content: "Please greet {{name}}."
```

See [Prompts docs](docs/prompts.md) for dynamic prompts, template inheritance, and metadata reference.

## Per-tool / per-prompt authorization (RBAC)

A tool or prompt may be restricted to specific security groups. Add an
`mcp.groups` list — the groups allowed to see and call it:

```yaml
meta:
  mcp.tool: true
  mcp.name: "count_users"
  mcp.groups:
    - myapp.security:admin
    - myapp.security:user_manager
```

The entry is visible in `tools/list` / `prompts/list` and callable via
`tools/call` / `prompts/get` **only if** the current actor belongs to at least
one listed group. Entries without `mcp.groups` are **public** (unchanged
behavior).

- Both list and call are gated from one place: `tools/call` re-discovers, so an
  unauthorized tool is simply absent → `Unknown tool` (leak-safe — a hidden tool
  is indistinguishable from a nonexistent one).
- A **nil actor** or an actor with no groups (stdio transport, anonymous) fails
  **closed** — gated entries are hidden.

### Host requirement: expose the actor's groups

The package reads the actor's groups from `security.actor():meta().groups` (a
`string[]`). The host must populate this when it mints the session actor, e.g.:

```lua
local actor = security.new_actor(user_id, { groups = user_group_ids })
```

`security` is a core Wippy module — declare it in the `modules:` of the MCP
libraries (already done in this package).

### Emergency kill-switch

To hide **all** gated tools/prompts at runtime without a redeploy (fail-safe
incident response), declare a `registry.entry` in the host app:

```yaml
- name: mcp_gating
  kind: registry.entry
  meta:
    type: mcp.gating
  data:
    emergency_hide_gated: true   # flip to hide every gated entry
```

## Supported MCP Methods

| Method                      | Type         | Description                            |
|-----------------------------|--------------|----------------------------------------|
| `initialize`                | request      | Handshake, returns server capabilities |
| `notifications/initialized` | notification | Client confirms initialization         |
| `ping`                      | request      | Health check, returns `{}`             |
| `tools/list`                | request      | List all discovered tools              |
| `tools/call`                | request      | Invoke a tool by name                  |
| `prompts/list`              | request      | List all discovered prompts            |
| `prompts/get`               | request      | Get prompt messages by name            |

## Documentation

| Document                                   | Description                                        |
|--------------------------------------------|----------------------------------------------------|
| [Stdio Transport](docs/stdio-transport.md) | Running via stdio, Claude Desktop configuration    |
| [HTTP Transport](docs/http-transport.md)   | Session lifecycle, host app setup, curl examples   |
| [Tools](docs/tools.md)                     | Creating tools, metadata reference, error handling |
| [Prompts](docs/prompts.md)                 | Static, dynamic, and template prompts              |
| [Scope Filtering](docs/scope-filtering.md) | Multi-endpoint visibility control                  |
| [Architecture](docs/architecture.md)       | Module design, dispatch chain, dependency graph    |

### Examples

| Example                                               | Description                                 |
|-------------------------------------------------------|---------------------------------------------|
| [Basic Tools](docs/examples/basic-tools.md)           | Minimal app with three simple tools         |
| [HTTP App](docs/examples/http-app.md)                 | HTTP server with MCP endpoint               |
| [Multi-Endpoint](docs/examples/multi-endpoint-app.md) | Admin vs. public tools with scope filtering |
| [Prompts App](docs/examples/prompts-app.md)           | Static, dynamic, and template prompts       |

## Protocol Details

- **MCP version**: `2025-06-18`
- **Transports**: stdio (newline-delimited JSON), HTTP (Streamable HTTP)
- **Capabilities**: `tools` and `prompts` (both with `listChanged: false`)
