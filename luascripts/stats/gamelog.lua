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


-- gamelog.record(label, group, fields)
function gamelog.record(label, group, fields)
    if not _enabled then return end

    local lt = et.trap_Milliseconds()
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

-- Suicide
function gamelog.suicide(victim_snap, weapon)
    gamelog.record("suicide", "player", {
        player        = victim_snap and victim_snap.guid,
        weapon        = weapon,
        victim_class  = victim_snap and victim_snap.class,
        victim_pos    = utils.fmt_pos(victim_snap and victim_snap.pos),
        victim_stance = stance_of(victim_snap),
    })
end

-- Teamkill
function gamelog.teamkill(killer_snap, victim_snap, weapon)
    gamelog.record("teamkill", "player", {
        killer          = killer_snap and killer_snap.guid,
        victim          = victim_snap  and victim_snap.guid,
        weapon          = weapon,
        killer_class    = killer_snap and killer_snap.class,
        killer_stance   = stance_of(killer_snap),
        victim_class    = victim_snap  and victim_snap.class,
        victim_health   = victim_snap  and victim_snap.health,
        victim_stance   = stance_of(victim_snap),
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
function gamelog.revive(medic_guid, victim_guid)
    gamelog.record("revive", "player", {
        player = medic_guid,
        victim = victim_guid,
    })
end

-- Class change
function gamelog.class_change(guid, new_class)
    gamelog.record("class_change", "player", {
        player = guid,
        class  = new_class,
    })
end

-- Generic objective event (label is the event type string, e.g. "obj_planted")
function gamelog.objective(label, guid, obj_name)
    gamelog.record(label, "player", {
        player    = guid,
        objective = obj_name,
    })
end

-- Flag captured
function gamelog.obj_flag_captured(guid, flag_name)
    gamelog.record("obj_flag_captured", "player", {
        player = guid,
        flag   = flag_name,
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
function gamelog.shove(shover_guid, target_guid)
    gamelog.record("shove", "player", {
        player = shover_guid,
        victim = target_guid,
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
