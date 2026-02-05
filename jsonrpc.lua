-- JSON-RPC 2.0 codec for MCP server
-- Pure protocol plumbing: encode/decode JSON-RPC envelopes
-- Entry kind: library.lua

local json = require("json")

-- JSON-RPC 2.0 version constant
local JSONRPC_VERSION = "2.0"

-- Standard JSON-RPC error codes
local PARSE_ERROR = -32700
local INVALID_REQUEST = -32600
local METHOD_NOT_FOUND = -32601
local INVALID_PARAMS = -32602
local INTERNAL_ERROR = -32603
local SERVER_ERROR = -32000

---------------------------------------------------------------------------
-- Encoding: table → JSON string
---------------------------------------------------------------------------

--- Encode a JSON-RPC success response
local function encode_response(id, result)
    local msg = {
        jsonrpc = JSONRPC_VERSION,
        id = id,
        result = result
    }
    local encoded = json.encode(msg)

    -- Workaround: Wippy's json.encode turns empty tables into [].
    -- MCP requires {} for empty results (ping, empty capabilities).
    encoded = string.gsub(encoded, '"result":%[%]', '"result":{}')
    return encoded
end

--- Encode a JSON-RPC error response
local function encode_error(id, code, message, data)
    local err_obj = {
        code = code,
        message = message
    }
    if data ~= nil then
        err_obj.data = data
    end

    local msg = {
        jsonrpc = JSONRPC_VERSION,
        id = id,
        error = err_obj
    }
    return json.encode(msg)
end

--- Encode a JSON-RPC notification (no id, no response expected)
local function encode_notification(method, params)
    local msg = {
        jsonrpc = JSONRPC_VERSION,
        method = method
    }
    if params ~= nil then
        msg.params = params
    end
    return json.encode(msg)
end

---------------------------------------------------------------------------
-- Decoding: JSON string → classified table
---------------------------------------------------------------------------

--- Decode a JSON-RPC line and classify it
local function decode(line)
    local data, err = json.decode(line)
    if err then
        return {
            kind = "invalid",
            error = "Parse error: " .. tostring(err)
        }
    end

    if type(data) ~= "table" then
        return {
            kind = "invalid",
            error = "Expected JSON object, got " .. type(data)
        }
    end

    if data.jsonrpc ~= JSONRPC_VERSION then
        return {
            kind = "invalid",
            error = "Missing or invalid jsonrpc version"
        }
    end

    if type(data.method) ~= "string" then
        return {
            kind = "invalid",
            error = "Missing or invalid method field"
        }
    end

    local params = data.params
    if params == nil then
        params = {}
    elseif type(params) ~= "table" then
        return {
            kind = "invalid",
            error = "params must be an object"
        }
    end

    if data.id ~= nil then
        return {
            kind = "request",
            id = data.id,
            method = data.method,
            params = params
        }
    else
        return {
            kind = "notification",
            method = data.method,
            params = params
        }
    end
end

---------------------------------------------------------------------------
-- Error helper constructors
---------------------------------------------------------------------------

local function parse_error(id, message)
    return encode_error(id, PARSE_ERROR, message or "Parse error")
end

local function invalid_request(id, message)
    return encode_error(id, INVALID_REQUEST, message or "Invalid request")
end

local function method_not_found(id, message)
    return encode_error(id, METHOD_NOT_FOUND, message or "Method not found")
end

local function invalid_params(id, message)
    return encode_error(id, INVALID_PARAMS, message or "Invalid params")
end

local function internal_error(id, message)
    return encode_error(id, INTERNAL_ERROR, message or "Internal error")
end

local function server_error(id, message)
    return encode_error(id, SERVER_ERROR, message or "Server error")
end

---------------------------------------------------------------------------
-- Module exports
---------------------------------------------------------------------------

return {
    JSONRPC_VERSION = JSONRPC_VERSION,
    PARSE_ERROR = PARSE_ERROR,
    INVALID_REQUEST = INVALID_REQUEST,
    METHOD_NOT_FOUND = METHOD_NOT_FOUND,
    INVALID_PARAMS = INVALID_PARAMS,
    INTERNAL_ERROR = INTERNAL_ERROR,
    SERVER_ERROR = SERVER_ERROR,

    encode_response = encode_response,
    encode_error = encode_error,
    encode_notification = encode_notification,

    decode = decode,

    parse_error = parse_error,
    invalid_request = invalid_request,
    method_not_found = method_not_found,
    invalid_params = invalid_params,
    internal_error = internal_error,
    server_error = server_error
}
