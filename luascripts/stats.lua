--[[
    stats.lua  — root module for ETLegacy game stats collection
    Version: 2.2.0

    All user-facing settings live in the CONFIGURATION block below.
    config.toml is kept only for map-specific patterns and common buildables.
--]]

-- ============================================================
-- CONFIGURATION
-- ============================================================

-- [API]
local API_TOKEN                 = "GameStatsWebLuaToken"
local API_URL_MATCHID           = "https://api.etl.lol/api/v2/stats/etl/match-manager"
local API_URL_SUBMIT            = "https://api.etl.lol/api/v2/stats/etl/matches/stats/submit"
local API_URL_VERSION           = "https://api.etl.lol/api/v2/stats/etl/matches/stats/version"

-- [PATHS]
local LOG_FILEPATH              = "/legacy/homepath/legacy/stats/game_stats.log"
local JSON_FILEPATH             = "/legacy/homepath/legacy/stats/"

-- [COLLECTION]
local LOGGING_ENABLED           = false
local LOG_LEVEL                 = "info"  -- "info" | "debug"
local COLLECT_OBJ_STATS         = true
local COLLECT_SHOVE_STATS       = true
local COLLECT_MOVEMENT_STATS    = true
local COLLECT_STANCE_STATS      = true   -- prone / crouch / sprint time, etc.
local COLLECT_GAMELOG           = true   -- in-round event timeline (kills, damage, chat, objectives, etc.)
local COLLECT_WEAPON_FIRE       = false  -- log every weapon shot (et_WeaponFire + et_FixedMGFire)
                                         -- WARNING: very high volume -- not recommended for normal use.

-- [OUTPUT]
local DUMP_STATS_DATA           = false  -- write indented JSON to JSON_FILEPATH
local SUBMIT_TO_API             = true   -- set false to write locally only

-- [GATHER FEATURES]
local AUTO_SORT                 = false  -- assign players to teams on connect via API
local AUTO_START                = false  -- foce game start via AUTO_START_WAIT and AUTO_START_WAIT_INITIAL
local AUTO_RENAME               = false  -- enforce team names via API
local AUTO_MAP                  = false  -- switch to next map in rotation after round 2 intermission
local AUTO_CONFIG               = false  -- apply server config (ref config) based on player count at match start
local AUTO_SCORES               = false  -- track match scores across maps (best-of-3)
local VERSION_CHECK             = true

-- [AUTO-CONFIG MAP] player count → server config name
local AUTO_CONFIG_MAP = {
    [2]  = "legacy1",
    [4]  = "legacy3",
    [6]  = "legacy3",
    [10] = "legacy5",
    [12] = "legacy6",
}

-- [AUTO-START TIMING]
local AUTO_START_WAIT_INITIAL   = 420    -- seconds  (First Round, 7min)
local AUTO_START_WAIT           = 180    -- seconds  (Consecutive Rounds, 3 min)

-- [STATS TIMING]
local STORE_TIME_INTERVAL       = 5000   -- ms between StoreStats calls
local SAVE_STATS_DELAY          = 3000   -- ms after intermission before SaveStats

-- [MODULE]
local MODNAME                   = "stats"
local VERSION                   = "2.2.0"

-- [ENV OVERRIDES]
-- Any setting above can be overridden by an environment variable of the same
-- name used in Docker (e.g. STATS_API_TOKEN, STATS_SUBMIT).
-- Unset variables are silently ignored and the defaults above apply.
local function env_bool(name, default)
    local v = os.getenv(name)
    if v == "true"  then return true  end
    if v == "false" then return false end
    return default
end

