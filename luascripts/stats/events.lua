--[[
    stats/events.lua
    Handles all combat and chat ET callbacks:
        et_Obituary, et_Damage, et_ClientCommand
--]]

local events = {}

local utils = require("luascripts/stats/util/utils")

local log
local players_ref
local gamelog_ref
local objectives_ref

local _collect_gamelog      = true
local _collect_weapon_fire  = false
local _maxClients           = 64

local CON_CONNECTED = 2

-- Hit-region constants
local HR_HEAD  = 0
local HR_ARMS  = 1
local HR_BODY  = 2
local HR_LEGS  = 3
local HR_NONE  = -1

local HR_TYPES = { HR_HEAD, HR_ARMS, HR_BODY, HR_LEGS }
local HR_NAMES = {
    [HR_HEAD] = "HR_HEAD",
    [HR_ARMS] = "HR_ARMS",
    [HR_BODY] = "HR_BODY",
    [HR_LEGS] = "HR_LEGS",
    [HR_NONE] = "HR_NONE",
}

-- Reinforcement-time constants
local MAX_REINFSEEDS = 8
local REINF_BLUEDELT = 3
local REINF_REDDELT  = 2

local _hit_region_cache = {}  -- [clientNum] = last hit-region counts snapshot
local _aReinfOffset     = {}  -- populated by parse_reinf_times()
local _level_time       = 0   -- updated from et_RunFrame via events.set_level_time()


function events.init(cfg, log_ref, players_module, gamelog_module, objectives_module)
    log            = log_ref
    players_ref    = players_module
    gamelog_ref    = gamelog_module
    objectives_ref = objectives_module

    _collect_gamelog     = cfg.collect_gamelog
    _collect_weapon_fire = cfg.collect_weapon_fire or false
    _maxClients          = cfg.maxClients or 64
end


function events.set_level_time(t)
    _level_time = t
end


function events.parse_reinf_times()
    local seed_str = et.trap_GetConfigstring(et.CS_REINFSEEDS)
    local seeds    = {}
    local aSeeds   = { 11, 3, 13, 7, 2, 5, 1, 17 }

    for seed in string.gmatch(seed_str, "%d+") do
        table.insert(seeds, tonumber(seed))
    end

    local offsets = {}
    offsets[et.TEAM_ALLIES] = seeds[1] >> REINF_BLUEDELT
    offsets[et.TEAM_AXIS]   = math.floor(seeds[2] / (1 << REINF_REDDELT))

    for team = et.TEAM_AXIS, et.TEAM_ALLIES do
        for j = 1, MAX_REINFSEEDS do
            if (j - 1) == offsets[team] then
                _aReinfOffset[team] = math.floor(seeds[j + 2] / aSeeds[j]) * 1000
                break
            end
        end
    end
end


local function calc_reinf_time(team)
    local start_time  = tonumber(et.trap_GetConfigstring(et.CS_LEVEL_START_TIME)) or 0
    local deploy_cvar = (team == et.TEAM_AXIS) and "g_redlimbotime" or "g_bluelimbotime"
    local deploy_time = tonumber(et.trap_Cvar_Get(deploy_cvar))
    if not deploy_time or deploy_time == 0 then return 0 end
    local offset = _aReinfOffset[team] or 0
    return (deploy_time - ((offset + _level_time - start_time) % deploy_time)) * 0.001
end


local function get_all_hit_regions(clientNum)
    local regions = {}
    for _, ht in ipairs(HR_TYPES) do
        local ok, count = pcall(function()
            return et.gentity_get(clientNum, "pers.playerStats.hitRegions", ht)
        end)
        regions[ht] = (ok and count) or 0
    end
    return regions
end


local function get_hit_region(clientNum)
    if type(clientNum) ~= "number" then return HR_NONE end

    local current = get_all_hit_regions(clientNum)

    if not _hit_region_cache[clientNum] then
        _hit_region_cache[clientNum] = current
        return HR_NONE
    end

    for _, ht in ipairs(HR_TYPES) do
        if current[ht] > (_hit_region_cache[clientNum][ht] or 0) then
            _hit_region_cache[clientNum] = current
            return ht
        end
    end

    _hit_region_cache[clientNum] = current
    return HR_NONE
end


