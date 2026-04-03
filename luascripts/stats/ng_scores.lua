--[[
    stats/ng_scores.lua
    Non-gather (ng) match scoring: tracks scores across rounds for matches
    without API-managed gather data (scrims, tournaments).

    A ng match begins when AUTO_SCORES=true and no gather match is active.
    Match identity is maintained via GUID continuity across et_InitGame restarts:
    if >= CONTINUITY_THRESHOLD of stored GUIDs are still connected at round start,
    the match continues; otherwise a new match is started.

    State is persisted to {match_id}_team_data.json (marked ng=true) in the same
    directory as gather team data, using a compatible schema.
--]]

local ng_scores = {}

local json  = require("dkjson")
local utils = require("luascripts/stats/util/utils")

local log
local scores_ref
local http_ref
local gather_ref

local _auto_scores  = false
local _api_token    = ""
local _players_url  = nil

local CONTINUITY_THRESHOLD = 0.65
local TEAM_AXIS            = 1
local TEAM_ALLIES          = 2

local TAG_THRESHOLD = 0.8
local TAG_MIN_LEN   = 2
local TAG_MAX_LEN   = 15

local _match_id    = nil
local _alpha_guids = {}
local _beta_guids  = {}
local _alpha_name  = nil   -- player name from first axis player at match start
local _beta_name   = nil   -- player name from first allies player at match start
local _is_active   = false


function ng_scores.init(cfg, log_ref, scores_module, http_module, gather_module)
    log          = log_ref
    scores_ref   = scores_module
    http_ref     = http_module
    gather_ref   = gather_module
    _auto_scores = cfg and cfg.auto_scores or false
    _api_token   = (cfg and cfg.api_token) or ""

    -- Derive players endpoint from submit URL: .../etl/matches/stats/submit → .../etl/players/by-guid
    local submit_url = cfg and cfg.api_url_submit or ""
    local base = submit_url:match("^(https?://.+/etl)")
    _players_url = base and (base .. "/players/by-guid") or nil
end


-- No-op: ng state must survive rounds (persisted across et_InitGame via file).
function ng_scores.reset()
end


function ng_scores.reset_match()
    _match_id    = nil
    _alpha_guids = {}
    _beta_guids  = {}
    _alpha_name  = nil
    _beta_name   = nil
    _is_active   = false
    if scores_ref then scores_ref.reset_match() end
    if log then log.write("ng: match state reset") end
end



function ng_scores.is_active()
    return _is_active
end


local function check_continuity()
    local stored = {}
    for g in pairs(_alpha_guids) do stored[g] = true end
    for g in pairs(_beta_guids)  do stored[g] = true end

    local players = utils.get_connected_players()
    local _, ratio = utils.guid_overlap(stored, players)
    return ratio >= CONTINUITY_THRESHOLD, ratio
end


function ng_scores.on_round_start()
    if not _auto_scores then return end

    if _match_id ~= nil then
        local last = scores_ref and scores_ref.get_last_round()
        if last and last.round_num == 1 then
            if scores_ref then scores_ref.activate_ng_mode(_match_id, _alpha_name, _beta_name, _alpha_guids) end
            _is_active = true
            if log then log.write(string.format("ng: R2 start — match continued — match_id=%s", _match_id)) end
            return
        end

        local same, ratio = check_continuity()
        if log then
            log.write(string.format("ng: continuity check — ratio=%.2f threshold=%.2f same=%s",
                ratio, CONTINUITY_THRESHOLD, tostring(same)))
        end
        if not same then
            if log then
                log.write(string.format(
                    "ng: roster changed below threshold (%.0f%%) — starting new match",
                    ratio * 100))
            end
            ng_scores.reset_match()
        else
            -- Same match confirmed
            if scores_ref then scores_ref.activate_ng_mode(_match_id, _alpha_name, _beta_name, _alpha_guids) end
            _is_active = true
            if log then log.write(string.format("ng: match continued — match_id=%s", _match_id)) end
            return
        end
    end

    -- New match: capture team GUIDs for continuity checks; tag/name resolution deferred to intermission.
    local players = utils.get_connected_players()
    local n_axis, n_allies = 0, 0
    _alpha_guids = {}
    _beta_guids  = {}
    for _, p in ipairs(players) do
        if p.team == TEAM_AXIS   then _alpha_guids[p.guid] = true; n_axis   = n_axis   + 1 end
        if p.team == TEAM_ALLIES then _beta_guids[p.guid]  = true; n_allies = n_allies + 1 end
    end

    _is_active = true

    if scores_ref then scores_ref.activate_ng_mode(nil, nil, nil, _alpha_guids) end

    if log then
        log.write(string.format("ng: new match started — axis=%d allies=%d", n_axis, n_allies))
    end
