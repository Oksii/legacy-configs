--[[
    stats/movement.lua
    Per-frame stance accumulation and movement/speed tracking.
--]]

local movement = {}

local utils = require("luascripts/stats/util/utils")

local log 

local CON_CONNECTED             = 2
local EF_DEAD                   = 0x00000001
local EF_CROUCHING              = 0x00000010
local EF_MG42_ACTIVE            = 0x00000020
local EF_MOUNTEDTANK            = 0x00008000
local EF_PRONE                  = 0x00080000
local EF_PRONE_MOVING           = 0x00100000
local EF_TAGCONNECT             = 0x00008000

local MAX_SPRINT_TIME           = 20000
local STAMINA_CHANGE_THRESHOLD  = 50

local WP_MOBILE_MG42_SET        = 47
local WP_MOBILE_BROWNING_SET    = 50

local PW_REDFLAG                = 5
local PW_BLUEFLAG               = 6
local PW_OPS_DISGUISED          = 7

local BODY_DOWNED               = 67108864

local SPAWN_DETECTION_THRESHOLD = 50
local SPAWN_TRACK_DURATION      = 3000

local DISTANCE_MIN_M            = 0.025

-- movement_stats[guid] = {
--   distance_travelled, last_position, distance_travelled_spawn,
--   spawn_count, peak_speed_ups, total_speed_samples, total_speed_sum
-- }
local movement_stats = {}

-- stance_stats[guid] = {
--   in_prone, in_crouch, in_mg, in_lean,
--   in_objcarrier, in_vehiclescort, in_disguise, in_sprint, in_turtle, is_downed,
--   last_stance_check, last_sprint_time
-- }
local stance_stats = {}

-- spawn_tracking[guid] = {
--   tracking_active, tracking_end_time, spawn_position,
--   distance_travelled, last_detected_spawn_time
-- }
local spawn_tracking = {}

local _last_frame_time = 0
local _maxClients      = 64


local function ensure_tracking(guid)
    if not movement_stats[guid] then
        movement_stats[guid] = {
            distance_travelled       = 0,
            last_position            = nil,
            distance_travelled_spawn = 0,
            spawn_count              = 0,
            peak_speed_ups           = 0,
            total_speed_samples      = 0,
            total_speed_sum          = 0,
        }
    end

    if not stance_stats[guid] then
        stance_stats[guid] = {
            in_prone        = 0,
            in_crouch       = 0,
            in_mg           = 0,
            in_lean         = 0,
            in_objcarrier   = 0,
            in_vehiclescort = 0,
            in_disguise     = 0,
            in_sprint       = 0,
            in_turtle       = 0,
            is_downed       = 0,
            last_stance_check = 0,
            last_sprint_time  = MAX_SPRINT_TIME,
        }
    end

    if not spawn_tracking[guid] then
        spawn_tracking[guid] = {
            tracking_active           = false,
            tracking_end_time         = 0,
            spawn_position            = nil,
            distance_travelled        = 0,
            last_detected_spawn_time  = 0,
        }
    end
end


function movement.init(log_ref, maxClients)
    log = log_ref
    _maxClients = maxClients or 64
end


