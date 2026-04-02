--[[
    stats/gather.lua
    Consolidated gather-match features: auto_rename, auto_sort, auto_start, auto_map, auto_config.

    AUTO_RENAME  - enforces team roster names during warmup and gameplay.
    AUTO_SORT    - assigns connecting spectators to their roster team (GS_WARMUP only).
    AUTO_START   - countdown to scheduled_start and force-starts the game.
    AUTO_MAP     - automatically switches to the next map for the game.
    AUTO_CONFIG  - loads server config on init according to player count 

    State machine for auto_start (active only while gamestate == GS_WARMUP):
        IDLE → ARMED → WARNING_60 → WARNING_10 → COUNTDOWN → START_ATTEMPT → DONE
                                                                        └→ LATE_JOIN_COUNTDOWN

    Primary guard: any gamestate other than GS_WARMUP resets to IDLE immediately.
--]]

local gather = {}

local json  = require("dkjson")
local utils = require("luascripts/stats/util/utils")
local say   = utils.say
local cp    = utils.cp

local log
local http_ref
local api_ref
local scores_ref

local _auto_rename              = false
local _auto_sort                = false
local _auto_start               = false
local _auto_map                 = false
local _auto_config              = false
local _auto_scores              = false
local _eff_rename               = false  -- _auto_rename  AND match_data.auto_rename
local _eff_sort                 = false  -- _auto_sort    AND match_data.auto_sort
local _eff_start                = false  -- _auto_start   AND match_data.auto_start
local _eff_map                  = false  -- _auto_map     AND match_data.auto_map
local _eff_config               = false  -- _auto_config  AND route data present
local _eff_scores               = false  -- _auto_scores  AND match_data.auto_scores
local _maxClients               = 24
local _log_level                = "info"
local _start_wait_initial       = 420   -- map 1 round 1
local _start_wait               = 180   -- all other rounds
local _server_config_applied    = false
local _auto_config_map          = {}    -- player-count → config name
local _timing_computed          = false -- reset between rounds
local _initial_round            = 0     -- g_currentRound captured at et_InitGame; used in on_intermission
local _pending_map_switch       = nil   -- next_map to switch to after round 2 intermission
local _pending_map_switch_time  = 0

local TEAM_DATA_CHECK_INTERVAL  = 5000  -- ms between mass-validation sweeps
local RENAME_DELAY              = 150   -- ms between rename queue items
local CON_CONNECTED             = 2
local EF_READY                  = 0x00000008

local _team_data_cache          = nil

local _team_data_fetched        = false
local _team_names_cache         = { alpha_teamname = nil, beta_teamname = nil, last_updated = 0 }
local _match_extra              = {}
local _match_data_stale         = true
local _route_match_id           = nil   -- match_id from the route response

local _rename_queue             = {}
local _rename_timer             = 0
local _rename_in_progress       = {}
local _player_ready_status      = {}
local _last_name_check_time     = 0

local STATE_IDLE                = "idle"
local STATE_ARMED               = "armed"
local STATE_WARNING_60          = "warning_60"
local STATE_WARNING_10          = "warning_10"
local STATE_COUNTDOWN           = "countdown"
local STATE_START_ATTEMPT       = "start_attempt"
local STATE_DONE                = "done"
local STATE_LATE_JOIN_COUNTDOWN = "late_join_countdown"

local _state                    = STATE_IDLE
local _countdown_val            = nil
local _countdown_last           = 0

local NOTIFY_INIT_SUPPRESS_MS   = 3000  -- suppress notify calls for 3s after init/reset
local _init_frame_time          = 0     -- set at gather.init() and gather.reset()

local scan_players
local notify_api

local _server_ip                = ""
local _server_port              = ""
local _api_url_notify           = nil
local _api_token                = nil

local TEAM_AXIS                 = 1
local TEAM_ALLIES               = 2


function gather.init(cfg, log_ref, http_module, api_module, scores_module)
    log        = log_ref
    http_ref   = http_module
    api_ref    = api_module
    scores_ref = scores_module

    _auto_rename        = cfg.auto_rename     or false
    _auto_sort          = cfg.auto_sort       or false
    _auto_start         = cfg.auto_start      or false
    _auto_map           = cfg.auto_map        or false
    _auto_config        = cfg.auto_config     or false
    _auto_scores        = cfg.auto_scores     or false
    _eff_rename         = false
    _eff_sort           = false
    _eff_start          = false
    _eff_map            = false
    _eff_config         = false
    _eff_scores         = false
    _auto_config_map    = cfg.auto_config_map or {}
    _maxClients         = cfg.maxClients      or 24
    _log_level          = cfg.api_log_level or cfg.log_level or "info"
    _start_wait_initial = cfg.start_wait_initial or 420
    _start_wait         = cfg.start_wait         or 180
    _initial_round      = cfg.initial_round      or 0

    _match_extra         = {}
    _match_data_stale    = true

    _server_ip   = cfg.server_ip   or ""
    _server_port = cfg.server_port or ""
    _api_token   = cfg.api_token   or ""

    local base = cfg.api_url_submit or ""
    _api_url_notify = base:gsub("/matches/stats/submit$", "/matches/auto-start/notify")
    if _api_url_notify == base then
        local root = (cfg.api_url_matchid or ""):match("^(https?://[^/]+)")
        _api_url_notify = (root or "") .. "/api/v2/stats/etl/matches/auto-start/notify"
    end

    _state         = STATE_IDLE
    _countdown_val = nil
    _countdown_last = 0
    _init_frame_time = et.trap_Milliseconds()
