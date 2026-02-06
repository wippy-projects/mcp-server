# MCP Server for Wippy

A [Model Context Protocol](https://modelcontextprotocol.io/) server that runs as a Wippy process, communicates over
stdio, and exposes tools and prompts to LLM clients (Claude Desktop, MCP Inspector, etc.).

Tools and prompts are **registry-native** — declared as standard Wippy `function.lua` entries with metadata and
discovered automatically. Adding a tool or prompt requires only a YAML entry and (optionally) a Lua handler. No server
code changes.

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
      "args": ["run", "-s", "-x", "mcp:server"],
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
      "args": ["-c", "cd /path/to/project && wippy run -s -x mcp:server"]
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
| `prompts/list`              | request      | List all discovered prompts            |
| `prompts/get`               | request      | Get prompt messages by name            |

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

### Tool Metadata Reference

| Meta field        | Required | Description                                                                 |
|-------------------|----------|-----------------------------------------------------------------------------|
| `mcp.tool`        | yes      | Must be `true` for discovery                                                |
| `mcp.name`        | yes      | Tool name exposed to clients                                                |
| `mcp.description` | no       | Human-readable description                                                  |
| `mcp.inputSchema` | no       | JSON Schema for `arguments` validation                                      |
| `mcp.annotations` | no       | Hints: `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint` |

---

## Adding Prompts

Prompts are reusable message templates exposed to LLM clients. Like tools, they are declared as `function.lua` entries
with `mcp.prompt` metadata. The server discovers them automatically.

There are three ways to define prompts:

### Static Prompts (messages in YAML only)

Messages are defined entirely in meta. The Lua handler is never called — it exists only because Wippy requires a source
file for `function.lua` entries. Use a shared placeholder file.

```yaml
- name: greeting
  kind: function.lua
  source: file://prompts/static.lua    # placeholder, never called
  method: get
  meta:
    mcp.prompt: true
    mcp.prompt.name: "greeting"
    mcp.prompt.description: "Generate a personalized greeting"
    mcp.prompt.arguments:
      - name: "name"
        description: "Name of the person to greet"
        required: true
      - name: "style"
        description: "Greeting style (formal, casual, friendly)"
        required: false
    mcp.prompt.messages:
      - role: "user"
        content: "Please greet {{name}} in a {{style}} style."
```

The `{{name}}` and `{{style}}` placeholders are substituted with argument values at request time.

### Dynamic Prompts (custom Lua handler)

For prompts that need logic, computation, or conditional messages, implement a handler function:

```lua
-- prompts/code_review.lua
local function get(arguments)
    local code = arguments.code or ""
    local language = arguments.language or "unknown"

    return {
        messages = {
            {
                role = "user",
                content = {
                    type = "text",
                    text = "Please review this " .. language .. " code:\n\n```\n" .. code .. "\n```"
                }
            }
        }
    }
end

return { get = get }
```

```yaml
- name: code_review
  kind: function.lua
  source: file://prompts/code_review.lua
  method: get
  meta:
    mcp.prompt: true
    mcp.prompt.name: "code_review"
    mcp.prompt.description: "Review code quality and suggest improvements"
    mcp.prompt.arguments:
      - name: "code"
        description: "The code to review"
        required: true
      - name: "language"
        description: "Programming language"
        required: false
```

Dynamic prompts are called via `funcs.call()` — they have no `mcp.prompt.messages` or `mcp.prompt.extend` in meta.

### Template Inheritance (extend)

Prompts can extend templates to inherit and compose messages. Templates are prompts with `type: "template"` — they
don't appear in `prompts/list` but can be referenced by other prompts.

```yaml
# Template (not listed, acts as base)
- name: base_instruction
  kind: function.lua
  source: file://prompts/static.lua
  method: get
  meta:
    mcp.prompt: true
    mcp.prompt.name: "base_instruction"
    mcp.prompt.type: "template"
    mcp.prompt.messages:
      - role: "user"
        content: "You are a helpful {{role}} assistant. {{instruction}}"

# Prompt that extends the template
- name: coding_assistant
  kind: function.lua
  source: file://prompts/static.lua
  method: get
  meta:
    mcp.prompt: true
    mcp.prompt.name: "coding_assistant"
    mcp.prompt.description: "Get coding assistance from a senior developer"
    mcp.prompt.extend:
      - id: "base_instruction"
        arguments:
          role: "senior software developer"
          instruction: "Help the user with their coding question."
    mcp.prompt.arguments:
      - name: "question"
        description: "The coding question"
        required: true
    mcp.prompt.messages:
      - role: "user"
        content: "Question: {{question}}"
```

When `coding_assistant` is retrieved, the resolved messages are:
1. `"You are a helpful senior software developer assistant. Help the user with their coding question."` (from template)
2. `"Question: <user's question>"` (from prompt)

Multi-level inheritance is supported — templates can extend other templates.

### Prompt Metadata Reference

| Meta field                | Required | Description                                                    |
|---------------------------|----------|----------------------------------------------------------------|
| `mcp.prompt`              | yes      | Must be `true` for discovery                                   |
| `mcp.prompt.name`         | yes      | Prompt name exposed to clients                                 |
| `mcp.prompt.description`  | no       | Human-readable description                                     |
| `mcp.prompt.type`         | no       | `"prompt"` (default) or `"template"` (hidden from list)        |
| `mcp.prompt.tags`         | no       | Tags for organization/filtering                                |
| `mcp.prompt.arguments`    | no       | List of `{name, description, required}` argument definitions   |
| `mcp.prompt.messages`     | no*      | Static messages with `{role, content}` and `{{arg}}` templates |
| `mcp.prompt.extend`       | no       | List of `{id, arguments}` template references to inherit       |

\* Either `messages`/`extend` (static) or neither (dynamic, handler called via `funcs.call()`).

### Example Prompts

Four demo prompts are included in `src/examples/`:

**greeting** — static prompt with argument substitution:
```
prompts/get → {"name": "greeting", "arguments": {"name": "Alice", "style": "friendly"}}
           ← messages: ["Please greet Alice in a friendly style."]
```

**coding_assistant** — static prompt with template inheritance:
```
prompts/get → {"name": "coding_assistant", "arguments": {"question": "How do I sort a list?"}}
           ← messages: ["You are a helpful senior software developer...", "Question: How do I sort a list?"]
```

**code_review** — dynamic prompt with custom Lua handler:
```
prompts/get → {"name": "code_review", "arguments": {"code": "def hello(): ...", "language": "python"}}
           ← messages: ["Please review this python code: ..."]
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
                                           prompts.handle()
                                                 │
                                          ┌──────┴──────┐
                                          │ handled?      │
                                          │ (prompts/list,│
                                          │  prompts/get) │
                                          └──────┬────────┘
                                            no   │   yes ──▶ stdout
                                                 ▼
                                          METHOD_NOT_FOUND ──▶ stdout
```

### Module Dependency Graph

```
server.lua (process.lua)
├── imports: jsonrpc   ← mcp:jsonrpc
├── imports: protocol  ← mcp:protocol    ── imports: jsonrpc
├── imports: tools     ← mcp:tools_lib   ── imports: jsonrpc, modules: registry, funcs
└── imports: prompts   ← mcp:prompts_lib ── imports: jsonrpc, modules: registry, funcs
```

### Project Structure

```
src/mcp/
├── _index.yaml      Registry: terminal.host, libraries, server process
├── jsonrpc.lua      JSON-RPC 2.0 codec (encode/decode/error helpers)
├── protocol.lua     MCP handshake state machine (initialize → ready)
├── tools.lua        Tool discovery via registry + tools/list & tools/call dispatch
├── prompts.lua      Prompt discovery via registry + prompts/list & prompts/get dispatch
├── server.lua       Main process: stdin loop → dispatch chain → stdout
└── README.md

src/examples/        Demo tools & prompts (separate namespace, zero coupling to server)
├── _index.yaml      Tool + prompt entries with MCP metadata
├── tools/
│   ├── weather.lua
│   └── echo.lua
└── prompts/
    ├── static.lua       Placeholder handler for YAML-only prompts
    └── code_review.lua  Dynamic prompt with custom logic
```

### Modules

**jsonrpc.lua** — JSON-RPC 2.0 codec. No MCP-specific logic.

**protocol.lua** — MCP connection lifecycle. State machine: `disconnected` → `ready`. Advertises `tools` and `prompts`
capabilities.

**tools.lua** — Tool discovery and dispatch via Wippy's registry. `discover()` finds entries where
`meta["mcp.tool"] == true`. Tool errors are returned as `isError: true` per MCP spec.

**prompts.lua** — Prompt discovery and dispatch via Wippy's registry. `discover()` finds entries where
`meta["mcp.prompt"] == true`. Supports static messages (from meta), dynamic messages (from handler), template
inheritance (`extend`), and `{{argument}}` substitution. Templates (`type: "template"`) are hidden from `prompts/list`.

**server.lua** — Main process. Reads stdin line by line, dispatches through jsonrpc → protocol → tools → prompts chain.

### Protocol Details

- **MCP version**: `2025-06-18`
- **Transport**: stdio (newline-delimited JSON)
- **Capabilities advertised**: `tools` and `prompts` (both with `listChanged: false`)
- **Tool errors**: Returned as `isError: true` in `CallToolResult`, not as JSON-RPC errors
- **Empty object encoding**: Wippy's `json.encode({})` produces `[]`. The jsonrpc module applies a `string.gsub`
  workaround to fix `"result":[]` → `"result":{}` for ping and capabilities.
