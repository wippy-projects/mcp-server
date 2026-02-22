# Example: App with Prompts

An app that exposes static prompts, dynamic prompts, and template inheritance to MCP clients.

## Project Structure

```
my-prompts-app/
├── wippy.yaml
└── src/
    ├── _index.yaml
    └── prompts/
        ├── static.lua
        └── code_review.lua
```

## wippy.yaml

```yaml
organization: myorg
module: my-prompts-app
description: App with MCP prompts
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

  - name: terminal
    kind: terminal.host
    lifecycle:
      auto_start: true

  # ── Placeholder handler for static prompts ────────────

  - name: static_handler
    kind: function.lua
    source: file://prompts/static.lua
    method: get

  # ── Static prompt with argument substitution ──────────

  - name: greeting_prompt
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
        - name: "style"
          description: "Greeting style (formal, casual, friendly)"
          required: false
      mcp.prompt.messages:
        - role: "user"
          content: "Please greet {{name}} in a {{style}} style."

  # ── Template (hidden from prompts/list) ───────────────

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

  # ── Prompt that extends the template ──────────────────

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

  # ── Dynamic prompt (Lua handler) ──────────────────────

  - name: code_review_prompt
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

## prompts/static.lua

Placeholder handler for YAML-only prompts. Never actually called for static prompts — exists because Wippy requires
a source file for `function.lua` entries.

```lua
local function get(arguments)
    return { messages = {} }
end

return { get = get }
```

## prompts/code_review.lua

Dynamic prompt handler with custom logic:

```lua
local function get(arguments)
    local code = arguments.code or ""
    local language = arguments.language or "unknown"

    local messages = {
        {
            role = "user",
            content = {
                type = "text",
                text = "Please review this " .. language .. " code for:\n"
                    .. "- Correctness\n"
                    .. "- Performance\n"
                    .. "- Best practices\n\n"
                    .. "```" .. language .. "\n" .. code .. "\n```"
            }
        }
    }

    return { messages = messages }
end

return { get = get }
```

## Running

```bash
wippy run -s -x mcp:server
```

## Expected Output

**prompts/list** returns `greeting`, `coding_assistant`, and `code_review` (but NOT `base_instruction` — it's a
template):

```json
{
  "prompts": [
    {"name": "greeting", "description": "Generate a personalized greeting", "arguments": [...]},
    {"name": "coding_assistant", "description": "Get coding assistance from a senior developer", "arguments": [...]},
    {"name": "code_review", "description": "Review code quality and suggest improvements", "arguments": [...]}
  ]
}
```

**prompts/get** for `greeting`:

```json
{
  "messages": [
    {"role": "user", "content": {"type": "text", "text": "Please greet Alice in a friendly style."}}
  ]
}
```

**prompts/get** for `coding_assistant` — includes inherited template messages:

```json
{
  "messages": [
    {"role": "user", "content": {"type": "text", "text": "You are a helpful senior software developer assistant. Help the user with their coding question."}},
    {"role": "user", "content": {"type": "text", "text": "Question: How do I sort a list?"}}
  ]
}
```

**prompts/get** for `code_review` — dynamic handler builds messages:

```json
{
  "messages": [
    {"role": "user", "content": {"type": "text", "text": "Please review this python code for:\n- Correctness\n- Performance\n- Best practices\n\n```python\ndef hello(): pass\n```"}}
  ]
}
```
