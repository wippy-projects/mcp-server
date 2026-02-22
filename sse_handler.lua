-- MCP HTTP Handler: Streamable HTTP transport (POST/GET/DELETE)
-- Single endpoint that routes by HTTP method
-- Entry kind: function.lua
--
-- Wippy HTTP handlers receive no arguments — use http.request() / http.response()

local http = require("http")
local json = require("json")
local jsonrpc = require("jsonrpc")
local handler = require("handler")

-- Shared handler instance (created on first request)
local h = nil
local session_counter = 0

--- Generate a new session ID
local function new_session_id()
    session_counter = session_counter + 1
    local id = string.format("%x%x", os.time(), session_counter)
    return id
end

--- Get or create the shared handler instance
local function get_handler()
    if h then
        return h
    end

    h = handler.new({
        name = "wippy-mcp",
        version = "0.1.0",
        capabilities = { tools = true, prompts = true }
    })

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
    else
        -- Existing session — read from header
        session_id = req:header("Mcp-Session-Id")
        if not session_id or not mcp:get_session(session_id) then
            res:set_status(400)
            return res:write_json({error = "Missing or invalid Mcp-Session-Id header"})
        end
    end

    -- Dispatch through handler chain
    local response = mcp:dispatch(session_id, msg)

    if response then
        -- Set session ID header on initialize response
        if msg.kind == "request" and msg.method == "initialize" then
            res:set_header("Mcp-Session-Id", session_id)
        end

        res:set_header("Content-Type", "application/json")
        res:write(response)
    else
        -- Notification — no response body
        res:set_status(204)
    end
end

--- Handle GET: SSE stream (not yet implemented)
local function handle_get(req, res)
    res:set_status(405)
    res:write_json({error = "SSE streaming not yet supported"})
end

--- Handle DELETE: close session
local function handle_delete(req, res)
    local mcp = get_handler()

    local session_id = req:header("Mcp-Session-Id")
    if not session_id then
        res:set_status(400)
        return res:write_json({error = "Missing Mcp-Session-Id header"})
    end

    if not mcp:get_session(session_id) then
        res:set_status(404)
        return res:write_json({error = "Session not found"})
    end

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
        res:set_status(405)
        res:write_json({error = "Method not allowed"})
    end
end

return { handler = handler_fn }
