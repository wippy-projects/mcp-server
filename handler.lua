-- MCP Handler: shared dispatch chain + session management
-- Used by both stdio (server.lua) and HTTP (sse_handler.lua) transports
-- Entry kind: library.lua

local jsonrpc = require("jsonrpc")
local protocol = require("protocol")
local tools = require("tools")
local prompts = require("prompts")

---------------------------------------------------------------------------
-- Handler constructor
---------------------------------------------------------------------------

local function new(config)
    config = config or {}

    local h = {
        sessions = {},
        config = config
    }

    --- Create a new session with its own protocol state machine
    function h:create_session(session_id)
        local server = protocol.new_server({
            name = config.name or "wippy-mcp",
            version = config.version or "0.1.0",
            capabilities = config.capabilities or { tools = true, prompts = true },
            instructions = config.instructions
        })
        self.sessions[session_id] = { server = server }
        return session_id
    end

    --- Get an existing session by ID
    function h:get_session(session_id)
        return self.sessions[session_id]
    end

    --- Delete a session
    function h:delete_session(session_id)
        self.sessions[session_id] = nil
    end

    --- Dispatch a classified JSON-RPC message through the handler chain
    function h:dispatch(session_id, msg)
        local session = self.sessions[session_id]
        if not session then
            return nil, "unknown session"
        end

        -- Invalid JSON → parse error
        if msg.kind == "invalid" then
            return jsonrpc.parse_error(nil, msg.error or "Invalid message")
        end

        -- 1. Protocol (initialize, ping, notifications/initialized)
        local response = session.server.handle(msg)
        if response then
            return response
        end

        -- Notifications handled by protocol return nil — no response needed
        if msg.kind == "notification" then
            return nil
        end

        -- 2. Tools (tools/list, tools/call)
        response = tools.handle(msg, config.scope)
        if response then
            return response
        end

        -- 3. Prompts (prompts/list, prompts/get)
        response = prompts.handle(msg, config.scope)
        if response then
            return response
        end

        -- 4. Unknown method
        if msg.kind == "request" then
            return jsonrpc.method_not_found(msg.id, "Unknown method: " .. msg.method)
        end

        return nil
    end

    return h
end

return {
    new = new
}
