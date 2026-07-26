--[[
    stats/objectives.lua
    Handles et_Print for all objective pattern matching, buildable tracking,
    flag/item pickups, shove tracking, and objective-carrier death attribution.

    Attribution relies on the current ET:Legacy console output:
      - "Item: N team_CTF_*flag" precedes the matching "legacy popup:" line
        (same frame) for both steals AND returns — N is the acting client.
      - "Objective_Destroyed: N <track>" — N is the planting client.
      - "Repair: N" — N is the repairing client.
    Older ET:Legacy builds that omitted these lines are not supported.
--]]

local objectives = {}
local utils    = require("luascripts/stats/util/utils")
local pathgate = require("luascripts/stats/util/pathgate")

local log
local players_ref
local gamelog_ref
local vehicle_ref

local _collect_objstats     = true
local _collect_shovestats   = true
local _collect_gamelog      = true
local _maxClients           = 24

-- objstats[guid] = { obj_planted={}, obj_defused={}, ... }
objectives.objstats         = {}

-- objective_carriers.players[clientNum] = obj_name
local objective_carriers    = { players = {} }

-- objective_states[obj_name] = {
--   last_announce, last_action, timestamp, carrier_id, dropped
-- }
local objective_states      = {}

-- buffer of recent announce lines (used for repair attribution)
local recent_announcements  = {}
local ANNOUNCE_BUFFER       = 5
local REPAIR_BUFFER_MS      = 2000
local MAX_OBJ_DISTANCE      = 500  -- game units
local pending_pickup        = nil

-- Last "Item: N team_CTF_*flag" line — consumed by the popup that follows it.
local pending_flag_touch    = nil  -- { clientNum, timestamp }
local FLAG_TOUCH_WINDOW_MS  = 150

-- Recent damage to non-client entities (from et_Damage), used to attribute
-- destruction of buildables that emit no Objective_Destroyed line (e.g.
-- command posts destroyed by direct fire/satchel).
local recent_entity_damage  = {}   -- newest first: { entnum, attacker, timestamp }
local ENTITY_DAMAGE_BUFFER  = 8
local ENTITY_DAMAGE_WINDOW_MS = 1000
local DESTROY_DEDUP_MS      = 1500

-- Carrier position telemetry (gated by collect_vehicle_telemetry).
-- Sampled every frame and emitted only at path vertices -- see util/pathgate:
local _collect_telemetry    = false
local _carrier_gates        = {}   -- [clientNum] = pathgate instance

-- Carry-run identity. Every pickup opens a numbered run, and the number is
-- stamped on the run's carrier_pos samples and on the events that open and close
-- it. Without it a consumer has to rebuild run boundaries by interleaving
-- events, and the ambiguity is real rather than theoretical: one karsiah round
-- has a single player take the same documents four separate times, so
-- (player, objective) does not identify a run. Ids are per round, allocated in
-- pickup order from 1, and shared across objectives.
local _run_seq              = 0
local _carrier_run_id       = {}   -- [clientNum] = run id

-- Active map config
local _map_config           = nil
local _common_buildables    = nil


-- Furthest a run's closing position may sit from the last sampled vertex before
-- we stop believing it. This is the ingest side's teleport threshold, and with
-- the carrier sample floor the last vertex is at most ~32 units old, so the
-- bound is slack by two orders of magnitude -- it only ever catches a reading
-- that is wrong, never one that is merely stale.
local MAX_CLOSING_JUMP = 2000

-- A run's exit path reads the carrier's origin one last time, and that read is
-- not always trustworthy. handle_disconnect runs from et_ClientDisconnect,
-- where the entity may already be torn down and read as the world origin, and
-- any stale or zeroed value would be drawn as a line from the route to the
-- corner of the map. Reject the implausible rather than emit it: a missing
-- reading, an exact 0 0 0, or a jump no player could have made since the last
-- known-good vertex.
--
-- Note pers.connected is useless as a guard here -- the engine does not clear
-- it until the end of ClientDisconnect, so it still reads CON_CONNECTED on the
-- one path that needs checking.
local function plausible_origin(pos, last)
    if not pos then return nil end
    if pos[1] == 0 and pos[2] == 0 and pos[3] == 0 then return nil end
    if last and utils.distance3d_units(last, pos) > MAX_CLOSING_JUMP then return nil end
    return pos
end


-- Closes out a carry: emits the run's final carrier_pos and returns the
-- validated position, so the caller's own obj_secured / obj_dropped describes
-- the same instant instead of issuing a second, separately-trusted read.
-- Returns nil when no position could be trusted, in which case the caller
-- should emit no pos at all.
--
-- gamelog_module mirrors handle_carrier_death's override: the final point must
-- land in the same buffer as the event that ends the run, not a different one.
local function end_carrier_run(clientNum, gamelog_module)
    local gate = _carrier_gates[clientNum]
    _carrier_gates[clientNum] = nil

    -- Validate before any of the emit-side early returns: the position is the
    -- return value and callers need it whether or not telemetry is collected.
    local pos = plausible_origin(et.gentity_get(clientNum, "r.currentOrigin"),
                                gate and gate:last_emitted())
    if not pos then return nil end

    local gl = gamelog_module or gamelog_ref
    if not gate or not _collect_telemetry or not _collect_gamelog or not gl then return pos end

    local obj_name = objective_carriers.players[clientNum]
    local entry    = players_ref.guids[clientNum]
    if not obj_name or not entry or not entry.guid or entry.guid == "WORLD" then return pos end

    -- Nothing to close out when the run already ended on a vertex (a parked
    -- carrier whose heartbeat just fired at this exact spot).
    local last = gate:last_emitted()
    if last and utils.distance3d_units(last, pos) < 1 then return pos end

    gl.carrier_pos(entry.guid, obj_name, utils.fmt_pos(pos), et.trap_Milliseconds(),
        _carrier_run_id[clientNum])
    return pos