end


-- Between-round reset: resets auto-start state only.
-- Team data intentionally survives into the next round.
function gather.reset()
    _state            = STATE_IDLE
    _countdown_val    = nil
    _countdown_last   = 0
    _timing_computed  = false  -- recompute scheduled_start/sides_swapped for the new round
    _init_frame_time  = et.trap_Milliseconds()
end


function gather.reset_team_data()
    _team_data_cache      = nil
    _team_data_fetched    = false
    _team_names_cache     = { alpha_teamname = nil, beta_teamname = nil, last_updated = 0 }
    _rename_queue         = {}
    _rename_timer         = 0
    _rename_in_progress   = {}
    _player_ready_status  = {}
    _last_name_check_time = 0
    _route_match_id       = nil
    _match_extra           = {}
    _match_data_stale      = true
    _eff_rename            = false
    _eff_sort              = false
    _eff_start             = false
    _eff_map               = false
    _eff_config            = false
    _eff_scores            = false
end


local function get_team_data_file_path(match_id)
    local dir = utils.get_team_data_dir()
    if not dir then return nil end
    if match_id and match_id ~= "" then
        return string.format("%s/%s_team_data.json", dir, match_id)
    end
    local ok, f = pcall(io.popen,
        string.format('ls -t "%s"/*_team_data.json 2>/dev/null | head -1', dir))
    if ok and f then
        local found = f:read("*l")
        f:close()
        if found and found ~= "" then return found end
    end
    return string.format("%s/team_data.json", dir)
end


function gather.save_team_data_to_file(match_id)
    if not _team_data_cache then return false end
    if not (_match_extra and _match_extra.is_gather) then return false end
    local effective_id = match_id or _route_match_id
    local path = get_team_data_file_path(effective_id)
    if not path then return false end

    local data = {
        match_id       = effective_id,
        alpha_teamname = _team_names_cache.alpha_teamname,
        beta_teamname  = _team_names_cache.beta_teamname,
        match          = _team_data_cache,
        match_extra    = _match_extra,
        last_updated   = et.trap_Milliseconds(),
        scores_state   = scores_ref and scores_ref.get_state_for_persistence() or nil,
    }
    local jstr = json.encode(data)
    if not jstr then return false end

    local ok = pcall(function()
        local f = io.open(path, "w")
        if not f then error("cannot open " .. path) end
        f:write(jstr)
        f:close()
    end)
    if ok and log then
        log.write(string.format("Team data saved — match_id: %s, alpha: %s, beta: %s",
            effective_id or "nil",
            _team_names_cache.alpha_teamname or "nil",
            _team_names_cache.beta_teamname  or "nil"))
    end
    return ok
end


function gather.load_team_data_from_file(cached_match_id_ref)
    local path = get_team_data_file_path(_route_match_id)
    if not path then return false end

    local ok, result = pcall(function()
        local f = io.open(path, "r")
        if not f then return nil end
        local content = f:read("*all")
        f:close()
        if not content or content == "" then return nil end
        return json.decode(content)
    end)

    if ok and result then
        if result.ng or (result.match_extra and result.match_extra.is_gather == false) then
            return false
        end
        if result.match_id then
            if cached_match_id_ref then cached_match_id_ref[1] = result.match_id end
            _route_match_id = result.match_id
        end
        _team_names_cache.alpha_teamname = result.alpha_teamname
        _team_names_cache.beta_teamname  = result.beta_teamname
        _team_names_cache.last_updated   = result.last_updated or 0
        _team_data_cache   = result.match
        _team_data_fetched = true
        if result.match_extra then
            _match_extra = result.match_extra
            -- Re-derive effective flags; gather.init() reset them all to false.
            local is_gather = _match_extra.is_gather or false
            _eff_rename  = _auto_rename  and is_gather and (_match_extra.auto_rename  or false)
            _eff_sort    = _auto_sort    and is_gather and (_match_extra.auto_sort    or false)
            _eff_start   = _auto_start   and is_gather and (_match_extra.auto_start   or false)
            _eff_map     = _auto_map     and is_gather and (_match_extra.auto_map     or false)
            _eff_scores  = _auto_scores  and (_match_extra.auto_scores  or false)
        end
        -- Pass all effective feature flags to scores so it can include them in metadata
        if scores_ref and result.match_id and result.match then
            scores_ref.update_match_data(result.match_id, result.match, {
                auto_rename = _eff_rename,
                auto_sort   = _eff_sort,
                auto_start  = _eff_start,
                auto_map    = _eff_map,
                auto_config = _eff_config,
                auto_scores = _eff_scores,
            })
            -- Restore cumulative scores from the previous round
            -- Called after update_match_data so _match_id is set and the match_id guard fires.
            if result.scores_state then
                scores_ref.restore_state(result.scores_state)
            end
        end
        if log then
            log.write(string.format("Team data loaded from file — match_id: %s, alpha: %s, beta: %s",
                result.match_id or "nil",
                result.alpha_teamname or "nil",
                result.beta_teamname  or "nil"))
        end
        return true
    end
    return false
end


