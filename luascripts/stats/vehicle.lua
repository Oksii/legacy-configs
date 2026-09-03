--[[
    stats/vehicle.lua
    Entity-state driven escort vehicle tracking.

    Instead of matching per-map announce strings, escort vehicles (tank,
    truck - script_mover entities with a scriptName) are found at map
    init and each is polled every tick:
      - origin delta   → moving / stopped / distance travelled
      - health <= 0    → damaged (disabled)
      - health restore → repaired
    Maps can have several escort vehicles in sequence (goldrush: tank then
    truck), so every candidate runs its own state machine; a candidate enters
    the timeline the first time it moves or takes damage.

    Per-player escort credit (time + distance) accrues while a vehicle is
    actually moving and the player is alive, on the owning team and within
    ESCORT_RADIUS of it.

    Damage attribution comes from et_Damage (fires for script_movers with a
    scriptName — target is the vehicle entnum). Repair attribution comes from
    the "Repair: <clientNum>" console line forwarded by objectives.lua.
--]]

local vehicle = {}
local utils    = require("luascripts/stats/util/utils")
local pathgate = require("luascripts/stats/util/pathgate")

local log
local players_ref
local gamelog_ref
local activity_ref
local ACT_SRC_OBJ

local _collect_telemetry    = false
local _collect_damage       = false

-- Telemetry is vertex-gated (util/pathgate) rather than fixed-cadence: movers
-- run on rails, so points are only worth emitting where the rail bends. The
-- poll interval stays 250ms because escort credit accrues dt_ms from it.
local POLL_INTERVAL_MS      = 250
local STOP_GRACE_MS         = 1000   -- moving → stopped after this long without displacement
local INIT_GRACE_MS         = 2000   -- after a fresh poll clock: resync only, no events/credit.
                                     -- Covers mid-round VM reloads where the engine restores
                                     -- mover positions/health a few frames after lua init.
local MOVE_EPSILON          = 1      -- units per poll below this = not moving
local TELEPORT_LIMIT        = 512    -- origin jump larger than this per poll = relink/teleport, no credit
local REPAIR_WINDOW_MS      = 3000   -- Repair: N line must arrive within this of a health restore
local DAMAGE_WINDOW_MS      = 3000   -- et_Damage must precede the disable transition within this
local DEFAULT_ESCORT_RADIUS = 500    -- game units, override via config escort.<name>.radius

local ENT_FIRST             = 64
local ENT_LAST              = 1021

-- candidates[entnum] = per-vehicle state machine:
-- { script_name, origin, health, disabled, started, is_moving,
--   last_move_ms, pos_gate, segment_distance, total_distance,
--   moving_time_ms, damaged_count, repaired_count, last_damager }
local candidates            = {}

local owner_team            = nil    -- et.TEAM_ALLIES / et.TEAM_AXIS
local escort_radius         = DEFAULT_ESCORT_RADIUS
local last_poll_ms          = 0
local grace_until_ms        = 0      -- resync-only until this time after a fresh clock
local pending_repair        = nil    -- { clientNum, ms } from "Repair: N"

-- escort_credit[guid][vehicle_script_name] = { time_ms, distance, finale }
local escort_credit         = {}
-- damage_tally[guid] = { damage, hits }   repair_tally[guid] = count
local damage_tally          = {}
local repair_tally          = {}


local function guid_of(clientNum)
    local entry = players_ref and players_ref.guids[clientNum]
    return entry and entry.guid ~= "WORLD" and entry.guid or nil
end


local function emit(label, cand, fields, leveltime)
    if gamelog_ref then
        gamelog_ref.vehicle_event(label, cand and cand.script_name or nil, fields, leveltime)
    end
    if log then
        log.debug(string.format("Vehicle: %s (%s)", label, cand and cand.script_name or "?"))
    end
end


function vehicle.init(cfg, log_ref, players_module, gamelog_module, activity_module)
    log          = log_ref
    players_ref  = players_module
    gamelog_ref  = gamelog_module
    activity_ref = activity_module
    ACT_SRC_OBJ  = activity_module and activity_module.SRC_OBJ or nil

    _collect_telemetry = cfg.collect_vehicle_telemetry or false
    _collect_damage    = cfg.collect_vehicle_damage or false
end