end


local function flush_pending_pickup()
    if pending_pickup and _collect_gamelog and gamelog_ref and pending_pickup.player_snap then
        gamelog_ref.pickup(pending_pickup.player_snap, pending_pickup.item, pending_pickup.owner_snap)
    end
    pending_pickup = nil
end


local function queue_item_pickup(clientNum, item)
    local entry = players_ref.guids[clientNum]
    if not entry or not entry.guid or entry.guid == "WORLD" then return end

    pending_pickup = {
        clientNum   = clientNum,
        item        = item,
        player_snap = players_ref.get_snapshot(clientNum) or { guid = entry.guid },
        owner_snap  = nil,
    }
end


local function emit_direct_pickup(player_id, owner_id, item)
    local player_entry = players_ref.guids[player_id]
    if not player_entry or not player_entry.guid or player_entry.guid == "WORLD" then return end

    local player_snap = players_ref.get_snapshot(player_id) or { guid = player_entry.guid }
    local owner_entry = owner_id and players_ref.guids[owner_id] or nil
    local owner_snap  = owner_entry and owner_entry.guid and owner_entry.guid ~= "WORLD"
        and (players_ref.get_snapshot(owner_id) or { guid = owner_entry.guid })
        or nil

    if _collect_gamelog and gamelog_ref then
        gamelog_ref.pickup(player_snap, item, owner_snap)
    end
end


local function attach_pickup_owner(owner_id, player_id, item)
    if pending_pickup
    and pending_pickup.clientNum == player_id
    and pending_pickup.item == item then
        local owner_entry = players_ref.guids[owner_id]
        pending_pickup.owner_snap = owner_entry and owner_entry.guid and owner_entry.guid ~= "WORLD"
            and (players_ref.get_snapshot(owner_id) or { guid = owner_entry.guid })
            or nil
        flush_pending_pickup()
        return
    end

    emit_direct_pickup(player_id, owner_id, item)
end


local function record_obj_stat(guid, event_type, objective, killer_info)
    if not guid or not event_type then return end

    if not objectives.objstats[guid] then
        objectives.objstats[guid] = {
            obj_planted       = {},
            obj_destroyed     = {},
            obj_taken         = {},
            obj_repickup      = {},
            obj_dropped       = {},
            obj_returned      = {},
            obj_secured       = {},
            obj_repaired      = {},
            obj_defused       = {},
            obj_carrierkilled = {},
            obj_flagcaptured  = {},
            obj_misc          = {},
            shoves_given      = {},
            shoves_received   = {},
        }
    end

    local ts = et.trap_Milliseconds()

    if event_type == "obj_carrierkilled" and killer_info then
        objectives.objstats[guid][event_type][ts] = {
            victim         = killer_info.guid,
            weapon         = killer_info.weapon,
            objective      = killer_info.objective,
            timestamp_unix = os.time(),
        }
    else
        objectives.objstats[guid][event_type][ts] = {
            objective      = objective or "unknown",
            timestamp_unix = os.time(),
        }
    end

    if log then
        log.debug(string.format("Obj stat: %s %s %s", guid, event_type, objective or "unknown"))
    end
end

local function add_recent_announcement(text, timestamp)
    table.insert(recent_announcements, 1, { text = text, timestamp = timestamp })
    if #recent_announcements > ANNOUNCE_BUFFER then
        table.remove(recent_announcements)
    end
end

local function update_objective_state(obj_name, action, guid, normalized_text)
    if not objective_states[obj_name] then
        objective_states[obj_name] = {
            last_announce = "",
            last_action   = "",
            timestamp     = 0,
        }
    end

    local ts = et.trap_Milliseconds()
    objective_states[obj_name].timestamp   = ts
    objective_states[obj_name].last_action = action

    -- Rebuilding clears any remembered charge position: the next destruction of
    -- this objective is a new charge, and must not inherit the old one's
    -- coordinate. Handled here rather than at the four construct call sites.
    if action == "constructed" then
        objective_states[obj_name].plant_pos = nil
    end

    if normalized_text then
        objective_states[obj_name].last_announce = normalized_text
    end

    return ts
end

local function parse_coords(str)
    if not str then return nil end
    local x, y, z = str:match("([%-%.%d]+)%s+([%-%.%d]+)%s+([%-%.%d]+)")
    return x and { tonumber(x), tonumber(y), tonumber(z) } or nil
end

local function find_nearest_players(coordinates, team)
    local coord = parse_coords(coordinates)
    if not coord then return {} end

    local nearest = {}
    local best_d  = math.huge

    -- Iterate only connected, non-spectator players via the guids cache.
    -- Spectators (team 3) and unassigned (team 0) are skipped by the team check.
    for clientNum, entry in pairs(players_ref.guids) do
        if entry.team == team then
            local health = tonumber(et.gentity_get(clientNum, "health")) or 0
            local body   = tonumber(et.gentity_get(clientNum, "r.contents")) or 0
            if health > 0 or (health <= 0 and body == 67108864) then
                local origin = et.gentity_get(clientNum, "r.currentOrigin")
                if origin then
                    local d = utils.distance3d_units(coord, origin)
                    if d <= MAX_OBJ_DISTANCE then
                        if d < best_d then
                            best_d  = d
                            nearest = { clientNum }
                        elseif d == best_d then
                            table.insert(nearest, clientNum)
                        end
                    end
                end
            end
        end
    end

    return nearest
end


-- Credit a flag capture to every player the announce implicates. Each gets their
-- own origin as pos, and they share the checkpoint's position as flag_pos --
-- credit is proximity-based, so pos says who was there and flag_pos says where
-- "there" was. Shared by the allies, axis and named-flag branches, which differ
-- only in which team is searched.
local function credit_flag_capture(flag_name, flag_coordinates, team)
    local flag_pos = utils.fmt_pos(parse_coords(flag_coordinates))

    for _, cnum in ipairs(find_nearest_players(flag_coordinates, team)) do
        local guid = players_ref.guids[cnum] and players_ref.guids[cnum].guid
        if guid then
            record_obj_stat(guid, "obj_flagcaptured", flag_name)
            if _collect_gamelog and gamelog_ref then
                gamelog_ref.obj_flag_captured(guid, flag_name,
                    utils.fmt_pos(et.gentity_get(cnum, "r.currentOrigin")), flag_pos)
            end
        end
    end