function movement.track(level_time, players_ref)
    local frame_dt = level_time - _last_frame_time
    if frame_dt <= 0 then
        _last_frame_time = level_time
        return
    end

    for guid, sp in pairs(spawn_tracking) do
        if sp.tracking_active and level_time >= sp.tracking_end_time then
            sp.tracking_active = false
            if movement_stats[guid] then
                movement_stats[guid].distance_travelled_spawn =
                    movement_stats[guid].distance_travelled_spawn + sp.distance_travelled
            end
        end
    end

    for clientNum = 0, _maxClients - 1 do
        if et.gentity_get(clientNum, "pers.connected") == CON_CONNECTED then
            local entry = players_ref.guids[clientNum]
            if entry and entry.guid ~= "WORLD" then
                local team = entry.team
                if team == et.TEAM_AXIS or team == et.TEAM_ALLIES then
                    local guid = entry.guid
                    ensure_tracking(guid)

                    local health  = tonumber(et.gentity_get(clientNum, "health"))         or 0
                    local eFlags  = tonumber(et.gentity_get(clientNum, "ps.eFlags"))      or 0
                    local body    = tonumber(et.gentity_get(clientNum, "r.contents"))     or 0

                    local is_alive  = health > 0
                    local is_downed = (health < 0 and body == BODY_DOWNED)
                    local st        = stance_stats[guid]
                    local time_dt   = level_time - (st.last_stance_check or level_time)

                    if is_alive and not is_downed then
                        -- Spawn detection
                        local last_spawn = tonumber(et.gentity_get(clientNum, "pers.lastSpawnTime")) or 0
                        local sp = spawn_tracking[guid]
                        if last_spawn > 0
                        and (level_time - last_spawn) < SPAWN_DETECTION_THRESHOLD
                        and last_spawn > sp.last_detected_spawn_time then
                            local origin = et.gentity_get(clientNum, "ps.origin")
                            if origin then
                                sp.tracking_active          = true
                                sp.tracking_end_time        = level_time + SPAWN_TRACK_DURATION
                                sp.spawn_position           = { origin[1], origin[2], origin[3] }
                                sp.last_detected_spawn_time = last_spawn
                                sp.distance_travelled       = 0
                                movement_stats[guid].spawn_count =
                                    (movement_stats[guid].spawn_count or 0) + 1
                            end
                        end

                        -- Stance accumulation
                        if time_dt > 0 then
                            local weapon  = tonumber(et.gentity_get(clientNum, "ps.weapon")) or 0
                            local leanf   = tonumber(et.gentity_get(clientNum, "ps.leanf"))  or 0

                            local red_flag  = tonumber(et.gentity_get(clientNum, "ps.powerups", PW_REDFLAG))       or 0
                            local blue_flag = tonumber(et.gentity_get(clientNum, "ps.powerups", PW_BLUEFLAG))      or 0
                            local disguise  = tonumber(et.gentity_get(clientNum, "ps.powerups", PW_OPS_DISGUISED)) or 0

                            local sprint_val  = tonumber(et.gentity_get(clientNum, "ps.stats", 8)) or MAX_SPRINT_TIME
                            local last_st_val = st.last_sprint_time or MAX_SPRINT_TIME
                            local sprint_delta = last_st_val - sprint_val

                            local is_prone    = (eFlags & EF_PRONE)       ~= 0 or (eFlags & EF_PRONE_MOVING) ~= 0
                            local is_crouching= (eFlags & EF_CROUCHING)   ~= 0
                            local is_mounted  = (eFlags & EF_MG42_ACTIVE) ~= 0
                                             or (eFlags & EF_MOUNTEDTANK)  ~= 0
                                             or weapon == WP_MOBILE_MG42_SET
                                             or weapon == WP_MOBILE_BROWNING_SET
                            local is_leaning  = leanf ~= 0
                            local is_vehicle  = (eFlags & EF_TAGCONNECT)  ~= 0
                            local is_carrying = (red_flag > 0 or blue_flag > 0)
                            local is_disguised= disguise > 0
                            local is_sprinting= sprint_delta > STAMINA_CHANGE_THRESHOLD
                            local is_turtle   = (sprint_val == 0)
                                             or (sprint_val == MAX_SPRINT_TIME)
                                             or (sprint_delta < -STAMINA_CHANGE_THRESHOLD)

                            local dt_sec = time_dt / 1000

                            if is_prone    then st.in_prone  = st.in_prone  + dt_sec end
                            if is_mounted  then st.in_mg     = st.in_mg     + dt_sec end
                            if is_crouching and not is_prone and not is_mounted then
                                st.in_crouch = st.in_crouch + dt_sec
                            end
                            if is_leaning and not is_prone and not is_mounted then
                                st.in_lean = st.in_lean + dt_sec
                            end
                            if is_carrying  then st.in_objcarrier   = st.in_objcarrier   + dt_sec end
                            if is_vehicle   then st.in_vehiclescort = st.in_vehiclescort + dt_sec end
                            if is_disguised then st.in_disguise     = st.in_disguise     + dt_sec end
                            if is_sprinting then st.in_sprint       = st.in_sprint       + dt_sec end
                            if is_turtle    then st.in_turtle       = st.in_turtle       + dt_sec end

                            st.last_sprint_time  = sprint_val
                            players_ref.update_sprint_time(guid, sprint_val)
                        end

                        -- Distance + speed tracking
                        local mv = movement_stats[guid]
                        local sp = spawn_tracking[guid]
                        local cur_pos  = et.gentity_get(clientNum, "ps.origin")
                        local velocity = et.gentity_get(clientNum, "ps.velocity")

                        if velocity then
                            local speed_ups = math.sqrt(
                                velocity[1]*velocity[1] +
                                velocity[2]*velocity[2] +
                                velocity[3]*velocity[3])
                            if speed_ups > mv.peak_speed_ups then
                                mv.peak_speed_ups = speed_ups
                            end
                            if speed_ups > 10 then
                                mv.total_speed_samples = mv.total_speed_samples + 1
                                mv.total_speed_sum     = mv.total_speed_sum + speed_ups
                            end
                        end

                        if cur_pos and mv.last_position then
                            local dist_m = utils.distance3d(mv.last_position, cur_pos)
                            if dist_m > DISTANCE_MIN_M then
                                mv.distance_travelled = mv.distance_travelled + dist_m
                                if sp.tracking_active then
                                    sp.distance_travelled = sp.distance_travelled + dist_m
                                end
                            end
                        end
                        if cur_pos then
                            if mv.last_position then
                                mv.last_position[1] = cur_pos[1]
                                mv.last_position[2] = cur_pos[2]
                                mv.last_position[3] = cur_pos[3]
                            else
                                mv.last_position = { cur_pos[1], cur_pos[2], cur_pos[3] }
                            end
                        else
                            mv.last_position = nil
                        end

                    elseif is_downed then
                        if time_dt > 0 then
                            st.is_downed = st.is_downed + (time_dt / 1000)
                        end
                    end

                    st.last_stance_check = level_time
                end
            end
        end
    end

    _last_frame_time = level_time
