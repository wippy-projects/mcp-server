-- MCP Handler: shared dispatch chain + session management + event emission
-- Used by both stdio (server.lua) and HTTP (sse_handler.lua) transports
-- Entry kind: library.lua

local jsonrpc = require("jsonrpc")
local protocol = require("protocol")
local tools = require("tools")
local prompts = require("prompts")
local emitter = require("emitter")
local logger = require("logger")

local log = logger:named("mcp.handler")

---------------------------------------------------------------------------
-- Handler constructor
---------------------------------------------------------------------------

local function new(config)
    config = config or {}

    local emit = emitter.new(config.scope)

    local h = {
        sessions = {},
        config = config,
        emitter = emit
    }

    -- Optional persistent session store (host-provided). Lets sessions survive
    -- across HTTP worker processes and restarts: the per-worker `sessions` table
    -- is just a cache; `store` is the shared source of truth for "this session
    -- id is valid". Interface: store.put(id), store.has(id)->bool, store.remove(id).
    local store = config.store

    -- Build a fresh protocol server. `resumed` brings it straight to READY for a
    -- session that was already initialized elsewhere (rebuilt from the store).
    local function build_server(resumed)
        return protocol.new_server({
            name = config.name or "wippy-mcp",
            version = config.version or "0.1.0",
            capabilities = config.capabilities or { tools = true, prompts = true },
            instructions = config.instructions,
            resumed = resumed,
        })
    end

    --- Create a new session with its own protocol state machine
    function h:create_session(session_id)
        self.sessions[session_id] = { server = build_server(false) }
        if store then store.put(session_id) end
        log:debug("session created", {session_id = session_id, scope = config.scope})
        return session_id
    end

    --- Get an existing session by ID. Falls back to the shared store on a local
    --- cache miss (different worker / post-restart) and rebuilds the session in
    --- the READY state, since its presence in the store means it was initialized.
    function h:get_session(session_id)
        local s = self.sessions[session_id]
        if s then return s end
        if store and store.has(session_id) then
            s = { server = build_server(true) }
            self.sessions[session_id] = s
            log:debug("session rebuilt from store", {session_id = session_id})
            return s
        end
        return nil
    end

    --- Delete a session
    function h:delete_session(session_id)
        self.sessions[session_id] = nil
        if store then store.remove(session_id) end
        log:debug("session deleted", {session_id = session_id})
    end

    --- Dispatch a classified JSON-RPC message through the handler chain
    function h:dispatch(session_id, msg)
        local session = self:get_session(session_id)
        if not session then
            log:warn("dispatch to unknown session", {session_id = session_id})
            return nil, "unknown session"
        end

        -- Invalid JSON → parse error
        if msg.kind == "invalid" then
            log:debug("invalid message", {session_id = session_id, error = msg.error})
            return jsonrpc.parse_error(nil, msg.error or "Invalid message")
        end

        log:debug("dispatch", {
            session_id = session_id,
            kind = msg.kind,
            method = msg.method
        })

        -- 1. Protocol (initialize, ping, notifications/initialized)
        local response = session.server.handle(msg)
        if response then
            -- Note: protocol events are emitted by the transport layer (sse_handler/server)
            -- because events.send() doesn't work after funcs.call() in dispatch context
            return response
        end

        -- Notifications handled by protocol return nil — no response needed
        if msg.kind == "notification" then
            return nil
        end

        -- 2. Tools (tools/list, tools/call)
        local call_info
        response, call_info = tools.handle(msg, config.scope)
        if response then
            -- Note: tool.called event is emitted by the transport layer (sse_handler/server)
            -- because events.send() doesn't work after funcs.call() in dispatch context
            if call_info then
                log:debug("tool called", {
                    session_id = session_id,
                    tool = call_info.tool_name,
                    duration_ms = call_info.duration_ms,
                    success = call_info.success
                })
            end
            return response
        end

        -- 3. Prompts (prompts/list, prompts/get)
        response = prompts.handle(msg, config.scope)
        if response then
            -- Emit prompt.get event
            if msg.method == "prompts/get" then
                local prompt_name = (msg.params or {}).name or "unknown"
                log:debug("prompt get", {session_id = session_id, prompt = prompt_name})
                emit:emit("prompt.get", session_id,
                    "/sessions/" .. session_id .. "/prompts/" .. prompt_name, {
                        prompt_name = prompt_name
                    })
            end
            return response
        end

        -- 4. Unknown method
        if msg.kind == "request" then
            log:warn("unknown method", {session_id = session_id, method = msg.method})
            return jsonrpc.method_not_found(msg.id, "Unknown method: " .. msg.method)
        end

        return nil
    end

    return h
end

return {
    new = new
}