end


local function get_flag_coordinates()
    local flags = {}
    for i = 64, 1021 do
        local classname = et.gentity_get(i, "classname")
        if classname == "team_WOLF_checkpoint" then
            local origin = et.gentity_get(i, "origin")
            if origin then
                local coords = string.format("%d %d %d", origin[1], origin[2], origin[3])
                flags["allies_flag"] = {
                    flag_pattern    = "The Allies have captured the forward bunker!",
                    flag_coordinates = coords,
                }
                flags["axis_flag"] = {
                    flag_pattern    = "The Axis have captured the forward bunker!",
                    flag_coordinates = coords,
                }
                break
            end
        end
    end
    return flags
end


-- entity_pos is supplied by the announce-only path, which knows the entity that
-- was destroyed; the Objective_Destroyed path has no entity but does have a
-- charge, so it falls back to the plant position.
local function emit_destroyed(guid, obj_name, normalized_text, entity_pos)
    if guid then
        record_obj_stat(guid, "obj_destroyed", obj_name)
        if _collect_gamelog and gamelog_ref then
            -- Never the attributed player's live origin: a dynamite destruction
            -- fires ~30s after the plant (karsiah r1: planted 3119603, destroyed
            -- 3149585) and by then the planter is usually dead or respawned, so
            -- their origin would put the marker on a spawn point. The charge's
            -- own position, remembered at plant time, is where it went off.
            local state = objective_states[obj_name]
            gamelog_ref.objective("obj_destroyed", guid, obj_name,
                entity_pos or (state and state.plant_pos))
        end
    end
    update_objective_state(obj_name, "destroyed", nil, normalized_text)

    -- The charge is spent either way; do not let a later destruction of the same
    -- objective replay this one's coordinate.
    local state = objective_states[obj_name]
    if state then state.plant_pos = nil end
end


-- Announce-only destructions (no Objective_Destroyed line, e.g. command posts):
-- attribute to whoever last damaged a non-client entity — the destruction
-- announce fires in the same frame as the killing blow.
local function handle_buildable_destruction(obj_name, normalized_text)
    local current_time = et.trap_Milliseconds()
    local guid, entnum
    for _, dmg in ipairs(recent_entity_damage) do
        if (current_time - dmg.timestamp) <= ENTITY_DAMAGE_WINDOW_MS then
            local entry = players_ref.guids[dmg.attacker]
            if entry and entry.guid and entry.guid ~= "WORLD" then
                guid   = entry.guid
                entnum = dmg.entnum
                break
            end
        end
    end

    -- These destructions have no charge to replay a position from, but the thing
    -- destroyed is itself an entity and we already know which one: events.lua
    -- filters et_Damage down to ET_CONSTRUCTIBLE before buffering it, so
    -- dmg.entnum *is* the objective. Read its origin directly.
    --
    -- Deliberately not the attacker's position. It is a fair proxy for a satchel,
    -- which has to be placed on the target, but not for the panzerfaust or tank
    -- shell that can take a command post from across the map.
    local pos
    if entnum then
        pos = utils.fmt_pos(plausible_origin(et.gentity_get(entnum, "r.currentOrigin")))
    end

    emit_destroyed(guid, obj_name, normalized_text, pos)
end


local function check_recent_construction(obj_name, patterns, obj_config, current_time)
    if not obj_config then return false end

    local state = objective_states[obj_name]
    if state and state.last_announce and (current_time - state.timestamp) < REPAIR_BUFFER_MS then
        local last = state.last_announce
        if type(obj_config) == "table" and obj_config.construct_pattern then
            if string.find(last, utils.normalize(obj_config.construct_pattern)) then
                return true
            end
        elseif type(obj_config) == "table" and obj_config.enabled then
            if type(patterns) == "table" and patterns.construct then
                for _, p in ipairs(patterns.construct) do
                    if string.find(last, utils.normalize(p)) then return true end
                end
            end
        end
    end

    for _, ann in ipairs(recent_announcements) do
        if (current_time - ann.timestamp) < REPAIR_BUFFER_MS then
            if type(obj_config) == "table" and obj_config.construct_pattern then
                if string.find(ann.text, utils.normalize(obj_config.construct_pattern)) then
                    update_objective_state(obj_name, "constructed", nil, ann.text)
                    return true
                end
            elseif type(obj_config) == "table" and obj_config.enabled then
                if type(patterns) == "table" and patterns.construct then
                    for _, p in ipairs(patterns.construct) do
                        if string.find(ann.text, utils.normalize(p)) then
                            update_objective_state(obj_name, "constructed", nil, ann.text)
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end


