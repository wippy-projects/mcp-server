-- MCP Server Process: stdio transport
-- Reads JSON-RPC lines from stdin, dispatches through handler, writes to stdout
-- Entry kind: process.lua
-- Run: wippy run -s -x mcp:server

local function main()
    local io_mod = require("io")
    local jsonrpc = require("jsonrpc")
    local handler = require("handler")
    local emitter = require("emitter")
    local logger = require("logger")

    local log = logger:named("mcp.stdio")

    -- Create handler with a single stdio session
    local h = handler.new({
        name = "wippy-mcp",
        version = "0.1.0",
        capabilities = { tools = true, prompts = true }
    })
    h:create_session("stdio")

    local emit = emitter.new(h.config.scope)

    -- Emit session.created for stdio
    emit:emit("session.created", "stdio", "/sessions/stdio", {
        transport = "stdio"
    })

    log:info("server started", {transport = "stdio"})

    --- Write a JSON-RPC response line to stdout
    local function send(response)
        if response then
            io_mod.write(response .. "\n")
            io_mod.flush()
        end
    end

    -- Main loop: read stdin line by line
    while true do
        local line, err = io_mod.readline()
        if err then
            -- EOF or read error → emit session.destroyed and exit gracefully
            log:info("stdin closed, shutting down", {reason = "eof"})
            emit:emit("session.destroyed", "stdio", "/sessions/stdio", {
                transport = "stdio",
                reason = "eof"
            })
            return 0
        end

        if line and #line > 0 then
            log:debug("received message", {length = #line})
            local msg = jsonrpc.decode(line)
            local response = h:dispatch("stdio", msg)
            send(response)
        end
    end

    return 0
end

return { main = main }