-- Scan for script_mover candidates. 
function vehicle.init_map(map_config)
    vehicle.reset()

    if not (map_config and map_config.escort and next(map_config.escort)) then
        if log then
            log.write("Vehicle tracking off — no escort config for this map")
        end
        return
    end

    local pinned = {}
    do
        for e_name, e_cfg in pairs(map_config.escort) do
            if e_cfg.script_name and e_cfg.script_name ~= "" then
                pinned[utils.normalize(e_cfg.script_name)] = true
            else
                pinned[utils.normalize(e_name)] = true
            end
            if e_cfg.team == "axis" then owner_team = et.TEAM_AXIS end
            if tonumber(e_cfg.radius) then escort_radius = tonumber(e_cfg.radius) end
        end
    end
    -- `team = "axis"` in the escort config overrides.
    owner_team = owner_team or et.TEAM_ALLIES

    local all, matched = {}, {}
    for entnum = ENT_FIRST, ENT_LAST do
        if et.gentity_get(entnum, "classname") == "script_mover" then
            local sname = et.gentity_get(entnum, "scriptName")
            if sname and sname ~= "" then
                local origin = et.gentity_get(entnum, "r.currentOrigin")
                local cand = {
                    script_name       = sname,
                    origin            = origin and { origin[1], origin[2], origin[3] } or nil,
                    health            = tonumber(et.gentity_get(entnum, "health")) or 0,
                    disabled          = false,
                    started           = false,
                    is_moving         = false,
                    last_move_ms      = 0,
                    pos_gate          = pathgate.new(pathgate.VEHICLE),
                    segment_distance  = 0,
                    total_distance    = 0,
                    moving_time_ms    = 0,
                    damaged_count     = 0,
                    repaired_count    = 0,
                    last_damager      = nil,
                }
                all[entnum] = cand
                if pinned[utils.normalize(sname)] then
                    matched[entnum] = cand
                end
            end
        end
    end

    candidates = next(matched) and matched or all
    if log then
        for entnum, cand in pairs(candidates) do
            log.write(string.format("Vehicle candidate: ent %d scriptName=%s%s",
                entnum, cand.script_name, matched[entnum] and " (pinned)" or ""))
        end
    end
end


local function escort_entry(guid, vehicle_name)
    local per = escort_credit[guid]
    if not per then
        per = {}
        escort_credit[guid] = per
    end
    local acc = per[vehicle_name]
    if not acc then
        acc = { time_ms = 0, distance = 0 }
        per[vehicle_name] = acc
    end
    return acc
end


-- Returns the guids credited this tick so movement/telemetry events can
-- carry the escorting players alongside the vehicle position.
local function accrue_escort(cand, origin, displacement, dt_ms)
    local escorts = {}
    for clientNum, entry in pairs(players_ref.guids) do
        if entry.team == owner_team and entry.guid and entry.guid ~= "WORLD" then
            local health = tonumber(et.gentity_get(clientNum, "health")) or 0
            local pos    = et.gentity_get(clientNum, "r.currentOrigin")
            if health > 0 and pos and utils.distance3d_units(origin, pos) <= escort_radius then
                local acc = escort_entry(entry.guid, cand.script_name)
                acc.time_ms  = acc.time_ms + dt_ms
                acc.distance = acc.distance + displacement
                table.insert(escorts, entry.guid)

                if activity_ref then activity_ref.stamp(entry.guid, ACT_SRC_OBJ) end
            end
        end
    end
    return escorts
end


