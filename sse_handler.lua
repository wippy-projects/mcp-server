-- MCP HTTP Handler: Streamable HTTP transport (POST/GET/DELETE)
-- Single endpoint that routes by HTTP method
-- Entry kind: function.lua
--
-- Wippy HTTP handlers receive no arguments — use http.request() / http.response()

local http = require("http")
local json = require("json")
local jsonrpc = require("jsonrpc")
local handler = require("handler")
local emitter = require("emitter")
local logger = require("logger")
local registry = require("registry")
local funcs = require("funcs")
local crypto = require("crypto")

local log = logger:named("mcp.http")

-- Shared handler instance (created on first request)
local h = nil
local emit = nil

--- Generate a new session ID. Random (not time+counter) so two worker
--- processes can't mint the same id in the same second — which matters now
--- that ids are shared across workers via the session store.
local function new_session_id()
    return crypto.random.string(24, "0123456789abcdef")
end

--- Resolve an optional host-provided persistent session store, the same way the
--- gating config is discovered: a registry entry tagged `meta.type =
--- "mcp.session_store"` whose `data.func` names a function taking
--- { op = "put"|"has"|"remove", session_id } and returning { valid = bool } for
--- "has". Returns nil when no host store is configured (in-memory only).
local function resolve_store()
    local ok, entries = pcall(registry.find, { ["meta.type"] = "mcp.session_store" })
    if not ok or type(entries) ~= "table" then return nil end
    for _, e in ipairs(entries) do
        local fid = e.data and e.data.func
        if fid and fid ~= "" then
            log:info("persistent session store wired", { func = fid })
            return {
                put = function(id)
                    pcall(funcs.call, fid, { op = "put", session_id = id })
                end,
                has = function(id)
                    local okc, res = pcall(funcs.call, fid, { op = "has", session_id = id })
                    if not okc or type(res) ~= "table" then return false end
                    return res.valid == true
                end,
                remove = function(id)
                    pcall(funcs.call, fid, { op = "remove", session_id = id })
                end,
            }
        end
    end
    return nil
end

--- Get or create the shared handler instance
local function get_handler()
    if h then
        return h
    end

    h = handler.new({
        name = "wippy-mcp",
        version = "0.1.0",
        capabilities = { tools = true, prompts = true },
        store = resolve_store(),
    })

    emit = emitter.new(h.config.scope)

    log:info("handler initialized")

    return h
end

---------------------------------------------------------------------------
-- HTTP method handlers
---------------------------------------------------------------------------

--- Handle POST: JSON-RPC request/response
local function handle_post(req, res)
    local mcp = get_handler()

    -- Parse JSON body
    local data, parse_err = req:body_json()
    if parse_err or not data or type(data) ~= "table" then
        log:debug("invalid JSON body in POST request")
        res:set_header("Content-Type", "application/json")
        res:set_status(400)
        return res:write_json({error = "Invalid JSON body"})
    end

    -- Classify the JSON-RPC message
    local msg = jsonrpc.classify(data)

    -- Session management
    local session_id

    if msg.kind == "request" and msg.method == "initialize" then
        -- New session
        session_id = new_session_id()
        mcp:create_session(session_id)

        -- Emit session.created event (include clientInfo since handler events don't propagate)
        local client_ip = req:header("X-Forwarded-For") or req:header("X-Real-Ip")
        local user_agent = req:header("User-Agent")
        local params = msg.params or {}
        local client_info = params.clientInfo or {}
        emit:emit("session.created", session_id, "/sessions/" .. session_id, {
            transport = "http",
            client_ip = client_ip,
            user_agent = user_agent,
            client_name = client_info.name,
            client_version = client_info.version
        })

        log:info("new session", {
            session_id = session_id,
            client_ip = client_ip,
            user_agent = user_agent
        })
    else
        -- Existing session — read from header
        session_id = req:header("Mcp-Session-Id")
        if not session_id or not mcp:get_session(session_id) then
            -- For notifications, accept gracefully even without session ID.
            -- Some clients send notifications/initialized before processing
            -- the initialize response (race condition).
            if msg.kind == "notification" then
                log:debug("notification without valid session, accepting", {method = msg.method})
                res:set_status(202)
                return
            end

            log:debug("invalid or missing session header", {session_id = session_id})
            res:set_header("Content-Type", "application/json")
            res:set_status(400)
            return res:write_json({error = "Missing or invalid Mcp-Session-Id header"})
        end
    end

    -- Emit tool.called event BEFORE dispatch (events.send fails after funcs.call inside dispatch)
    if msg.kind == "request" and msg.method == "tools/call" then
        local tool_name = (msg.params or {}).name or "unknown"
        emit:emit("tool.called", session_id,
            "/sessions/" .. session_id .. "/tools/" .. tool_name, {
                tool_name = tool_name
            })
    end

    -- Dispatch through handler chain
    log:debug("dispatching", {session_id = session_id, method = msg.method})
    local response = mcp:dispatch(session_id, msg)

    if response then
        -- Set session ID header on initialize response
        if msg.kind == "request" and msg.method == "initialize" then
            res:set_header("Mcp-Session-Id", session_id)
        end

        res:set_header("Content-Type", "application/json")
        res:write(response)
    else
        -- Notification — no response body (MCP spec: 202 Accepted)
        res:set_status(202)
    end
end

--- Handle GET: SSE stream
--- Delegates to the SSE relay middleware for a long-lived connection.
--- The relay sends automatic heartbeat keepalives and manages the lifecycle.
local function handle_get(req, res)
    local mcp = get_handler()

    local session_id = req:header("Mcp-Session-Id")
    if not session_id or not mcp:get_session(session_id) then
        res:set_header("Content-Type", "application/json")
        res:set_status(400)
        return res:write_json({error = "Missing or invalid Mcp-Session-Id header"})
    end

    log:info("SSE stream opened", {session_id = session_id})

    -- Delegate to SSE relay middleware (detached mode — no target process needed).
    -- The relay keeps the connection open with automatic heartbeats.
    res:set_header("X-SSE-Relay", json.encode({
        heartbeat_interval = "15s",
        idle_timeout = "30m",
    }))
end

--- Handle DELETE: close session
local function handle_delete(req, res)
    local mcp = get_handler()

    local session_id = req:header("Mcp-Session-Id")
    if not session_id then
        res:set_header("Content-Type", "application/json")
        res:set_status(400)
        return res:write_json({error = "Missing Mcp-Session-Id header"})
    end

    if not mcp:get_session(session_id) then
        res:set_header("Content-Type", "application/json")
        res:set_status(404)
        return res:write_json({error = "Session not found"})
    end

    -- Emit session.destroyed event before deleting
    emit:emit("session.destroyed", session_id, "/sessions/" .. session_id, {
        transport = "http",
        reason = "client_delete"
    })

    mcp:delete_session(session_id)
    res:set_status(200)
end

---------------------------------------------------------------------------
-- Main handler: route by HTTP method
---------------------------------------------------------------------------

local function handler_fn()
    local req = http.request()
    local res = http.response()

    local method = req:method()

    if method == "POST" then
        handle_post(req, res)
    elseif method == "GET" then
        handle_get(req, res)
    elseif method == "DELETE" then
        handle_delete(req, res)
    else
        res:set_header("Content-Type", "application/json")
        res:set_status(405)
        res:write_json({error = "Method not allowed"})
    end
end

return { handler = handler_fn }
