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
function http.async(curl_cmd, payload)
    if payload then
        local cmd, tmp, err = write_temp_payload(curl_cmd, payload)
        if not tmp then return false, err end
        curl_cmd = cmd
        -- Deferred cleanup: remove after curl finishes (max ~15 s)
        os.execute(string.format("sleep 15 && rm -f %s &",
            http.shell_escape(tmp)))
    end

    if not curl_cmd:find("--retry") then
        curl_cmd = curl_cmd .. ASYNC_FLAGS
    end
    curl_cmd = curl_cmd .. " &"

    local ok = os.execute(curl_cmd)
    local success = (ok == true) or (ok == 0)  -- Lua 5.1 returns int 0; 5.2+ returns true
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
