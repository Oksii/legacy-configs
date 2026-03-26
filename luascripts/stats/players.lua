--[[
    stats/players.lua
    Player GUID/team cache, class-switch tracking,
--]]

local players                   = {}
local utils                     = require("luascripts/stats/util/utils")

local log
local _maxClients               = 24

local CON_CONNECTED             = 2

local EF_DEAD                   = 0x00000001
local EF_CROUCHING              = 0x00000010
local EF_MG42_ACTIVE            = 0x00000020
local EF_MOUNTEDTANK            = 0x00008000
local EF_PRONE                  = 0x00080000
local EF_PRONE_MOVING           = 0x00100000
local EF_TAGCONNECT             = 0x00008000  -- vehicle escort

local MAX_SPRINT_TIME           = 20000
local STAMINA_CHANGE_THRESHOLD  = 50

local WP_MOBILE_MG42_SET        = 47
local WP_MOBILE_BROWNING_SET    = 50

local PW_REDFLAG                = 5
local PW_BLUEFLAG               = 6
local PW_OPS_DISGUISED          = 7

local BODY_DOWNED               = 67108864

local CLASS_LOOKUP = {
    [0] = "soldier",
    [1] = "medic",
    [2] = "engineer",
    [3] = "fieldop",
    [4] = "covertops",
}

players.guids = setmetatable({}, {
    __index = function(t, clientNum)
        if type(clientNum) ~= "number" then
            return { guid = "WORLD", team = 0 }
        end

        if clientNum >= 0 and clientNum < _maxClients then
            local userinfo = et.trap_GetUserinfo(clientNum)
            if userinfo and userinfo ~= "" then
                local guid = string.upper(et.Info_ValueForKey(userinfo, "cl_guid"))
                local team = tonumber(et.gentity_get(clientNum, "sess.sessionTeam")) or 0
                if guid and guid ~= "" then
                    t[clientNum] = { guid = guid, team = team }
                    return t[clientNum]
                end
            end
        end

        return { guid = "WORLD", team = 0 }
    end,
})


-- players.class_switches[guid] → array of { timestamp, from_class, to_class }
players.class_switches = {}

local _last_sprint_time = {}  -- [guid] = last sprint value from ps.stats[8]

function players.init(log_ref, maxClients)
    log = log_ref
    _maxClients = maxClients or 64
end


function players.get_snapshot(clientNum)
    if type(clientNum) ~= "number" or clientNum < 0 then return nil end

    local entry = players.guids[clientNum]
    if not entry or entry.guid == "WORLD" then return nil end

    local eFlags  = tonumber(et.gentity_get(clientNum, "ps.eFlags"))   or 0
    local health  = tonumber(et.gentity_get(clientNum, "health"))       or 0
    local body    = tonumber(et.gentity_get(clientNum, "r.contents"))   or 0
    local leanf   = tonumber(et.gentity_get(clientNum, "ps.leanf"))     or 0
    local weapon  = tonumber(et.gentity_get(clientNum, "ps.weapon"))    or 0
    local pt      = tonumber(et.gentity_get(clientNum, "sess.playerType")) or 0

    local red_flag  = tonumber(et.gentity_get(clientNum, "ps.powerups", PW_REDFLAG))       or 0
    local blue_flag = tonumber(et.gentity_get(clientNum, "ps.powerups", PW_BLUEFLAG))      or 0
    local disguise  = tonumber(et.gentity_get(clientNum, "ps.powerups", PW_OPS_DISGUISED)) or 0

    local sprint_time = tonumber(et.gentity_get(clientNum, "ps.stats", 8)) or MAX_SPRINT_TIME
    local last_st     = _last_sprint_time[entry.guid] or MAX_SPRINT_TIME
    local sprint_delta = last_st - sprint_time
    local is_sprint   = sprint_delta > STAMINA_CHANGE_THRESHOLD

    local is_prone    = (eFlags & EF_PRONE)       ~= 0 or (eFlags & EF_PRONE_MOVING) ~= 0
    local is_crouch   = (eFlags & EF_CROUCHING)   ~= 0
    local is_mounted  = (eFlags & EF_MG42_ACTIVE) ~= 0
                     or (eFlags & EF_MOUNTEDTANK)  ~= 0
                     or weapon == WP_MOBILE_MG42_SET
                     or weapon == WP_MOBILE_BROWNING_SET
    local is_leaning  = leanf ~= 0

    local pos = et.gentity_get(clientNum, "r.currentOrigin")

    return {
        guid            = entry.guid,
        team            = entry.team,
        class           = CLASS_LOOKUP[pt] or "unknown",
        health          = health,
        pos             = pos and { pos[1], pos[2], pos[3] } or nil,
        is_prone        = is_prone,
        is_crouch       = is_crouch and not is_prone and not is_mounted,
        is_mounted      = is_mounted,
        is_leaning      = is_leaning and not is_prone and not is_mounted,
        is_carrying_obj = (red_flag > 0 or blue_flag > 0),
        is_disguised    = disguise > 0,
        is_downed       = (health < 0 and body == BODY_DOWNED),
        is_sprint       = is_sprint,
    }
