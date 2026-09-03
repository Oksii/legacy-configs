--[[
    stats/activity.lua
    Per-player "actively involved" time — the split between idle camping and
    time spent engaging.

    Model: a sliding activity window PER SOURCE. Any trigger (weapon use, damage
    dealt, damage taken, objective work) stamps that source; its accumulator
    advances by the real frame delta for as long as
    now - stamp < ACTIVITY_WINDOW_MS. Overlapping triggers extend one window
    instead of stacking, so a burst costs one window, not one per round fired.

    Clock: et.trap_Milliseconds() ONLY, cached once per frame by set_frame().
    Accumulates in integer ms, floors to seconds at get_stats (vehicle.lua's
    idiom, not movement.lua's float seconds).
--]]

local activity = {}
local log
local ACTIVITY_WINDOW_MS = 3000
local MAX_FRAME_DT_MS    = 1000

activity.SRC_WEAPON = 1
activity.SRC_DEALT  = 2
activity.SRC_TAKEN  = 3
activity.SRC_OBJ    = 4

local SRC_COUNT = 4
local SRC_FIELD = { "from_weapon", "from_dmg_dealt", "from_dmg_taken", "from_objective" }

-- _activity[guid] = {
--   alive_ms, engaged_ms,
--   src_ms   = { per-source accumulated ms, indexed by SRC_* },
--   stamp_ms = { per-source last trigger ms, 0 = never },
--   last_tick,
-- }
local _activity = {}
local _enabled = false
local _now     = 0      -- et.trap_Milliseconds(), refreshed once per frame
local _live    = false  -- GS_PLAYING and not paused

local function ensure(guid)
    local a = _activity[guid]
    if not a then
        a = {
            alive_ms   = 0,
            engaged_ms = 0,
            src_ms     = { 0, 0, 0, 0 },
            stamp_ms   = { 0, 0, 0, 0 },
            last_tick  = _now,
        }
        _activity[guid] = a
    end
    return a
end


function activity.init(cfg, log_ref)
    log      = log_ref
    _enabled = cfg.collect_activity_stats and true or false
end

function activity.set_frame(now_ms, live)
    _now  = now_ms or 0
    _live = live and true or false
end

function activity.stamp(guid, src)
    if not _enabled or not _live or not guid or guid == "WORLD" then return end
    if not src then return end
    ensure(guid).stamp_ms[src] = _now
end

function activity.accumulate(guid, eligible)
    if not _enabled or not guid or guid == "WORLD" then return end
    local a = ensure(guid)

    local dt    = _now - a.last_tick
    a.last_tick = _now

    if not _live or not eligible then return end
    if dt <= 0 or dt > MAX_FRAME_DT_MS then return end

    a.alive_ms = a.alive_ms + dt

    local stamp_ms, src_ms = a.stamp_ms, a.src_ms
    local open = false
    for i = 1, SRC_COUNT do
        local st = stamp_ms[i]
        if st > 0 and (_now - st) < ACTIVITY_WINDOW_MS then
            src_ms[i] = src_ms[i] + dt
            open = true
        end
    end
    if open then a.engaged_ms = a.engaged_ms + dt end
end

function activity.get_stats(guid)
    local a = _activity[guid]
    if not a or a.alive_ms <= 0 then return nil end

    local out = {
        alive   = math.floor(a.alive_ms   / 1000),
        engaged = math.floor(a.engaged_ms / 1000),
    }
    for i = 1, SRC_COUNT do
        out[SRC_FIELD[i]] = math.floor(a.src_ms[i] / 1000)
    end
    return out
end

function activity.clear(guid)
    _activity[guid] = nil
end

function activity.reset()
    _activity = {}
    _now      = 0
    _live     = false
end

return activity
