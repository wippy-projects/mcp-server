-- MCP Tool Discovery & Dispatch
-- Discovers tools from Wippy registry (meta mcp.tool = true)
-- Handles tools/list and tools/call via registry.find() + funcs.call()
-- Entry kind: library.lua

local registry = require("registry")
local funcs = require("funcs")
local jsonrpc = require("jsonrpc")

---------------------------------------------------------------------------
-- Tool discovery from registry
---------------------------------------------------------------------------

local function discover()
    local entries, err = registry.find({kind = "function.lua"})
    if err then
        return nil, err
    end

    local tools = {}
    for _, entry in ipairs(entries) do
        local meta = entry.meta
        if meta and meta["mcp.tool"] == true then
            local name = meta["mcp.name"] or entry.id
            tools[name] = {
                entry_id = entry.id,
                name = name,
                description = meta["mcp.description"],
                inputSchema = meta["mcp.inputSchema"],
                annotations = meta["mcp.annotations"]
            }
        end
    end

    return tools, nil
end

---------------------------------------------------------------------------
-- tools/list handler
---------------------------------------------------------------------------

local function handle_list(id, params)
    local tools, err = discover()
    if err then
        return jsonrpc.internal_error(id, "Failed to discover tools: " .. tostring(err))
    end

    local tool_list = {}
    for _, tool in pairs(tools) do
        local entry = { name = tool.name }
        if tool.description then
            entry.description = tool.description
        end
        if tool.inputSchema then
            entry.inputSchema = tool.inputSchema
        end
        if tool.annotations then
            entry.annotations = tool.annotations
        end
        table.insert(tool_list, entry)
    end

    return jsonrpc.encode_response(id, {tools = tool_list})
end

---------------------------------------------------------------------------
-- tools/call handler
---------------------------------------------------------------------------

local function handle_call(id, params)
    local tool_name = params.name
    local arguments = params.arguments or {}

    if not tool_name or tool_name == "" then
        return jsonrpc.invalid_params(id, "Missing tool name")
    end

    local tools, err = discover()
    if err then
        return jsonrpc.internal_error(id, "Failed to discover tools: " .. tostring(err))
    end

    local tool = tools[tool_name]
    if not tool then
        return jsonrpc.invalid_params(id, "Unknown tool: " .. tool_name)
    end

    -- Invoke via funcs.call
    local result, call_err = funcs.call(tool.entry_id, arguments)

    if call_err then
        -- Tool errors → isError=true in result (per MCP spec)
        return jsonrpc.encode_response(id, {
            content = {{type = "text", text = tostring(call_err)}},
            isError = true
        })
    end

    -- Wrap result into MCP TextContent
    local content
    if type(result) == "string" then
        content = {{type = "text", text = result}}
    elseif type(result) == "table" and result.content then
        content = result.content
    else
        content = {{type = "text", text = tostring(result)}}
    end

    return jsonrpc.encode_response(id, {
        content = content,
        isError = false
    })
end

---------------------------------------------------------------------------
-- Top-level dispatch for tool methods
---------------------------------------------------------------------------

local function handle(msg)
    if msg.kind ~= "request" then
        return nil
    end

    if msg.method == "tools/list" then
        return handle_list(msg.id, msg.params or {})
    elseif msg.method == "tools/call" then
        return handle_call(msg.id, msg.params or {})
    end

    return nil
end

return {
    discover = discover,
    handle_list = handle_list,
    handle_call = handle_call,
    handle = handle
}
