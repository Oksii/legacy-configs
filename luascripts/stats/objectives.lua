--[[
    stats/objectives.lua
    Handles et_Print for all objective pattern matching, buildable tracking,
    flag/item pickups, shove tracking, and objective-carrier death attribution.
--]]

local objectives = {}
local utils = require("luascripts/stats/util/utils")

local log
local players_ref
local gamelog_ref

local _collect_objstats     = true
local _collect_shovestats   = true
local _collect_gamelog      = true
local _maxClients           = 24

-- objstats[guid] = { obj_planted={}, obj_defused={}, ... }
objectives.objstats         = {}

-- objective_carriers.players[clientNum] = obj_name
-- objective_carriers.ids = [ clientNum, ... ]
local objective_carriers    = { players = {}, ids = {} }

-- objective_states[obj_name] = {
--   last_popup, last_announce, last_action, timestamp,
--   carrier_id, planter_guid
-- }
local objective_states      = {}

-- buffer of recent announce lines (used for repair attribution)
local recent_announcements  = {}
local ANNOUNCE_BUFFER       = 5
local REPAIR_BUFFER_MS      = 2000
local MAX_OBJ_DISTANCE      = 500  -- game units
local pending_pickup        = nil

-- Active map config
local _map_config           = nil
local _common_buildables    = nil


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
            obj_returned      = {},
            obj_secured       = {},
            obj_repaired      = {},
            obj_defused       = {},
            obj_carrierkilled = {},
            obj_flagcaptured  = {},
            obj_misc          = {},
            obj_escort        = {},
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
            last_popup    = "",
            last_announce = "",
            last_action   = "",
            timestamp     = 0,
        }
    end

    local ts = et.trap_Milliseconds()
    objective_states[obj_name].timestamp   = ts
    objective_states[obj_name].last_action = action

    if normalized_text then
        objective_states[obj_name].last_announce = normalized_text
    end

    if guid and action == "planted" then
        objective_states[obj_name].planter_guid = guid.guid or guid
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


local function get_active_covert_ops()
    local COVERT_OPS = 4
    local result = {}
    for clientNum, entry in pairs(players_ref.guids) do
        if entry.team == et.TEAM_AXIS or entry.team == et.TEAM_ALLIES then
            local pt = tonumber(et.gentity_get(clientNum, "sess.playerType"))
            if pt == COVERT_OPS then
                table.insert(result, clientNum)
            end
        end
    end
    return result
end


local function handle_destroyer_attribution(obj_name)
    local state = objective_states[obj_name]
    if state and state.planter_guid then
        return state.planter_guid, true
    end

    local coverts = get_active_covert_ops()
    if #coverts == 1 then
        local entry = players_ref.guids[coverts[1]]
        return entry and entry.guid, true
    end

    return nil, false
end


local function handle_buildable_destruction(obj_name, normalized_text)
    local destroyer_guid, found = handle_destroyer_attribution(obj_name)
    if found and destroyer_guid then
        record_obj_stat(destroyer_guid, "obj_destroyed", obj_name)
        if _collect_gamelog and gamelog_ref then
            gamelog_ref.objective("obj_destroyed", destroyer_guid, obj_name)
        end
    end
    update_objective_state(obj_name, "destroyed", nil, normalized_text)
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
                        local stat_key = "obj_" .. action_name
                        record_obj_stat(guid, stat_key, obj_name)
                        update_objective_state(obj_name, action_name, entry)
                        if _collect_gamelog and gamelog_ref then
                            gamelog_ref.objective(stat_key, guid, obj_name)
                        end
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
                    local stat_key = "obj_" .. action_name
                    record_obj_stat(guid, stat_key, obj_name)
                    update_objective_state(obj_name, action_name, entry)
                    if _collect_gamelog and gamelog_ref then
                        gamelog_ref.objective(stat_key, guid, obj_name)
                    end
                    break
                end
            end
        end
    end
end


function objectives.init(cfg, log_ref, players_module, gamelog_module)
    log                 = log_ref
    players_ref         = players_module
    gamelog_ref         = gamelog_module

    _collect_objstats   = cfg.collect_obj_stats
    _collect_shovestats = cfg.collect_shove_stats
    _collect_gamelog    = cfg.collect_gamelog
    _maxClients         = cfg.maxClients or 64
end