local function handle_dynamite_event(text, event_type, action_name)
    local id_str, event_text = text:match("^" .. event_type .. ": (%d+) (.+)$")
    if not id_str then return end

    local id = tonumber(id_str)
    local entry = players_ref.guids[id]
    if not entry then return end

    local guid            = entry.guid
    local normalized_text = utils.normalize(event_text:match("^%s*(.-)%s*$") or event_text)

    -- Both match branches below emit identically; only the pattern source differs.
    local function emit(obj_name)
        local stat_key = "obj_" .. action_name
        record_obj_stat(guid, stat_key, obj_name)
        update_objective_state(obj_name, action_name, entry)

        -- The planter/defuser is standing at the dynamite, so their origin is
        -- the objective's location. Remember it on a plant: obj_destroyed fires
        -- ~30s later, by which time the planter is usually dead or respawned
        -- elsewhere and their live origin says nothing about where the charge
        -- went off. A defuse removes the charge, so the stored position goes
        -- with it.
        local pos = et.gentity_get(id, "r.currentOrigin")
        local state = objective_states[obj_name]
        if state then
            state.plant_pos = (action_name == "planted") and utils.fmt_pos(pos) or nil
        end

        if _collect_gamelog and gamelog_ref then
            gamelog_ref.objective(stat_key, guid, obj_name, utils.fmt_pos(pos))
        end
    end

    if _common_buildables then
        for obj_name, common_cfg in pairs(_common_buildables) do
            if _map_config.buildables and _map_config.buildables[obj_name] then
                if type(common_cfg.patterns) == "table" and common_cfg.patterns.plant then
                    local matched = false
                    for _, p in ipairs(common_cfg.patterns.plant) do
                        if string.find(normalized_text, utils.normalize(p)) then
                            matched = true
                            break
                        end
                    end
                    if matched then
                        emit(obj_name)
                        return
                    end
                end
            end
        end
    end

    if _map_config and _map_config.buildables then
        for obj_name, obj_cfg in pairs(_map_config.buildables) do
            if type(obj_cfg) ~= "boolean" and obj_cfg.plant_pattern and obj_cfg.plant_pattern ~= "" then
                if string.find(normalized_text, utils.normalize(obj_cfg.plant_pattern)) then
                    emit(obj_name)
                    break
                end
            end
        end
    end
end


function objectives.init(cfg, log_ref, players_module, gamelog_module, vehicle_module)
    log                 = log_ref
    players_ref         = players_module
    gamelog_ref         = gamelog_module
    vehicle_ref         = vehicle_module

    _collect_objstats   = cfg.collect_obj_stats
    _collect_shovestats = cfg.collect_shove_stats
    _collect_gamelog    = cfg.collect_gamelog
    _collect_telemetry  = cfg.collect_vehicle_telemetry or false
    _maxClients         = cfg.maxClients or 64
end


function objectives.init_map(map_config, common_buildables)
    _map_config        = map_config
    _common_buildables = common_buildables

    if not map_config then return end

    if map_config.objectives then
        for _, obj in ipairs(map_config.objectives) do
            objective_states[obj.name] = {
                last_announce = "",
                last_action   = "",
                carrier_id    = nil,
                dropped       = false,
                timestamp     = 0,
            }
        end
    end

    if map_config.buildables then
        for obj_name, _ in pairs(map_config.buildables) do
            objective_states[obj_name] = objective_states[obj_name] or {
                last_announce = "",
                last_action   = "",
                timestamp     = 0,
            }
        end
    end

    if map_config.flags then
        local dynamic = get_flag_coordinates()
        for flag_name, flag_data in pairs(dynamic) do
            if map_config.flags[flag_name] then
                map_config.flags[flag_name].flag_coordinates = flag_data.flag_coordinates
                if log then
                    log.write(string.format("Flag coords updated: %s → %s",
                        flag_name, flag_data.flag_coordinates))
                end
            end
        end
    end
end