API_TOKEN                       = os.getenv("STATS_API_TOKEN")          or API_TOKEN
API_URL_SUBMIT                  = os.getenv("STATS_API_URL_SUBMIT")     or API_URL_SUBMIT
API_URL_MATCHID                 = os.getenv("STATS_API_URL_MATCHID")    or API_URL_MATCHID
API_URL_VERSION                 = os.getenv("STATS_API_URL_VERSION")    or API_URL_VERSION
JSON_FILEPATH                   = os.getenv("STATS_API_PATH")           or JSON_FILEPATH
LOG_LEVEL                       = os.getenv("STATS_API_LOG_LEVEL")      or LOG_LEVEL
LOGGING_ENABLED                 = env_bool("STATS_API_LOG",             LOGGING_ENABLED)
COLLECT_GAMELOG                 = env_bool("STATS_API_GAMELOG",         COLLECT_GAMELOG)
COLLECT_OBJ_STATS               = env_bool("STATS_API_OBJSTATS",        COLLECT_OBJ_STATS)
COLLECT_SHOVE_STATS             = env_bool("STATS_API_SHOVESTATS",      COLLECT_SHOVE_STATS)
COLLECT_MOVEMENT_STATS          = env_bool("STATS_API_MOVEMENTSTATS",   COLLECT_MOVEMENT_STATS)
COLLECT_STANCE_STATS            = env_bool("STATS_API_STANCESTATS",     COLLECT_STANCE_STATS)
COLLECT_WEAPON_FIRE             = env_bool("STATS_API_WEAPON_FIRE",     COLLECT_WEAPON_FIRE)
DUMP_STATS_DATA                 = env_bool("STATS_API_DUMPJSON",        DUMP_STATS_DATA)
SUBMIT_TO_API                   = env_bool("STATS_SUBMIT",              SUBMIT_TO_API)
AUTO_RENAME                     = env_bool("STATS_AUTO_RENAME",         AUTO_RENAME)
AUTO_SORT                       = env_bool("STATS_AUTO_SORT",           AUTO_SORT)
AUTO_START                      = env_bool("STATS_AUTO_START",          AUTO_START)
AUTO_MAP                        = env_bool("STATS_AUTO_MAP",            AUTO_MAP)
AUTO_CONFIG                     = env_bool("STATS_AUTO_CONFIG",         AUTO_CONFIG)
AUTO_SCORES                     = env_bool("STATS_AUTO_SCORES",         AUTO_SCORES)
VERSION_CHECK                   = env_bool("STATS_API_VERSION_CHECK",   VERSION_CHECK)
AUTO_CONFIG_MAP[2]              = os.getenv("STATS_AUTO_CONFIG_2")  or AUTO_CONFIG_MAP[2]
AUTO_CONFIG_MAP[4]              = os.getenv("STATS_AUTO_CONFIG_4")  or AUTO_CONFIG_MAP[4]
AUTO_CONFIG_MAP[6]              = os.getenv("STATS_AUTO_CONFIG_6")  or AUTO_CONFIG_MAP[6]
AUTO_CONFIG_MAP[10]             = os.getenv("STATS_AUTO_CONFIG_10") or AUTO_CONFIG_MAP[10]
AUTO_CONFIG_MAP[12]             = os.getenv("STATS_AUTO_CONFIG_12") or AUTO_CONFIG_MAP[12]
AUTO_START_WAIT_INITIAL         = tonumber(os.getenv("STATS_AUTO_START_WAIT_INITIAL")) or AUTO_START_WAIT_INITIAL
AUTO_START_WAIT                 = tonumber(os.getenv("STATS_AUTO_START_WAIT"))         or AUTO_START_WAIT

-- STATS_GATHER_FEATURES=true enables all gather features at once.
-- Individual flags can still be explicitly overridden (e.g. STATS_AUTO_CONFIG=false).
if env_bool("STATS_GATHER_FEATURES", false) then
    if os.getenv("STATS_AUTO_RENAME")  == nil then AUTO_RENAME  = true end
    if os.getenv("STATS_AUTO_SORT")    == nil then AUTO_SORT    = true end
    if os.getenv("STATS_AUTO_START")   == nil then AUTO_START   = true end
    if os.getenv("STATS_AUTO_MAP")     == nil then AUTO_MAP     = true end
    if os.getenv("STATS_AUTO_CONFIG")  == nil then AUTO_CONFIG  = true end
    if os.getenv("STATS_AUTO_SCORES")  == nil then AUTO_SCORES  = true end
end

-- [SUB-MODULES]
local function gs_require(mod)
    return require("luascripts/stats/" .. mod)
end

local log_mod                   = gs_require("util/log")
local http                      = gs_require("util/http")
local utils                     = gs_require("util/utils")
local config_mod                = gs_require("config")
local players                   = gs_require("players")
local movement                  = gs_require("movement")
local gamelog                   = gs_require("gamelog")
local events                    = gs_require("events")
local objectives                = gs_require("objectives")
local gather                    = gs_require("gather")
local api                       = gs_require("api")
local stats                     = gs_require("stats")
local scores                    = gs_require("scores")
local gamestate                 = gs_require("gamestate")

