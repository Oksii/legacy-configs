--[[
    stats/assists.lua
    Kill-assist tracking: 1:1 Lua replication of the engine's
    G_AddKillAssistPoints (g_stats.c:589-647), which is not exposed to Lua.

    The engine keeps a per-life per-damager record on the victim
    (gclient_t.dmgReceivedSts[], wiped by Com_Memset in every ClientSpawn)
    and on each lethal G_Damage walks it sorted by cumulative damage,
    crediting up to 4 opposite-team damagers hit within 1500 ms.

    This module mirrors that ledger from et_Damage (record), et_ClientSpawn
    (per-life wipe) and et_Obituary (credit loop). Key differences from the
    engine are deliberate and documented in the design review:
      - GUID-keyed instead of slot-keyed (churn-immune; killer exclusion by
        GUID is arguably more intuitive than the engine's slot identity)
      - attacker team frozen at last-hit time (engine reads sessionTeam at
        kill time); diverges only for a team switch inside the 1.5 s window
      - deaths that bypass G_Damage via direct player_die calls (/kill,
        team switch, bot swap-places) never credit — the mod filter below
        enforces that, because et_Obituary fires for them too
      - ts-map keys are bumped on collision (a multi-kill explosive can
        credit one assister twice in the same server frame)

    Output: _assists[assister_guid][leveltime] = { killer, victim, weapon,
    timestamp_unix }  (+ one "assist" gamelog event per credit, when the
    gamelog collector is on).
--]]

local assists = {}

local log
local players_ref
local gamelog_ref

local MAX_CLIENT_SLOTS      = 64  -- entity numbers below this are always clients

-- Engine constants (g_stats.c). The 1500 comparison is a hard-coded literal
-- at g_stats.c:620 with a strict `<`: a hit exactly 1500 ms old IS inside the
-- window. MAX_ASSIST_ELAPSED_TIME is defined but referenced nowhere.
local ASSIST_WINDOW_MS      = 1500
local MAX_ASSISTS_PER_DEATH = 4   -- MAX_PLAYERS_ASSIST_TO_REWARDS, g_stats.c:609

-- Deaths routed through direct player_die() calls never reach
-- G_AddKillAssistPoints (it lives on G_Damage's lethal branch), yet
-- et_Obituary still fires for them:
--   MOD_SUICIDE     /kill                (g_cmds.c:1255)
--   MOD_SWITCHTEAM  team switch          (g_cmds.c:1550)
--   MOD_SWAP_PLACES bot swap places      (g_cmds.c:5284)
-- A weapon-inflicted selfkill (own grenade) DOES route through G_Damage and
-- must still credit, so the skip is by mod, never by killer == victim.
local NO_ASSIST_DEATH_MODS = {}
for _, mod_name in ipairs({ "MOD_SUICIDE", "MOD_SWITCHTEAM", "MOD_SWAP_PLACES" }) do
    if et[mod_name] ~= nil then
        NO_ASSIST_DEATH_MODS[et[mod_name]] = true
    end
end

-- _pool[victim_guid][attacker_guid] = { damage, last_hit, mod, team }
-- Mirrors the victim's dmgReceivedSts: dropped on every spawn of the victim
-- (the engine's ClientSpawn wipe). Entries where a player appears as an
-- ATTACKER in someone else's pool survive the attacker's own spawn.
local _pool = {}

-- _assists[assister_guid][leveltime] = { killer, victim, weapon, timestamp_unix }
local _assists = {}


function assists.init(log_ref, players_module, gamelog_module)
    log         = log_ref
    players_ref = players_module
    gamelog_ref = gamelog_module
end


-- Resolve a snapshot for a GUID by scanning the live slot cache. Pool entries
-- are GUID-keyed, so the credited assister's clientNum is not known at death
-- time; a recently-disconnected assistor simply yields no snapshot (the
-- ts-map credit and its GUID still stand).
local function snapshot_for_guid(guid)
    for slot = 0, MAX_CLIENT_SLOTS - 1 do
        local entry = players_ref.guids[slot]
        if entry and entry.guid == guid then
            return players_ref.get_snapshot(slot)
        end
    end
    return nil
end


-- Mirror of the engine's dmgReceivedSts accumulation (g_combat.c:1882-1884,
-- which runs immediately after the et_Damage hook with the same post-scaling
-- `take` value — no clamping to remaining health needed here).
function assists.on_damage(target, attacker, damage, mod)
    if type(damage) ~= "number" or damage <= 0 then return end
    if type(target) ~= "number" or type(attacker) ~= "number" then return end
    if target < 0 or target >= MAX_CLIENT_SLOTS then return end
    if attacker < 0 or attacker >= MAX_CLIENT_SLOTS then return end
    -- Self-hits are never creditable (the engine records them but always
    -- skips them as "victim itself"), so don't store dead entries.
    if attacker == target then return end

    local target_entry  = players_ref.guids[target]
    if not target_entry or target_entry.guid == "WORLD" then return end
    local attacker_entry = players_ref.guids[attacker]
    if not attacker_entry or attacker_entry.guid == "WORLD" then return end

    local slot = _pool[target_entry.guid]
    if not slot then
        slot = {}
        _pool[target_entry.guid] = slot
    end

    local rec = slot[attacker_entry.guid]
    if not rec then
        rec = { damage = 0, last_hit = 0, mod = 0, team = 0 }
        slot[attacker_entry.guid] = rec
    end
    rec.damage   = rec.damage + damage
    rec.last_hit = et.trap_Milliseconds()
    rec.mod      = mod or 0
    rec.team     = attacker_entry.team
end


-- The engine's ClientSpawn wipe (g_client.c:3122): dmgReceivedSts is a member
-- of gclient_s and is memset on EVERY spawn — respawn, revive, team change.
-- Only the spawning player's received-damage pool is dropped.
function assists.on_spawn(clientNum)
    if type(clientNum) ~= "number" then return end
    local entry = players_ref.guids[clientNum]
    if not entry or entry.guid == "WORLD" then return end
    _pool[entry.guid] = nil
end


-- Mirror of G_AddKillAssistPoints (g_stats.c:589-647). Called at the top of
-- events.on_obituary with no teamkill/suicide gating: the engine credits
-- assists on teamkills and on weapon-inflicted suicides too.
function assists.on_death(victim, killer, mod)
    if NO_ASSIST_DEATH_MODS[mod] then return end

    if type(victim) ~= "number" then return end
    local victim_entry = players_ref.guids[victim]
    if not victim_entry or victim_entry.guid == "WORLD" then return end

    local pool = _pool[victim_entry.guid]
    if not pool then return end

    local victim_guid = victim_entry.guid
    -- A WORLD killer resolves to "WORLD", which never matches a player GUID —
    -- mirroring the engine's slot-based `ent == attacker` skip, which world
    -- kills match nothing.
    local killer_entry = players_ref.guids[killer]
    local killer_guid  = killer_entry and killer_entry.guid or "WORLD"

    local now         = et.trap_Milliseconds()
    local victim_snap = players_ref.get_snapshot(victim)

    -- Snapshot + sort descending by cumulative damage (engine qsort with a
    -- comparator that returns 0 on ties — tie order is arbitrary in both).
    local list = {}
    for guid, rec in pairs(pool) do
        list[#list + 1] = { guid = guid, rec = rec }
    end
    table.sort(list, function(a, b) return a.rec.damage > b.rec.damage end)

    local credited = 0
    for _, e in ipairs(list) do
        local rec = e.rec

        -- End of real damagers (engine: `break`). With the on_damage guard
        -- this can only be empty, but keep the break for structural parity.
        if rec.damage <= 0 then break end
        if credited >= MAX_ASSISTS_PER_DEATH then break end

        if rec.last_hit + ASSIST_WINDOW_MS < now then
            -- stale: skipped, does NOT consume the cap (engine: `continue`)
        elseif e.guid == killer_guid then
            -- the killing blow's author is never credited
        elseif rec.team == victim_entry.team then
            -- Same-team skip is the engine's ONLY team rule: it credits any
            -- in-window damager whose team merely differs from the victim's,
            -- TEAM_FREE / TEAM_SPECTATOR included (unassigned-slot edge cases
            -- only — spectators never deal damage in practice).
        else
            credited = credited + 1

            local map = _assists[e.guid]
            if not map then
                map = {}
                _assists[e.guid] = map
            end
            -- Assists-specific collision bump (see README): one explosive can
            -- kill two victims in the same server frame and credit the same
            -- assister for both; losing a credit is worse than a key that is
            -- off by a millisecond.
            local ts = now
            while map[ts] do ts = ts + 1 end
            map[ts] = {
                killer         = killer_guid,
                victim         = victim_guid,
                weapon         = rec.mod,  -- assister's last meansOfDeath on this victim
                timestamp_unix = os.time(),
            }

            if log then
                log.debug(string.format("Assist: %s credited (victim %s, killer %s, dmg %d, mod %d)",
                    e.guid, victim_guid, killer_guid, rec.damage, rec.mod))
            end

            if gamelog_ref then
                gamelog_ref.assist(snapshot_for_guid(e.guid), victim_snap, killer_guid, rec.mod)
            end
        end
    end
end


function assists.get_stats()
    return _assists
end


function assists.reset()
    _pool    = {}
    _assists = {}
end

return assists