end

function movement.get_stats(guid)
    local mv = movement_stats[guid]
    local st = stance_stats[guid]
    if not mv then return nil end

    local avg_speed = 0
    if mv.total_speed_samples > 0 then
        avg_speed = mv.total_speed_sum / mv.total_speed_samples
    end

    local avg_spawn_dist = 0
    if mv.spawn_count > 0 then
        avg_spawn_dist = mv.distance_travelled_spawn / mv.spawn_count
    end

    return {
        distance_travelled       = mv.distance_travelled,
        distance_travelled_spawn = avg_spawn_dist,
        spawn_count              = mv.spawn_count,
        peak_speed_ups           = mv.peak_speed_ups,
        avg_speed_ups            = avg_speed,
        stance_stats_seconds     = st and {
            in_prone             = st.in_prone,
            in_crouch            = st.in_crouch,
            in_mg                = st.in_mg,
            in_lean              = st.in_lean,
            in_objcarrier        = st.in_objcarrier,
            in_vehiclescort      = st.in_vehiclescort,
            in_disguise          = st.in_disguise,
            in_sprint            = st.in_sprint,
            in_turtle            = st.in_turtle,
            is_downed            = st.is_downed,
        } or nil,
    }
end

function movement.clear(guid)
    movement_stats[guid] = nil
    stance_stats[guid]   = nil
    spawn_tracking[guid] = nil
end

function movement.reset()
    movement_stats  = {}
    stance_stats    = {}
    spawn_tracking  = {}
    _last_frame_time = 0
end

return movement