function events.on_obituary(target, attacker, mod)
    local victim_entry   = players_ref.guids[target]
    local attacker_entry = players_ref.guids[attacker]

    local victim_guid   = victim_entry   and victim_entry.guid   or "WORLD"
    local attacker_guid = attacker_entry and attacker_entry.guid or "WORLD"

    local is_suicide = (attacker == target)
                    or (attacker == 1022)   -- ENTITYNUM_WORLD
                    or (victim_entry and attacker_entry
                        and victim_entry.team == attacker_entry.team
                        and victim_entry.team ~= 0
                        and victim_guid == attacker_guid)

    local is_teamkill = (not is_suicide)
                     and victim_entry and attacker_entry
                     and victim_entry.team == attacker_entry.team
                     and victim_entry.team ~= 0
                     and victim_guid ~= attacker_guid
                     and attacker_guid ~= "WORLD"

    if _collect_gamelog and gamelog_ref then
        if is_suicide then
            local victim_snap = players_ref.get_snapshot(target)
            gamelog_ref.suicide(victim_snap, mod)

        elseif is_teamkill then
            local killer_snap = players_ref.get_snapshot(attacker)
            local victim_snap = players_ref.get_snapshot(target)
            gamelog_ref.teamkill(killer_snap, victim_snap, mod)

        else
            local killer_snap  = players_ref.get_snapshot(attacker)
            local victim_snap  = players_ref.get_snapshot(target)
            local alive        = players_ref.count_alive()
            local killer_reinf = attacker_entry and calc_reinf_time(attacker_entry.team) or 0
            local victim_reinf = victim_entry   and calc_reinf_time(victim_entry.team)   or 0
            gamelog_ref.kill(killer_snap, victim_snap, mod, alive.allies, alive.axis, killer_reinf, victim_reinf)
        end
    end

    if objectives_ref then
        objectives_ref.handle_carrier_death(target, attacker, mod, gamelog_ref)
    end
end


function events.on_damage(target, attacker, damage, damage_flags, mod)
    if not _collect_gamelog or not gamelog_ref then return end

    local hit_region     = get_hit_region(attacker)
    local hit_region_str = HR_NAMES[hit_region] or "HR_NONE"

    local killer_snap = players_ref.get_snapshot(attacker)
    local victim_snap = players_ref.get_snapshot(target)
    gamelog_ref.damage(killer_snap, victim_snap,
        damage or 0, damage_flags or 0, mod or 0, hit_region_str)
end


local CHAT_COMMANDS = {
    say         = true,
    say_team    = true,
    say_teamNL  = true,
    say_buddy   = true,
    say_buddyNL = true,
    vsay        = true,
    vsay_team   = true,
    vsay_buddy  = true,
}


function events.on_client_command(clientNum, command)
    if not _collect_gamelog or not gamelog_ref then return 0 end
    if not CHAT_COMMANDS[command] then return 0 end

    local gs = tonumber(et.trap_Cvar_Get("gamestate"))
    if not gs or gs > 2 then return 0 end

    local entry = players_ref.guids[clientNum]
    if not entry or entry.guid == "WORLD" then return 0 end

    local guid    = entry.guid
    local is_vsay = (command == "vsay" or command == "vsay_team" or command == "vsay_buddy")
    local message = is_vsay and et.trap_Argv(1) or et.ConcatArgs(1)
    local vsay_text

    if is_vsay and et.trap_Argc() > 2 then
        vsay_text = et.ConcatArgs(2)
    end

    gamelog_ref.message(guid, command, message, vsay_text)

    return 0
end


function events.on_weapon_fire(clientNum, weapon)
    if not _collect_weapon_fire or not gamelog_ref then return 0 end

    local entry = players_ref.guids[clientNum]
    if not entry or entry.guid == "WORLD" then return 0 end

    local snap   = players_ref.get_snapshot(clientNum)
    local angles = et.gentity_get(clientNum, "ps.viewangles")

    gamelog_ref.weapon_fire(
        snap,
        weapon,
        angles and (math.floor((angles[1] or 0) * 10) / 10) or nil,  -- pitch
        angles and (math.floor((angles[2] or 0) * 10) / 10) or nil   -- yaw
    )

    return 0
end

function events.reset()
    _hit_region_cache = {}
    _aReinfOffset     = {}
    _level_time       = 0
end

return events