-- Compute scheduled_start and sides_swapped from current map and round.
-- sides_swapped = (map_index + round) % 2 == 1
--   map_index 0, round 0 → alpha=Axis (default)
--   map_index 0, round 1 → alpha=Allies (swapped)
--   map_index 1, round 0 → alpha=Allies (swapped)
--   map_index 1, round 1 → alpha=Axis
--   ... and so on.
local function recompute_match_timing()
    if not _match_extra then return end
    local has_auto = _match_extra.auto_start or _match_extra.auto_sort
    if not has_auto then return end

    local maps        = _match_extra.maps or {}
    local current_map = utils.strip_colors(et.trap_Cvar_Get("mapname") or ""):lower()
    local round_raw   = et.trap_Cvar_Get("g_currentRound") or "0"
    local round       = tonumber(round_raw:match("%d+")) or 0

    local map_index = 0
    for i, m in ipairs(maps) do
        if current_map:find(m:lower(), 1, true) then
            map_index = i - 1
            break
        end
    end

    local swapped = (map_index + round) % 2 == 1
    _match_extra.sides_swapped = swapped

    -- scheduled_start: longer window only for the very first start
    if _match_extra.auto_start then
        local is_first_start = (map_index == 0 and round == 0)
        local wait = is_first_start and _start_wait_initial or _start_wait
        _match_extra.scheduled_start = os.time() + wait
        if log then
            log.write(string.format(
                "auto_start: map=%q (idx=%d) round=%d → sides_swapped=%s scheduled_start=now+%ds",
                current_map, map_index, round + 1, tostring(swapped), wait))
        end
    elseif log then
        log.write(string.format(
            "auto_sort: map=%q (idx=%d) round=%d → sides_swapped=%s",
            current_map, map_index, round + 1, tostring(swapped)))
    end

    _timing_computed = true
end


local function resolve_server_config(total_players, fallback)
    if not _auto_config_map or next(_auto_config_map) == nil then
        return fallback
    end
    local best_threshold = nil
    local best_config    = nil
    for threshold, cfg_name in pairs(_auto_config_map) do
        if total_players <= threshold then
            if best_threshold == nil or threshold < best_threshold then
                best_threshold = threshold
                best_config    = cfg_name
            end
        end
    end
    return best_config or fallback
end


function gather.on_team_data_fetched(match_id, match_data)
    if not match_data then return end

    if match_id and match_id ~= "" then _route_match_id = match_id end
    local had_names = _team_names_cache.alpha_teamname ~= nil
    if match_data.alpha_teamname and match_data.beta_teamname then
        _team_names_cache.alpha_teamname = match_data.alpha_teamname
        _team_names_cache.beta_teamname  = match_data.beta_teamname
        _team_names_cache.last_updated   = et.trap_Milliseconds()
    end
    _team_data_cache   = match_data
    _team_data_fetched = true
    _match_data_stale  = false

    _match_extra = {
        auto_rename     = match_data.auto_rename     or false,
        auto_sort       = match_data.auto_sort       or false,
        auto_start      = match_data.auto_start      or false,
        auto_map        = match_data.auto_map        or false,
        auto_scores     = match_data.auto_scores     or false,
        scheduled_start = match_data.scheduled_start or nil,
        sides_swapped   = match_data.sides_swapped   or false,
        maps            = match_data.maps            or {},
        channel_id      = match_data.channel_id      or nil,
        server_config   = match_data.server_config   or nil,
        is_gather       = match_data.is_gather       or false,
    }

    -- Static master enable AND match_data must both be true.
    -- _eff_config requires roster players (alpha+beta > 0) to distinguish gather matches
    -- from ng routes that carry no team data.
    local _cfg_alpha = match_data.alpha_team and #match_data.alpha_team or 0
    local _cfg_beta  = match_data.beta_team  and #match_data.beta_team  or 0
    local is_gather = _match_extra.is_gather or false
    _eff_rename  = _auto_rename  and is_gather and _match_extra.auto_rename
    _eff_sort    = _auto_sort    and is_gather and _match_extra.auto_sort
    _eff_start   = _auto_start   and is_gather and _match_extra.auto_start
    _eff_map     = _auto_map     and is_gather and _match_extra.auto_map
    _eff_config  = _auto_config  and is_gather and (_cfg_alpha + _cfg_beta) > 0
    _eff_scores  = _auto_scores  and _match_extra.auto_scores

    -- Pass all effective feature flags to scores so it can include them in metadata
    if scores_ref then
        scores_ref.update_match_data(match_id, match_data, {
            auto_rename = _eff_rename,
            auto_sort   = _eff_sort,
            auto_start  = _eff_start,
            auto_map    = _eff_map,
            auto_config = _eff_config,
            auto_scores = _eff_scores,
        })

        -- Restore accumulated scores from the previous round's save.
        -- update_match_data above may have reset scores if this is a new Lua VM
        -- (et_InitGame fires between every round). _route_match_id is now set so
        -- we can locate {match_id}_team_data.json directly without a directory scan.
        -- restore_state is idempotent: it skips if the file's match_id doesn't match.
        if _route_match_id then
            local path = get_team_data_file_path(_route_match_id)
            if path then
                local ok, file_data = pcall(function()
                    local f = io.open(path, "r")
                    if not f then return nil end
                    local content = f:read("*all")
                    f:close()
                    return content and json.decode(content) or nil
                end)
                if ok and file_data and file_data.scores_state then
                    scores_ref.restore_state(file_data.scores_state)
                end
            end
        end
    end

    if not had_names and _team_names_cache.alpha_teamname and _eff_rename then
        for clientNum = 0, _maxClients - 1 do
            if et.gentity_get(clientNum, "pers.connected") == CON_CONNECTED then
                local sessionTeam = tonumber(et.gentity_get(clientNum, "sess.sessionTeam")) or 0
                if sessionTeam == 1 or sessionTeam == 2 then
                    gather.enforce_player_name(clientNum, 200)
                end
            end
        end
    end

    local current_gs = tonumber(et.trap_Cvar_Get("gamestate")) or -1
    if current_gs == et.GS_WARMUP then

        local _live_round = tonumber(et.trap_Cvar_Get("g_currentRound")) or 0
        if _eff_config and not _server_config_applied and _live_round == 0 then
            local alpha_count = match_data.alpha_team and #match_data.alpha_team or 0
            local beta_count  = match_data.beta_team  and #match_data.beta_team  or 0
            local total       = alpha_count + beta_count

            -- Apply only if the server is empty (pre-connect) or the in-team count
            -- matches the expected roster size. Mismatches suggest stale/wrong match data.
            local connected_in_teams = 0
            for cnum = 0, _maxClients - 1 do
                if et.gentity_get(cnum, "pers.connected") == CON_CONNECTED then
                    local t = tonumber(et.gentity_get(cnum, "sess.sessionTeam")) or 0
                    if t == TEAM_AXIS or t == TEAM_ALLIES then
                        connected_in_teams = connected_in_teams + 1
                    end
                end
            end

            local count_ok = connected_in_teams == 0 or connected_in_teams == total
            local resolved = resolve_server_config(total, _match_extra.server_config)
            if resolved and resolved ~= "" and count_ok then
                _server_config_applied = true
                if log then
                    log.write(string.format(
                        "auto_config: %d expected / %d connected → applying '%s'",
                        total, connected_in_teams, resolved))
                end
                et.trap_SendConsoleCommand(et.EXEC_APPEND,
                    string.format("ref config %s\n", resolved))
            elseif not count_ok and log then
                log.write(string.format(
                    "auto_config: skipped — %d connected but %d expected",
                    connected_in_teams, total))
            end
        end

        -- Compute fresh scheduled_start and sides_swapped from current map+round.
        -- Only once per warmup cycle (reset between rounds by gather.reset()).
        if not _timing_computed then
            recompute_match_timing()
        end
    end
