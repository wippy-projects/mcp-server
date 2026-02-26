-- MCP Event Emitter: standardized event emission via Wippy event bus
-- Ensures session_id, scope, and timestamp are always present in every event.
-- Entry kind: library.lua
--
-- Usage:
--   local emitter = require("emitter")
--   local e = emitter.new("public")  -- scope (optional)
--   e:emit("tool.called", session_id, "/sessions/abc/tools/foo", {tool_name = "foo"})

local events = require("events")
local time = require("time")
local logger = require("logger")

local log = logger:named("mcp.emitter")

local SYSTEM = "mcp"

local function new(scope)
    local e = { scope = scope }

    --- Emit an MCP event
    --- @param kind string Event kind (e.g. "session.created", "tool.called")
    --- @param session_id string Session identifier
    --- @param path string Event path (e.g. "/sessions/abc123/tools/foo")
    --- @param data table? Additional event data
    function e:emit(kind, session_id, path, data)
        data = data or {}
        data.session_id = session_id
        data.scope = self.scope
        data.timestamp = time.now():unix()

        log:debug("emit", {kind = kind, session_id = session_id, path = path})

        events.send(SYSTEM, kind, path, data)
    end

    return e
end

return { new = new }