local function poll_entity(entnum, cand, now, dt_ms)
    local origin = et.gentity_get(entnum, "r.currentOrigin")
    local health = tonumber(et.gentity_get(entnum, "health")) or 0

    local displacement = 0
    if origin and cand.origin then
        displacement = utils.distance3d_units(cand.origin, origin)
    end
    if displacement >= TELEPORT_LIMIT then
        displacement = 0  -- relink/teleport jump — no movement credit
    end

    local moved = displacement >= MOVE_EPSILON

    -- movement transitions
    if moved then
        local escorts = accrue_escort(cand, origin, displacement, dt_ms)
        if #escorts == 0 then escorts = nil end  -- omit empty arrays from the JSON
        cand.last_escorts = escorts

        if not cand.is_moving then
            cand.is_moving = true
            if not cand.started then
                cand.started = true
                emit("vehicle_started", cand, { pos = utils.fmt_pos(origin), escorts = escorts })
            else
                emit("vehicle_moving", cand, { pos = utils.fmt_pos(origin), escorts = escorts })
            end
        end
        cand.last_move_ms     = now
        cand.segment_distance = cand.segment_distance + displacement
        cand.total_distance   = cand.total_distance + displacement
        cand.moving_time_ms   = cand.moving_time_ms + dt_ms

        -- Only sampled while moving, so a parked vehicle stays silent (its
        -- vehicle_stopped event already carries the position).
        if _collect_telemetry then
            local vertex, vertex_ms = cand.pos_gate:sample(origin, now)
            if vertex then
                emit("vehicle_pos", cand,
                    { pos = utils.fmt_pos(vertex), escorts = escorts }, vertex_ms)
            end
        end
    elseif cand.is_moving and (now - cand.last_move_ms) >= STOP_GRACE_MS then
        cand.is_moving = false
        emit("vehicle_stopped", cand, {
            pos              = utils.fmt_pos(origin),
            segment_distance = math.floor(cand.segment_distance),
            escorts          = cand.last_escorts,
        })
        cand.segment_distance = 0
        cand.last_escorts     = nil
    end

    -- health transitions
    if not cand.disabled and cand.health > 0 and health <= 0 then
        cand.disabled      = true
        cand.damaged_count = cand.damaged_count + 1
        local damager_guid
        if cand.last_damager and (now - cand.last_damager.ms) <= DAMAGE_WINDOW_MS then
            damager_guid = guid_of(cand.last_damager.clientNum)
        end
        emit("vehicle_damaged", cand, { player = damager_guid, pos = utils.fmt_pos(origin) })
    elseif cand.disabled and health > 0 then
        cand.disabled       = false
        cand.repaired_count = cand.repaired_count + 1
        local repairer_guid
        if pending_repair and (now - pending_repair.ms) <= REPAIR_WINDOW_MS then
            repairer_guid = guid_of(pending_repair.clientNum)
            if _collect_damage and repairer_guid then
                repair_tally[repairer_guid] = (repair_tally[repairer_guid] or 0) + 1
            end
            pending_repair = nil
        end
        emit("vehicle_repaired", cand, { player = repairer_guid, pos = utils.fmt_pos(origin) })
    end

    cand.origin = origin and { origin[1], origin[2], origin[3] } or cand.origin
    cand.health = health
end


-- Resync tracked origin/health to the live entity state without emitting
-- anything. Used while the poll clock is in its grace window.
local function resync_candidates()
    for entnum, cand in pairs(candidates) do
        local origin = et.gentity_get(entnum, "r.currentOrigin")
        cand.origin = origin and { origin[1], origin[2], origin[3] } or cand.origin
        cand.health = tonumber(et.gentity_get(entnum, "health")) or cand.health
    end
end


-- Called from et_RunFrame. Skips accrual across pauses/non-play frames by
-- restarting the poll clock instead of accumulating a large dt. A fresh
-- clock opens a short grace window that only resyncs entity state — the
-- engine may still be restoring mover positions/health (mid-round VM
-- reload), and those restore jumps must not become events or credit.
function vehicle.tick(now, paused, playing)
    if not next(candidates) then return end

    if paused or not playing then
        last_poll_ms = 0
        return
    end

    if last_poll_ms == 0 then
        grace_until_ms = now + INIT_GRACE_MS
    end

    if now < grace_until_ms then
        resync_candidates()
        last_poll_ms = now
        return
    end

    if (now - last_poll_ms) < POLL_INTERVAL_MS then return end
    local dt_ms  = now - last_poll_ms
    last_poll_ms = now

    for entnum, cand in pairs(candidates) do
        poll_entity(entnum, cand, now, dt_ms)
    end
end


