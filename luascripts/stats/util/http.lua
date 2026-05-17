--[[
    stats/util/http.lua
    Async and sync curl helpers.  All external HTTP is funnelled here
--]]

local http = {}

function http.shell_escape(str)
    if not str then return "''" end
    return "'" .. str:gsub("'", "'\"'\"'") .. "'"
end

-- Write payload to a temp file
local function write_temp_payload(curl_cmd, payload)
    local tmp = os.tmpname() .. ".json"
    local f   = io.open(tmp, "w")
    if not f then
        return curl_cmd, nil, "Failed to create temp file"
    end
    f:write(payload)
    f:close()
    return curl_cmd .. " --data-binary @" .. http.shell_escape(tmp), tmp, nil
end

local ASYNC_FLAGS =
    " -H 'Content-Type: application/json'" ..
    " --compressed --connect-timeout 2 --max-time 10" ..
    " --retry 3 --retry-delay 1 --retry-max-time 15" ..
    " --silent --output /dev/null"

-- Fire-and-forget POST.
-- Pass compress=true to pipe the payload through gzip before sending.
-- The entire operation (compression + transfer + cleanup) runs in the background.
function http.async(curl_cmd, payload, compress)
    if payload then
        local tmp = os.tmpname() .. ".json"
        local f = io.open(tmp, "w")
        if not f then return false, "Failed to create temp file" end
        f:write(payload)
        f:close()

        if not curl_cmd:find("--retry") then
            curl_cmd = curl_cmd .. ASYNC_FLAGS
        end

        local shell_cmd
        if compress then
            -- gzip pipes directly into curl stdin; subshell cleans up tmp on exit
            shell_cmd = string.format(
                "(gzip -c %s | %s --data-binary @- -H 'Content-Encoding: gzip' ; rm -f %s) &",
                http.shell_escape(tmp), curl_cmd, http.shell_escape(tmp))
        else
            -- Original path: pass temp file directly, defer cleanup
            os.execute(string.format("sleep 15 && rm -f %s &", http.shell_escape(tmp)))
            shell_cmd = curl_cmd .. " --data-binary @" .. http.shell_escape(tmp) .. " &"
        end

        local ok = os.execute(shell_cmd)
        local success = (ok == true) or (ok == 0)
        return success, success and "sent" or "fork failed"
    end

    if not curl_cmd:find("--retry") then
        curl_cmd = curl_cmd .. ASYNC_FLAGS
    end
    local ok = os.execute(curl_cmd .. " &")
    local success = (ok == true) or (ok == 0)
    return success, success and "sent" or "fork failed"
end

-- used only at init/warmup, never inside a hot frame path.
local SYNC_FLAGS =
    " -H 'Content-Type: application/json'" ..
    " --compressed --connect-timeout 1 --max-time 2" ..
    " --retry 1 --retry-delay 0 --retry-max-time 3" ..
    " --silent"

local json  -- set lazily to avoid circular init order

function http.sync(curl_cmd, payload)
    if not json then
        json = require("dkjson")
    end

    local tmp
    if payload then
        local err
        curl_cmd, tmp, err = write_temp_payload(curl_cmd, payload)
        if not tmp then return nil, err end
    end

    if not curl_cmd:find("--retry") then
        curl_cmd = curl_cmd .. SYNC_FLAGS
    end

    local handle = io.popen(curl_cmd, "r")
    if tmp then os.remove(tmp) end

    if not handle then
        return nil, "Failed to spawn curl"
    end

    local result = handle:read("*a")
    handle:close()

    if not result or result == "" then
        return nil, "Empty response"
    end

    local ok, decoded = pcall(json.decode, result)
    if ok and decoded then return decoded end
    return result  -- return raw string if JSON parse fails
end

-- Callback-based async request: writes response body to a tempfile, atomically
-- signals completion via a .done marker, then poll_pending() dispatches to cb.
-- Use for any request that previously used http.sync() from a frame-path call site.
local _pending = {}
local _async_counter = 0

local ASYNC_REQ_FLAGS =
    " --silent --connect-timeout 2 --max-time 5" ..
    " --retry 2 --retry-delay 1 --retry-max-time 8"

local PENDING_TIMEOUT_MS = 30000

local function next_id()
    _async_counter = _async_counter + 1
    local ms = (et and et.trap_Milliseconds and et.trap_Milliseconds()) or (os.time() * 1000)
    return string.format("%d_%d", ms, _async_counter)
end

function http.async_request(curl_cmd, callback)
    if not curl_cmd:find("--connect-timeout") then
        curl_cmd = curl_cmd .. ASYNC_REQ_FLAGS
    end
    local id   = next_id()
    local resp = "/tmp/stats_async_" .. id .. ".resp"
    local done = "/tmp/stats_async_" .. id .. ".done"
    -- Write body to resp, then touch done. Stderr discarded. Backgrounded.
    local shell = string.format(
        "(%s -o %s 2>/dev/null ; touch %s) &",
        curl_cmd, http.shell_escape(resp), http.shell_escape(done))
    os.execute(shell)
    _pending[id] = {
        cb      = callback,
        resp    = resp,
        done    = done,
        started = (et and et.trap_Milliseconds and et.trap_Milliseconds()) or 0,
    }
    return id
end

local function dispatch(id, r, body, err)
    _pending[id] = nil
    if not r.cb then return end
    local decoded
    if body and body ~= "" then
        if not json then json = require("dkjson") end
        local ok, d = pcall(json.decode, body)
        if ok then decoded = d end
    end
    pcall(r.cb, decoded, body, err)
end

-- Polls for completed async requests. The optional argument is ignored; we
-- always read et.trap_Milliseconds() so the elapsed-time math uses the same
-- clock as r.started (caller-passed level_time would mismatch across map
-- changes and trigger spurious timeouts).
function http.poll_pending(_unused)
    if not next(_pending) then return end
    local now = (et and et.trap_Milliseconds and et.trap_Milliseconds()) or 0
    for id, r in pairs(_pending) do
        local df = io.open(r.done, "r")
        if df then
            df:close()
            local body
            local rf = io.open(r.resp, "r")
            if rf then body = rf:read("*a"); rf:close() end
            os.remove(r.resp)
            os.remove(r.done)
            dispatch(id, r, body, nil)
        elseif (now - r.started) > PENDING_TIMEOUT_MS then
            os.remove(r.resp)
            os.remove(r.done)
            dispatch(id, r, nil, "timeout")
        end
    end
end

-- Best-effort public IP lookup (used when net_ip is 0.0.0.0).
function http.getPublicIP()
    local result = http.sync(
        "curl -s --connect-timeout 2 --max-time 5 https://api.ipify.org?format=json"
    )
    if type(result) == "table" and result.ip then
        return result.ip
    end
    return "0.0.0.0"
end

return http
