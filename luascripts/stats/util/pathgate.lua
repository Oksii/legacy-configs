--[[
    stats/util/pathgate.lua
    Vertex-preserving position sampling for path telemetry.

    Streaming Reumann-Witkam: the last emitted point is the anchor, the
    direction it left in defines a corridor, and the corridor being violated
    means a vertex is due. Extra gates cover the cases a pure corridor test
    misses -- a 180-degree reversal keeps perpendicular deviation at zero, a
    ladder/fall changes only z, and a stationary entity produces no geometry
    at all (keepalive keeps the ingest side's segment anchors fresh).

    Usage:
        local gate = pathgate.new(pathgate.CARRIER)
        local vertex, vertex_ms = gate:sample(origin, level_time)  -- every frame
        if vertex then emit(utils.fmt_pos(vertex), vertex_ms) end
        gate:reset()                                     -- new run / round

    A corner vertex is necessarily a *past* sample: the corridor is only known
    to be violated after the entity has already moved off it, so the point that
    belongs on the polyline is the one from before the violation. sample()
    therefore returns that point's own leveltime alongside it, and callers must
    stamp the event with it -- otherwise the coordinate and the timestamp
    describe different moments. Every other gate (stop, heartbeat, height,
    segment cap) needs no lookback and returns the live sample at `now`.
--]]

local pathgate = {}

-- Tunables, in game units / ms.
--   tol_xy      corridor half-width; bounds how far the drawn polyline may
--               deviate from the real path
--   tol_z       vertical change from the anchor that forces a vertex
--   max_seg     hard cap on straight-line segment length
--   keepalive_ms  heartbeat while the entity is parked within min_dir_seg of
--               the anchor. Deliberately does NOT apply while moving: a clock
--               tick would otherwise pre-empt the geometry and drop the vertex
--               wherever the timer happened to fire instead of on the corner
--   max_gap_ms  absolute cap on the interval between points, so even a prone
--               crawl stays well inside the ingest side's segment gap limit
--   still_epsilon  per-sample displacement below which the entity counts as
--               stopped; coming to a stop pins a vertex at the stopping point
--   min_gap_ms  floor between points for the stop rule, so stutter-stepping
--               cannot spam vertices
--   min_dir_seg travel needed before the corridor direction is trusted (short
--               deltas at high sv_fps are jitter, not heading)
--   dev_epsilon deviation under which a sample still counts as "on the line";
--               the last such sample is the corner candidate
local DEFAULTS = {
    tol_xy       = 48,
    tol_z        = 48,
    max_seg      = 512,
    keepalive_ms  = 1000,
    max_gap_ms    = 5000,
    min_dir_seg   = 32,
    dev_epsilon   = 8,
    still_epsilon = 2,
    min_gap_ms    = 250,
}

-- Objective carriers move at player speed (g_speed 320, more when sprinting
-- or boosted) and take tight corners.
pathgate.CARRIER = {}

-- Escort vehicles are slow and follow fixed spline paths, so a wider corridor
-- costs nothing in fidelity.
pathgate.VEHICLE = {
    tol_xy      = 64,
    tol_z       = 64,
    max_seg     = 768,
    dev_epsilon = 12,
}


local Gate = {}
Gate.__index = Gate


function pathgate.new(opts)
    local g = setmetatable({}, Gate)
    for k, v in pairs(DEFAULTS) do
        g[k] = (opts and tonumber(opts[k])) or v
    end
    g:reset()
    return g
end


function Gate:reset()
    self.anchor       = nil   -- last emitted point
    self.prev         = nil   -- previous sample
    self.prev_ms      = 0
    self.dir_x        = nil   -- corridor direction (xy, normalised)
    self.dir_y        = nil
    self.t_max        = 0     -- furthest projection along the corridor
    self.t_max_pos    = nil   -- sample at t_max (vertex for a reversal)
    self.t_max_ms     = 0
    self.dev_start    = nil   -- last sample still within dev_epsilon of the line
    self.dev_start_ms = 0
    self.last_emit_ms = 0
    self.moving       = false -- moved since the previous sample
end


-- Last point this gate emitted, so callers can avoid re-emitting it.
function Gate:last_emitted()
    return self.anchor
end


-- Feed one position sample. Returns the point to emit and the leveltime that
-- point was sampled at, or nil.
function Gate:sample(pos, now)
    if not pos then return nil end
    local p = { pos[1], pos[2], pos[3] }
    now = now or 0

    -- Discontinuity. Callers feed this every frame, so a gap this large means
    -- the timeline jumped: a pause, a mid-round VM reload, or a vehicle that
    -- sat still for a while (it is only sampled while moving). Backdating a
    -- vertex across such a gap would place its leveltime on the far side of a
    -- pause marker that already precedes it in the buffer, and the ingest
    -- side's drift correction is index-ordered -- it would subtract the wrong
    -- offset. Start a fresh corridor at the live position instead.
    if self.anchor and (now - self.prev_ms) > self.keepalive_ms then
        self:reset()
    end

    -- First sample of a run: the start of the path is always a vertex.
    if not self.anchor then
        self.anchor       = p
        self.prev         = p
        self.prev_ms      = now
        self.dev_start    = p
        self.dev_start_ms = now
        self.last_emit_ms = now
        return p, now
    end

    local vx = p[1] - self.anchor[1]
    local vy = p[2] - self.anchor[2]
    local vz = p[3] - self.anchor[3]
    local planar = math.sqrt(vx * vx + vy * vy)

    local vertex, vertex_ms

    if not self.dir_x then
        -- Direction not established yet: wait for enough travel that the
        -- heading means something.
        if planar >= self.min_dir_seg then
            self.dir_x, self.dir_y = vx / planar, vy / planar
            self.t_max        = planar
            self.t_max_pos    = p
            self.t_max_ms     = now
            self.dev_start    = p
            self.dev_start_ms = now
        end
    else
        local t    = vx * self.dir_x + vy * self.dir_y
        local perp = math.abs(vx * self.dir_y - vy * self.dir_x)

        if t > self.t_max then
            self.t_max     = t
            self.t_max_pos = p
            self.t_max_ms  = now
        end
        if perp <= self.dev_epsilon then
            self.dev_start    = p
            self.dev_start_ms = now
        end

        if perp > self.tol_xy then
            -- Turned out of the corridor: the corner is the last sample that
            -- was still on the line.
            vertex    = self.dev_start or self.prev
            vertex_ms = self.dev_start and self.dev_start_ms or self.prev_ms
        elseif (self.t_max - t) > self.tol_xy then
            -- Doubled back along the same line (grab and retreat). Perpendicular
            -- deviation never sees this; the turnaround point does.
            vertex    = self.t_max_pos or self.prev
            vertex_ms = self.t_max_pos and self.t_max_ms or self.prev_ms
        end
    end

    -- Stillness is measured against the previous sample, not the anchor: an
    -- entity that ran somewhere and stopped is parked even though it sits far
    -- from its last vertex.
    local step = math.sqrt(
        (p[1] - self.prev[1]) ^ 2 +
        (p[2] - self.prev[2]) ^ 2 +
        (p[3] - self.prev[3]) ^ 2)
    local was_moving = self.moving
    self.moving = step > self.still_epsilon

    -- None of these need a lookback -- the condition is true of the live
    -- sample -- so they emit it as-is, timestamped now.
    if not vertex then
        local travelled = math.sqrt(vx * vx + vy * vy + vz * vz)
        local elapsed   = now - self.last_emit_ms
        if math.abs(vz) > self.tol_z then
            vertex, vertex_ms = p, now
        elseif travelled >= self.max_seg then
            vertex, vertex_ms = p, now
        elseif was_moving and not self.moving and elapsed >= self.min_gap_ms then
            vertex, vertex_ms = p, now  -- came to a stop: pin where
        elseif not self.moving and elapsed >= self.keepalive_ms then
            vertex, vertex_ms = p, now  -- parked: heartbeat
        elseif elapsed >= self.max_gap_ms then
            vertex, vertex_ms = p, now  -- crawling: bound the gap anyway
        end
    end

    if not vertex then
        self.prev    = p
        self.prev_ms = now
        return nil
    end

    self.anchor       = vertex
    self.prev         = p
    self.prev_ms      = now
    self.dir_x        = nil
    self.dir_y        = nil
    self.t_max        = 0
    self.t_max_pos    = nil
    self.t_max_ms     = 0
    self.dev_start    = nil
    self.dev_start_ms = 0
    self.last_emit_ms = now
    return vertex, vertex_ms or now
end


return pathgate
