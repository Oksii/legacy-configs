--[[
    stats/scores.lua

    Scoring rules (ET stopwatch, best-of-3):
        Map result is always determined by R2:
          R2 winner wins the map → +2 pts
          Double fullhold (both rounds held full R1 timelimit) → +1 pt each (draw)
        R1 fullhold (timelimit == nextTimeLimit): provisional +1 to R1 winner
          used only for clinch detection; removed when R2 is processed.
        Clinch (3-0): ONLY when score reaches exactly 3-0 via R1 fullhold provisional
          (requires 2-0 lead from winning map 1 cleanly + map 2 R1 fullhold).
        Match ends: after map 2 if either score >= 3, OR always after map 3.

    Possible final scores: 3-0 (clinch), 4-0, 3-1, 4-2, 3-3 (draw)

    Team side table (alpha expected side per map/round):
        map1 r1 = axis(1),   map1 r2 = allies(2)
        map2 r1 = allies(2), map2 r2 = axis(1)
        map3 r1 = axis(1),   map3 r2 = allies(2)

    Persistent state survives gamestate.reset() between rounds.
    Only reset_match() (triggered by a new match_id) wipes scoring state.

    Persistence across server restarts is handled by gather.lua, which embeds
    scores_state into team_data.json and restores it via scores.restore_state()
    when loading from file at round start.

    Scores are surfaced via get_metadata(round_info) and embedded into the
    stats submission payload as the top-level 'metadata' key.
--]]

local scores = {}

local utils = require("luascripts/stats/util/utils")

local log
local gamestate_ref

local _auto_scores = false
local _eff_scores  = false

local _match_id        = nil
local _alpha_team      = nil   -- alpha roster; used for team-side validation
local _alpha_teamname  = nil
local _beta_teamname   = nil

local _features = {}

local _round_buffer    = {}
local _alpha_score     = 0
local _beta_score      = 0
local _match_finished  = false
local _match_winner    = nil  -- "alpha" | "beta" | "draw"
local _fullhold_buffer = {}

local TEAM_AXIS   = 1
local TEAM_ALLIES = 2

-- [map_num][round_num] → expected ET team for alpha (1=axis, 2=allies)
local ALPHA_SIDE_TABLE = {
    [1] = { [1] = 1, [2] = 2 },
    [2] = { [1] = 2, [2] = 1 },
    [3] = { [1] = 1, [2] = 2 },
}

local VALIDATION_THRESHOLD = 0.8   -- 80% of scanned alpha players must confirm side


-- http_module kept for interface compatibility; scores no longer makes its own HTTP calls.
function scores.init(cfg, log_ref, http_module, gamestate_module)
    log           = log_ref
    gamestate_ref = gamestate_module
    _auto_scores  = cfg.auto_scores or false

    -- Persistent scoring state is intentionally NOT cleared here.
    -- init() is called once at et_InitGame; round results must survive rounds.
end


-- Called by gamestate.reset() between rounds.  Intentional no-op:
-- scoring state must survive into the next round.
function scores.reset()
end


function scores.reset_match()
    _round_buffer    = {}
    _alpha_score     = 0
    _beta_score      = 0
    _match_finished  = false
    _match_winner    = nil
    _fullhold_buffer = {}
    _alpha_teamname  = nil
    _beta_teamname   = nil
    if log then log.write("scores: match state reset") end
end


function scores.update_match_data(match_id, match_data, features)
    if not match_data then return end

    if match_id and (not _match_id or match_id ~= _match_id) then
        if log then
            log.write(string.format(
                "scores: match change (%s → %s) — resetting match state",
                tostring(_match_id), match_id))
        end
        scores.reset_match()
    end

    _match_id       = match_id
    _alpha_team     = match_data.alpha_team or nil
    _alpha_teamname = match_data.alpha_teamname or _alpha_teamname
    _beta_teamname  = match_data.beta_teamname  or _beta_teamname
    _features       = features or {}

    _eff_scores = _auto_scores and (match_data.auto_scores or false)

    if log then
        log.write(string.format(
            "scores: match_data updated — match_id=%s eff_scores=%s",
            tostring(match_id), tostring(_eff_scores)))
    end
end