function objectives.handle_print(text)
    local current_time = et.trap_Milliseconds()
    local _ = current_time

    -- Gamelog-only pickup events are coalesced from adjacent Item + pack-owner lines.
    if _collect_gamelog and gamelog_ref and string.find(text, "Ammo_Pack:", 1, true) then
        local owner_str, player_str = text:match("Ammo_Pack:%s*(%d+)%s+(%d+)")
        if player_str and owner_str then
            attach_pickup_owner(tonumber(owner_str), tonumber(player_str), "weapon_magicammo")
            return
        end
    end

    if _collect_gamelog and gamelog_ref and string.find(text, "Health_Pack:", 1, true) then
        local owner_str, player_str = text:match("Health_Pack:%s*(%d+)%s+(%d+)")
        if player_str and owner_str then
            attach_pickup_owner(tonumber(owner_str), tonumber(player_str), "item_health")
            return
        end
    end

    if pending_pickup then
        flush_pending_pickup()
    end

    if _collect_gamelog and gamelog_ref and string.find(text, "Item:", 1, true) then
        local id_str, item = text:match("Item:%s*(%d+)%s+(%S+)")
        if id_str and item
        and item ~= "team_CTF_redflag"
        and item ~= "team_CTF_blueflag"
        and (item == "item_health" or item == "weapon_magicammo" or string.find(item, "^weapon_")) then
            queue_item_pickup(tonumber(id_str), item)
            return
        end
    end

    -- Shove tracking does not depend on map objective config either.
    if _collect_shovestats and string.find(text, "Shove:", 1, true) then
        local shover_str, target_str = text:match("^Shove: (%d+) (%d+)")
        if shover_str then
            local shover_num = tonumber(shover_str)
            local target_num = tonumber(target_str)
            local shover_entry = players_ref.guids[shover_num]
            local target_entry = players_ref.guids[target_num]
            if shover_entry and target_entry then
                local shover_guid = shover_entry.guid
                local target_guid = target_entry.guid
                record_obj_stat(shover_guid, "shoves_given",    target_guid)
                record_obj_stat(target_guid, "shoves_received", shover_guid)

                if _collect_gamelog and gamelog_ref then
                    local shover_snap = players_ref.get_snapshot(shover_num)
                        or { guid = shover_guid }
                    local target_snap = players_ref.get_snapshot(target_num)
                        or { guid = target_guid }
                    gamelog_ref.shove(shover_snap, target_snap)
                end
            end
        end
    end

    if not _map_config then return end
    if not _collect_objstats then return end

    -- Objective_Destroyed: <id> <track>
    -- id is the planting client; track is the same text the Dynamite_Plant
    -- line carried, so plant_pattern resolves the objective name.
    if string.find(text, "Objective_Destroyed:", 1, true) then
        local id_str, obj_text = text:match("^Objective_Destroyed: (%d+) (.+)$")
        if id_str and obj_text then
            local normalized = utils.normalize(obj_text:match("^%s*(.-)%s*$") or obj_text)
            local entry      = players_ref.guids[tonumber(id_str)]
            local guid       = entry and entry.guid

            local resolved
            if _common_buildables and _map_config.buildables then
                for obj_name, common_cfg in pairs(_common_buildables) do
                    if _map_config.buildables[obj_name]
                    and type(common_cfg.patterns) == "table" and common_cfg.patterns.plant then
                        for _, p in ipairs(common_cfg.patterns.plant) do
                            if string.find(normalized, utils.normalize(p)) then
                                resolved = obj_name
                                break
                            end
                        end
                    end
                    if resolved then break end
                end
            end
            if not resolved and _map_config.buildables then
                for obj_name, obj_cfg in pairs(_map_config.buildables) do
                    if type(obj_cfg) == "table" then
                        if (obj_cfg.plant_pattern and obj_cfg.plant_pattern ~= ""
                            and string.find(normalized, utils.normalize(obj_cfg.plant_pattern)))
                        or (obj_cfg.destruct_pattern and obj_cfg.destruct_pattern ~= ""
                            and string.find(normalized, utils.normalize(obj_cfg.destruct_pattern))) then
                            resolved = obj_name
                            break
                        end
                    end
                end
            end

            emit_destroyed(guid, resolved or normalized, normalized)
        end
    end

    -- legacy announce: "<text>"
    if string.find(text, "legacy announce:", 1, true) then
        local raw_text   = text:match("legacy announce: \"(.+)\"")
        local clean      = raw_text and utils.strip_colors(raw_text) or ""
        local normalized = utils.normalize(clean)

        add_recent_announcement(normalized, current_time)

        if _common_buildables and _map_config.buildables then
            for obj_name, common_cfg in pairs(_common_buildables) do
                local map_build = _map_config.buildables[obj_name]
                if map_build and type(map_build) == "table" and map_build.enabled then
                    local patterns = type(common_cfg.patterns) == "table" and common_cfg.patterns or {}

                    local matched_construct = false
                    if patterns.construct then
                        for _, p in ipairs(patterns.construct) do
                            if string.find(normalized, utils.normalize(p)) then
                                matched_construct = true
                                break
                            end
                        end
                    end

                    local matched_destruct = false
                    if not matched_construct and patterns.destruct then
                        for _, p in ipairs(patterns.destruct) do
                            if string.find(normalized, utils.normalize(p)) then
                                matched_destruct = true
                                break
                            end
                        end
                    end

                    if matched_construct then
                        update_objective_state(obj_name, "constructed", nil, normalized)
                    elseif matched_destruct then
                        local state = objective_states[obj_name]
                        if not (state
                            and state.last_action == "destroyed"
                            and (current_time - state.timestamp) < DESTROY_DEDUP_MS) then
                            handle_buildable_destruction(obj_name, normalized)
                        end
                    end
                end
            end
        end

        -- Map-specific buildables
        if _map_config.buildables then
            for obj_name, obj_cfg in pairs(_map_config.buildables) do
                if type(obj_cfg) == "table" then
                    if obj_cfg.construct_pattern and obj_cfg.construct_pattern ~= ""
                    and string.find(normalized, utils.normalize(obj_cfg.construct_pattern)) then
                        update_objective_state(obj_name, "constructed", nil, normalized)

                    elseif obj_cfg.destruct_pattern and obj_cfg.destruct_pattern ~= ""
                    and string.find(normalized, utils.normalize(obj_cfg.destruct_pattern)) then
                        local state = objective_states[obj_name]
                        if not (state
                            and state.last_action == "destroyed"
                            and (current_time - state.timestamp) < DESTROY_DEDUP_MS) then
                            handle_buildable_destruction(obj_name, normalized)
                        end
                    end
                end
            end
        end

        -- Flag captures
        if _map_config.flags then
            -- Allies flag
            local allies_cfg = _map_config.flags.allies_flag
            if allies_cfg and allies_cfg.flag_pattern and allies_cfg.flag_coordinates
            and string.find(normalized, utils.normalize(allies_cfg.flag_pattern)) then
                credit_flag_capture("allies_flag", allies_cfg.flag_coordinates, et.TEAM_ALLIES)
            end

            -- Axis flag
            local axis_cfg = _map_config.flags.axis_flag
            if axis_cfg and axis_cfg.flag_pattern and axis_cfg.flag_coordinates
            and string.find(normalized, utils.normalize(axis_cfg.flag_pattern)) then
                credit_flag_capture("axis_flag", axis_cfg.flag_coordinates, et.TEAM_AXIS)
            end

            -- Generic named flags in config
            for flag_name, flag_cfg in pairs(_map_config.flags) do
                if flag_name ~= "allies_flag" and flag_name ~= "axis_flag"
                and flag_cfg.flag_pattern and flag_cfg.flag_coordinates
                and string.find(normalized, utils.normalize(flag_cfg.flag_pattern)) then
                    -- Closest player from either team
                    for _, team in ipairs({ et.TEAM_ALLIES, et.TEAM_AXIS }) do
                        credit_flag_capture(flag_name, flag_cfg.flag_coordinates, team)
                    end
                end
            end
        end

        -- Misc objectives
        if _map_config.misc then
            for misc_name, misc_data in pairs(_map_config.misc) do
                if misc_data.misc_pattern and misc_data.misc_coordinates
                and string.find(normalized, utils.normalize(misc_data.misc_pattern)) then
                    local nearest = find_nearest_players(misc_data.misc_coordinates, et.TEAM_ALLIES)
                    for _, cnum in ipairs(nearest) do
                        local guid = players_ref.guids[cnum] and players_ref.guids[cnum].guid
                        if guid then
                            record_obj_stat(guid, "obj_misc", misc_name)
                        end
                    end
                    break
                end
            end
        end

        -- Escort finale announces → vehicle module (marks finale involvement
        -- on the per-vehicle escort credit instead of a one-shot proximity stat)
        if _map_config.escort and vehicle_ref and vehicle_ref.on_escort_finale then
            for escort_name, escort_data in pairs(_map_config.escort) do
                if escort_data.escort_pattern and escort_data.escort_pattern ~= ""
                and string.find(normalized, utils.normalize(escort_data.escort_pattern)) then
                    vehicle_ref.on_escort_finale(escort_name, escort_data.escort_coordinates)
                    break
                end
            end
        end
    end

    -- legacy popup: objective steal / return
    if string.find(text, "legacy popup:", 1, true) then
        local normalized = utils.normalize(utils.strip_colors(text)):gsub('"', '')

        local touch_id
        if pending_flag_touch
        and (current_time - pending_flag_touch.timestamp) <= FLAG_TOUCH_WINDOW_MS then
            touch_id = pending_flag_touch.clientNum
        end

        if _map_config.objectives then
            for _, obj in ipairs(_map_config.objectives) do
                if obj.steal_pattern and obj.steal_pattern ~= ""
                and string.find(normalized, (utils.normalize(obj.steal_pattern):gsub('"', ''))) then
                    local state = objective_states[obj.name]
                    if not state then
                        state = { last_announce = "", last_action = "", timestamp = 0 }
                        objective_states[obj.name] = state
                    end

                    local entry = touch_id and players_ref.guids[touch_id]
                    if entry and entry.guid and entry.guid ~= "WORLD" then
                        local event = state.dropped and "obj_repickup" or "obj_taken"
                        record_obj_stat(entry.guid, event, obj.name)

                        -- A pickup is the only thing that opens a run, so it is
                        -- the only place an id is allocated.
                        _run_seq = _run_seq + 1
                        _carrier_run_id[touch_id] = _run_seq

                        if _collect_gamelog and gamelog_ref then
                            -- pos anchors the route: this is the exact start of
                            -- the run, a frame ahead of the first carrier_pos.
                            local pos = et.gentity_get(touch_id, "r.currentOrigin")
                            gamelog_ref.objective(event, entry.guid, obj.name,
                                utils.fmt_pos(pos), _run_seq)
                        end

                        -- Fresh gate per run, so a re-pickup never continues the
                        -- previous carry's corridor.
                        _carrier_gates[touch_id] = nil

                        objective_carriers.players[touch_id] = obj.name
                        state.carrier_id = touch_id
                        -- The previous run is no longer the one a return would
                        -- terminate; this one is, once it ends. Its resting place
                        -- goes with it -- the objective is off the ground now.
                        state.last_run   = nil
                        state.last_pos   = nil
                    end

                    state.dropped     = false
                    state.last_action = "taken"
                    state.timestamp   = current_time
                    pending_flag_touch = nil
                    break

                elseif obj.return_pattern and obj.return_pattern ~= ""
                and string.find(normalized, (utils.normalize(obj.return_pattern):gsub('"', ''))) then
                    local entry = touch_id and players_ref.guids[touch_id]
                    local returner_guid = entry and entry.guid or "WORLD"

                    -- A return names the run it terminated, which is almost never
                    -- a live one: an objective is returned while it lies on the
                    -- ground, so its run already closed at the obj_dropped and
                    -- state.carrier_id is nil by now. state.last_run is that run,
                    -- and it is the useful link -- it says this carry ended in a
                    -- reset rather than in someone picking the objective back up.
                    -- The carrier_id branch is defensive, for a return that
                    -- somehow lands while a carry is still in flight.
                    local state = objective_states[obj.name]
                    local ended_run = state and state.last_run
                    if state and state.carrier_id then
                        ended_run = _carrier_run_id[state.carrier_id]
                        -- Note the two positions differ: end_carrier_run's is
                        -- where the carry stopped, pos below is where the
                        -- returner was standing.
                        end_carrier_run(state.carrier_id)
                    end

                    record_obj_stat(returner_guid, "obj_returned", obj.name)
                    if _collect_gamelog and gamelog_ref then
                        -- The returner's origin is where the objective was lying,
                        -- since they had to reach it to return it. A WORLD return
                        -- has no actor -- the objective timed out back to its
                        -- stand after being dropped and left -- so fall back to
                        -- where the carry ended, which is where it sat until the
                        -- timer ran out. Same place, one of them observed via a
                        -- player and the other remembered.
                        local pos = touch_id
                            and utils.fmt_pos(et.gentity_get(touch_id, "r.currentOrigin"))
                            or (state and state.last_pos)
                        gamelog_ref.objective("obj_returned", returner_guid, obj.name,
                            pos, ended_run)
                    end

                    if state then
                        if state.carrier_id then
                            objective_carriers.players[state.carrier_id] = nil
                            state.carrier_id = nil
                        end
                        state.dropped     = false
                        state.last_action = "returned"
                        state.timestamp   = current_time
                    end
                    pending_flag_touch = nil
                    break
                end
            end
        end
    end

    -- Dynamite_Plant / Dynamite_Diffuse
    if string.find(text, "Dynamite_Plant:", 1, true) then
        handle_dynamite_event(text, "Dynamite_Plant", "planted")
    elseif string.find(text, "Dynamite_Diffuse:", 1, true) then
        handle_dynamite_event(text, "Dynamite_Diffuse", "defused")
    end

    -- Repair: <clientNum>
    if string.find(text, "Repair:", 1, true) then
        local id_str = text:match("^Repair: (%d+)")
        if id_str then
            local id    = tonumber(id_str)
            local entry = players_ref.guids[id]

            if vehicle_ref then
                vehicle_ref.on_repair(id, current_time)
            end

            if entry then
                local guid         = entry.guid
                local objective_name = "Unknown Repair"

                if _common_buildables and _map_config.buildables then
                    for obj_name, common_cfg in pairs(_common_buildables) do
                        local map_build = _map_config.buildables[obj_name]
                        if map_build
                        and check_recent_construction(obj_name, common_cfg.patterns, map_build, current_time) then
                            objective_name = obj_name
                            break
                        end
                    end
                end

                if objective_name == "Unknown Repair" and _map_config.buildables then
                    for obj_name, obj_cfg in pairs(_map_config.buildables) do
                        if type(obj_cfg) == "table"
                        and obj_cfg.construct_pattern and obj_cfg.construct_pattern ~= ""
                        and check_recent_construction(obj_name, nil, obj_cfg, current_time) then
                            objective_name = obj_name
                            break
                        end
                    end
                end

                record_obj_stat(guid, "obj_repaired", objective_name)
                if _collect_gamelog and gamelog_ref then
                    -- The engineer is standing at what they are repairing.
                    local pos = et.gentity_get(id, "r.currentOrigin")
                    gamelog_ref.objective("obj_repaired", guid, objective_name,
                        utils.fmt_pos(pos))
                end
            end
        end
    end

    -- Item: <clientNum> team_CTF_redflag / team_CTF_blueflag
    -- Precedes the steal/return popup; stash the toucher for it to consume.
    if string.find(text, "Item:", 1, true)
    and (string.find(text, "team_CTF_redflag", 1, true) or string.find(text, "team_CTF_blueflag", 1, true)) then
        local id = tonumber(text:match("Item: (%d+)"))
        if id then
            pending_flag_touch = { clientNum = id, timestamp = current_time }
        end
    end

    -- secure / escape / transmit / capture / transport — objective secured
    if string.find(text, "secure", 1, true)
    or string.find(text, "escap", 1, true)
    or string.find(text, "transmit", 1, true)
    or string.find(text, "capture", 1, true)
    or string.find(text, "transport", 1, true) then
        local normalized     = utils.normalize(utils.strip_colors(text))
        local first_sentence = normalized:match("[^.]+")

        if first_sentence and _map_config.objectives then
            for _, obj in ipairs(_map_config.objectives) do
                if obj.secured_pattern and obj.secured_pattern ~= ""
                and string.find(first_sentence, utils.normalize(obj.secured_pattern)) then
                    for carrier_id, carried_obj in pairs(objective_carriers.players) do
                        if carried_obj == obj.name then
                            -- pos closes the run: paired with obj_taken's start
                            -- coordinate it bounds the route exactly. Taken from
                            -- end_carrier_run so it is the same validated
                            -- reading as the run's final carrier_pos.
                            local run = _carrier_run_id[carrier_id]
                            local pos = end_carrier_run(carrier_id)

                            local entry = players_ref.guids[carrier_id]
                            if entry then
                                record_obj_stat(entry.guid, "obj_secured", obj.name)
                                if _collect_gamelog and gamelog_ref then
                                    gamelog_ref.objective("obj_secured", entry.guid, obj.name,
                                        utils.fmt_pos(pos), run)
                                end
                            end

                            objective_carriers.players[carrier_id] = nil

                            update_objective_state(obj.name, "secured")

                            local secured_state = objective_states[obj.name]
                            if secured_state then
                                secured_state.carrier_id = nil
                                secured_state.dropped    = false
                                secured_state.last_run   = run
                            end
                            break
                        end
                    end
                    break
                end
            end
        end
    end

