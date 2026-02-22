# Stdio Transport

The stdio transport is the default mode — the server reads newline-delimited JSON-RPC from stdin and writes responses
to stdout. This is how MCP clients like Claude Desktop and MCP Inspector communicate with the server.

## Running

```bash
wippy run -s -x mcp:server
```

| Flag              | Purpose                                                                                     |
|-------------------|---------------------------------------------------------------------------------------------|
| `-s` / `--silent` | **Required.** Suppresses runtime logs from stdout so they don't corrupt the JSON-RPC stream |
| `-x mcp:server`   | Execute the server process on the terminal host                                             |

## Testing with MCP Inspector

```bash
npx @modelcontextprotocol/inspector wippy run -s -x mcp:server
```

## Claude Desktop Configuration

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

## Protocol

- **Transport**: newline-delimited JSON (`\n` separator)
- **Direction**: client writes to stdin, server writes to stdout
- **Session**: single implicit session (ID: `"stdio"`)

The server reads lines in a loop. Empty lines are ignored. On EOF or read error, the process exits gracefully with
code 0.
