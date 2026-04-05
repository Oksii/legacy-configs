--[[
    stats/stats.lua
    Weapon-stats collection and final JSON assembly + submission

    Legacy JSON schema is preserved exactly:
        { round_info: {...}, player_stats: {...} }
    The new gamelog array is appended at the same level.
--]]

local stats             = {}
local utils             = require("luascripts/stats/util/utils")

local json = require("dkjson")
local log
local http_ref
local api_ref
local movement_ref
local objectives_ref
local events_ref
local gamelog_ref
local players_ref
local scores_ref

local _api_token        = ""
local _url_submit       = ""
local _json_filepath    = ""
local _dump_stats_data  = false
local _submit_to_api    = true
local _collect_gamelog  = true
local _collect_objstats = true
local _maxClients       = 24
local _version          = "unknown"

local SPEED_US_TO_KPH   = 15.58
local SPEED_US_TO_MPH   = 23.44

local _weapon_stats     = {}

local CON_CONNECTED     = 2
local WS_KNIFE          = 0
local WS_MAX            = 28
local PERS_SCORE        = 0


function stats.init(cfg, log_ref, http_module, api_module,
                    movement_module, objectives_module,
                    events_module, gamelog_module, players_module, version_str,
                    scores_module)
    log            = log_ref
    http_ref       = http_module
    api_ref        = api_module
    movement_ref   = movement_module
    objectives_ref = objectives_module
    events_ref     = events_module
    gamelog_ref    = gamelog_module
    players_ref    = players_module
    scores_ref     = scores_module

    _api_token          = cfg.api_token             or ""
    _url_submit         = cfg.api_url_submit        or ""
    _json_filepath      = cfg.json_filepath         or ""
    _dump_stats_data    = cfg.dump_stats_data       or false
    _submit_to_api      = cfg.submit_to_api ~= false
    _collect_gamelog    = cfg.collect_gamelog
    _collect_objstats   = cfg.collect_obj_stats
    _maxClients         = cfg.maxClients or 64
    _version            = version_str or "unknown"
end


local function save_stats_to_file(payload, file_path)
    local dir = file_path:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p " .. dir) end

    local ok = pcall(function()
        local f = io.open(file_path, "w")
        if not f then error("cannot open " .. file_path) end
        f:write(payload)
        f:close()
    end)

    if ok then
        if log then log.write(string.format("JSON written to: %s", file_path)) end
    else
        if log then log.write(string.format("Failed to write JSON to: %s", file_path)) end
    end
    return ok
end

local function is_empty(str)
    if str == nil or str == "" then return 0 end
    return str
end


function stats.store(maxClients)
    maxClients = maxClients or _maxClients

    for i = 0, maxClients - 1 do
        if et.gentity_get(i, "pers.connected") == CON_CONNECTED then
            local dwWeaponMask = 0
            local weaponStats  = ""

            for j = WS_KNIFE, WS_MAX - 1 do
                local ws   = et.gentity_get(i, "sess.aWeaponStats", j)
                local atts = ws[1]
                local deaths = ws[2]
                local headshots = ws[3]
                local hits = ws[4]
                local kills = ws[5]

                if atts ~= 0 or hits ~= 0 or deaths ~= 0 or kills ~= 0 then
                    weaponStats  = string.format("%s %d %d %d %d %d",
                        weaponStats, hits, atts, kills, deaths, headshots)
                    dwWeaponMask = dwWeaponMask | (1 << j)
                end
            end

            if dwWeaponMask ~= 0 then
                local userinfo      = et.trap_GetUserinfo(i)
                local guid          = string.upper(et.Info_ValueForKey(userinfo, "cl_guid"))
                local name          = et.gentity_get(i, "pers.netname")
                local rounds        = et.gentity_get(i, "sess.rounds")
                local team          = et.gentity_get(i, "sess.sessionTeam")

                local dmg_given     = et.gentity_get(i, "sess.damage_given")
                local dmg_recv      = et.gentity_get(i, "sess.damage_received")
                local tdmg_given    = et.gentity_get(i, "sess.team_damage_given")
                local tdmg_recv     = et.gentity_get(i, "sess.team_damage_received")
                local gibs          = et.gentity_get(i, "sess.gibs")
                local selfkills     = et.gentity_get(i, "sess.self_kills")
                local teamkills     = et.gentity_get(i, "sess.team_kills")
                local teamgibs      = et.gentity_get(i, "sess.team_gibs")
                local time_axis     = et.gentity_get(i, "sess.time_axis")
                local time_allies   = et.gentity_get(i, "sess.time_allies")
                local time_played   = et.gentity_get(i, "sess.time_played")
                local xp            = et.gentity_get(i, "ps.persistant", PERS_SCORE)

                local total_time = (time_axis or 0) + (time_allies or 0)
                local pct_played = total_time == 0 and 0
                    or (100.0 * (time_played or 0) / total_time)

                local row = string.format(
                    "%s\\%s\\%d\\%d\\%d%s %d %d %d %d %d %d %d %d %0.1f %d\n",
                    string.sub(guid, 1, 8), name, rounds, team, dwWeaponMask, weaponStats,
                    dmg_given, dmg_recv, tdmg_given, tdmg_recv,
                    gibs, selfkills, teamkills, teamgibs, pct_played, xp)

                _weapon_stats[guid] = row
            end
        end
    end
