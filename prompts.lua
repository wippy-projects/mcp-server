-- MCP Prompt Discovery & Dispatch
-- Discovers prompts from Wippy registry (meta mcp.prompt = true)
-- Handles prompts/list and prompts/get
-- Supports static prompts (messages in meta), dynamic prompts (function handler),
-- template inheritance (extend), and {{argument}} substitution
-- Entry kind: library.lua

local registry = require("registry")
local funcs = require("funcs")
local jsonrpc = require("jsonrpc")

---------------------------------------------------------------------------
-- Prompt discovery from registry
---------------------------------------------------------------------------

local function discover()
    local entries, err = registry.find({kind = "function.lua"})
    if err then
        return nil, err
    end

    local prompts = {}
    for _, entry in ipairs(entries) do
        local meta = entry.meta
        if meta and meta["mcp.prompt"] == true then
            local name = meta["mcp.prompt.name"] or entry.id
            prompts[name] = {
                entry_id = entry.id,
                name = name,
                description = meta["mcp.prompt.description"],
                prompt_type = meta["mcp.prompt.type"] or "prompt",
                tags = meta["mcp.prompt.tags"],
                arguments = meta["mcp.prompt.arguments"],
                messages = meta["mcp.prompt.messages"],
                extend = meta["mcp.prompt.extend"],
            }
        end
    end

    return prompts, nil
end

---------------------------------------------------------------------------
-- Argument substitution: replace {{name}} placeholders in text
---------------------------------------------------------------------------

local function substitute(text, arguments)
    if not text or not arguments then
        return text
    end
    local result = text
    for key, value in pairs(arguments) do
        result = string.gsub(result, "{{" .. key .. "}}", tostring(value))
    end
    return result
end

---------------------------------------------------------------------------
-- Resolve template inheritance (extend chain)
---------------------------------------------------------------------------

local function resolve_messages(prompt, all_prompts, arguments)
    local messages = {}

    -- 1. Resolve extended templates first (prepend their messages)
    if prompt.extend then
        for _, ext in ipairs(prompt.extend) do
            local parent = all_prompts[ext.id]
            if parent then
                -- Merge extension arguments with caller arguments
                local merged_args = {}
                if ext.arguments then
                    for k, v in pairs(ext.arguments) do
                        -- Extension arguments may contain {{placeholders}} too
                        merged_args[k] = substitute(tostring(v), arguments)
                    end
                end
                -- Also pass through caller arguments for any remaining placeholders
                if arguments then
                    for k, v in pairs(arguments) do
                        if not merged_args[k] then
                            merged_args[k] = v
                        end
                    end
                end

                -- Recursively resolve parent (supports multi-level inheritance)
                local parent_msgs = resolve_messages(parent, all_prompts, merged_args)
                for _, msg in ipairs(parent_msgs) do
                    table.insert(messages, msg)
                end
            end
        end
    end

    -- 2. Append this prompt's own messages
    if prompt.messages then
        for _, msg in ipairs(prompt.messages) do
            local content_text = msg.content
            if type(content_text) == "table" and content_text.text then
                content_text = content_text.text
            end
            table.insert(messages, {
                role = msg.role or "user",
                content = {
                    type = "text",
                    text = substitute(tostring(content_text), arguments)
                }
            })
        end
    end

    return messages
end

---------------------------------------------------------------------------
-- prompts/list handler
---------------------------------------------------------------------------

local function handle_list(id, params)
    local prompts, err = discover()
    if err then
        return jsonrpc.internal_error(id, "Failed to discover prompts: " .. tostring(err))
    end

    local prompt_list = {}
    for _, prompt in pairs(prompts) do
        -- Only list prompts, not templates
        if prompt.prompt_type ~= "template" then
            local entry = { name = prompt.name }
            if prompt.description then
                entry.description = prompt.description
            end
            -- Convert schema-style arguments to MCP PromptArgument format
            if prompt.arguments then
                local args = {}
                for _, arg in ipairs(prompt.arguments) do
                    local a = { name = arg.name }
                    if arg.description then
                        a.description = arg.description
                    end
                    if arg.required then
                        a.required = arg.required
                    end
                    table.insert(args, a)
                end
                entry.arguments = args
            end
            table.insert(prompt_list, entry)
        end
    end

    return jsonrpc.encode_response(id, {prompts = prompt_list})
end

---------------------------------------------------------------------------
-- prompts/get handler
---------------------------------------------------------------------------

local function handle_get(id, params)
    local prompt_name = params.name
    local arguments = params.arguments or {}

    if not prompt_name or prompt_name == "" then
        return jsonrpc.invalid_params(id, "Missing prompt name")
    end

    local prompts, err = discover()
    if err then
        return jsonrpc.internal_error(id, "Failed to discover prompts: " .. tostring(err))
    end

    local prompt = prompts[prompt_name]
    if not prompt then
        return jsonrpc.invalid_params(id, "Unknown prompt: " .. prompt_name)
    end

    -- Templates cannot be retrieved directly
    if prompt.prompt_type == "template" then
        return jsonrpc.invalid_params(id, "Cannot get template directly: " .. prompt_name)
    end

    -- Check if this is a dynamic prompt (has a function handler without static messages)
    local messages
    if not prompt.messages and not prompt.extend then
        -- Dynamic prompt: call the function handler
        local result, call_err = funcs.call(prompt.entry_id, arguments)
        if call_err then
            return jsonrpc.internal_error(id, "Prompt handler error: " .. tostring(call_err))
        end
        if type(result) == "table" and result.messages then
            messages = result.messages
        elseif type(result) == "string" then
            messages = {
                {role = "user", content = {type = "text", text = result}}
            }
        else
            messages = {}
        end
    else
        -- Static prompt: resolve from meta (with template inheritance)
        messages = resolve_messages(prompt, prompts, arguments)
    end

    local result = {messages = messages}
    if prompt.description then
        result.description = prompt.description
    end

    return jsonrpc.encode_response(id, result)
end

---------------------------------------------------------------------------
-- Top-level dispatch for prompt methods
---------------------------------------------------------------------------

local function handle(msg)
    if msg.kind ~= "request" then
        return nil
    end

    if msg.method == "prompts/list" then
        return handle_list(msg.id, msg.params or {})
    elseif msg.method == "prompts/get" then
        return handle_get(msg.id, msg.params or {})
    end

    return nil
end

return {
    discover = discover,
    handle_list = handle_list,
    handle_get = handle_get,
    handle = handle
}
