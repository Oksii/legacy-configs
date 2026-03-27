--[[
    stats/api.lua
    API interactions: match-ID fetch, version check.
    Uses http.sync() for init-time calls only (never in a hot frame path).
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

function api.fetch_match_id()
    if not _url_matchid or _url_matchid == "" then
        api.cached_match_id = tostring(os.time())
        return api.cached_match_id
    end

    local url      = string.format("%s/%s/%s", _url_matchid, _server_ip, _server_port)
    local curl_cmd = string.format(
        "curl -H \"Authorization: Bearer %s\" --connect-timeout 1 --max-time 2 %s",
        _api_token, url)

    local result = http_ref.sync(curl_cmd)

    if type(result) == "table" and result.match_id and result.match_id ~= "" then
        api.cached_match_id = result.match_id

        if names_ref and result.match then
            names_ref.on_team_data_fetched(result.match_id, result.match)
        end

        if log then
            log.write(string.format("API fetch OK — match_id: %s", result.match_id))
        end
        return result.match_id
    end

    -- Fallback
    local fallback = tostring(os.time())
    api.cached_match_id = fallback
    if log then
        log.write("API fetch failed, using unix-time as match_id: " .. fallback)
    end
    return fallback
end

-- Checks if the route is still registered for expected_match_id.
-- No side effects: does not update cached_match_id or call gather callbacks.
-- Returns true only if the route responds with the exact same match_id.
function api.validate_route(expected_match_id)
    if not expected_match_id or expected_match_id == "" then return false end
    if not _url_matchid or _url_matchid == "" then return true end

    local url      = string.format("%s/%s/%s", _url_matchid, _server_ip, _server_port)
    local curl_cmd = string.format(
        "curl -H \"Authorization: Bearer %s\" --connect-timeout 1 --max-time 2 %s",
        _api_token, url)

    local result = http_ref.sync(curl_cmd)
    return type(result) == "table" and result.match_id == expected_match_id
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
        "curl -H \"Authorization: Bearer %s\" %s",
        _api_token, _url_version)

    if log then log.debug("Checking version against API…") end

    local result = http_ref.sync(curl_cmd)

    if type(result) == "table" and result.version then
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
    else
        if log then log.write("Version check: no data received") end
    end
end

function api.reset()
    api.cached_match_id = nil
end

return api
