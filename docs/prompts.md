# Adding Prompts

Prompts are reusable message templates exposed to LLM clients. Like tools, they are declared as `function.lua` entries
with `mcp.prompt` metadata and discovered automatically.

There are three ways to define prompts: **static**, **dynamic**, and **template inheritance**.

## Static Prompts

Messages are defined entirely in YAML meta. The Lua handler is never called — it exists only because Wippy requires a
source file for `function.lua` entries. Use a shared placeholder file.

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

The placeholder file:

```lua
-- prompts/static.lua
local function get(arguments)
    return { messages = {} }
end

return { get = get }
```

`{{name}}` and `{{style}}` placeholders are substituted with argument values at request time.

## Dynamic Prompts

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

Dynamic prompts have no `mcp.prompt.messages` or `mcp.prompt.extend` in meta — the server calls the function handler
via `funcs.call()`.

## Template Inheritance

Prompts can extend templates to inherit and compose messages. Templates are prompts with `type: "template"` — they
don't appear in `prompts/list` but can be referenced by other prompts.

```yaml
# Template (hidden from prompts/list)
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

When `coding_assistant` is retrieved with `{"question": "How do I sort a list?"}`, the resolved messages are:

1. `"You are a helpful senior software developer assistant. Help the user with their coding question."`
2. `"Question: How do I sort a list?"`

Multi-level inheritance is supported — templates can extend other templates.

## Metadata Reference

| Meta field               | Required | Description                                                                                                                                              |
|--------------------------|----------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `mcp.prompt`             | yes      | Must be `true` for discovery                                                                                                                             |
| `mcp.prompt.name`        | yes      | Prompt name exposed to clients                                                                                                                           |
| `mcp.prompt.description` | no       | Human-readable description                                                                                                                               |
| `mcp.prompt.type`        | no       | `"prompt"` (default) or `"template"` (hidden from list)                                                                                                  |
| `mcp.prompt.tags`        | no       | Tags for organization/filtering                                                                                                                          |
| `mcp.prompt.arguments`   | no       | List of `{name, description, required}` argument definitions                                                                                             |
| `mcp.prompt.messages`    | no*      | Static messages with `{role, content}` and `{{arg}}` templates                                                                                           |
| `mcp.prompt.extend`      | no       | List of `{id, arguments}` template references to inherit                                                                                                 |
| `mcp.scope`              | no       | Scope tag — prompt is only visible on endpoints with matching scope. Unscoped prompts are visible everywhere. See [scope filtering](scope-filtering.md). |

\* Either `messages`/`extend` (static) or neither (dynamic, handler called via `funcs.call()`).
