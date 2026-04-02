--[[
    stats/gamestate.lua
    Tracks the ET gamestate (warmup, playing, intermission).
    Orchestrates all module resets between rounds and the intermission
    save-stats countdown.
--]]

local gamestate = {}

local log

local players_ref
local movement_ref
local gamelog_ref
local events_ref
local objectives_ref
local gather_ref
local api_ref
local stats_ref
local scores_ref
local ng_scores_ref

gamestate.current          = -1
gamestate._last_gs_raw     = ""
gamestate.round_start_time = 0
gamestate.round_end_time   = 0
gamestate.round_start_unix = 0
gamestate.round_end_unix   = 0

gamestate.intermission      = false
gamestate.save_stats_state  = { in_progress = false }

local _scheduled_save_time = 0
local _save_stats_delay    = 3000  -- ms after intermission start


function gamestate.init(cfg, log_ref, all_modules)
    log            = log_ref
    players_ref    = all_modules.players
    movement_ref   = all_modules.movement
    gamelog_ref    = all_modules.gamelog
    events_ref     = all_modules.events
    objectives_ref = all_modules.objectives
    gather_ref     = all_modules.gather
    api_ref        = all_modules.api
    stats_ref      = all_modules.stats
    scores_ref     = all_modules.scores
    ng_scores_ref  = all_modules.ng_scores

    _save_stats_delay = cfg.save_stats_delay or 3000
end


function gamestate.reset(server_ip, server_port)
    if players_ref    then players_ref.reset()           end
    if movement_ref   then movement_ref.reset()          end
    if gamelog_ref    then gamelog_ref.reset()           end
    if events_ref     then events_ref.reset()            end
    if objectives_ref then objectives_ref.reset()        end
    if api_ref        then api_ref.reset()               end
    if stats_ref      then stats_ref.reset()             end
    if gather_ref     then gather_ref.reset()            end
    if scores_ref     then scores_ref.reset()            end
    if ng_scores_ref  then ng_scores_ref.reset()         end
    if gather_ref     then gather_ref.reset_team_data()  end
    -- team data is cleared here, after stats.save() and the post-save team_data.json

    gamestate.round_start_time = 0
    gamestate.round_end_time   = 0
    gamestate.round_start_unix = 0
    gamestate.round_end_unix   = 0
    gamestate.save_stats_state.in_progress = false
    _scheduled_save_time = 0
end


function gamestate.handle_change(new_gs, server_ip, server_port, frame_time)
    if new_gs == gamestate.current then return end

    local old_gs = gamestate.current
    gamestate.current = new_gs

    if new_gs == et.GS_PLAYING and old_gs ~= et.GS_PLAYING then
        if gather_ref then
            -- During playing, only load team data from file (no API calls)
            local cached = { nil }
            gather_ref.load_team_data_from_file(cached)
        end

        if ng_scores_ref and not (gather_ref and gather_ref.is_gather()) then
            ng_scores_ref.on_round_start()
        end

        if gamelog_ref then gamelog_ref.round_start() end

    -- fetch fresh data before round starts
    elseif new_gs == et.GS_WARMUP_COUNTDOWN and old_gs == et.GS_WARMUP then
        if gather_ref and gather_ref.is_auto_rename_enabled() then
            if log then log.write("Warmup countdown — fetching fresh team data") end
            local match_id = api_ref and api_ref.fetch_match_id()
            if match_id then
                gather_ref.save_team_data_to_file(match_id)
                if gather_ref.is_team_data_available() then
                    gather_ref.validate_all_players()
                end
            end
        end

    elseif new_gs == et.GS_INTERMISSION and old_gs == et.GS_PLAYING then
        gamestate.round_end_time = et.trap_Milliseconds()
        gamestate.round_end_unix = os.time()

        if gamelog_ref then gamelog_ref.round_end() end

        if gather_ref then
            gather_ref.on_intermission()
        end
    end
end


function gamestate.tick(frame_time, server_ip, server_port)
    if gamestate.current == et.GS_INTERMISSION then
        if not gamestate.intermission then
            if log then log.write("Entering intermission") end
            gamestate.intermission     = true
            stats_ref.store()
            _scheduled_save_time       = frame_time + _save_stats_delay
        elseif frame_time >= _scheduled_save_time
            and _scheduled_save_time > 0
            and not gamestate.save_stats_state.in_progress then

            gamestate.save_stats_state.in_progress = true

            if ng_scores_ref and ng_scores_ref.is_active() then
                ng_scores_ref.resolve_match_id(api_ref)
            end

            stats_ref.save(
                gamestate.round_start_time,
                gamestate.round_end_time,
                gamestate.round_start_unix,
                gamestate.round_end_unix,
                server_ip, server_port)

            -- Persist {match_id}_team_data.json with updated scores_state before resetting.
            -- scores_ref holds the authoritative match_id (set via load_team_data_from_file or
            -- on_team_data_fetched) and survives the et_InitGame VM reset via restore_state().
            local save_match_id = scores_ref and scores_ref.get_match_id() or nil
            if gather_ref then gather_ref.save_team_data_to_file(save_match_id) end
            if ng_scores_ref and ng_scores_ref.is_active() then
                ng_scores_ref.save_to_file()
            end

            gamestate.reset(server_ip, server_port)
        end
    else
        if gamestate.intermission then
            if log then log.write("Leaving intermission") end
            gamestate.intermission    = false
            _scheduled_save_time      = 0
            gamestate.save_stats_state.in_progress = false
        end
    end
end

return gamestate
