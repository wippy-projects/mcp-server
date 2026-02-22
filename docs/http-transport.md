# HTTP Transport

The MCP server
supports [Streamable HTTP](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#streamable-http)
transport, allowing it to run alongside an existing HTTP server in a host application.

## How It Works

The host application provides an HTTP router via Wippy's `ns.requirement` mechanism. The MCP server registers `/mcp`
endpoints (POST, GET, DELETE) on that router.

| HTTP Method | Purpose                          |
|-------------|----------------------------------|
| `POST`      | JSON-RPC request/response        |
| `GET`       | SSE stream (not yet implemented) |
| `DELETE`    | Close a session                  |

## Session Lifecycle

Sessions are stateful — each `initialize` request creates a new session with its own protocol state machine.

```
POST initialize  →  200 + Mcp-Session-Id header
POST notifications/initialized (with Mcp-Session-Id)  →  204
POST tools/list (with Mcp-Session-Id)  →  200 + JSON
POST tools/call (with Mcp-Session-Id)  →  200 + JSON
DELETE (with Mcp-Session-Id)  →  200
```

The `Mcp-Session-Id` header is returned in the `initialize` response and **must** be included in all subsequent
requests.

## Host Application Setup

Add the MCP server as a dependency and provide your router via `parameters:`:

```yaml
entries:
  # Your HTTP infrastructure
  - name: gateway
    kind: http.service
    addr: ":8085"
    lifecycle:
      auto_start: true

  - name: api
    kind: http.router
    meta:
      server: app:gateway
    prefix: /api

  # MCP dependency — wire router
  - name: dep.mcp
    kind: ns.dependency
    component: butschster/mcp-server
    version: "*"
    parameters:
      - name: router
        value: app:api
```

This registers MCP endpoints at `/api/mcp`.

The default router is `app:api.public`. If your router entry has that ID, you don't need the `parameters:` override.

## Testing with curl

**Initialize:**

```bash
curl -s -D - -X POST http://localhost:8085/api/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"test","version":"1.0"},"protocolVersion":"2025-06-18"}}'
```

**Subsequent requests** (use the `Mcp-Session-Id` from the response):

```bash
# Notify initialized
curl -s -X POST http://localhost:8085/api/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# List tools
curl -s -X POST http://localhost:8085/api/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# Call a tool
curl -s -X POST http://localhost:8085/api/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"}}}'

# Close session
curl -s -X DELETE http://localhost:8085/api/mcp \
  -H "Mcp-Session-Id: <SESSION_ID>"
```

## Multiple Endpoints

The MCP module registers a default unscoped endpoint at `/mcp`. To add additional endpoints with different tool sets,
create custom handler files with a `scope` parameter and register them on your router. See
[Scope Filtering](scope-filtering.md) for the full pattern and
[Multi-Endpoint Example](examples/multi-endpoint-app.md) for a complete working example.

```yaml
# Example: admin endpoint alongside the default public one
- name: admin_mcp_handler
  kind: function.lua
  source: file://handlers/admin_mcp.lua
  method: handler
  modules: [http, json]
  imports:
    handler: mcp:handler_lib
    jsonrpc: mcp:jsonrpc

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

## Error Responses

| Scenario                   | HTTP Status | Body                                                    |
|----------------------------|-------------|---------------------------------------------------------|
| Invalid JSON body          | 400         | `{"error": "Invalid JSON body"}`                        |
| Missing/invalid session ID | 400         | `{"error": "Missing or invalid Mcp-Session-Id header"}` |
| DELETE unknown session     | 404         | `{"error": "Session not found"}`                        |
| GET (SSE not implemented)  | 405         | `{"error": "SSE streaming not yet supported"}`          |