function objectives.init_map(map_config, common_buildables)
    _map_config        = map_config
    _common_buildables = common_buildables

    if not map_config then return end

    if map_config.objectives then
        for _, obj in ipairs(map_config.objectives) do
            objective_states[obj.name] = {
                last_popup    = "",
                last_announce = "",
                last_action   = "",
                carrier_id    = nil,
                timestamp     = 0,
                planter_guid  = nil,
            }
        end
    end

    if map_config.buildables then
        for obj_name, _ in pairs(map_config.buildables) do
            objective_states[obj_name] = objective_states[obj_name] or {
                last_popup    = "",
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
            local shover_entry = players_ref.guids[tonumber(shover_str)]
            local target_entry = players_ref.guids[tonumber(target_str)]
            if shover_entry and target_entry then
                local shover_guid = shover_entry.guid
                local target_guid = target_entry.guid
                record_obj_stat(shover_guid, "shoves_given",    target_guid)
                record_obj_stat(target_guid, "shoves_received", shover_guid)

                if _collect_gamelog and gamelog_ref then
                    gamelog_ref.shove(shover_guid, target_guid)
                end
            end
        end
    end

    if not _map_config then return end
    if not _collect_objstats then return end

    -- Objective_Destroyed: <id> <text>
    if string.find(text, "Objective_Destroyed:", 1, true) then
        local id_str, obj_text = text:match("^Objective_Destroyed: (%d+) (.+)$")
        if id_str and obj_text then
            local normalized = utils.normalize(obj_text:match("^%s*(.-)%s*$") or obj_text)
            if _map_config.buildables then
                for obj_name, obj_cfg in pairs(_map_config.buildables) do
                    if type(obj_cfg) == "table"
                    and obj_cfg.destruct_pattern and obj_cfg.destruct_pattern ~= ""
                    and string.find(normalized, utils.normalize(obj_cfg.destruct_pattern)) then
                        handle_buildable_destruction(obj_name, normalized)
                        break
                    end
                end
            end
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
                        handle_buildable_destruction(obj_name, normalized)
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
                            and (current_time - state.timestamp) < 1000) then
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
                local nearest = find_nearest_players(allies_cfg.flag_coordinates, et.TEAM_ALLIES)
                for _, cnum in ipairs(nearest) do
                    local guid = players_ref.guids[cnum] and players_ref.guids[cnum].guid
                    if guid then
                        record_obj_stat(guid, "obj_flagcaptured", "allies_flag")
                        if _collect_gamelog and gamelog_ref then
                            gamelog_ref.obj_flag_captured(guid, "allies_flag")
                        end
                    end
                end
            end

            -- Axis flag
            local axis_cfg = _map_config.flags.axis_flag
            if axis_cfg and axis_cfg.flag_pattern and axis_cfg.flag_coordinates
            and string.find(normalized, utils.normalize(axis_cfg.flag_pattern)) then
                local nearest = find_nearest_players(axis_cfg.flag_coordinates, et.TEAM_AXIS)
                for _, cnum in ipairs(nearest) do
                    local guid = players_ref.guids[cnum] and players_ref.guids[cnum].guid
                    if guid then
                        record_obj_stat(guid, "obj_flagcaptured", "axis_flag")
                        if _collect_gamelog and gamelog_ref then
                            gamelog_ref.obj_flag_captured(guid, "axis_flag")
                        end
                    end
                end
            end

            -- Generic named flags in config
            for flag_name, flag_cfg in pairs(_map_config.flags) do
                if flag_name ~= "allies_flag" and flag_name ~= "axis_flag"
                and flag_cfg.flag_pattern and flag_cfg.flag_coordinates
                and string.find(normalized, utils.normalize(flag_cfg.flag_pattern)) then
                    -- Closest player from either team
                    for _, team in ipairs({ et.TEAM_ALLIES, et.TEAM_AXIS }) do
                        local nearest = find_nearest_players(flag_cfg.flag_coordinates, team)
                        for _, cnum in ipairs(nearest) do
                            local guid = players_ref.guids[cnum] and players_ref.guids[cnum].guid
                            if guid then
                                record_obj_stat(guid, "obj_flagcaptured", flag_name)
                                if _collect_gamelog and gamelog_ref then
                                    gamelog_ref.obj_flag_captured(guid, flag_name)
                                end
                            end
                        end
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

        -- Escort objectives
        if _map_config.escort then
            for escort_name, escort_data in pairs(_map_config.escort) do
                if escort_data.escort_pattern and escort_data.escort_coordinates
                and string.find(normalized, utils.normalize(escort_data.escort_pattern)) then
                    local nearest = find_nearest_players(escort_data.escort_coordinates, et.TEAM_ALLIES)
                    for _, cnum in ipairs(nearest) do
                        local guid = players_ref.guids[cnum] and players_ref.guids[cnum].guid
                        if guid then
                            record_obj_stat(guid, "obj_escort", escort_name)
                        end
                    end
                    break
                end
            end
        end
    end

    -- legacy popup: popup state for objective steal / return
    if string.find(text, "legacy popup:", 1, true) then
        local normalized = utils.normalize(utils.strip_colors(text))

        if _map_config.objectives then
            for _, obj in ipairs(_map_config.objectives) do
                if obj.steal_pattern and obj.steal_pattern ~= ""
                and string.find(normalized, utils.normalize(obj.steal_pattern)) then
                    if not objective_states[obj.name] then
                        objective_states[obj.name] = { last_popup = "", last_announce = "",
                            last_action = "", timestamp = 0 }
                    end
                    objective_states[obj.name].last_popup = normalized
                    objective_states[obj.name].timestamp  = current_time
                    break

                elseif obj.return_pattern and obj.return_pattern ~= ""
                and string.find(normalized, utils.normalize(obj.return_pattern)) then
                    local state = objective_states[obj.name]
                    local returner_guid = state and state.carrier_id
                        and players_ref.guids[state.carrier_id]
                        and players_ref.guids[state.carrier_id].guid
                        or "WORLD"

                    record_obj_stat(returner_guid, "obj_returned", obj.name)
                    if _collect_gamelog and gamelog_ref then
                        gamelog_ref.objective("obj_returned", returner_guid, obj.name)
                    end

                    if state and state.carrier_id then
                        objective_carriers.players[state.carrier_id] = nil
                        state.carrier_id = nil
                    end
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
                    gamelog_ref.objective("obj_repaired", guid, objective_name)
                end
            end
        end
    end

    -- Item: <clientNum> team_CTF_redflag / team_CTF_blueflag
    if string.find(text, "Item:", 1, true)
    and (string.find(text, "team_CTF_redflag", 1, true) or string.find(text, "team_CTF_blueflag", 1, true)) then
        local id = tonumber(text:match("Item: (%d+)"))
        if id and _map_config.objectives then
            for _, obj in ipairs(_map_config.objectives) do
                local state = objective_states[obj.name]
                if state and state.last_popup and state.last_popup ~= ""
                and (current_time - state.timestamp) < 1000 then
                    local norm_popup = utils.normalize(utils.strip_colors(state.last_popup))
                    if obj.steal_pattern ~= "" and string.find(norm_popup, utils.normalize(obj.steal_pattern)) then
                        local entry = players_ref.guids[id]
                        if entry then
                            record_obj_stat(entry.guid, "obj_taken", obj.name)
                            if _collect_gamelog and gamelog_ref then
                                gamelog_ref.objective("obj_taken", entry.guid, obj.name)
                            end

                            objective_carriers.players[id] = obj.name
                            state.carrier_id = id
                            local found = false
                            for _, v in ipairs(objective_carriers.ids) do
                                if v == id then found = true; break end
                            end
                            if not found then
                                table.insert(objective_carriers.ids, id)
                            end
                        end
                        break
                    end
                end
            end
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
                            local entry = players_ref.guids[carrier_id]
                            if entry then
                                record_obj_stat(entry.guid, "obj_secured", obj.name)
                                if _collect_gamelog and gamelog_ref then
                                    gamelog_ref.objective("obj_secured", entry.guid, obj.name)
                                end
                            end

                            objective_carriers.players[carrier_id] = nil
                            for i, v in ipairs(objective_carriers.ids) do
                                if v == carrier_id then
                                    table.remove(objective_carriers.ids, i)
                                    break
                                end
                            end

                            update_objective_state(obj.name, "secured")
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

            local victim_guid = victim_entry  and victim_entry.guid  or "WORLD"
            local killer_guid = killer_entry  and killer_entry.guid  or "WORLD"

            record_obj_stat(victim_guid, "obj_carrierkilled", obj_name, {
                guid      = killer_guid,
                weapon    = mod,
                objective = obj_name,
            })

            if _collect_gamelog and (gamelog_module or gamelog_ref) then
                local gl = gamelog_module or gamelog_ref
                gl.objective("obj_carrierkilled", victim_guid, obj_name)
            end

            objective_carriers.players[target] = nil
            state.carrier_id = nil
            state.last_action = "killed"
        end
    end
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
    objective_carriers   = { players = {}, ids = {} }
    objective_states     = {}
    recent_announcements = {}
    pending_pickup       = nil
    _map_config          = nil
    _common_buildables   = nil
end

return objectives