end



function objectives.handle_carrier_death(target, attacker, mod, gamelog_module)
    for obj_name, state in pairs(objective_states) do
        if state.carrier_id == target then
            local victim_entry  = players_ref.guids[target]
            local killer_entry  = players_ref.guids[attacker]
            local victim_guid   = victim_entry and victim_entry.guid or "WORLD"

            local gl = gamelog_module or gamelog_ref

            local run = _carrier_run_id[target]
            local pos = end_carrier_run(target, gl)

            if killer_entry and killer_entry.guid and killer_entry.guid ~= "WORLD"
            and attacker ~= target
            and victim_entry and killer_entry.team ~= victim_entry.team then
                record_obj_stat(killer_entry.guid, "obj_carrierkilled", obj_name, {
                    guid      = victim_guid,
                    weapon    = mod,
                    objective = obj_name,
                })
                if _collect_gamelog and gl then
                    -- victim_pos is `pos` from end_carrier_run: where the carry
                    -- stopped, and the same reading the closing carrier_pos and
                    -- obj_dropped use. The killer's own origin is read fresh.
                    gl.obj_carrier_killed(killer_entry.guid, victim_guid, obj_name, mod, run,
                        utils.fmt_pos(et.gentity_get(attacker, "r.currentOrigin")),
                        utils.fmt_pos(pos))
                end
            end

            record_obj_stat(victim_guid, "obj_dropped", obj_name)
            if _collect_gamelog and gl then
                gl.obj_dropped(victim_guid, obj_name, utils.fmt_pos(pos), run)
            end

            objective_carriers.players[target] = nil
            state.carrier_id  = nil
            state.dropped     = true
            state.last_action = "dropped"
            state.last_run    = run
            state.last_pos    = utils.fmt_pos(pos)
            state.timestamp   = et.trap_Milliseconds()
        end
    end
