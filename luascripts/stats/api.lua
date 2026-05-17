--[[
    stats/api.lua
    API interactions: match-ID fetch, route validation, version check.
    All HTTP is non-blocking; callers register callbacks. Results dispatched
    from util/http.poll_pending() which runs every et_RunFrame.
--]]

local api = {}

local log
local http_ref
local names_ref

local _api_token        = ""
local _url_matchid      = ""
local _url_version      = ""
local _version_check    = false
local _version          = "unknown"

local _server_ip        = ""
local _server_port      = ""

local _fetch_in_flight = false

-- Cached match ID from last successful fetch.
api.cached_match_id = nil

function api.init(cfg, log_ref, http_module, names_module, version_str)
    log        = log_ref
    http_ref   = http_module
    names_ref  = names_module

    _api_token     = cfg.api_token     or ""
    _url_matchid   = cfg.api_url_matchid or ""
    _url_version   = cfg.api_url_version or ""
    _version_check = cfg.version_check  or false
    _version       = version_str or "unknown"

    _server_ip   = cfg.server_ip   or ""
    _server_port = cfg.server_port or ""
end

-- Allow server ip/port to be updated after init
function api.set_server_info(ip, port)
    _server_ip   = ip
    _server_port = port
end

function api.fetch_match_id(on_complete)
    if not _url_matchid or _url_matchid == "" then
        api.cached_match_id = tostring(os.time())
        if on_complete then pcall(on_complete, api.cached_match_id) end
        return
    end

    if _fetch_in_flight then
        if log then log.debug("API fetch already in flight — skipping duplicate") end
        return
    end
    _fetch_in_flight = true

    local url      = string.format("%s/%s/%s", _url_matchid, _server_ip, _server_port)
    local curl_cmd = string.format(
        "curl -s -H \"Authorization: Bearer %s\" %s",
        _api_token, url)

    http_ref.async_request(curl_cmd, function(result, _body, err)
        _fetch_in_flight = false
        local match_id
        if type(result) == "table" and result.match_id and result.match_id ~= "" then
            match_id = result.match_id
            api.cached_match_id = match_id
            if names_ref and result.match then
                names_ref.on_team_data_fetched(match_id, result.match)
            end
            if log then
                log.write(string.format("API fetch OK — match_id: %s", match_id))
            end
        else
            match_id = tostring(os.time())
            api.cached_match_id = match_id
            if log then
                log.write(string.format(
                    "API fetch failed (%s), using unix-time as match_id: %s",
                    err or "no data", match_id))
            end
        end
        if on_complete then pcall(on_complete, match_id) end
    end)
end

-- Async route validation. cb(true) = route confirms expected_match_id, cb(false) =
-- route reports a different match_id or no data, cb(nil) = network/timeout error.
function api.validate_route_async(expected_match_id, cb)
    if not expected_match_id or expected_match_id == "" then
        if cb then pcall(cb, false) end
        return
    end
    if not _url_matchid or _url_matchid == "" then
        if cb then pcall(cb, true) end
        return
    end

    local url      = string.format("%s/%s/%s", _url_matchid, _server_ip, _server_port)
    local curl_cmd = string.format(
        "curl -s -H \"Authorization: Bearer %s\" %s",
        _api_token, url)

    http_ref.async_request(curl_cmd, function(result, _body, err)
        if err then
            if cb then pcall(cb, nil) end
            return
        end
        local ok = (type(result) == "table" and result.match_id == expected_match_id)
        if cb then pcall(cb, ok) end
    end)
end


local function parse_version(v)
    local ma, mi, pa = v:match("^(%d+)%.(%d+)%.(%d+)")
    if ma then return tonumber(ma), tonumber(mi), tonumber(pa) end
end

local function version_older_than(a, b)
    local ama, ami, apa = parse_version(a)
    local bma, bmi, bpa = parse_version(b)
    if not ama or not bma then return false end
    if ama ~= bma then return ama < bma end
    if ami ~= bmi then return ami < bmi end
    return apa < bpa
end

function api.check_version()
    if not _version_check then return end
    if not _url_version or _url_version == "" then return end

    local curl_cmd = string.format(
        "curl -s -H \"Authorization: Bearer %s\" %s",
        _api_token, _url_version)

    if log then log.debug("Checking version against API…") end

    http_ref.async_request(curl_cmd, function(result, _body, err)
        if err or type(result) ~= "table" or not result.version then
            if log then log.write("Version check: no data received") end
            return
        end
        local latest = result.version
        if log then
            log.debug(string.format("Version check — current: %s, latest: %s", _version, latest))
        end
        if version_older_than(_version, latest) then
            et.trap_SendServerCommand(-1, string.format(
                "chat \"^3stats.lua^7 is outdated (^i%s^7).\"", _version))
            et.trap_SendServerCommand(-1, string.format(
                "chat \"^7Please update to the latest version (^2%s^7) ASAP.\"", latest))
        end
    end)
end

function api.reset()
    api.cached_match_id = nil
    _fetch_in_flight    = false
end

return api
