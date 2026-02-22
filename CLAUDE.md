# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MCP (Model Context Protocol) server for the Wippy platform. Written in Lua, it communicates over stdio or HTTP
(Streamable HTTP) and exposes tools and prompts to LLM clients (Claude Desktop, MCP Inspector, etc.). MCP protocol
version: `2025-06-18`.

## Running the Server

```bash
wippy run -s -x mcp:server
```

The `-s` (silent) flag is **required** — it suppresses runtime logs from stdout so they don't corrupt the JSON-RPC
stream.

Test with MCP Inspector:

```bash
npx @modelcontextprotocol/inspector wippy run -s -x mcp:server
```

There is no test suite. No build step is needed.

## Architecture

Seven Lua modules. No external dependencies beyond Wippy's built-in modules (`json`, `registry`, `funcs`, `io`, `http`).
Requires `wippy/terminal >=0.3.0`.

### Transports

```
                      ┌── server.lua (stdio) ─── stdin/stdout
handler.lua (lib) ────┤
                      └── sse_handler.lua (HTTP) ─── POST/GET/DELETE /mcp
```

Both transports use the shared `handler.lua` library for dispatch and session management.

### Dispatch Chain (Chain of Responsibility)

```
msg → handler:dispatch() → protocol.handle() → tools.handle(scope) → prompts.handle(scope) → METHOD_NOT_FOUND
```

Each handler returns a response string if it handled the request, or `nil` to pass to the next handler.

### Module Responsibilities

- **handler.lua** — Shared dispatch chain + session management. Each session has its own protocol state machine. Accepts
  optional `scope` for filtering tools/prompts per endpoint.
- **server.lua** — Stdio transport. Stdin read loop, dispatches through handler, writes to stdout.
- **sse_handler.lua** — HTTP transport. Single endpoint handling POST (JSON-RPC), GET (SSE, future), DELETE (session
  close). Routes by `req:method()`. Manages `Mcp-Session-Id` header.
- **jsonrpc.lua** — JSON-RPC 2.0 codec. `decode()` parses from string; `classify()` validates a pre-parsed table.
  No MCP-specific logic. Contains a `string.gsub` workaround because Wippy's `json.encode({})` produces `[]` instead
  of `{}`.
- **protocol.lua** — MCP connection lifecycle. State machine (`disconnected` → `ready`). Handles `initialize`,
  `notifications/initialized`, `ping`. Advertises `tools` and `prompts` capabilities.
- **tools.lua** — Tool discovery and dispatch. Scans the Wippy registry for entries with `meta["mcp.tool"] == true`.
  Handles `tools/list` and `tools/call`. Supports optional scope filtering via `mcp.scope` metadata.
- **prompts.lua** — Prompt discovery and dispatch. Scans registry for `meta["mcp.prompt"] == true`. Handles
  `prompts/list` and `prompts/get`. Supports three modes: static (YAML messages with `{{arg}}` substitution), dynamic
  (Lua handler), and template inheritance (`mcp.prompt.extend`). Supports scope filtering.

### Registry-Native Extensibility

Tools and prompts are declared as `function.lua` entries in `_index.yaml` with MCP metadata. The server discovers them
automatically — **no server code changes are needed** to add tools or prompts. See `src/examples/` for reference
implementations.

### Key Conventions

- Tool handlers receive an `arguments` table. Return a string (auto-wrapped as `{type: "text"}`) or a table with
  `.content` (passed through).
- Prompt handlers return `{messages = {...}}`. Static prompts define messages in YAML meta; dynamic prompts return them
  from Lua.
- Templates (`mcp.prompt.type: "template"`) are hidden from `prompts/list` but can be extended by other prompts.
- All module wiring is in `_index.yaml` — libraries declare `modules` (Wippy built-ins) and `imports` (other libraries
  in this namespace).
- Scope filtering: tools/prompts with `mcp.scope` are only visible on endpoints with matching scope. Unscoped
  tools/prompts are visible to all endpoints. An unscoped endpoint only sees unscoped tools/prompts.

## Wippy Documentation

Platform docs: https://wippy.ai/llm.txt (index) — use `https://wippy.ai/llm/path/en/<path>` for full pages,
`https://wippy.ai/llm/search?q=<query>` for search.

### Core Concepts (used in this project)

- Registry: https://wippy.ai/llm/path/en/concepts/registry
- Functions: https://wippy.ai/llm/path/en/concepts/functions
- Process Model: https://wippy.ai/llm/path/en/concepts/process-model
- Entry Kinds: https://wippy.ai/llm/path/en/guides/entry-kinds

### Lua Modules (used in this project)

- JSON: https://wippy.ai/llm/path/en/lua/data/json
- Registry (Lua API): https://wippy.ai/llm/path/en/lua/core/registry
- Functions (funcs): https://wippy.ai/llm/path/en/lua/core/funcs
- I/O: https://wippy.ai/llm/path/en/lua/system/io
- HTTP: https://wippy.ai/llm/path/en/lua/http/http
- Contract: https://wippy.ai/llm/path/en/lua/core/contract

### HTTP & Transport

- HTTP Server: https://wippy.ai/llm/path/en/http/server
- HTTP Router: https://wippy.ai/llm/path/en/http/router
- HTTP Endpoint: https://wippy.ai/llm/path/en/http/endpoint
- HTTP Middleware: https://wippy.ai/llm/path/en/http/middleware
- Server-Sent Events: https://wippy.ai/llm/path/en/http/sse

### System Components

- Terminal: https://wippy.ai/llm/path/en/system/terminal
- Dependency Management: https://wippy.ai/llm/path/en/guides/dependency-management

### MCP Protocol Spec

- MCP Specification: https://modelcontextprotocol.io/specification/2025-06-18
- Streamable HTTP Transport: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#streamable-http