end


-- Carrier disconnects also drop the objective.
function objectives.handle_disconnect(clientNum)
    for obj_name, state in pairs(objective_states) do
        if state.carrier_id == clientNum then
            local entry = players_ref.guids[clientNum]
            local guid  = entry and entry.guid or "WORLD"

            -- The disconnect path is exactly why end_carrier_run validates: the
            -- entity may already be torn down here, and a zeroed origin would
            -- put both the closing sample and this obj_dropped at the world
            -- origin. A nil pos is the correct outcome, not a fabricated one.
            local run = _carrier_run_id[clientNum]
            local pos = end_carrier_run(clientNum)

            record_obj_stat(guid, "obj_dropped", obj_name)
            if _collect_gamelog and gamelog_ref then
                gamelog_ref.obj_dropped(guid, obj_name, utils.fmt_pos(pos), run)
            end

            objective_carriers.players[clientNum] = nil
            state.carrier_id  = nil
            state.dropped     = true
            state.last_action = "dropped"
            state.last_run    = run
            state.last_pos    = utils.fmt_pos(pos)
            state.timestamp   = et.trap_Milliseconds()
        end
    end
end


-- Damage to non-client entities, routed from events.on_damage.
-- Buffered for announce-only destruction attribution (command posts etc.).
function objectives.on_entity_damage(target, attacker, timestamp)
    table.insert(recent_entity_damage, 1,
        { entnum = target, attacker = attacker, timestamp = timestamp })
    if #recent_entity_damage > ENTITY_DAMAGE_BUFFER then
        table.remove(recent_entity_damage)
    end