function scores.get_state_for_persistence()
    if not _match_id then return nil end
    local state = {
        match_id        = _match_id,
        alpha_score     = _alpha_score,
        beta_score      = _beta_score,
        match_finished  = _match_finished,
        match_winner    = _match_winner,
        round_buffer    = _round_buffer,
        fullhold_buffer = {},
        alpha_teamname  = _alpha_teamname,
        beta_teamname   = _beta_teamname,
    }

    for k, v in pairs(_fullhold_buffer) do
        state.fullhold_buffer[tostring(k)] = v
    end
    return state
end


function scores.restore_state(state)
    if not state then return false end
    if state.match_id ~= _match_id then
        if log then
            log.write(string.format(
                "scores: restore_state skipped — match_id mismatch (state=%s active=%s)",
                tostring(state.match_id), tostring(_match_id)))
        end
        return false
    end

    _alpha_score    = state.alpha_score    or 0
    _beta_score     = state.beta_score     or 0
    _match_finished = state.match_finished or false
    _match_winner   = state.match_winner   or nil
    _round_buffer   = state.round_buffer   or {}
    _alpha_teamname = state.alpha_teamname or _alpha_teamname
    _beta_teamname  = state.beta_teamname  or _beta_teamname

    _fullhold_buffer = {}
    for k, v in pairs(state.fullhold_buffer or {}) do
        _fullhold_buffer[tonumber(k)] = v
    end

    if log then
        log.write(string.format(
            "scores: state restored — match=%s alpha=%d beta=%d rounds=%d",
            _match_id, _alpha_score, _beta_score, #_round_buffer))
    end
    return true
end


local function build_alpha_guid_set()
    local set = {}
    if not _alpha_team then return set end
    for _, player in ipairs(_alpha_team) do
        if player.GUID then
            for _, g in ipairs(player.GUID) do
                set[string.upper(g)] = true
            end
        end
    end
    return set
end


-- Scan connected players, count how many alpha roster members are on each team.
local function detect_alpha_side_from_players()
    local alpha_guid_set = build_alpha_guid_set()
    if not next(alpha_guid_set) then return nil end

    local maxC = tonumber(et.trap_Cvar_Get("sv_maxclients")) or 24
    local on_axis   = 0
    local on_allies = 0
    local total     = 0

    for i = 0, maxC - 1 do
        if et.gentity_get(i, "pers.connected") == 2 then
            local userinfo = et.trap_GetUserinfo(i)
            if userinfo and userinfo ~= "" then
                local guid = string.upper(
                    et.Info_ValueForKey(userinfo, "cl_guid") or "")
                if alpha_guid_set[guid] then
                    total = total + 1
                    local team = tonumber(et.gentity_get(i, "sess.sessionTeam")) or 0
                    if team == TEAM_AXIS   then on_axis   = on_axis   + 1 end
                    if team == TEAM_ALLIES then on_allies = on_allies + 1 end
                end
            end
        end
    end

    if total == 0 then return nil end

    if on_axis   / total >= VALIDATION_THRESHOLD then return TEAM_AXIS   end
    if on_allies / total >= VALIDATION_THRESHOLD then return TEAM_ALLIES end

    if log then
        log.write(string.format(
            "scores: side validation inconclusive — %d alpha players: %d axis (%.0f%%), %d allies (%.0f%%)",
            total, on_axis, (on_axis / total) * 100, on_allies, (on_allies / total) * 100))
    end
    return nil
end


local function resolve_alpha_side(map_num, round_num)
    local expected = (ALPHA_SIDE_TABLE[map_num] or {})[round_num] or TEAM_AXIS

    local detected = detect_alpha_side_from_players()
    if detected then
        if detected ~= expected and log then
            log.write(string.format(
                "scores: side MISMATCH — expected alpha=%d detected alpha=%d (map %d r%d) — using detected",
                expected, detected, map_num, round_num))
        elseif log then
            log.write(string.format(
                "scores: side confirmed — alpha=%d (map %d r%d)",
                detected, map_num, round_num))
        end
        return detected
    end

    if log then
        log.write(string.format(
            "scores: side detection inconclusive — falling back to expected alpha=%d (map %d r%d)",
            expected, map_num, round_num))
    end
    return expected
end


local function process_r1(map_num, alpha_won, fullhold)
    _fullhold_buffer[map_num] = {
        r1_fullhold  = fullhold,
        alpha_won_r1 = alpha_won,
        provisional  = false,
    }

    if not fullhold then return end

    if alpha_won then
        _alpha_score = _alpha_score + 1
    else
        _beta_score = _beta_score + 1
    end
    _fullhold_buffer[map_num].provisional = true

    if log then
        log.write(string.format(
            "scores: R1 fullhold — provisional +1 to %s (score %d-%d)",
            alpha_won and "alpha" or "beta", _alpha_score, _beta_score))
    end

    -- Clinch is ONLY valid at exactly 3-0: one team has 3 points and the
    -- other has 0. Only reachable via: win map1 cleanly (+2) then hold R1
    -- of map2 for the full timelimit (+1 provisional = 3-0).
    local clinch = (_alpha_score == 3 and _beta_score == 0)
                or (_beta_score == 3 and _alpha_score == 0)
    if clinch then
        _match_finished = true
        _match_winner   = _alpha_score > _beta_score and "alpha" or "beta"
        if log then
            log.write(string.format(
                "scores: CLINCH (3-0) after R1 fullhold — winner=%s (score %d-%d)",
                _match_winner, _alpha_score, _beta_score))
        end
    end
end


local function process_r2(map_num, alpha_won, fullhold)
    local fb       = _fullhold_buffer[map_num] or {}
    local r1_fh    = fb.r1_fullhold  or false
    local alpha_r1 = fb.alpha_won_r1  -- nil if no r1 data
    local had_prov = fb.provisional  or false

    if had_prov then
        if alpha_r1 then
            _alpha_score = _alpha_score - 1
        else
            _beta_score  = _beta_score  - 1
        end
        _fullhold_buffer[map_num].provisional = false
        if log then
            log.write(string.format("scores: R1 provisional removed from %s",
                alpha_r1 and "alpha" or "beta"))
        end
    end

    if r1_fh and fullhold then
        _alpha_score = _alpha_score + 1
        _beta_score  = _beta_score  + 1
        if log then
            log.write(string.format("scores: double fullhold — +1 each (score %d-%d)",
                _alpha_score, _beta_score))
        end
    elseif alpha_r1 ~= nil then
        if alpha_won then
            _alpha_score = _alpha_score + 2
        else
            _beta_score  = _beta_score  + 2
        end
        if log then
            log.write(string.format("scores: map won by %s — +2 (score %d-%d)",
                alpha_won and "alpha" or "beta", _alpha_score, _beta_score))
        end
    else
        _alpha_score = _alpha_score + 1
        _beta_score  = _beta_score  + 1
        if log then
            log.write(string.format(
                "scores: no R1 data for map %d — awarding +1 each as fallback (score %d-%d)",
                map_num, _alpha_score, _beta_score))
        end
    end

    local completed_maps = map_num
    if completed_maps >= 2 and (_alpha_score >= 3 or _beta_score >= 3) then
        _match_finished = true
    end
    if completed_maps >= 3 then
        _match_finished = true
    end

    if _match_finished then
        _match_winner = _alpha_score > _beta_score and "alpha"
                     or _beta_score > _alpha_score and "beta"
                     or "draw"
        if log then
            log.write(string.format(
                "scores: match finished — winner=%s final score %d-%d",
                _match_winner, _alpha_score, _beta_score))
        end
    end
end


-- round_info fields used: winnerteam (1/2), timelimit, nextTimeLimit, mapname, round, matchID
-- Only processes during GS_INTERMISSION — map restarts (which skip intermission) are ignored.
function scores.on_round_end(round_info)
    if not _eff_scores then return end
    if gamestate_ref and gamestate_ref.current ~= et.GS_INTERMISSION then
        if log then log.write("scores: on_round_end skipped — not in intermission") end
        return
    end
    if _match_finished then
        if log then log.write("scores: on_round_end skipped — match already finished") end
        return
    end

    -- Discard if the round belongs to a different match than the restored/active state.
    -- Protects against stale state surviving into a new match if update_match_data hasn't
    -- fired yet, or against a mismatch after a state restore.
    if round_info.matchID and _match_id and round_info.matchID ~= _match_id then
        if log then
            log.write(string.format(
                "scores: on_round_end discarded — matchID mismatch (round=%s state=%s)",
                tostring(round_info.matchID), tostring(_match_id)))
        end
        return
    end

    local round_num   = round_info.round      -- 1 or 2 within the current map
    local winner_side = round_info.winnerteam -- 1=axis, 2=allies
    local fullhold    = (round_info.timelimit == round_info.nextTimeLimit)

    -- Derive map_num from rounds already completed (before pushing this one)
    local map_num = math.floor(#_round_buffer / 2) + 1

    -- Validate and resolve which ET side alpha is actually on this round
    local alpha_side = resolve_alpha_side(map_num, round_num)
    local alpha_won  = (winner_side == alpha_side)

    local record = {
        map_num    = map_num,
        round_num  = round_num,
        mapname    = round_info.mapname,
        winner     = alpha_won and "alpha" or "beta",
        winner_et  = winner_side,
        alpha_side = alpha_side,
        fullhold   = fullhold,
        match_id   = round_info.matchID,
        timestamp  = os.time(),
    }
    table.insert(_round_buffer, record)

    if log then
        log.write(string.format(
            "scores: round end — map %d r%d | winner_et=%d alpha_side=%d " ..
            "alpha_won=%s fullhold=%s",
            map_num, round_num, winner_side, alpha_side,
            tostring(alpha_won), tostring(fullhold)))
    end

    if round_num == 1 then
        process_r1(map_num, alpha_won, fullhold)
    else
        process_r2(map_num, alpha_won, fullhold)
    end

    if log then
        log.write(string.format(
            "scores: state — alpha=%d beta=%d finished=%s winner=%s maps=%d",
            _alpha_score, _beta_score, tostring(_match_finished),
            tostring(_match_winner),
            math.floor(#_round_buffer / 2)))
    end

    scores.announce_score()
end


-- Returns a metadata table to embed at the top level of the stats submission JSON.
-- Called by stats.save() after on_round_end() so scores reflect the completed round.
function scores.get_metadata(round_info)
    local info = {
        servername    = round_info.servername,
        config        = round_info.config,
        stats_version = round_info.stats_version,
        mod_version   = round_info.mod_version,
        et_version    = round_info.et_version,
        server_ip     = round_info.server_ip,
        server_port   = round_info.server_port,
        matchID       = round_info.matchID,
        features      = next(_features) and _features or nil,
    }

    if _eff_scores and #_round_buffer > 0 then
        local latest = _round_buffer[#_round_buffer]
        info.scores = {
            alpha          = _alpha_score,
            beta           = _beta_score,
            completed_maps = math.floor(#_round_buffer / 2),
            match_finished = _match_finished,
            match_winner   = _match_winner or nil,
            round = {
                map_num    = latest.map_num,
                round_num  = latest.round_num,
                winner     = latest.winner,
                winner_et  = latest.winner_et,
                alpha_side = latest.alpha_side,
                fullhold   = latest.fullhold,
            },
        }
    end

    return info
end


function scores.get_state()
    return {
        alpha_score    = _alpha_score,
        beta_score     = _beta_score,
        match_finished = _match_finished,
        match_winner   = _match_winner,
        round_count    = #_round_buffer,
        completed_maps = math.floor(#_round_buffer / 2),
        eff_scores     = _eff_scores,
    }
end

function scores.get_match_id()
    return _match_id
end

function scores.get_last_round()
    if #_round_buffer == 0 then return nil end
    return _round_buffer[#_round_buffer]
end


local function clean_teamname(name)
    if not name then return nil end
    name = name:gsub("{name}", "")
    name = name:match("^%s*(.-)%s*$")
    name = utils.resolve_random_colors(name)    -- resolve ^~ to random unique colors
    return name ~= "" and name or nil
end


function scores.announce_score()
    if not _eff_scores then return end
    if _alpha_score == 0 and _beta_score == 0 then return end
    if gamestate_ref and gamestate_ref.current ~= et.GS_INTERMISSION then return end

    local alpha_name = clean_teamname(_alpha_teamname) or "Alpha"
    local beta_name  = clean_teamname(_beta_teamname)  or "Beta"

    local a_col, b_col
    if _alpha_score > _beta_score then
        a_col = "^2" ; b_col = "^1"
    elseif _beta_score > _alpha_score then
        a_col = "^1" ; b_col = "^2"
    else
        a_col = "^3" ; b_col = "^3"
    end

    local line = string.format("%s^7 %s%d ^7- %s%d ^7%s",
        alpha_name, a_col, _alpha_score, b_col, _beta_score, beta_name)
    utils.say(line)

    if log then log.write("scores: announced — " .. utils.strip_colors(line)) end
end

function scores.is_finished()
    return _match_finished
end

function scores.get_winner()
    return _match_winner
end

return scores
