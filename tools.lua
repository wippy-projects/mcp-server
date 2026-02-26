-- MCP Tool Discovery & Dispatch
-- Discovers tools from Wippy registry (meta mcp.tool = true)
-- Handles tools/list and tools/call via registry.find() + funcs.call()
-- Entry kind: library.lua

local registry = require("registry")
local funcs = require("funcs")
local jsonrpc = require("jsonrpc")
local time = require("time")
local logger = require("logger")

local log = logger:named("mcp.tools")

---------------------------------------------------------------------------
-- Tool discovery from registry
---------------------------------------------------------------------------

local function discover(scope)
    local entries, err = registry.find({kind = "function.lua"})
    if err then
        log:error("tool discovery failed", {error = tostring(err)})
        return nil, err
    end

    local tools = {}
    local count = 0
    for _, entry in ipairs(entries) do
        local meta = entry.meta
        if meta and meta["mcp.tool"] == true then
            -- Scope filter: scoped tools only visible on matching endpoints
            if meta["mcp.scope"] and meta["mcp.scope"] ~= scope then
                -- skip: tool has a scope that doesn't match this endpoint
            else
                local name = meta["mcp.name"] or entry.id
                tools[name] = {
                    entry_id = entry.id,
                    name = name,
                    description = meta["mcp.description"],
                    inputSchema = meta["mcp.inputSchema"],
                    annotations = meta["mcp.annotations"]
                }
                count = count + 1
            end
        end
    end

    log:debug("tools discovered", {count = count, scope = scope})

    return tools, nil
end

---------------------------------------------------------------------------
-- tools/list handler
---------------------------------------------------------------------------

local function handle_list(id, params, scope)
    local tools, err = discover(scope)
    if err then
        return jsonrpc.internal_error(id, "Failed to discover tools: " .. tostring(err))
    end

    local tool_list = {}
    for _, tool in pairs(tools) do
        local entry = { name = tool.name }
        if tool.description then
            entry.description = tool.description
        end
        -- inputSchema is REQUIRED per MCP spec; default to empty object schema
        entry.inputSchema = tool.inputSchema or {type = "object"}
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

local function handle_call(id, params, scope)
    local tool_name = params.name
    local arguments = params.arguments or {}

    if not tool_name or tool_name == "" then
        return jsonrpc.invalid_params(id, "Missing tool name"), nil
    end

    local tools, err = discover(scope)
    if err then
        return jsonrpc.internal_error(id, "Failed to discover tools: " .. tostring(err)), nil
    end

    local tool = tools[tool_name]
    if not tool then
        return jsonrpc.invalid_params(id, "Unknown tool: " .. tool_name), nil
    end

    -- Invoke via funcs.call with duration measurement
    log:debug("calling tool", {tool = tool_name, entry_id = tool.entry_id})
    local start = time.now()
    local result, call_err = funcs.call(tool.entry_id, arguments)
    local duration_ms = time.now():sub(start):milliseconds()

    -- Build call metadata for event emission
    local call_info = {
        tool_name = tool_name,
        duration_ms = duration_ms,
        success = call_err == nil,
        error = call_err and tostring(call_err) or nil
    }

    if call_err then
        log:warn("tool call failed", {
            tool = tool_name,
            duration_ms = duration_ms,
            error = tostring(call_err)
        })
        -- Tool errors → isError=true in result (per MCP spec)
        return jsonrpc.encode_response(id, {
            content = {{type = "text", text = tostring(call_err)}},
            isError = true
        }), call_info
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
    }), call_info
end

---------------------------------------------------------------------------
-- Top-level dispatch for tool methods
---------------------------------------------------------------------------

local function handle(msg, scope)
    if msg.kind ~= "request" then
        return nil, nil
    end

    if msg.method == "tools/list" then
        return handle_list(msg.id, msg.params or {}, scope), nil
    elseif msg.method == "tools/call" then
        return handle_call(msg.id, msg.params or {}, scope)
    end

    return nil, nil
end

return {
    discover = discover,
    handle_list = handle_list,
    handle_call = handle_call,
    handle = handle
}
