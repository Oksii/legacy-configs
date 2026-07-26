--[[
    stats/gamelog.lua
    Pure in-memory event buffer.
    All callers (events.lua, objectives.lua, players.lua, gamestate.lua)
    push events here; stats.lua drains the buffer at SaveStats time.

    Event structure (every entry):
        { unixtime, leveltime, group, label, ...fields }

    match_id and round_id are NOT stored per-event; they are injected
    into every entry by gamelog.get() at SaveStats time.
--]]

local gamelog = {}

local utils = require("luascripts/stats/util/utils")

local _buffer                = {}  -- array of event tables
local _enabled               = true
local _round_start_unix_ms   = 0   -- os.time() * 1000 recorded at round_start
local _round_start_leveltime = 0   -- et.trap_Milliseconds() recorded at round_start


function gamelog.init(enabled)
    _enabled = (enabled ~= false)
end


-- gamelog.record(label, group, fields, leveltime)
-- leveltime/unixtime are raw (paused time is removed downstream in ingest using the
-- pause/unpause markers -- see gamelog.pause_start/pause_end).
function gamelog.record(label, group, fields, leveltime)
    if not _enabled then return end

    local lt = leveltime or et.trap_Milliseconds()
    local ev = {
        unixtime  = _round_start_unix_ms + (lt - _round_start_leveltime),
        leveltime = lt,
        group     = group or "player",
        label     = label,
    }

    if fields then
        for k, v in pairs(fields) do
            ev[k] = v
        end
    end

    table.insert(_buffer, ev)
end


local function stance_of(snap)
    if not snap then return nil end
    return {
        is_prone        = snap.is_prone,
        is_crouch       = snap.is_crouch,
        is_mounted      = snap.is_mounted,
        is_leaning      = snap.is_leaning,
        is_carrying_obj = snap.is_carrying_obj,
        is_disguised    = snap.is_disguised,
        is_downed       = snap.is_downed,
        is_sprint       = snap.is_sprint,
    }
end


-- Kill
function gamelog.kill(killer_snap, victim_snap, weapon, allies_alive, axis_alive, killer_reinf, victim_reinf)
    gamelog.record("kill", "player", {
        killer          = killer_snap and killer_snap.guid,
        victim          = victim_snap  and victim_snap.guid,
        weapon          = weapon,
        killer_health   = killer_snap and killer_snap.health,
        killer_class    = killer_snap and killer_snap.class,
        killer_pos      = utils.fmt_pos(killer_snap and killer_snap.pos),
        killer_stance   = stance_of(killer_snap),
        victim_class    = victim_snap  and victim_snap.class,
        victim_pos      = utils.fmt_pos(victim_snap  and victim_snap.pos),
        victim_stance   = stance_of(victim_snap),
        allies_alive    = allies_alive,
        axis_alive      = axis_alive,
        killer_reinf    = killer_reinf,
        victim_reinf    = victim_reinf,
    })
end

-- Suicide. victim_reinf/team describe the dying player (the player is the victim
-- of their own death) so downstream full-spawn detection can use the exact reinf.
function gamelog.suicide(victim_snap, weapon, victim_reinf, team)
    gamelog.record("suicide", "player", {
        player        = victim_snap and victim_snap.guid,
        weapon        = weapon,
        team          = team,
        victim_class  = victim_snap and victim_snap.class,
        victim_pos    = utils.fmt_pos(victim_snap and victim_snap.pos),
        victim_stance = stance_of(victim_snap),
        victim_reinf  = victim_reinf,
    })
end

-- Teamkill
function gamelog.teamkill(killer_snap, victim_snap, weapon, victim_reinf)
    gamelog.record("teamkill", "player", {
        killer          = killer_snap and killer_snap.guid,
        victim          = victim_snap  and victim_snap.guid,
        weapon          = weapon,
        killer_class    = killer_snap and killer_snap.class,
        killer_stance   = stance_of(killer_snap),
        victim_class    = victim_snap  and victim_snap.class,
        victim_health   = victim_snap  and victim_snap.health,
        victim_stance   = stance_of(victim_snap),
        victim_reinf    = victim_reinf,
    })
