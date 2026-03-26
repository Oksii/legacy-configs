--[[
    stats/config.lua
    Loads and processes config.toml.
    The [configuration] / [docker_configuration] sections have been
    removed from the TOML file — all API/feature settings live in the
    root stats.lua configuration block instead.
    This module only handles map configs and common buildables.
--]]

local config = {}

local toml  = require("toml")
local utils = require("luascripts/stats/util/utils")

local function get_config_path()
    local fs_basepath = et.trap_Cvar_Get("fs_basepath")
    local fs_game     = et.trap_Cvar_Get("fs_game")
    if not fs_basepath or not fs_game then return nil end
    return string.format("%s/%s/luascripts/config.toml", fs_basepath, fs_game)
end

local function load_toml(filepath)
    if not filepath then return nil, "nil filepath" end

    local f, err = io.open(filepath, "r")
    if not f then return nil, "cannot open: " .. (err or "unknown") end

    local content = f:read("*all")
    f:close()

    if not content or content == "" then return nil, "empty file" end

    local ok, result = pcall(toml.parse, content)
    if not ok then
        local line = result and result:match(":(%d+):") or "?"
        return nil, string.format("parse error near line %s: %s", line, result)
    end
    return result
end

-- Normalise a single map section into a consistent structure.
local function process_map(map_name, map_data)
    local norm_name = utils.normalize(map_name)
    local entry = {
        objectives = {},
        buildables = {},
        flags      = {},
        misc       = {},
        escort     = {},
    }

    if map_data.objectives then
        for obj_name, obj_data in pairs(map_data.objectives) do
            table.insert(entry.objectives, {
                name            = utils.normalize(obj_name),
                steal_pattern   = utils.normalize(obj_data.steal_pattern   or ""),
                secured_pattern = utils.normalize(obj_data.secured_pattern or ""),
                return_pattern  = utils.normalize(obj_data.return_pattern  or ""),
            })
        end
    end

    if map_data.buildables then
        for b_name, b_data in pairs(map_data.buildables) do
            local key = utils.normalize(b_name)
            if b_data.enabled ~= nil then
                entry.buildables[key] = { enabled = b_data.enabled }
            else
                entry.buildables[key] = {
                    construct_pattern = utils.normalize(b_data.construct_pattern or ""),
                    destruct_pattern  = utils.normalize(b_data.destruct_pattern  or ""),
                    plant_pattern     = utils.normalize(b_data.plant_pattern     or ""),
                }
            end
        end
    end

    if map_data.flags then
        for f_name, f_data in pairs(map_data.flags) do
            entry.flags[utils.normalize(f_name)] = {
                flag_pattern     = utils.normalize(f_data.flag_pattern or ""),
                flag_coordinates = f_data.flag_coordinates,
            }
        end
    end

    if map_data.misc then
        for m_name, m_data in pairs(map_data.misc) do
            entry.misc[utils.normalize(m_name)] = {
                misc_pattern     = utils.normalize(m_data.misc_pattern or ""),
                misc_coordinates = m_data.misc_coordinates,
            }
        end
    end

    if map_data.escort then
        for e_name, e_data in pairs(map_data.escort) do
            entry.escort[utils.normalize(e_name)] = {
                escort_pattern     = utils.normalize(e_data.escort_pattern or ""),
                escort_coordinates = e_data.escort_coordinates,
            }
        end
    end

    return norm_name, entry
end

local function process_maps(maps_section)
    if not maps_section then return {} end
    local result = {}
    for map_name, map_data in pairs(maps_section) do
        local norm_name, entry = process_map(map_name, map_data)
        result[norm_name] = entry
    end
    return result
end

local function process_common_buildables(buildables_section)
    return buildables_section or {}
end

function config.load()
    local path = get_config_path()
    local raw, err = load_toml(path)
    if not raw then
        return nil, string.format("Failed to load %s: %s",
            path or "nil", err)
    end

    local map_configs       = process_maps(raw.maps)
    local common_buildables = process_common_buildables(raw.common_buildables)

    return {
        map_configs       = map_configs,
        common_buildables = common_buildables,
    }, nil
end

return config
