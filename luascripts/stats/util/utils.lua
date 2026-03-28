--[[
    stats/util/utils.lua
    Shared utility functions
--]]

local utils = {}

-- Strip ET color codes
function utils.strip_colors(text)
    if not text then return "" end
    return (text:gsub("%^%w", ""))
end


function utils.normalize(key)
    if type(key) ~= "string" then
        return tostring(key):lower()
    end
    return key:lower()
end


-- Sanitize arbitrary data for safe JSON embedding.
-- Strings are escape-cleaned and truncated; tables are recursed.
-- UTF-8 multi-byte sequences (0x80-0xFF) are passed through as-is — ET:Legacy supports them.
local ESCAPE_MAP = {
    ['"']  = '\\"',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

function utils.sanitize(data, max_len)
    max_len = max_len or 256
    local t = type(data)

    if t == "string" then
        local s = data:gsub('["\n\r\t]', ESCAPE_MAP)
        s = s:gsub('%c', '')  -- strip null bytes and remaining control chars; leaves UTF-8 high bytes intact
        if #s > max_len then
            return s:sub(1, max_len) .. "..."
        end
        return s

    elseif t == "table" then
        local out = {}
        for k, v in pairs(data) do
            local sk = type(k) == "string" and utils.sanitize(k, max_len) or k
            out[sk]  = utils.sanitize(v, max_len)
        end
        return out

    elseif t == "number" or t == "boolean" then
        return data

    else
        return ""
    end
end


function utils.table_count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- 3-D Euclidean distance between two {x,y,z} tables or arrays
-- Returns metres (1 m ≈ 39.37 game units)
function utils.distance3d(a, b)
    if not a or not b then return 0 end
    local dx = b[1] - a[1]
    local dy = b[2] - a[2]
    local dz = b[3] - a[3]
    return math.sqrt(dx*dx + dy*dy + dz*dz) / 39.37
end

-- Raw Euclidean distance in game units
function utils.distance3d_units(a, b)
    if not a or not b then return 0 end
    local dx = b[1] - a[1]
    local dy = b[2] - a[2]
    local dz = b[3] - a[3]
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end


function utils.convert_timelimit(timelimit)
    local msec    = math.floor(tonumber(timelimit) * 60000)
    local seconds = math.floor(msec / 1000)
    local mins    = math.floor(seconds / 60)
    seconds       = seconds - mins * 60
    local tens    = math.floor(seconds / 10)
    local ones    = seconds - tens * 10
    return string.format("%d:%d%d", mins, tens, ones)
end


function utils.fmt_pos(pos)
    if not pos then return nil end
    return string.format("%d %d %d",
        math.floor(pos[1] + 0.5),
        math.floor(pos[2] + 0.5),
        math.floor(pos[3] + 0.5))
end


-- Resolve ^~ placeholders in a string to random unique ET color codes.
-- Each ^~ gets a color not already present elsewhere in the string.
-- Valid ET color characters: 0-9, A-Z, a-z.
local ET_COLOR_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

function utils.resolve_random_colors(text)
    if not text or not text:find("%^~") then return text end

    local used = {}
    for c in text:gmatch("%^([0-9A-Za-z])") do
        used[c] = true
    end

    local pool = {}
    for i = 1, #ET_COLOR_CHARS do
        local c = ET_COLOR_CHARS:sub(i, i)
        if not used[c] then pool[#pool + 1] = c end
    end
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end

    local idx = 0
    return (text:gsub("%^~", function()
        idx = idx + 1
        return pool[idx] and ("^" .. pool[idx]) or "^7"
    end))
end


function utils.say(msg)
    et.trap_SendServerCommand(-1, "chat \"" .. msg .. "\"")
end


function utils.cp(msg)
    et.trap_SendServerCommand(-1, "cp \"" .. msg .. "\"")
end

return utils
