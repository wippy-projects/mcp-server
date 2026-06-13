-- MCP Tool Discovery & Dispatch
-- Discovers tools from Wippy registry (meta mcp.tool = true)
-- Handles tools/list and tools/call via registry.find() + funcs.call()
-- Entry kind: library.lua

local registry = require("registry")
local funcs = require("funcs")
local security = require("security")
local jsonrpc = require("jsonrpc")
local time = require("time")
local logger = require("logger")

local log = logger:named("mcp.tools")

---------------------------------------------------------------------------
-- Per-tool authorization (RBAC)
--
-- A tool MAY declare `meta["mcp.groups"] = {"<group-id>", ...}` — the security
-- groups allowed to see/call it. It is visible only if the current actor belongs
-- to at least one of them. Tools without `mcp.groups` are public.
--
-- The actor's groups are read from `security.actor():meta().groups`, which the
-- host populates at login (no DB round-trip). A nil actor or an actor with no
-- groups (stdio / anonymous) fails closed.
--
-- Gating both `tools/list` (here) and `tools/call` happens for free: handle_call
-- re-runs discover(), so an unauthorized tool is simply absent → "Unknown tool"
-- (leak-safe — indistinguishable from a nonexistent tool).
--
-- Emergency kill-switch (host-tunable, no redeploy): the host app may declare a
-- `registry.entry` with `meta.type = "mcp.gating"` whose data carries
-- `emergency_hide_gated = true`, which hides ALL gated tools (fail-SAFE).
---------------------------------------------------------------------------

local function gating_emergency_hide()
    local entries = registry.find({ ["meta.type"] = "mcp.gating" })
    if not entries then return false end
    for _, e in ipairs(entries) do
        if e.data and e.data.emergency_hide_gated == true then
            return true
        end
    end
    return false
end

-- Set of the current actor's security groups (or nil if no actor / no groups).
local function actor_group_set()
    local actor = security.actor()
    if not actor then return nil end
    local meta = actor:meta()
    local groups = meta and meta.groups
    if type(groups) ~= "table" then return nil end
    local set = {}
    for _, g in ipairs(groups) do set[g] = true end
    return set
end

local function authorized(meta, emergency_hide, group_set)
    local required = meta["mcp.groups"]
    if not required then
        return true -- public tool, no gate
    end
    if emergency_hide then
        return false -- kill-switch active: hide all gated tools
    end
    if not group_set then
        return false -- nil actor / no groups → fail closed
    end
    for _, g in ipairs(required) do
        if group_set[g] then
            return true -- member of at least one allowed group
        end
    end
    return false
end

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
    local emergency_hide = gating_emergency_hide()
    local group_set = actor_group_set()
    for _, entry in ipairs(entries) do
        local meta = entry.meta
        if meta and meta["mcp.tool"] == true then
            -- Scope filter: scoped tools only visible on matching endpoints
            if meta["mcp.scope"] and meta["mcp.scope"] ~= scope then
                -- skip: tool has a scope that doesn't match this endpoint
            elseif not authorized(meta, emergency_hide, group_set) then
                -- skip: actor not in an allowed group for this gated tool (RBAC)
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

    -- Invoke via funcs.call with duration measurement, protected by pcall
    log:debug("calling tool", {tool = tool_name, entry_id = tool.entry_id})
    local start = time.now()
    local ok, result, call_err = pcall(funcs.call, tool.entry_id, arguments)
    local duration_ms = time.now():sub(start):milliseconds()

    -- pcall caught a Lua runtime error
    if not ok then
        local err_msg = tostring(result) -- pcall puts error in first return
        log:error("tool call crashed", {
            tool = tool_name,
            entry_id = tool.entry_id,
            duration_ms = duration_ms,
            error = err_msg
        })
        return jsonrpc.encode_response(id, {
            content = {{type = "text", text = "Tool error: " .. err_msg}},
            isError = true
        }), {
            tool_name = tool_name,
            duration_ms = duration_ms,
            success = false,
            error = err_msg
        }
    end

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

    -- Wrap result into MCP TextContent, preserving isError from tool
    local content
    local is_error = false
    if type(result) == "string" then
        content = {{type = "text", text = result}}
    elseif type(result) == "table" and result.content then
        content = result.content
        is_error = result.isError == true
    else
        content = {{type = "text", text = tostring(result)}}
    end

    if is_error then
        log:warn("tool returned error", {
            tool = tool_name,
            duration_ms = duration_ms
        })
        call_info.success = false
    end

    return jsonrpc.encode_response(id, {
        content = content,
        isError = is_error
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
