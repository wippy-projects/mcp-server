-- MCP Protocol: handshake state machine and core method handlers
-- Handles initialize/initialized/ping lifecycle
-- Entry kind: library.lua

local jsonrpc = require("jsonrpc")

-- MCP protocol version
local PROTOCOL_VERSION = "2025-06-18"

-- Connection states
local STATE_DISCONNECTED = "disconnected"
local STATE_READY = "ready"

---------------------------------------------------------------------------
-- Server constructor
---------------------------------------------------------------------------

local function new_server(config)
    config = config or {}

    local server = {
        state = STATE_DISCONNECTED,
        server_info = {
            name = config.name or "wippy-mcp",
            version = config.version or "0.1.0"
        },
        client_info = nil,
        capabilities = config.capabilities or { tools = true },
        instructions = config.instructions
    }

    -- Build InitializeResult payload
    local function build_init_result()
        local caps = {}
        if server.capabilities.tools then
            caps.tools = { listChanged = false }
        end

        local result = {
            protocolVersion = PROTOCOL_VERSION,
            capabilities = caps,
            serverInfo = server.server_info
        }
        if server.instructions then
            result.instructions = server.instructions
        end
        return result
    end

    -- Handle initialize request
    local function handle_initialize(msg)
        if server.state ~= STATE_DISCONNECTED then
            return jsonrpc.encode_error(
                msg.id, jsonrpc.INVALID_REQUEST,
                "Server already initialized"
            )
        end

        local params = msg.params or {}
        server.client_info = params.clientInfo
        server.state = STATE_READY

        return jsonrpc.encode_response(msg.id, build_init_result())
    end

    -- Handle notifications/initialized
    local function handle_initialized(msg)
        return nil
    end

    -- Handle ping
    local function handle_ping(msg)
        if server.state ~= STATE_READY then
            return jsonrpc.encode_error(
                msg.id, jsonrpc.INVALID_REQUEST,
                "Server not initialized"
            )
        end
        return jsonrpc.encode_response(msg.id, {})
    end

    -- Main dispatch
    function server.handle(msg)
        if msg.kind == "notification" then
            if msg.method == "notifications/initialized" then
                return handle_initialized(msg)
            end
            return nil
        end

        if msg.kind == "request" then
            if msg.method == "initialize" then
                return handle_initialize(msg)
            end

            if server.state ~= STATE_READY then
                return jsonrpc.encode_error(
                    msg.id, jsonrpc.INVALID_REQUEST,
                    "Server not initialized"
                )
            end

            if msg.method == "ping" then
                return handle_ping(msg)
            end

            -- Unknown method: return nil so caller can dispatch to tools
            return nil
        end

        if msg.kind == "invalid" then
            return jsonrpc.parse_error(nil, msg.error or "Invalid message")
        end

        return nil
    end

    return server
end

return {
    PROTOCOL_VERSION = PROTOCOL_VERSION,
    STATE_DISCONNECTED = STATE_DISCONNECTED,
    STATE_READY = STATE_READY,
    new_server = new_server
}
