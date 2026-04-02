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


-- Returns array of { guid=string(upper), team=number, clientNum=number }
-- for every connected player on teams 1 (axis) or 2 (allies).
-- Spectators (team 3+) are always excluded.
function utils.get_connected_players(maxClients)
    maxClients = maxClients or (tonumber(et.trap_Cvar_Get("sv_maxclients")) or 24)
    local players = {}
    for i = 0, maxClients - 1 do
        if et.gentity_get(i, "pers.connected") == 2 then
            local team = tonumber(et.gentity_get(i, "sess.sessionTeam")) or 0
            if team == 1 or team == 2 then
                local userinfo = et.trap_GetUserinfo(i)
                if userinfo and userinfo ~= "" then
                    local guid = string.upper(et.Info_ValueForKey(userinfo, "cl_guid") or "")
                    if guid ~= "" then
                        players[#players + 1] = { guid = guid, team = team, clientNum = i }
                    end
                end
            end
        end
    end
    return players
end


function utils.build_guid_set(team_array)
    local set = {}
    for _, player in ipairs(team_array or {}) do
        for _, g in ipairs(player.GUID or {}) do
            set[string.upper(g)] = true
        end
    end
    return set
end


function utils.guid_overlap(guid_set, players_array)
    local set_size = 0
    for _ in pairs(guid_set) do set_size = set_size + 1 end
    local count = 0
    for _, p in ipairs(players_array) do
        if guid_set[p.guid] then count = count + 1 end
    end
    local denom = math.max(set_size, #players_array)
    return count, (denom > 0 and count / denom or 0)
end


function utils.fetch_player_tags(guids, api_token, players_url, http_module)
    if not http_module or not players_url or not players_url:find("^https?://") then return {} end
    if not guids or #guids == 0 then return {} end

    local parts = {}
    for _, g in ipairs(guids) do
        parts[#parts + 1] = "guid=" .. g
    end
    local url = players_url .. "?" .. table.concat(parts, "&")
    local cmd = string.format(
        "curl -H \"Authorization: Bearer %s\"" ..
        " --connect-timeout 1 --max-time 1 --retry 0 --silent --compressed \"%s\"",
        api_token or "", url)

    local result = http_module.sync(cmd)
    if type(result) ~= "table" then return {} end

    local out = {}
    for _, v in ipairs(result) do
        if type(v) == "table" and type(v.guid) == "string" then
            local raw_tag = v.user_tag_no_separator or v.user_tag
            if raw_tag and raw_tag ~= "" then
                -- Tags are comma-separated; strip {name}, split, pick one at random
                local candidates = {}
                for t in raw_tag:gmatch("[^,]+") do
                    t = t:gsub("{name}", ""):match("^%s*(.-)%s*$")
                    if t ~= "" then candidates[#candidates + 1] = t end
                end
                if #candidates > 0 then
                    out[v.guid:upper()] = candidates[math.random(#candidates)]
                end
            end
        end
    end
    return out
end


function utils.get_team_data_dir()
    local fs_basepath = et.trap_Cvar_Get("fs_basepath")
    local fs_game     = et.trap_Cvar_Get("fs_game")
    if not fs_basepath or not fs_game then return nil end
    return string.format("%s/%s/luascripts", fs_basepath, fs_game)
end

return utils
