# Architecture

## Overview

The MCP server is built as a set of Wippy libraries that can be used by two transports: stdio and HTTP. Both transports
share the same dispatch chain and session management via `handler.lua`.

```
                      ┌── server.lua (stdio) ─── stdin/stdout
handler.lua (lib) ────┤
                      └── sse_handler.lua (HTTP) ─── POST/GET/DELETE /mcp
```

## Dispatch Chain

Every JSON-RPC message goes through the same chain of responsibility:

```
msg ──▶ protocol.handle()
             │
      ┌──────┴──────┐
      │ handled?    │         initialize, ping,
      │             │         notifications/initialized
      └──────┬──────┘
        no   │   yes ──▶ response
             ▼
        tools.handle(scope)
             │
      ┌──────┴──────┐
      │ handled?    │         tools/list, tools/call
      └──────┬──────┘
        no   │   yes ──▶ response
             ▼
       prompts.handle(scope)
             │
      ┌──────┴──────┐
      │ handled?    │         prompts/list, prompts/get
      └──────┬──────┘
        no   │   yes ──▶ response
             ▼
      METHOD_NOT_FOUND ──▶ response
```

Each handler returns a response string if it handled the request, or `nil` to pass to the next handler.

## Modules

| Module            | Kind         | Purpose                                                                                    |
|-------------------|--------------|--------------------------------------------------------------------------------------------|
| `jsonrpc.lua`     | library.lua  | JSON-RPC 2.0 codec. `decode()` from string, `classify()` from parsed table. No MCP logic.  |
| `protocol.lua`    | library.lua  | MCP lifecycle state machine: `disconnected` → `ready`. Handles `initialize`, `ping`.       |
| `handler.lua`     | library.lua  | Shared dispatch chain + session management. Each session gets its own protocol instance.   |
| `tools.lua`       | library.lua  | Tool discovery via registry (`mcp.tool == true`). Handles `tools/list` and `tools/call`.   |
| `prompts.lua`     | library.lua  | Prompt discovery via registry (`mcp.prompt == true`). Static, dynamic, and template modes. |
| `server.lua`      | process.lua  | Stdio transport. Reads stdin, dispatches via handler, writes to stdout.                    |
| `sse_handler.lua` | function.lua | HTTP transport. Handles POST/GET/DELETE, manages `Mcp-Session-Id` header.                  |

## Dependency Graph

```
server.lua (process.lua)
├── jsonrpc  ← mcp:jsonrpc
└── handler  ← mcp:handler_lib
    ├── jsonrpc   ← mcp:jsonrpc
    ├── protocol  ← mcp:protocol    ── jsonrpc
    ├── tools     ← mcp:tools_lib   ── jsonrpc, registry, funcs
    └── prompts   ← mcp:prompts_lib ── jsonrpc, registry, funcs

sse_handler.lua (function.lua)
├── jsonrpc  ← mcp:jsonrpc
└── handler  ← mcp:handler_lib (same tree)
```

## Session Management

`handler.lua` maintains a table of sessions, keyed by session ID. Each session has its own `protocol` state machine
instance, so one session's `initialize` → `ready` state does not affect another.

- **Stdio**: single session with ID `"stdio"`, created at startup
- **HTTP**: new session created per `initialize` request, with a generated hex ID returned via `Mcp-Session-Id` header

## Scope Filtering

Each handler instance is created with an optional `scope` parameter. When tools and prompts are discovered, the scope
is used to filter visibility:

- Tools/prompts without `mcp.scope` are visible on **all** endpoints
- Tools/prompts with `mcp.scope` are only visible when the handler's scope matches
- An unscoped handler only sees unscoped tools/prompts

This allows host applications to create multiple MCP endpoints with different tool sets by creating additional handler
files that pass `scope` to `handler.new()`. See [Scope Filtering](scope-filtering.md) for details.

## Registry-Native Extensibility

Tools and prompts are declared as `function.lua` entries in any namespace's `_index.yaml` with MCP metadata. The server
discovers them via `registry.find({kind = "function.lua"})` and checks for `meta["mcp.tool"]` or `meta["mcp.prompt"]`.

This means adding a tool or prompt requires **no server code changes** — only a YAML entry and optionally a Lua handler.

## Protocol Details

- **MCP version**: `2025-06-18`
- **Transports**: stdio (newline-delimited JSON), HTTP (Streamable HTTP)
- **Capabilities**: `tools` and `prompts` (both with `listChanged: false`)
- **Tool errors**: Returned as `isError: true` in `CallToolResult`, not as JSON-RPC errors
- **Empty object workaround**: Wippy's `json.encode({})` produces `[]`. The jsonrpc module applies `string.gsub` to fix
  `"key":[]` → `"key":{}`.