end

-- Damage
function gamelog.damage(killer_snap, victim_snap, damage, damage_flags, weapon, hit_region)
    gamelog.record("damage", "player", {
        killer          = killer_snap and killer_snap.guid,
        victim          = victim_snap  and victim_snap.guid,
        damage          = damage,
        damage_flags    = damage_flags,
        weapon          = weapon,
        hit_region      = hit_region,
        killer_health   = killer_snap and killer_snap.health,
        killer_class    = killer_snap and killer_snap.class,
        killer_pos      = utils.fmt_pos(killer_snap and killer_snap.pos),
        killer_stance   = stance_of(killer_snap),
        victim_health   = victim_snap  and victim_snap.health,
        victim_class    = victim_snap  and victim_snap.class,
        victim_pos      = utils.fmt_pos(victim_snap  and victim_snap.pos),
        victim_stance   = stance_of(victim_snap),
    })
end

-- Revive
function gamelog.revive(medic_snap, revivee_snap)
    gamelog.record("revive", "player", {
        player        = medic_snap   and medic_snap.guid,
        victim        = revivee_snap and revivee_snap.guid,
        player_pos    = utils.fmt_pos(medic_snap   and medic_snap.pos),
        player_stance = stance_of(medic_snap),
        victim_pos    = utils.fmt_pos(revivee_snap and revivee_snap.pos),
        victim_stance = stance_of(revivee_snap),
    })
end

-- Class change
function gamelog.class_change(guid, new_class)
    gamelog.record("class_change", "player", {
        player = guid,
        class  = new_class,
    })
end

-- Generic objective event (label is the event type string, e.g. "obj_planted").
-- pos is optional: obj_taken / obj_repickup carry it so a carrier route has a
-- true start vertex (and a run has a start coordinate).
-- run is the carry-run id, on the labels that open or close a run.
function gamelog.objective(label, guid, obj_name, pos, run)
    gamelog.record(label, "player", {
        player    = guid,
        objective = obj_name,
        pos       = pos,
        run       = run,
    })
end

-- Flag captured.
-- pos is the crediting player's origin; flag_pos is the checkpoint entity's own
-- position, which is where the flag is regardless of who is standing near it.
-- Credit goes to everyone within range, so several of these share one flag_pos.
function gamelog.obj_flag_captured(guid, flag_name, pos, flag_pos)
    gamelog.record("obj_flag_captured", "player", {
        player   = guid,
        flag     = flag_name,
        pos      = pos,
        flag_pos = flag_pos,
    })
end

-- Killed an enemy objective carrier — credited to the killer.
-- pos/victim_pos follow gamelog.kill's killer_pos/victim_pos convention: pos
-- belongs to `player` (the killer), victim_pos to the carrier who went down.
-- victim_pos is the interesting one for a replay -- it is where the objective
-- was dropped, and it closes the carry run named by `run`.
function gamelog.obj_carrier_killed(killer_guid, victim_guid, obj_name, weapon, run,
                                    pos, victim_pos)
    gamelog.record("obj_carrierkilled", "player", {
        player     = killer_guid,
        victim     = victim_guid,
        objective  = obj_name,
        weapon     = weapon,
        run        = run,
        pos        = pos,
        victim_pos = victim_pos,
    })
end

function gamelog.obj_dropped(guid, obj_name, pos, run)
    gamelog.record("obj_dropped", "player", {
        player    = guid,
        objective = obj_name,
        pos       = pos,
        run       = run,
    })
end

-- Damage to a non-vehicle damageable objective (command post, destroyable
-- walls). Only hits passing the engine's weapon-class gate arrive here.
function gamelog.obj_damage(guid, damage, target_name)
    gamelog.record("obj_damage", "player", {
        player = guid,
        damage = damage,
        target = target_name,
    })
