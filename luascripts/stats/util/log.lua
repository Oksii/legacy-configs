--[[
    stats/util/log.lua
    Shared logger with verbosity levels.

    Levels:
        "info"  — key lifecycle events (init, round start/end, stat saves, errors)
        "debug" — everything including per-event verbose trace

    Usage:
        log.init(filepath, enabled, level)
        log.write(message)        -- always written when logging is enabled
        log.debug(message)        -- written only when level == "debug"
--]]

local log = {}

local _filepath    = nil
local _enabled     = false
local _level       = "info"   -- "info" | "debug"
local _init_buffer = nil      -- nil = off; table = buffering active (batch file writes)

function log.init(filepath, enabled, level)
    _filepath = filepath
    _enabled  = enabled == true
    _level    = (level == "debug") and "debug" or "info"
end

local function write_line(message)
    local ms   = et.trap_Milliseconds() % 1000
    local line = string.format("[%s.%03d] %s\n",
        os.date("%Y-%m-%d %H:%M:%S"), ms, message)
    if _init_buffer then
        table.insert(_init_buffer, line)
        return
    end
    local ok, err = pcall(function()
        local file, open_err = io.open(_filepath, "a")
        if not file then
            et.G_LogPrint(string.format("[stats] Failed to open log: %s\n",
                open_err or "unknown"))
            return
        end
        local wok, werr = pcall(function() file:write(line) end)
        file:close()
        if not wok then
            et.G_LogPrint(string.format("[stats] Log write error: %s\n",
                werr or "unknown"))
        end
    end)
    if not ok then
        et.G_LogPrint(string.format("[stats] Logging error: %s\n", err or "unknown"))
    end
end

-- Start buffering log writes. Call buffer_flush() to write them all in one file open/close.
function log.buffer_start()
    if _enabled and _filepath then _init_buffer = {} end
end

-- Flush buffered lines to disk as a single append operation, then disable buffering.
function log.buffer_flush()
    if not _init_buffer then return end
    local buf = _init_buffer
    _init_buffer = nil
    if #buf == 0 then return end
    local file, err = io.open(_filepath, "a")
    if file then
        for _, line in ipairs(buf) do file:write(line) end
        file:close()
    else
        et.G_LogPrint(string.format("[stats] Failed to open log on flush: %s\n",
            err or "unknown"))
    end
end


function log.write(message)
    if not _enabled or not _filepath then return end
    write_line(message)
end


function log.debug(message)
    if not _enabled or not _filepath or _level ~= "debug" then return end
    write_line("[DEBUG] " .. message)
end


function log.is_debug()
    return _enabled and _level == "debug"
end

return log