end


function gather.is_auto_rename_enabled()   return _eff_rename  end

function gather.is_team_data_available()
    return _team_data_fetched
        and _team_data_cache ~= nil
        and _team_names_cache.alpha_teamname ~= nil
        and _team_names_cache.beta_teamname  ~= nil
end


function gather.is_gather()
    return _match_extra and _match_extra.is_gather or false
end


local function find_player_name_by_guid(guid)
    if not _team_data_cache then return nil end
    for _, team_key in ipairs({ "alpha_team", "beta_team" }) do
        local team = _team_data_cache[team_key]
        if team then
            for _, player in ipairs(team) do
                if player.GUID then
                    for _, pg in ipairs(player.GUID) do
                        if string.upper(pg) == string.upper(guid) then
                            return player.name
                        end
                    end
                end
            end
        end
    end
    return nil
end


local function is_player_ready(clientNum)
    local eFlags = et.gentity_get(clientNum, "ps.eFlags")
    return eFlags and (eFlags & EF_READY) ~= 0
end


local function get_first_color_code(name)
    return name:match("(%^%w)")
end


local function get_spectator_enforced_name(spectator_teamname, current_name)
    spectator_teamname = spectator_teamname or ""
    current_name       = current_name or ""
    local candidate    = spectator_teamname .. " " .. current_name
    if #candidate <= 35 then return candidate end

    local first_code = get_first_color_code(current_name) or "^7"
    local no_color   = first_code .. utils.strip_colors(current_name)
    candidate        = spectator_teamname .. " " .. no_color
    if #candidate <= 35 then return candidate end

    local allowed = 35 - (#spectator_teamname + 1 + #first_code)
    return spectator_teamname .. " " .. first_code
        .. string.sub(utils.strip_colors(current_name), 1, allowed)
end


local function has_spectator_prefix(current_name, spectator_teamname)
    if not current_name or not spectator_teamname then return false end
    local clean_name   = utils.strip_colors(current_name):lower()
    local clean_prefix = utils.strip_colors(spectator_teamname):lower()
    return clean_name:sub(1, #clean_prefix) == clean_prefix
end


local function rename_player(clientNum, new_name)
    local clientInfo = et.trap_GetUserinfo(clientNum)
    clientInfo = et.Info_SetValueForKey(clientInfo, "name", new_name)
    et.trap_SetUserinfo(clientNum, clientInfo)
    et.ClientUserinfoChanged(clientNum)
end


function gather.queue_rename(clientNum, new_name, reason)
    table.insert(_rename_queue, {
        clientNum = clientNum,
        newName   = new_name,
        reason    = reason,
        timestamp = et.trap_Milliseconds(),
    })
    if log then
        log.debug(string.format("Queued rename: player %d → '%s' (%s)", clientNum, new_name, reason))
    end
end


function gather.process_rename_queue(current_time)
    if #_rename_queue == 0 then return end
    if current_time < _rename_timer then return end

    local item = table.remove(_rename_queue, 1)
    if item then
        if et.gentity_get(item.clientNum, "pers.connected") == CON_CONNECTED then
            rename_player(item.clientNum, item.newName)
            if log then
                log.debug(string.format("Rename applied: player %d → '%s' (%s)",
                    item.clientNum, item.newName, item.reason))
            end
        else
            if log then
                log.debug(string.format("Rename skipped: player %d disconnected", item.clientNum))
            end
        end
        _rename_timer = current_time + RENAME_DELAY
    end
end


function gather.enforce_player_name(clientNum, delay_ms)
    if not _eff_rename then return end
    if not gather.is_team_data_available() then return end
    if _rename_in_progress[clientNum] then return end

    local userinfo = et.trap_GetUserinfo(clientNum)
    if not userinfo or userinfo == "" then return end

    local guid         = string.upper(et.Info_ValueForKey(userinfo, "cl_guid"))
    local current_name = et.Info_ValueForKey(userinfo, "name")
    if not guid or guid == "" or not current_name then return end

    local correct_name = find_player_name_by_guid(guid)
    if not correct_name then return end

    if utils.strip_colors(current_name):lower() ~= utils.strip_colors(correct_name):lower() then
        local trimmed = correct_name
        if #trimmed > 35 then trimmed = trimmed:sub(1, 35) end
        if log then
            log.debug(string.format("Enforcing name: player %d '%s' → '%s'",
                clientNum, current_name, trimmed))
        end
        if delay_ms and delay_ms > 0 then
            _rename_timer = math.max(_rename_timer, et.trap_Milliseconds() + delay_ms)
            gather.queue_rename(clientNum, trimmed, "enforce_delayed")
        else
            _rename_in_progress[clientNum] = true
            rename_player(clientNum, trimmed)
        end
    end
end


function gather.on_userinfo_changed(clientNum, current_gamestate)
    if not _eff_rename then return end
    if _rename_in_progress[clientNum] then
        _rename_in_progress[clientNum] = nil
        if log then log.debug(string.format("Rename completed: player %d", clientNum)) end
    else
        if current_gamestate == et.GS_PLAYING then
            gather.enforce_player_name(clientNum)
        end
    end
end


function gather.on_disconnect(clientNum)
    _player_ready_status[clientNum] = nil
    _rename_in_progress[clientNum]  = nil

    if not _eff_start then return end
    if not (_match_extra and _match_extra.scheduled_start) then return end

    local now       = os.time()
    local scheduled = _match_extra.scheduled_start
    local conn, miss, unk = scan_players(_team_data_cache)
    local remaining = math.max(0, scheduled - now)

    local should_notify = (_log_level == "debug") or (#miss == 0 or #miss == 1)
    if not should_notify then return end

    notify_api(remaining, conn, miss, unk, _route_match_id or "", "disconnect")
    if log then
        local miss_names = {}
        for _, p in ipairs(miss) do table.insert(miss_names, p.nick or p.expected_name or "?") end
        local suffix = #miss > 0 and (" — " .. table.concat(miss_names, ", ")) or ""
        log.write(string.format("auto_start: disconnect — %d connected, %d missing%s", #conn, #miss, suffix))
    end
end


function gather.validate_all_players()
    if not _eff_rename or not gather.is_team_data_available() then return end
    if log then log.debug("Mass name validation") end

    local spectator_teamname = _team_data_cache and _team_data_cache.spectator_teamname

    for clientNum = 0, _maxClients - 1 do
        if et.gentity_get(clientNum, "pers.connected") == CON_CONNECTED then
            local sessionTeam = tonumber(et.gentity_get(clientNum, "sess.sessionTeam")) or 0
            if sessionTeam == 1 or sessionTeam == 2 then
                gather.enforce_player_name(clientNum)
            elseif sessionTeam == 3 and spectator_teamname then
                local userinfo     = et.trap_GetUserinfo(clientNum)
                local current_name = userinfo and et.Info_ValueForKey(userinfo, "name")
                if current_name and not has_spectator_prefix(current_name, spectator_teamname) then
                    local new_name = get_spectator_enforced_name(spectator_teamname, current_name)
                    if new_name ~= current_name then
                        gather.queue_rename(clientNum, new_name, "mass validation spectator")
                    end
                end
            end
        end
    end
end


function gather.check_all_players_names_gameplay(current_time)
    if not _eff_rename then return end
    if current_time < _last_name_check_time + TEAM_DATA_CHECK_INTERVAL then return end
    _last_name_check_time = current_time

    if not gather.is_team_data_available() then return end

    for clientNum = 0, _maxClients - 1 do
        if et.gentity_get(clientNum, "pers.connected") == CON_CONNECTED
        and not _rename_in_progress[clientNum] then
            local sessionTeam = tonumber(et.gentity_get(clientNum, "sess.sessionTeam")) or 0
            if sessionTeam == 1 or sessionTeam == 2 then
                gather.enforce_player_name(clientNum)
            end
        end
    end
end


function gather.check_player_ready_status(api_module)
    if not (_auto_rename or _auto_sort or _auto_start) then return end

    -- If static rename is on and match data says rename, but names haven't arrived yet
    -- (Phase 2 / WAITING_REPORT pending), keep polling until they do.
    if _auto_rename and _match_extra.auto_rename and not _team_names_cache.alpha_teamname then
        _match_data_stale = true
    end

    for clientNum = 0, _maxClients - 1 do
        if et.gentity_get(clientNum, "pers.connected") == CON_CONNECTED then
            local ready     = is_player_ready(clientNum)
            local was_ready = _player_ready_status[clientNum]

            if ready and not was_ready then
                if log then log.debug(string.format("Player %d readied up", clientNum)) end
                if not gather.is_team_data_available() then
                    if log then log.write("First ready — fetching team data") end
                    if api_module then api_module.fetch_match_id() end
                end
                gather.enforce_player_name(clientNum)
            end

            _player_ready_status[clientNum] = ready
        end
    end
end


-- Returns team_id, discord_nick (or nil, nil).
local function find_team_for_guid(guid)
    if not _team_data_cache or not guid or guid == "" then return nil, nil end
    local upper_guid = string.upper(guid)
    local swapped    = _match_extra and _match_extra.sides_swapped
    local team_map   = {
        alpha_team = swapped and TEAM_ALLIES or TEAM_AXIS,
        beta_team  = swapped and TEAM_AXIS   or TEAM_ALLIES,
    }
    for team_key, team_id in pairs(team_map) do
        local team = _team_data_cache[team_key]
        if team then
            for _, player in ipairs(team) do
                if player.GUID then
                    for _, pg in ipairs(player.GUID) do
                        if string.upper(pg) == upper_guid then
                            return team_id, player.nick
                        end
                    end
                end
            end
        end
    end
    return nil, nil
end


function gather.assign_team_on_connect(clientNum, current_gs)
    if current_gs ~= et.GS_WARMUP then return end

    -- If static rename is on and route confirms rename, re-poll on connect until names arrive.
    if _auto_rename and _match_extra.auto_rename and not gather.is_team_data_available() then
        if log then log.write(string.format(
            "client %d connected while names stale — re-polling API", clientNum)) end
        if api_ref then api_ref.fetch_match_id() end
    end

    if not _eff_sort then return end
    if not _team_data_fetched then return end

    local current_team = tonumber(et.gentity_get(clientNum, "sess.sessionTeam")) or 0
    if current_team ~= 3 then return end

    local userinfo = et.trap_GetUserinfo(clientNum)
    if not userinfo or userinfo == "" then return end
    local guid = et.Info_ValueForKey(userinfo, "cl_guid")
    if not guid or guid == "" then return end

    local team_id, discord_nick = find_team_for_guid(guid)
    if not team_id then return end  -- unknown GUID: leave as-is

    local team_letter = (team_id == 1) and "r" or "b"
    local team_name   = (team_id == 1) and "^1Axis" or "^4Allies"
    et.gentity_set(clientNum, "sess.latchPlayerType", 1)  -- medic; combinedfixes enforces ongoing
    et.trap_SendConsoleCommand(et.EXEC_APPEND,
        string.format("forceteam %d %s\n", clientNum, team_letter))

    local ingame_name = et.gentity_get(clientNum, "pers.netname") or ""
    local display     = discord_nick and (discord_nick ~= ingame_name) and
                            string.format(" ^7(^3%s^7)", discord_nick) or ""
    say(string.format("%s%s ^7moved to %s", ingame_name, display, team_name))

    if gather.is_team_data_available() then
        gather.enforce_player_name(clientNum, 200)
    end

    if log then
        log.write(string.format("auto_sort: client %d (%.8s…) → team %d (%s)",
            clientNum, guid, team_id, discord_nick or "?"))
    end
end


scan_players = function(match_data)
    local connected = {}
    local missing   = {}
    local unknown   = {}

    if not match_data then return connected, missing, unknown end

    local roster         = {}
    local roster_players = {}

    local function add_roster_team(team_list, team_id)
        if not team_list then return end
        for _, player in ipairs(team_list) do
            if player.GUID then
                local entry = {
                    discord_id = player.id or "",
                    name       = player.name or player.nick or "",
                    nick       = player.nick or "",
                    team       = team_id,
                    found      = false,
                }
                table.insert(roster_players, entry)
                for _, pg in ipairs(player.GUID) do
                    roster[string.upper(pg)] = entry
                end
            end
        end
    end

    add_roster_team(match_data.alpha_team, TEAM_AXIS)
    add_roster_team(match_data.beta_team,  TEAM_ALLIES)

    for _, p in ipairs(utils.get_connected_players()) do
        local entry  = p.guid ~= "" and roster[p.guid] or nil
        local ingame = et.Info_ValueForKey(et.trap_GetUserinfo(p.clientNum) or "", "name") or ""
        if entry then
            entry.found = true
            table.insert(connected, {
                guid       = p.guid,
                discord_id = entry.discord_id,
                name       = entry.name,
            })
        else
            table.insert(unknown, {
                guid        = p.guid,
                ingame_name = ingame,
                team        = p.team,
            })
        end
    end

    for _, entry in ipairs(roster_players) do
        if not entry.found then
            table.insert(missing, {
                discord_id    = entry.discord_id,
                expected_name = entry.name,
                nick          = entry.nick,
                team          = entry.team,
            })
        end
    end

    return connected, missing, unknown
end


local function total_roster_count(match_data)
    if not match_data then return 0 end
    local n = 0
    local function count_team(t) if t then n = n + #t end end
    count_team(match_data.alpha_team)
    count_team(match_data.beta_team)
    return n
end


local function count_ingame_teams()
    local axis   = 0
    local allies = 0
    for _, p in ipairs(utils.get_connected_players()) do
        if p.team == TEAM_AXIS   then axis   = axis   + 1 end
        if p.team == TEAM_ALLIES then allies = allies + 1 end
    end
    return axis, allies
end


notify_api = function(seconds_until_start, connected, missing, unknown, match_id, trigger)
    if not _api_url_notify or _api_url_notify == "" then return end
    local current_gs = tonumber(et.trap_Cvar_Get("gamestate")) or -1
    if current_gs ~= et.GS_WARMUP then return end
    if et.trap_Milliseconds() - _init_frame_time < NOTIFY_INIT_SUPPRESS_MS then return end

    local payload = {
        match_id            = match_id or "",
        channel_id          = (_match_extra and _match_extra.channel_id) or nil,
        server_ip           = _server_ip,
        server_port         = _server_port,
        timestamp           = os.time(),
        seconds_until_start = seconds_until_start,
        connected_players   = connected,
        missing_players     = missing,
        unknown_players     = unknown,
        trigger             = trigger or "timer",
    }

    local json_str = json.encode(payload)
    if not json_str then return end

    local curl_cmd = string.format(
        "curl -s -X POST -H 'Content-Type: application/json' -H 'Authorization: Bearer %s'" ..
        " --connect-timeout 2 --max-time 5 --silent --output /dev/null '%s'",
        _api_token, _api_url_notify
    )
    http_ref.async(curl_cmd, json_str)
end


local function check_start_conditions(match_data, connected, missing)
    if #missing == 0 then return true end
    local roster_count = total_roster_count(match_data)
    if roster_count == 0 then return false end
    local axis, allies = count_ingame_teams()
    local half = roster_count / 2
    return (axis + allies) >= roster_count and axis == allies and axis == half
end


function gather.on_player_connect(clientNum, current_gs)
    if not _eff_start then return end
    if current_gs ~= et.GS_WARMUP then return end
    if not (_match_extra and _match_extra.scheduled_start) then return end

    local now       = os.time()
    local scheduled = _match_extra.scheduled_start
    local conn, miss, unk = scan_players(_team_data_cache)
    local remaining = math.max(0, scheduled - now)

    -- Late-join: past scheduled time, STATE_DONE → 10-second countdown if all present
    if _state == STATE_DONE and now >= scheduled then
        if check_start_conditions(_team_data_cache, conn, miss) then
            _state          = STATE_LATE_JOIN_COUNTDOWN
            _countdown_val  = 10
            _countdown_last = now
            say("^7All players present! Auto-starting in ^110 seconds^7...")
            cp("^1" .. _countdown_val)
            if log then
                log.write("auto_start: late join detected — starting 10-second countdown")
            end
        end
    end

    -- Notify API on connect: always in debug mode, otherwise only when notable
    -- (all present, one missing, or past T-0 late-join)
    local should_notify = (_log_level == "debug") or (#miss == 0 or #miss == 1)
    if should_notify then
        notify_api(remaining, conn, miss, unk, _route_match_id or "", "connect")
    end
    if log then
        local miss_names = {}
        for _, p in ipairs(miss) do table.insert(miss_names, p.nick or p.expected_name or "?") end
        local suffix = #miss > 0 and (" — " .. table.concat(miss_names, ", ")) or ""
        log.write(string.format("auto_start: connect — %d connected, %d missing%s", #conn, #miss, suffix))
    end
end


function gather.tick(frame_time, current_gs)
    if _pending_map_switch and os.time() >= _pending_map_switch_time then
        local next_map = _pending_map_switch
        _pending_map_switch      = nil
        _pending_map_switch_time = 0
        if log then log.write(string.format("auto_map: issuing 'map %s'", next_map)) end
        et.trap_SendConsoleCommand(et.EXEC_APPEND, string.format("map %s\n", next_map))
    end

    -- Only active during GS_WARMUP; any other state silently cancels countdown.
    if current_gs ~= et.GS_WARMUP then
        if _state ~= STATE_IDLE and _state ~= STATE_DONE then
            if log then
                log.write(string.format("auto_start: cancelled (gs=%d left GS_WARMUP)", current_gs))
            end
            _state         = STATE_IDLE
            _countdown_val = nil
        end
        return
    end

    -- Suppress auto_start if the match is already finished (score determined).
    if scores_ref and _eff_start and scores_ref.is_finished() then
        if _state ~= STATE_IDLE then gather.reset() end
        return
    end

    -- Suppress auto_start if R2 has already completed on this map.
    if scores_ref and _eff_start then
        local last = scores_ref.get_last_round()
        if last and last.round_num == 2 then
            local current_map = (et.trap_Cvar_Get("mapname") or ""):lower()
            if last.mapname and current_map:find(last.mapname:lower(), 1, true) then
                if _state ~= STATE_IDLE then gather.reset() end
                return
            end
        end
    end

    if not (_match_extra and _match_extra.auto_start) then
        if _state ~= STATE_IDLE then gather.reset() end
        return
    end

    local scheduled = _match_extra.scheduled_start
    if not scheduled then
        if _state ~= STATE_IDLE then gather.reset() end
        return
    end

    local now        = os.time()
    local match_data = _team_data_cache
    local match_id   = _route_match_id or ""

    if _state == STATE_IDLE then
        _state = STATE_ARMED
        return
    end

    if _state == STATE_ARMED then
        if now >= scheduled - 60 then
            -- Re-validate route before firing any warnings: the match may have finished
            -- and the route deregistered after Lua cached the match data at init.
            if api_ref and not api_ref.validate_route(match_id) then
                if log then
                    log.write(string.format(
                        "auto_start: T-60 abort — route no longer valid for match %s",
                        tostring(match_id)))
                end
                gather.reset_team_data()
                return
            end

            _state = STATE_WARNING_60
            local conn, miss, unk = scan_players(match_data)

            -- Failsafe: ≤30% of team present at T-60 → assume different server, abort silently
            local roster_count  = total_roster_count(match_data)
            local present_count = #conn + #unk
            if roster_count > 0 and present_count <= math.floor(roster_count * 0.3) then
                _state = STATE_DONE
                if log then
                    log.write(string.format(
                        "auto_start: T-60 abort — only %d/%d players present (≤30%%), assuming wrong server",
                        present_count, roster_count))
                end
                return
            end

            say("^7Game starts in ^160^7 seconds!")
            cp("^7Game starts in ^160^7 seconds!")
            notify_api(60, conn, miss, unk, match_id)
            if log then
                local miss_names = {}
                for _, p in ipairs(miss) do table.insert(miss_names, p.nick or p.expected_name or "?") end
                local suffix = #miss > 0 and (" — " .. table.concat(miss_names, ", ")) or ""
                log.write(string.format("auto_start: T-60 — %d connected, %d missing%s", #conn, #miss, suffix))
            end
        end
        return
    end

    if _state == STATE_WARNING_60 then
        if now >= scheduled - 10 then
            _state = STATE_WARNING_10
            say("^7Game starts in ^110^7 seconds!")
            cp("^7Game starts in ^110^7 seconds!")
            local conn, miss, unk = scan_players(match_data)
            notify_api(10, conn, miss, unk, match_id)
            if log then
                local miss_names = {}
                for _, p in ipairs(miss) do table.insert(miss_names, p.nick or p.expected_name or "?") end
                local suffix = #miss > 0 and (" — " .. table.concat(miss_names, ", ")) or ""
                log.write(string.format("auto_start: T-10 — %d connected, %d missing%s", #conn, #miss, suffix))
            end
        end
        return
    end

    if _state == STATE_WARNING_10 then
        if now >= scheduled - 3 then
            _state          = STATE_COUNTDOWN
            _countdown_val  = 3
            _countdown_last = now
            cp("^1" .. _countdown_val)
        end
        return
    end

    if _state == STATE_COUNTDOWN then
        if now > _countdown_last then
            _countdown_last = now
            _countdown_val  = _countdown_val - 1
            if _countdown_val > 0 then
                cp("^1" .. _countdown_val)
            else
                _state = STATE_START_ATTEMPT
            end
        end
        return
    end

    if _state == STATE_START_ATTEMPT then
        _state = STATE_DONE

        local conn, miss, unk = scan_players(match_data)
        if check_start_conditions(match_data, conn, miss) then
            if log then log.write("auto_start: conditions met — calling ref allready") end
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "ref allready\n")
            notify_api(0, conn, miss, unk, match_id)
        else
            local names_list = {}
            for _, p in ipairs(miss) do
                table.insert(names_list, "^7" .. (p.expected_name or "?"))
            end
            say(string.format("^1Unable to start match. Missing %d player%s: %s",
                #miss, #miss == 1 and "" or "s",
                table.concat(names_list, "^1, ")))
            notify_api(0, conn, miss, unk, match_id)
            if log then
                local miss_names = {}
                for _, p in ipairs(miss) do table.insert(miss_names, p.nick or p.expected_name or "?") end
                log.write(string.format("auto_start: FAILED — %d connected, missing: %s", #conn, table.concat(miss_names, ", ")))
            end
        end
        return
    end

    if _state == STATE_LATE_JOIN_COUNTDOWN then
        if now > _countdown_last then
            _countdown_last = now
            _countdown_val  = _countdown_val - 1
            if _countdown_val > 0 then
                cp("^1" .. _countdown_val)
                if _countdown_val == 1 then say("^1Starting now!") end
            else
                _state = STATE_START_ATTEMPT
            end
        end
        return
    end

end

-- Called by gamestate on GS_INTERMISSION
-- Schedules a map switch only after round 2 completes (g_currentRound == 1).
function gather.on_intermission()
    if not _eff_map then return end
    local maps = _match_extra.maps
    if not maps or #maps < 2 then return end

    -- Use the round captured at et_InitGame time: the engine resets g_currentRound
    -- to 0 before on_intermission fires, so reading it here would always yield 0.
    local round = _initial_round
    if round ~= 1 then
        if log then
            log.write(string.format(
                "auto_map: round %d intermission — no map switch (only after round 2)", round + 1))
        end
        return
    end

    local current_map = utils.strip_colors(et.trap_Cvar_Get("mapname") or ""):lower()
    if current_map == "" then
        if log then log.write("auto_map: cannot determine current map (mapname cvar empty)") end
        return
    end

    local next_map = nil
    for i, m in ipairs(maps) do
        if current_map:find(m:lower(), 1, true) then
            next_map = maps[i + 1]
            break
        end
    end

    if not next_map then
        if log then
            log.write(string.format(
                "auto_map: '%s' is the last map in rotation — no switch", current_map))
        end
        return
    end

    -- Schedule switch 10s from now
    _pending_map_switch      = next_map
    _pending_map_switch_time = os.time() + 10
    if log then
        log.write(string.format(
            "auto_map: round 2 complete — '%s' → '%s' scheduled in 10s",
            current_map, next_map))
    end
end


return gather