end


function stats.save(round_start_time, round_end_time, round_start_unix, round_end_unix,
                    server_ip, server_port)

    local match_id = (scores_ref and scores_ref.get_match_id())
                  or (api_ref and api_ref.fetch_match_id())
                  or tostring(os.time())

    local mapname = et.Info_ValueForKey(
        et.trap_GetConfigstring(et.CS_SERVERINFO), "mapname")
    local round   = tonumber(et.trap_Cvar_Get("g_currentRound")) == 0 and 2 or 1

    if log then
        log.write(string.format("SaveStats — match_id: %s, map: %s, round: %d",
            match_id, mapname, round))
    end

    local cs_multi_info     = et.trap_GetConfigstring(et.CS_MULTI_INFO)
    local cs_multi_winner   = et.trap_GetConfigstring(et.CS_MULTI_MAPWINNER)

    local round_info = {
        servername          = et.trap_Cvar_Get("sv_hostname"),
        config              = et.trap_Cvar_Get("g_customConfig"),
        defenderteam        = tonumber(is_empty(et.Info_ValueForKey(cs_multi_info,   "d"))) + 1,
        winnerteam          = tonumber(is_empty(et.Info_ValueForKey(cs_multi_winner, "w"))) + 1,
        timelimit           = utils.convert_timelimit(et.trap_Cvar_Get("timelimit")),
        nextTimeLimit       = utils.convert_timelimit(et.trap_Cvar_Get("g_nextTimeLimit")),
        mapname             = mapname,
        round               = round,
        matchID             = match_id,
        stats_version       = _version,
        mod_version         = utils.strip_colors(et.trap_Cvar_Get("mod_version") or "unknown"),
        et_version          = utils.strip_colors(et.trap_Cvar_Get("version") or "unknown"),
        server_ip           = server_ip,
        server_port         = server_port,
        round_start         = round_start_time,
        round_end           = round_end_time,
        round_start_unix    = round_start_unix,
        round_end_unix      = round_end_unix,
    }

    if scores_ref then
        scores_ref.on_round_end(round_info)
    end

    local metadata = scores_ref and scores_ref.get_metadata(round_info) or nil

    local player_stats = {}

    for guid, row_str in pairs(_weapon_stats) do
        local parts = {}
        for p in row_str:gmatch("[^\\]+") do
            table.insert(parts, p)
        end

        local ws_tokens = {}
        if parts[5] then
            for tok in parts[5]:gmatch("[^%s]+") do
                table.insert(ws_tokens, tok)
            end
        end

        player_stats[guid] = {
            guid        = parts[1],
            name        = parts[2],
            rounds      = parts[3],
            team        = parts[4],
            weaponStats = ws_tokens,
        }

        if movement_ref then
            local mv = movement_ref.get_stats(guid)
            if mv then
                player_stats[guid].distance_travelled_meters = math.floor(mv.distance_travelled * 10) / 10

                if mv.distance_travelled_spawn > 0 then
                    player_stats[guid].distance_travelled_spawn = math.floor(mv.distance_travelled_spawn * 10) / 10
                end
                if mv.spawn_count and mv.spawn_count > 0 then
                    player_stats[guid].spawn_count = mv.spawn_count
                    player_stats[guid].distance_travelled_spawn_avg =
                        math.floor(mv.distance_travelled_spawn * 10) / 10
                end

                if mv.avg_speed_ups and mv.avg_speed_ups > 0 then
                    player_stats[guid].player_speed = {
                        ups_avg  = math.floor(mv.avg_speed_ups  * 10) / 10,
                        ups_peak = math.floor(mv.peak_speed_ups * 10) / 10,
                        kph_avg  = math.floor((mv.avg_speed_ups  / SPEED_US_TO_KPH) * 10) / 10,
                        kph_peak = math.floor((mv.peak_speed_ups / SPEED_US_TO_KPH) * 10) / 10,
                        mph_avg  = math.floor((mv.avg_speed_ups  / SPEED_US_TO_MPH) * 10) / 10,
                        mph_peak = math.floor((mv.peak_speed_ups / SPEED_US_TO_MPH) * 10) / 10,
                    }
                end

                if mv.stance_stats_seconds then
                    local ss = mv.stance_stats_seconds
                    player_stats[guid].stance_stats_seconds = {
                        in_prone        = math.floor(ss.in_prone),
                        in_crouch       = math.floor(ss.in_crouch),
                        in_mg           = math.floor(ss.in_mg),
                        in_lean         = math.floor(ss.in_lean),
                        in_objcarrier   = math.floor(ss.in_objcarrier),
                        in_vehiclescort = math.floor(ss.in_vehiclescort),
                        in_disguise     = math.floor(ss.in_disguise),
                        in_sprint       = math.floor(ss.in_sprint),
                        in_turtle       = math.floor(ss.in_turtle),
                        is_downed       = math.floor(ss.is_downed),
                    }
                end
            end
        end

        if _collect_objstats and objectives_ref then
            local obj = objectives_ref.get_stats()
            if obj and obj[guid] then
                for stat_type, stat_data in pairs(obj[guid]) do
                    if next(stat_data) then
                        player_stats[guid][stat_type] = stat_data
                    end
                end
            end
        end

    end

    local gamelog_data = nil
    if _collect_gamelog and gamelog_ref then
        if objectives_ref and objectives_ref.flush_pending_gamelog then
            objectives_ref.flush_pending_gamelog()
        end
        gamelog_data = gamelog_ref.get(match_id, round)
    end

    local raw_data = {
        round_info   = round_info,
        player_stats = player_stats,
    }
    if metadata then
        raw_data.metadata = metadata
    end
    if gamelog_data then
        raw_data.gamelog = gamelog_data
    end

    local final_data = utils.sanitize(raw_data)

    local jlib = json
    local json_str = jlib.encode(final_data)
    if not json_str then
        if log then log.write("SaveStats: JSON encode failed") end
        return false
    end

    if _submit_to_api then
        local curl_cmd = string.format(
            "curl -X POST -H \"Authorization: Bearer %s\" %s",
            _api_token, _url_submit)

        local ok, msg = http_ref.async(curl_cmd, json_str)
        if log then
            log.write(ok and "Stats submission started" or ("Stats submission failed: " .. (msg or "?")))
        end
    else
        if log then log.write("Stats submission skipped (SUBMIT_TO_API = false)") end
    end

    if _dump_stats_data then
        local indented = jlib.encode(final_data, { indent = true })
        if indented then
            local base = _json_filepath
            if not base:match("/$") then base = base .. "/" end
            local fname = string.format("%sstats-%s-%s%s-round-%d.json",
                base, match_id,
                os.date("%Y-%m-%d-%H%M%S-"),
                mapname, round)
            save_stats_to_file(indented, fname)
        end
    end

    return true
end


function stats.reset()
    _weapon_stats = {}
end

return stats