-- [RUNTIME VARIABLES]
local maxClients                = 24
local server_ip                 = "0.0.0.0"
local server_port               = "27960"
local mapname                   = ""
local map_configs               = {}
local common_buildables         = {}
local next_store_time           = 0
local level_time                = 0
local _deferred_init_pending    = false

-- [SHARED CONFIG TABLE] (passed to modules at init)
local function build_cfg()
    return {
        api_token               = API_TOKEN,
        api_url_matchid         = API_URL_MATCHID,
        api_url_submit          = API_URL_SUBMIT,
        api_url_version         = API_URL_VERSION,
        log_filepath            = LOG_FILEPATH,
        json_filepath           = JSON_FILEPATH,
        logging_enabled         = LOGGING_ENABLED,
        collect_obj_stats       = COLLECT_OBJ_STATS,
        collect_shove_stats     = COLLECT_SHOVE_STATS,
        collect_movement_stats  = COLLECT_MOVEMENT_STATS,
        collect_stance_stats    = COLLECT_STANCE_STATS,
        collect_gamelog         = COLLECT_GAMELOG,
        collect_weapon_fire     = COLLECT_WEAPON_FIRE,
        dump_stats_data         = DUMP_STATS_DATA,
        submit_to_api           = SUBMIT_TO_API,
        auto_rename             = AUTO_RENAME,
        auto_sort               = AUTO_SORT,
        auto_start              = AUTO_START,
        auto_map                = AUTO_MAP,
        auto_config             = AUTO_CONFIG,
        auto_scores             = AUTO_SCORES,
        auto_config_map         = AUTO_CONFIG_MAP,
        start_wait_initial      = AUTO_START_WAIT_INITIAL,
        start_wait              = AUTO_START_WAIT,
        initial_round           = tonumber(et.trap_Cvar_Get("g_currentRound")) or 0,
        log_level               = LOG_LEVEL,
        version_check           = VERSION_CHECK,
        save_stats_delay        = SAVE_STATS_DELAY,
        maxClients              = maxClients,
        server_ip               = server_ip,
        server_port             = server_port,
    }
end

-- ============================================================ --
-- ============================================================ --

local function resolve_server_ip()
    local env_ip   = os.getenv("MAP_IP")
    local net_ip   = et.trap_Cvar_Get("net_ip")
    local net_port = et.trap_Cvar_Get("net_port")

    if env_ip and env_ip ~= "" then
        return env_ip, net_port
    elseif net_ip and net_ip ~= "" and net_ip ~= "0.0.0.0" and net_ip ~= "::0" then
        return net_ip, net_port
    else
        return http.getPublicIP(), net_port
    end
end