end


local PW_REDFLAG  = 5
local PW_BLUEFLAG = 6

-- Manual drops (+dropobj) are completely silent on the console —
-- Cmd_DropObjective_f emits no log line or popup. Detect them by polling the
-- carrier's flag powerup: a tracked carrier who is alive but no longer holds
-- PW_REDFLAG/PW_BLUEFLAG has dropped the objective. Death/return/secure paths
-- clear the carrier table synchronously (same server frame as their console
-- lines), so they never reach this check.
local function check_manual_drops()
    for clientNum, obj_name in pairs(objective_carriers.players) do
        local health = tonumber(et.gentity_get(clientNum, "health")) or 0
        if health > 0 then
            local red  = tonumber(et.gentity_get(clientNum, "ps.powerups", PW_REDFLAG))  or 0
            local blue = tonumber(et.gentity_get(clientNum, "ps.powerups", PW_BLUEFLAG)) or 0
            if red == 0 and blue == 0 then
                local entry = players_ref.guids[clientNum]
                local guid  = entry and entry.guid or "WORLD"

                local run = _carrier_run_id[clientNum]
                local pos = end_carrier_run(clientNum)

                record_obj_stat(guid, "obj_dropped", obj_name)
                if _collect_gamelog and gamelog_ref then
                    gamelog_ref.obj_dropped(guid, obj_name, utils.fmt_pos(pos), run)
                end

                objective_carriers.players[clientNum] = nil
                local state = objective_states[obj_name]
                if state then
                    state.carrier_id  = nil
                    state.dropped     = true
                    state.last_action = "dropped"
                    state.last_run    = run
                    state.last_pos    = utils.fmt_pos(pos)
                    state.timestamp   = et.trap_Milliseconds()
                end
            end
        end
    end
end


-- Per-frame carrier upkeep: manual-drop detection (always) and carrier
-- position telemetry (collect_vehicle_telemetry, vertex-gated).
function objectives.tick(now)
    -- Reap run state for players who no longer carry anything (killed, secured,
    -- dropped, returned, disconnected) so nothing leaks across runs.
    --
    -- Reaped here rather than in end_carrier_run because that function runs
    -- *before* the event which ends the run in all five exit paths -- clearing
    -- the id there would strip it off the very event that needs it. Those events
    -- all fire from handle_print / handle_carrier_death / handle_disconnect, so
    -- by the time any tick runs they have already read what they needed.
    --
    -- Ahead of the no-carriers early return, or the round's final carry would
    -- never be reaped, and ahead of the telemetry gate, or run ids would leak
    -- whenever telemetry is switched off.
    for clientNum in pairs(_carrier_gates) do
        if objective_carriers.players[clientNum] == nil then
            _carrier_gates[clientNum] = nil
        end
    end
    for clientNum in pairs(_carrier_run_id) do
        if objective_carriers.players[clientNum] == nil then
            _carrier_run_id[clientNum] = nil
        end
    end

    if next(objective_carriers.players) == nil then return end

    check_manual_drops()

    if not _collect_telemetry or not _collect_gamelog or not gamelog_ref then return end

    for clientNum, obj_name in pairs(objective_carriers.players) do
        local entry = players_ref.guids[clientNum]
        if entry and entry.guid and entry.guid ~= "WORLD" then
            local pos = et.gentity_get(clientNum, "r.currentOrigin")
            if pos then
                local gate = _carrier_gates[clientNum]
                if not gate then
                    gate = pathgate.new(pathgate.CARRIER)
                    _carrier_gates[clientNum] = gate
                end
                -- Stamped with the vertex's own sample time, not now: a corner
                -- vertex is a sample from a few frames back, and the coordinate
                -- and timestamp have to describe the same instant.
                local vertex, vertex_ms = gate:sample(pos, now)
                if vertex then
                    gamelog_ref.carrier_pos(entry.guid, obj_name, utils.fmt_pos(vertex),
                        vertex_ms, _carrier_run_id[clientNum])
                end
            end
        end
    end
end


-- True while clientNum is a tracked objective carrier. Used by events.lua to
-- correct death snapshots: the engine drops carried items (G_DropItems)
-- before the obituary hook fires, so the flag powerup is already gone when
-- the victim snapshot is taken.
function objectives.is_carrier(clientNum)
    return objective_carriers.players[clientNum] ~= nil
end


function objectives.get_stats()
    return objectives.objstats
end


function objectives.flush_pending_gamelog()
    flush_pending_pickup()
end


function objectives.reset()
    flush_pending_pickup()
    objectives.objstats  = {}
    objective_carriers   = { players = {} }
    objective_states     = {}
    recent_announcements = {}
    pending_pickup       = nil
    pending_flag_touch   = nil
    recent_entity_damage = {}
    _carrier_gates       = {}
    _carrier_run_id      = {}
    -- Run ids restart at 1 each round: they are only ever meaningful within the
    -- round they were emitted in, which is the scope a gamelog covers.
    _run_seq             = 0
    _map_config          = nil
    _common_buildables   = nil
end

return objectives