end


function players.count_alive()
    local counts = { allies = 0, axis = 0 }
    for clientNum = 0, _maxClients - 1 do
        if et.gentity_get(clientNum, "pers.connected") == CON_CONNECTED then
            local health = tonumber(et.gentity_get(clientNum, "health")) or 0
            if health > 0 then
                local entry = players.guids[clientNum]
                if entry then
                    if entry.team == et.TEAM_ALLIES then
                        counts.allies = counts.allies + 1
                    elseif entry.team == et.TEAM_AXIS then
                        counts.axis = counts.axis + 1
                    end
                end
            end
        end
    end
    return counts
end


function players.on_userinfo_changed(clientNum, gamelog)
    local userinfo = et.trap_GetUserinfo(clientNum)
    if not userinfo or userinfo == "" then return end

    local guid = string.upper(et.Info_ValueForKey(userinfo, "cl_guid"))
    if not guid or guid == "" then return end

    local team = tonumber(et.gentity_get(clientNum, "sess.sessionTeam")) or 0
    players.guids[clientNum] = { guid = guid, team = team }

    -- Class-switch detection
    if team == et.TEAM_AXIS or team == et.TEAM_ALLIES then
        local pt = tonumber(et.gentity_get(clientNum, "sess.playerType"))
        if pt ~= nil then
            if not players.class_switches[guid] then
                players.class_switches[guid] = {}
            end

            local switches = players.class_switches[guid]
            local prev_class = (#switches > 0) and switches[#switches].to_class or nil

            if prev_class ~= pt then
                table.insert(switches, {
                    timestamp  = et.trap_Milliseconds(),
                    from_class = prev_class,
                    to_class   = pt,
                })

                if log then
                    log.debug(string.format("Class switch: %s %s → %s",
                        guid,
                        prev_class and CLASS_LOOKUP[prev_class] or "none",
                        CLASS_LOOKUP[pt] or "unknown"))
                end

                if gamelog then
                    gamelog.class_change(guid, CLASS_LOOKUP[pt] or "unknown")
                end
            end
        end
    end

    return players.guids[clientNum]
end


function players.on_disconnect(clientNum, movement)
    local entry = players.guids[clientNum]
    if entry and entry.guid ~= "WORLD" then
        players.class_switches[entry.guid] = nil
        _last_sprint_time[entry.guid] = nil
        if movement then
            movement.clear(entry.guid)
        end
    end
    players.guids[clientNum] = nil
end


function players.update_sprint_time(guid, sprint_time)
    _last_sprint_time[guid] = sprint_time
end


function players.reset()
    local mt = getmetatable(players.guids)
    players.guids = setmetatable({}, mt)

    players.class_switches = {}
    _last_sprint_time = {}
end

return players