-- Strip common map prefixes/suffixes for config lookup.
local function get_base_map_name(full)
    full = string.lower(full)
    for _, prefix in ipairs({ "etl_", "et_", "mp_", "sw_" }) do
        if full:sub(1, #prefix) == prefix then
            full = full:sub(#prefix + 1)
            break
        end
    end
    for _, suffix in ipairs({ "_b%d+", "_v%d+", "_final", "_te", "_sw" }) do
        full = full:gsub(suffix .. "$", "")
    end
    return full
end

-- Resolve the active map config name and initialise objectives.
local function initialize_map_config()
    local full_mapname  = et.trap_Cvar_Get("mapname")
    local base_mapname  = get_base_map_name(full_mapname)
    local found         = false

    for config_name, _ in pairs(map_configs) do
        if get_base_map_name(config_name) == base_mapname then
            mapname = config_name
            found   = true
            break
        end
    end

    local map_config = map_configs[mapname]
    objectives.init_map(map_config, common_buildables)

    if log_mod then
        local round = tonumber(et.trap_Cvar_Get("g_currentRound")) == 0 and 1 or 2
        local et_v  = et.trap_Cvar_Get("mod_version")
        log_mod.write(string.rep("-", 50))
        log_mod.write(string.format("Server started — %s %s", MODNAME, VERSION))
        log_mod.write(string.format("ET:Legacy: %s | Server: %s:%s", et_v, server_ip, server_port))
        log_mod.write(string.format("Map: %s (round %d) | config: %s",
            full_mapname, round, found and mapname or "none"))
    end

    return found
end

-- [CONFIG VALIDATION]
local function validate_configuration()
    if not API_TOKEN or API_TOKEN:match("^%%.*%%$") then
        return false, "Invalid or missing API token"
    end
    if not API_URL_MATCHID or not API_URL_MATCHID:match("^https?://") then
        return false, "Invalid matchid API URL"
    end
    if not API_URL_SUBMIT or not API_URL_SUBMIT:match("^https?://") then
        return false, "Invalid submit API URL"
    end
    if VERSION_CHECK and (not API_URL_VERSION or not API_URL_VERSION:match("^https?://")) then
        return false, "Invalid version check API URL"
    end
    if utils.table_count(map_configs) == 0 then
        return false, "No map configurations loaded"
    end
    if not next(common_buildables) then
        return false, "No common buildables loaded"
    end
    return true
end

-- [ET CALLBACKS]
function et_InitGame()
    local _init_t0 = os.clock()
    et.RegisterModname(string.format("%s %s", MODNAME, VERSION))
    log_mod.init(LOG_FILEPATH, LOGGING_ENABLED, LOG_LEVEL)
    log_mod.buffer_start()
    server_ip, server_port = resolve_server_ip()

    -- Load map config
    local cfg_data, cfg_err = config_mod.load()
    if not cfg_data then
        et.G_Print(string.format("[%s] Config load failed: %s\n", MODNAME, cfg_err or "unknown"))
        return
    end

    map_configs      = cfg_data.map_configs
    common_buildables = cfg_data.common_buildables
    maxClients = tonumber(et.trap_Cvar_Get("sv_maxclients")) or 24

    -- Build shared config
    local cfg = build_cfg()
    cfg.server_ip   = server_ip
    cfg.server_port = server_port
    cfg.maxClients  = maxClients

    local valid, verr = validate_configuration()
    if not valid then
        et.G_Print(string.format("[%s] Configuration error: %s\n", MODNAME, verr))
        return
    end

    -- Init sub-modules
    players.init(log_mod, maxClients)
    movement.init(log_mod, maxClients)
    gamelog.init(COLLECT_GAMELOG)
    events.init(cfg, log_mod, players, gamelog, objectives)
    objectives.init(cfg, log_mod, players, gamelog)
    scores.init(cfg, log_mod, http, gamestate)
    gather.init(cfg, log_mod, http, api, scores)
    api.init(cfg, log_mod, http, gather, VERSION)
    api.set_server_info(server_ip, server_port)
    stats.init(cfg, log_mod, http, api,
               movement, objectives, events, gamelog, players, VERSION, scores)
    gamestate.init(cfg, log_mod, {
        players    = players,
        movement   = movement,
        gamelog    = gamelog,
        events     = events,
        objectives = objectives,
        gather     = gather,
        api        = api,
        stats      = stats,
        scores     = scores,
    })

    events.parse_reinf_times()
    initialize_map_config()

    if log_mod.is_debug() then
        local bool = function(v) return v and "yes" or "no" end
        log_mod.debug("-- Active configuration --")
        log_mod.debug(string.format("  submit_to_api       : %s", bool(SUBMIT_TO_API)))
        log_mod.debug(string.format("  dump_stats_data     : %s  -> %s", bool(DUMP_STATS_DATA), JSON_FILEPATH))
        log_mod.debug(string.format("  logging             : %s  level=%s  -> %s", bool(LOGGING_ENABLED), LOG_LEVEL, LOG_FILEPATH))
        log_mod.debug(string.format("  collect_gamelog     : %s", bool(COLLECT_GAMELOG)))
        log_mod.debug(string.format("  collect_obj_stats   : %s", bool(COLLECT_OBJ_STATS)))
        log_mod.debug(string.format("  collect_shove_stats : %s", bool(COLLECT_SHOVE_STATS)))
        log_mod.debug(string.format("  collect_movement    : %s", bool(COLLECT_MOVEMENT_STATS)))
        log_mod.debug(string.format("  collect_stance      : %s", bool(COLLECT_STANCE_STATS)))
        log_mod.debug(string.format("  collect_weapon_fire : %s", bool(COLLECT_WEAPON_FIRE)))
        log_mod.debug(string.format("  auto_rename         : %s", bool(AUTO_RENAME)))
        log_mod.debug(string.format("  auto_sort           : %s", bool(AUTO_SORT)))
        log_mod.debug(string.format("  auto_start          : %s", bool(AUTO_START)))
        log_mod.debug(string.format("  auto_map            : %s", bool(AUTO_MAP)))
        log_mod.debug(string.format("  auto_scores         : %s", bool(AUTO_SCORES)))
        log_mod.debug(string.format("  version_check       : %s", bool(VERSION_CHECK)))
        log_mod.debug(string.format("  api_url_submit      : %s", API_URL_SUBMIT))
        log_mod.debug(string.format("  api_url_matchid     : %s", API_URL_MATCHID))
        log_mod.debug("-- End configuration --")
    end

    local current_gs = tonumber(et.trap_Cvar_Get("gamestate")) or -1
    gamestate.current = current_gs

    if current_gs == et.GS_PLAYING then
        gamestate.round_start_time = et.trap_Milliseconds()
        gamestate.round_start_unix = os.time()
        gamelog.round_start()

        if AUTO_RENAME or AUTO_SORT or AUTO_START or AUTO_MAP or AUTO_SCORES then
            log_mod.write("Game already in progress — loading team data from file")
            local cached = {}
            gather.load_team_data_from_file(cached)
            if cached[1] then api.cached_match_id = cached[1] end
        end
    elseif (current_gs == et.GS_WARMUP or current_gs == et.GS_WARMUP_COUNTDOWN)
        and (AUTO_RENAME or AUTO_SORT or AUTO_START or AUTO_MAP or AUTO_CONFIG or AUTO_SCORES) then
        log_mod.write(string.format("Warmup (gs=%d) — fetching match data", current_gs))
        local mid = api.fetch_match_id()
        if mid then
            log_mod.write("Match data fetched: " .. mid)
            gather.save_team_data_to_file(mid)
        end
    end

    -- Populate GUID cache
    for clientNum = 0, maxClients - 1 do
        if et.gentity_get(clientNum, "pers.connected") == 2 then
            players.on_userinfo_changed(clientNum, gamelog)
        end
    end

    -- Defer version check to first RunFrame — avoids blocking init with a sync HTTP call
    _deferred_init_pending = VERSION_CHECK

    local _init_ms = math.floor((os.clock() - _init_t0) * 1000)
    log_mod.write(string.format("[%s] initialized in %dms (rename:%s sort:%s start:%s)",
        MODNAME, _init_ms,
        AUTO_RENAME and "on" or "off",
        AUTO_SORT   and "on" or "off",
        AUTO_START  and "on" or "off"))
    log_mod.buffer_flush()

    et.G_Print(string.format("[%s] v%s initialized (%dms)\n", MODNAME, VERSION, _init_ms))
end

-- ============================================================ --

function et_RunFrame(frame_level_time)
    level_time = frame_level_time

    if _deferred_init_pending then
        _deferred_init_pending = false
        api.check_version()
    end

    events.set_level_time(level_time)

    local gs_raw = et.trap_Cvar_Get("gamestate")
    local current_gs = (gs_raw ~= gamestate._last_gs_raw)
        and (tonumber(gs_raw) or -1) or gamestate.current
    gamestate._last_gs_raw = gs_raw
    gamestate.handle_change(current_gs, server_ip, server_port, frame_level_time)
    gamestate.tick(frame_level_time, server_ip, server_port)

    if current_gs == et.GS_PLAYING and gamestate.round_start_time == 0 then
        gamestate.round_start_time = frame_level_time
        gamestate.round_start_unix = os.time()
    end

    if COLLECT_MOVEMENT_STATS or COLLECT_STANCE_STATS then
        movement.track(frame_level_time, players)
    end

    if AUTO_RENAME or AUTO_SORT or AUTO_START then
        if current_gs == et.GS_WARMUP then
            gather.check_player_ready_status(api)
        end
    end

    if AUTO_RENAME then
        if current_gs == et.GS_PLAYING then
            gather.check_all_players_names_gameplay(frame_level_time)
        end
        gather.process_rename_queue(frame_level_time)
    end

    if AUTO_START or AUTO_SORT or AUTO_MAP then
        gather.tick(frame_level_time, current_gs)
    end

    if frame_level_time >= next_store_time then
        stats.store(maxClients)
        next_store_time = frame_level_time + STORE_TIME_INTERVAL
    end
end

-- ============================================================ --

function et_InitGame_Restart()
    log_mod.buffer_start()
    initialize_map_config()
    events.parse_reinf_times()
    gamestate.reset(server_ip, server_port)
    gamelog.round_start()
    gamestate.round_start_time = et.trap_Milliseconds()
    gamestate.round_start_unix = os.time()
    log_mod.buffer_flush()
end

-- ============================================================ --

function et_ClientConnect(clientNum, firstTime, isBot)
    return nil
end

function et_ClientBegin(clientNum)
    players.on_userinfo_changed(clientNum, COLLECT_GAMELOG and gamelog or nil)
    if AUTO_RENAME or AUTO_SORT or AUTO_START then
        gather.on_player_connect(clientNum, gamestate.current)
        gather.assign_team_on_connect(clientNum, gamestate.current)
    end
end

function et_ClientDisconnect(clientNum)
    players.on_disconnect(clientNum, movement)
    if AUTO_RENAME or AUTO_START then
        gather.on_disconnect(clientNum)
    end
end

function et_ClientUserinfoChanged(clientNum)
    players.on_userinfo_changed(clientNum, COLLECT_GAMELOG and gamelog or nil)
    if AUTO_RENAME then
        gather.on_userinfo_changed(clientNum, gamestate.current)
    end
end

-- Notable weapons detectable at spawn via et.GetCurrentWeapon().
local SPAWN_WEAPON_NAMES = {
    [et.WP_PANZERFAUST]     = "panzerfaust",
    [et.WP_FLAMETHROWER]    = "flamethrower",
    [et.WP_MOBILE_MG42]     = "mobile_mg42",
    [et.WP_MOBILE_BROWNING] = "mobile_browning",
    [et.WP_BAZOOKA]         = "bazooka",
    [et.WP_CARBINE]         = "carbine",
    [et.WP_KAR98]           = "kar98",
    [et.WP_STEN]            = "sten",
    [et.WP_MP34]            = "mp34",
    [et.WP_FG42]            = "fg42",
    [et.WP_FG42_SCOPE]      = "fg42",
    [et.WP_GARAND]          = "garand_sniper",
    [et.WP_GARAND_SCOPE]    = "garand_sniper",
    [et.WP_K43]             = "k43_sniper",
    [et.WP_K43_SCOPE]       = "k43_sniper",
}

local CLASS_LOOKUP_SPAWN = {
    [0]="soldier",[1]="medic",[2]="engineer",[3]="fieldop",[4]="covertops"
}

function et_ClientSpawn(clientNum, revived, teamChange, restoreHealth)
    if not COLLECT_GAMELOG or revived == 1 then return end

    local entry = players.guids[clientNum]
    if not entry or entry.guid == "WORLD" then return end
    if entry.team ~= et.TEAM_ALLIES and entry.team ~= et.TEAM_AXIS then return end

    local pt = tonumber(et.gentity_get(clientNum, "sess.playerType")) or 0
    local wp = et.GetCurrentWeapon(clientNum)
    local weapons = wp and SPAWN_WEAPON_NAMES[wp] and { SPAWN_WEAPON_NAMES[wp] } or nil

    gamelog.spawn(entry.guid, entry.team, CLASS_LOOKUP_SPAWN[pt] or "unknown", weapons)
end

function et_Revive(revivee, reviver, invulnEndTime)
    if not COLLECT_GAMELOG then return end

    local revivee_entry = players.guids[revivee]
    local reviver_entry = players.guids[reviver]

    gamelog.revive(
        reviver_entry and reviver_entry.guid or "WORLD",
        revivee_entry and revivee_entry.guid or "WORLD"
    )
end

-- ============================================================ --

function et_Obituary(target, attacker, meansOfDeath)
    events.on_obituary(target, attacker, meansOfDeath)
end

function et_Damage(target, attacker, damage, damageFlags, meansOfDeath)
    events.on_damage(target, attacker, damage, damageFlags, meansOfDeath)
end

function et_ClientCommand(clientNum, command)
    return events.on_client_command(clientNum, command)
end

function et_Print(text)
    if COLLECT_OBJ_STATS or COLLECT_SHOVE_STATS then
        objectives.handle_print(text)
    end
end

-- et_WeaponFire: every weapon shot by any player.
-- Must return 0 (passthrough) — never override.
function et_WeaponFire(clientNum, weapon)
    return events.on_weapon_fire(clientNum, weapon)
end

-- et_FixedMGFire: fixed MG42 shots.
-- Must return 0 (passthrough).
function et_FixedMGFire(clientNum)
    -- Fixed MGs don't have a wp_ weapon number accessible here;
    -- use the player's current ps.weapon which will be WP_DUMMY_MG42.
    local weapon = tonumber(et.gentity_get(clientNum, "ps.weapon")) or 0
    return events.on_weapon_fire(clientNum, weapon)
end