end


function ng_scores.resolve_match_id(api_ref)
    if not _is_active then return end
    if _match_id then return end

    local players    = utils.get_connected_players()
    local alpha_list = {}
    local beta_list  = {}
    for _, p in ipairs(players) do
        if _alpha_guids[p.guid] then alpha_list[#alpha_list + 1] = p end
        if _beta_guids[p.guid]  then beta_list[#beta_list   + 1] = p end
    end

    local function build_and_detect(list)
        if #list == 0 then return nil, nil end
        local entries = {}
        for _, p in ipairs(list) do
            local ui  = et.trap_GetUserinfo(p.clientNum)
            local raw = (ui and et.Info_ValueForKey(ui, "name")) or
                        et.gentity_get(p.clientNum, "pers.netname") or ""
            if raw ~= "" then
                local stripped = utils.strip_colors(raw):match("^%s*(.-)%s*$") or ""
                if stripped ~= "" then
                    local tokens = {}
                    for tok in stripped:gmatch("[^%s%._%-%|%[%]%(%)]+") do
                        tokens[#tokens + 1] = tok
                    end
                    local raw_tokens = {}
                    for tok in raw:gmatch("[^%s%._%-%|%[%]%(%)]+") do
                        raw_tokens[#raw_tokens + 1] = tok
                    end
                    entries[#entries + 1] = {
                        raw       = raw,
                        guid      = p.guid,
                        first     = #tokens >= 2 and tokens[1]                   or nil,
                        last      = #tokens >= 2 and tokens[#tokens]             or nil,
                        raw_first = #raw_tokens >= 2 and raw_tokens[1]           or nil,
                        raw_last  = #raw_tokens >= 2 and raw_tokens[#raw_tokens] or nil,
                    }
                end
            end
        end
        if #entries == 0 then return nil, nil end

        local threshold = math.ceil(#entries * TAG_THRESHOLD)
        local function best_tag(get_tok, get_raw_tok)
            local freq = {}
            local order = {}
            for _, e in ipairs(entries) do
                local t = get_tok(e)
                if t then
                    local clean = t:match("^%s*(.-)%s*$") or ""
                    local lc = clean:lower()
                    if #lc >= TAG_MIN_LEN and #lc <= TAG_MAX_LEN then
                        if not freq[lc] then
                            freq[lc] = { tag = clean, count = 0 }
                            order[#order + 1] = lc
                        end
                        freq[lc].count = freq[lc].count + 1
                    end
                end
            end
            for _, key in ipairs(order) do
                local v = freq[key]
                if v.count >= threshold then
                    for _, e in ipairs(entries) do
                        local raw_tok = get_raw_tok(e)
                        if raw_tok then
                            local raw_clean = utils.strip_colors(raw_tok):match("^%s*(.-)%s*$") or ""
                            if raw_clean:lower() == key then
                                return raw_tok
                            end
                        end
                    end
                    return v.tag
                end
            end
        end
        local tag = best_tag(function(e) return e.first end, function(e) return e.raw_first end)
                 or best_tag(function(e) return e.last  end, function(e) return e.raw_last  end)
        return tag, entries
    end

    local alpha_tag, alpha_entries = build_and_detect(alpha_list)
    local beta_tag,  beta_entries  = build_and_detect(beta_list)

    local api_tags = {}
    do
        local lookup = {}
        if not alpha_tag and alpha_entries then lookup[#lookup + 1] = alpha_entries[1].guid end
        if not beta_tag  and beta_entries  then lookup[#lookup + 1] = beta_entries[1].guid  end
        if #lookup > 0 then
            api_tags = utils.fetch_player_tags(lookup, _api_token, _players_url, http_ref)
        end
    end

    local function resolve(tag, entries)
        if tag then return tag, "tag", nil end
        if not entries then return nil, "empty", nil end
        local api_tag = api_tags[entries[1].guid]
        if api_tag then return api_tag, "api", entries[1].raw end
        return "[" .. entries[1].raw .. "^7]", "fallback", entries[1].raw
    end

    local alpha_source, alpha_raw
    local beta_source,  beta_raw
    _alpha_name, alpha_source, alpha_raw = resolve(alpha_tag, alpha_entries)
    _beta_name,  beta_source,  beta_raw  = resolve(beta_tag,  beta_entries)

    local function warn_fallback(team_label, source, name, raw)
        if source == "tag" then return end
        local clean = raw and utils.strip_colors(raw):match("^%s*(.-)%s*$") or "?"
        utils.say(string.format("^7Couldn't determine tag for ^3%s", team_label))
        if source == "api" then
            utils.say(string.format("^7Using registered tag from ^3%s^7:", clean))
        else
            utils.say(string.format("^7Using player name ^3%s^7:", utils.strip_colors(name)))
        end
    end
    warn_fallback("Axis",   alpha_source, _alpha_name, alpha_raw)
    warn_fallback("Allies", beta_source,  _beta_name,  beta_raw)

    local id = (api_ref and api_ref.fetch_match_id()) or tostring(os.time())
    _match_id = id

    if scores_ref then
        scores_ref.set_match_id(id)
        scores_ref.activate_ng_mode(id, _alpha_name, _beta_name, _alpha_guids)
    end

    if log then
        log.write(string.format("ng: match_id resolved — %s alpha=%s beta=%s",
            id,
            utils.strip_colors(_alpha_name or "nil"),
            utils.strip_colors(_beta_name  or "nil")))
    end
end


function ng_scores.save_to_file()
    if not _match_id then return false end

    local dir = utils.get_team_data_dir()
    if not dir then
        if log then log.write("ng: save_to_file — cannot resolve team data dir") end
        return false
    end

    local path = string.format("%s/%s_team_data.json", dir, _match_id)

    local alpha_players = {}
    for g in pairs(_alpha_guids) do
        alpha_players[#alpha_players + 1] = { GUID = { g } }
    end
    local beta_players = {}
    for g in pairs(_beta_guids) do
        beta_players[#beta_players + 1] = { GUID = { g } }
    end

    local data = {
        match_id       = _match_id,
        ng             = true,
        alpha_teamname = _alpha_name,
        beta_teamname  = _beta_name,
        match          = { alpha_team = alpha_players, beta_team = beta_players },
        match_extra    = {},
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
        log.write(string.format("ng: team data saved — match_id=%s axis=%d allies=%d",
            _match_id, #alpha_players, #beta_players))
    end
    return ok
end


function ng_scores.load_from_file()
    if not _auto_scores then return false end
    if gather_ref and gather_ref.is_gather() then
        if log then log.write("ng: load_from_file skipped — gather match is active") end
        return false
    end

    local dir = utils.get_team_data_dir()
    if not dir then return false end

    local path
    if _match_id then
        path = string.format("%s/%s_team_data.json", dir, _match_id)
    else
        local ok, f = pcall(io.popen,
            string.format('ls -t "%s"/*_team_data.json 2>/dev/null', dir))
        if ok and f then
            for candidate in f:lines() do
                local rok, rdata = pcall(function()
                    local rf = io.open(candidate, "r")
                    if not rf then return nil end
                    local content = rf:read("*all")
                    rf:close()
                    if not content or content == "" then return nil end
                    return json.decode(content)
                end)
                if rok and rdata and rdata.ng then
                    path = candidate
                    break
                end
            end
            f:close()
        end
    end

    if not path then return false end

    local ok, result = pcall(function()
        local f = io.open(path, "r")
        if not f then return nil end
        local content = f:read("*all")
        f:close()
        if not content or content == "" then return nil end
        return json.decode(content)
    end)

    if not (ok and result and result.ng and result.match_id) then return false end

    _match_id    = result.match_id
    _alpha_name  = result.alpha_teamname or nil
    _beta_name   = result.beta_teamname  or nil
    _alpha_guids = {}
    _beta_guids  = {}

    for _, p in ipairs((result.match and result.match.alpha_team) or {}) do
        for _, g in ipairs(p.GUID or {}) do _alpha_guids[string.upper(g)] = true end
    end
    for _, p in ipairs((result.match and result.match.beta_team) or {}) do
        for _, g in ipairs(p.GUID or {}) do _beta_guids[string.upper(g)] = true end
    end

    if scores_ref then
        scores_ref.activate_ng_mode(_match_id, _alpha_name, _beta_name, _alpha_guids)
        if result.scores_state then
            scores_ref.restore_state(result.scores_state)
        end
    end

    _is_active = true

    if log then
        log.write(string.format("ng: match loaded from file — match_id=%s", _match_id))
    end
    return true
end


return ng_scores