end

-- Vehicle timeline / telemetry event (label e.g. "vehicle_started",
-- "vehicle_stopped", "vehicle_damaged", "vehicle_repaired", "vehicle_pos",
-- "vehicle_damage", "vehicle_summary")
function gamelog.vehicle_event(label, vehicle_name, fields, leveltime)
    local ev = { vehicle = vehicle_name }
    if fields then
        for k, v in pairs(fields) do ev[k] = v end
    end
    gamelog.record(label, "vehicle", ev, leveltime)
end

-- Objective-carrier position telemetry sample.
-- leveltime is the moment the position was sampled, which for a corner vertex
-- is a few frames before the event is emitted.
-- run identifies the carry this sample belongs to, so a consumer can partition
-- the series with a group-by instead of replaying the surrounding events. The
-- same player can carry the same objective several times in one round, which is
-- what makes the id load-bearing rather than a convenience.
function gamelog.carrier_pos(guid, obj_name, pos, leveltime, run)
    gamelog.record("carrier_pos", "player", {
        player    = guid,
        objective = obj_name,
        pos       = pos,
        run       = run,
    }, leveltime)
end

-- Pickup from console log
function gamelog.pickup(player_snap, item, owner_snap)
    gamelog.record("pickup", "player", {
        player       = player_snap and player_snap.guid,
        item         = item,
        owner        = owner_snap and owner_snap.guid or nil,
        pos          = utils.fmt_pos(player_snap and player_snap.pos),
        stance       = stance_of(player_snap),
        owner_pos    = utils.fmt_pos(owner_snap and owner_snap.pos),
        owner_stance = stance_of(owner_snap),
    })
end

-- Player spawn (not a revive)
-- weapons: array of notable weapon name strings present at spawn, or nil
function gamelog.spawn(guid, team, class, weapons)
    gamelog.record("spawn", "player", {
        player  = guid,
        team    = team,
        class   = class,
        weapons = weapons,  -- nil when not tracked
    })
end

-- Weapon fire (et_WeaponFire / et_FixedMGFire)
function gamelog.weapon_fire(snap, weapon, pitch, yaw)
    gamelog.record("weapon_fire", "player", {
        player = snap and snap.guid,
        weapon = weapon,
        pos    = utils.fmt_pos(snap and snap.pos),
        pitch  = pitch,
        yaw    = yaw,
        stance = stance_of(snap),
    })
end

-- Shove
function gamelog.shove(shover_snap, target_snap)
    gamelog.record("shove", "player", {
        player        = shover_snap and shover_snap.guid,
        victim        = target_snap and target_snap.guid,
        player_pos    = utils.fmt_pos(shover_snap and shover_snap.pos),
        player_stance = stance_of(shover_snap),
        victim_pos    = utils.fmt_pos(target_snap and target_snap.pos),
        victim_stance = stance_of(target_snap),
    })
end

-- Chat / vsay message
function gamelog.message(guid, command, message_text, vsay_text)
    gamelog.record("message", "player", {
        player    = guid,
        command   = command,
        message   = message_text,
        vsay_text = vsay_text,
    })
end

function gamelog.round_start()
    _round_start_unix_ms   = os.time() * 1000
    _round_start_leveltime = et.trap_Milliseconds()
    gamelog.record("round_start", "server", {})
end

function gamelog.round_end()
    gamelog.record("round_end", "server", {})
end

-- Pause markers. Emitted on pause/unpause so ingest can subtract paused time from the
-- timeline (drift = unpause.leveltime - pause.leveltime). Purely informational here.
function gamelog.pause_start()
    gamelog.record("pause", "server", {})
end

function gamelog.pause_end()
    gamelog.record("unpause", "server", {})
end

function gamelog.get(match_id, round_id)
    for _, ev in ipairs(_buffer) do
        ev.match_id = match_id
        ev.round_id = round_id
    end
    return _buffer
end

function gamelog.reset()
    _buffer = {}
end

return gamelog
