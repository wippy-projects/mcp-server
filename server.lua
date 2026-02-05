-- MCP Server Process: stdio transport
-- Reads JSON-RPC lines from stdin, dispatches through protocol + tools, writes to stdout
-- Entry kind: process.lua
-- Run: wippy run -s -x app.mcp:server

local function main()
    local io_mod = require("io")
    local jsonrpc = require("jsonrpc")
    local protocol = require("protocol")
    local tools = require("tools")

    -- Create protocol handler
    local server = protocol.new_server({
        name = "wippy-mcp",
        version = "0.1.0",
        capabilities = { tools = true }
    })

    --- Write a JSON-RPC response line to stdout
    local function send(response)
        if response then
            io_mod.write(response .. "\n")
            io_mod.flush()
        end
    end

    --- Process a single line from stdin
    local function handle_line(line)
        -- Decode JSON-RPC envelope
        local msg = jsonrpc.decode(line)

        -- Invalid JSON → parse error
        if msg.kind == "invalid" then
            send(jsonrpc.parse_error(nil, msg.error))
            return
        end

        -- Try protocol handler first (initialize, ping, notifications/initialized)
        local response = server.handle(msg)
        if response then
            send(response)
            return
        end

        -- Notifications handled by protocol return nil — no response needed
        if msg.kind == "notification" then
            return
        end

        -- Try tools handler (tools/list, tools/call)
        response = tools.handle(msg)
        if response then
            send(response)
            return
        end

        -- Unknown method
        if msg.kind == "request" then
            send(jsonrpc.method_not_found(msg.id, "Unknown method: " .. msg.method))
        end
    end

    -- Main loop: read stdin line by line
    while true do
        local line, err = io_mod.readline()
        if err then
            -- EOF or read error → exit gracefully
            return 0
        end

        if line and #line > 0 then
            handle_line(line)
        end
    end

    return 0
end

return { main = main }