function vehicle.on_damage(target, attacker, damage, now)
    local cand = candidates[target]
    if not cand then return false end

    cand.last_damager = { clientNum = attacker, ms = now }

    if _collect_damage then
        local guid = guid_of(attacker)
        if guid then
            -- Clamp to the vehicle's remaining health: the engine passes raw
            -- damage and subtracts health only after the hook, so a panzer or
            -- airstrike overkilling a near-dead tank would otherwise report its
            -- full amount rather than the fraction that disabled it.
            local hp  = tonumber(et.gentity_get(target, "health")) or 0
            local eff = math.min(damage or 0, math.max(0, hp))
            if eff > 0 then
                local tally = damage_tally[guid]
                if not tally then
                    tally = { damage = 0, hits = 0 }
                    damage_tally[guid] = tally
                end
                tally.damage = tally.damage + eff
                tally.hits   = tally.hits + 1
                emit("vehicle_damage", cand, { player = guid, damage = eff })
            end
        end
    end
    return true
end


function vehicle.on_repair(clientNum, now)
    for _, cand in pairs(candidates) do
        if cand.disabled then
            pending_repair = { clientNum = clientNum, ms = now }
            return
        end
    end
end


-- Escort finale: the map's escort announce fired ("Bank Doors destroyed",
-- "escaped with the Gold Crate", …). Emits a vehicle_finale timeline event
-- listing the owning-team players at the destination — the "who delivered
-- it" fact, complementing vehicle_started's "who stole it" escorts. The
-- per-player stats stay pure cumulative time/distance. Forwarded by
-- objectives.lua from the configured escort_pattern; coords come from
-- escort_coordinates, falling back to the named vehicle's current position.
function vehicle.on_escort_finale(escort_name, coords_str)
    local wanted = utils.normalize(escort_name or "")
    local vname, ref

    for entnum, cand in pairs(candidates) do
        if utils.normalize(cand.script_name) == wanted then
            vname = cand.script_name
            ref   = et.gentity_get(entnum, "r.currentOrigin")
            break
        end
    end
    vname = vname or escort_name

    if coords_str then
        local x, y, z = tostring(coords_str):match("([%-%.%d]+)%s+([%-%.%d]+)%s+([%-%.%d]+)")
        if x then ref = { tonumber(x), tonumber(y), tonumber(z) } end
    end
    if not ref or not owner_team then return end

    local escorts = {}
    for clientNum, entry in pairs(players_ref.guids) do
        if entry.team == owner_team and entry.guid and entry.guid ~= "WORLD" then
            local health = tonumber(et.gentity_get(clientNum, "health")) or 0
            local pos    = et.gentity_get(clientNum, "r.currentOrigin")
            if health > 0 and pos and utils.distance3d_units(ref, pos) <= escort_radius then
                table.insert(escorts, entry.guid)
            end
        end
    end

    if gamelog_ref then
        gamelog_ref.vehicle_event("vehicle_finale", vname, {
            pos     = utils.fmt_pos(ref),
            escorts = #escorts > 0 and escorts or nil,
        })
    end
end


function vehicle.round_end()
    for _, cand in pairs(candidates) do
        if cand.started then
            emit("vehicle_summary", cand, {
                total_distance = math.floor(cand.total_distance),
                moving_time_s  = math.floor(cand.moving_time_ms / 1000),
                damaged_count  = cand.damaged_count,
                repaired_count = cand.repaired_count,
            })
        end
    end
end


-- Per-guid stats merged into player_stats at SaveStats time.
-- { [guid] = { escort = { [vehicle] = {time_s, distance} },
--              damage = {damage, hits}, repairs = n } }
function vehicle.get_stats()
    local out = {}
    local function row(guid)
        local r = out[guid]
        if not r then r = {}; out[guid] = r end
        return r
    end

    for guid, per in pairs(escort_credit) do
        local escort = {}
        for vname, acc in pairs(per) do
            escort[vname] = {
                time_s   = math.floor(acc.time_ms / 1000),
                distance = math.floor(acc.distance),
            }
        end
        row(guid).escort = escort
    end
    for guid, tally in pairs(damage_tally) do
        row(guid).damage = { damage = tally.damage, hits = tally.hits }
    end
    for guid, count in pairs(repair_tally) do
        row(guid).repairs = count
    end
    return out
end


function vehicle.is_vehicle(entnum)
    return candidates[entnum] ~= nil
end


function vehicle.reset()
    candidates     = {}
    owner_team     = nil
    escort_radius  = DEFAULT_ESCORT_RADIUS
    last_poll_ms   = 0
    grace_until_ms = 0
    pending_repair = nil
    escort_credit  = {}
    damage_tally   = {}
    repair_tally   = {}
end

return vehicle
