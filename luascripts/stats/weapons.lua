--[[
    stats/weapons.lua
    Weapon id table and the COLLECT_WEAPON_FIRE filter spec parser.

    Ids are hardcoded rather than read from et.WP_*: the same numbers are already
    hardcoded in movement.lua / players.lua, and not every WP_ constant is
    guaranteed to be registered by the Lua API.
--]]

local weapons = {}

-- [id] = { name, class }
local W = {
    [0]  = { "none",                 nil        },
    [1]  = { "knife",                "hitscan"  },  -- Axis knife
    [2]  = { "luger",                "hitscan"  }, 
    [3]  = { "mp40",                 "hitscan"  }, 
    [4]  = { "grenade_launcher",     "spam"     },  -- Axis grenade
    [5]  = { "panzerfaust",          "spam"     },  -- Axis panzer
    [6]  = { "flamethrower",         "spam"     },
    [7]  = { "colt",                 "hitscan"  },
    [8]  = { "thompson",             "hitscan"  },
    [9]  = { "grenade_pineapple",    "spam"     },  -- Allied grenade
    [10] = { "sten",                 "hitscan"  },
    [11] = { "medic_syringe",        "utility"  },
    [12] = { "ammo",                 "support"  },
    [13] = { "arty",                 "spam"     },
    [14] = { "silencer",             "hitscan"  },  -- silenced Luger
    [15] = { "dynamite",             "spam"     },
    [16] = { "smoketrail",           nil        },  -- artillery initial smoke
    [17] = { "mapmortar",            "spam"     },  -- map-placed fixed mortar
    [18] = { "verybigexplosion",     nil        },
    [19] = { "medkit",               "support"  },
    [20] = { "binoculars",           "support"  },
    [21] = { "pliers",               "support"  },
    [22] = { "smoke_marker",         "spam"     },  -- airstrike marker canister
    [23] = { "kar98",                "hitscan"  },  -- Axis rifle (K43)
    [24] = { "carbine",              "hitscan"  },  -- Allied rifle (Garand)
    [25] = { "garand",               "hitscan"  },  -- Allied sniper
    [26] = { "landmine",             "spam"     },
    [27] = { "satchel",              "utility"  },
    [28] = { "satchel_det",          "utility"  },
    [29] = { "smoke_bomb",           "utility"  },  -- covert smoke
    [30] = { "mobile_mg42",          "hitscan"  },  -- Axis tank-mounted, crew-served
    [31] = { "k43",                  "hitscan"  },  -- Axis sniper
    [32] = { "fg42",                 "hitscan"  },
    [33] = { "dummy_mg42",           "hitscan"  },  -- heat store for mounted MG42s; the id
                                                    -- ps.weapon reports during et_FixedMGFire
    [34] = { "mortar",               "spam"     },  -- Allied mortar
    [35] = { "akimbo_colt",          "hitscan"  },
    [36] = { "akimbo_luger",         "hitscan"  },
    [37] = { "gpg40",                "spam"     },  -- Axis rifle grenade
    [38] = { "m7",                   "spam"     },  -- Allied rifle grenade
    [39] = { "silenced_colt",        "hitscan"  },  -- silenced colt
    [40] = { "garand_scope",         "hitscan"  },  -- scoped mode of 25
    [41] = { "k43_scope",            "hitscan"  },  -- scoped mode of 31
    [42] = { "fg42_scope",           "hitscan"  },  -- scoped mode of 32
    [43] = { "mortar_set",           "spam"     },  -- Allied mortar
    [44] = { "medic_adrenaline",     "support"  },
    [45] = { "akimbo_silencedcolt",  "hitscan"  },
    [46] = { "akimbo_silencedluger", "hitscan"  },
    [47] = { "mobile_mg42_set",      "hitscan"  },  -- Axis soldier MG, deployed
    [48] = { "knife_kabar",          "hitscan"  },  -- Allied knife
    [49] = { "mobile_browning",      "hitscan"  },  -- Allied tank-mounted and unset
    [50] = { "mobile_browning_set",  "hitscan"  },  -- Allied MG, deployed
    [51] = { "mortar2",              "spam"     },  -- Axis mortar, unset
    [52] = { "mortar2_set",          "spam"     },  -- Axis mortar, deployed
    [53] = { "bazooka",              "spam"     },  -- Allied panzer
    [54] = { "mp34",                 "hitscan"  },  -- Axis Sten
    [55] = { "airstrike",            nil        },  -- mod for the bombs; 22 is the call
}

weapons.NAMES  = {}  -- [id]   = name
weapons.CLASS  = {}  -- [id]   = class or nil
local BY_NAME  = {}  -- [name] = id

for id, entry in pairs(W) do
    weapons.NAMES[id]     = entry[1]
    weapons.CLASS[id]     = entry[2]
    BY_NAME[entry[1]]     = id
end

local SPAWN_LABELS = {
    panzerfaust         = "panzerfaust",
    flamethrower        = "flamethrower",
    mobile_mg42         = "mobile_mg42",
    mobile_browning     = "mobile_browning",
    bazooka             = "bazooka",
    carbine             = "carbine",
    kar98               = "kar98",
    sten                = "sten",
    mp34                = "mp34",
    fg42                = "fg42",
    fg42_scope          = "fg42",
    garand              = "garand_sniper",
    garand_scope        = "garand_sniper",
    k43                 = "k43_sniper",
    k43_scope           = "k43_sniper",
}

weapons.SPAWN_NAMES = {}
for name, label in pairs(SPAWN_LABELS) do
    weapons.SPAWN_NAMES[BY_NAME[name]] = label
end

local CLASS_NAMES = { hitscan = true, spam = true, utility = true, support = true }

local OFF_TOKENS = { ["false"] = true, ["none"] = true, ["off"] = true, ["0"] = true }
local ALL_TOKENS = { ["true"] = true, ["all"] = true }

local function all_classified()
    local set = {}
    for id, class in pairs(weapons.CLASS) do
        if class then set[id] = true end
    end
    return set
end

local function class_set(class)
    local set = {}
    for id, c in pairs(weapons.CLASS) do
        if c == class then set[id] = true end
    end
    return set
end

local function resolve(token)
    if OFF_TOKENS[token] then return "off" end
    if ALL_TOKENS[token] then return "all" end
    if CLASS_NAMES[token] then return class_set(token) end

    local id = tonumber(token)
    if id and id == math.floor(id) and id >= 0 then
        return { [id] = true }
    end
    if BY_NAME[token] then
        return { [BY_NAME[token]] = true }
    end
    return nil
end

function weapons.parse(spec)
    local warnings = {}

    if spec == nil or spec == false then return nil, warnings end
    if spec == true then return true, warnings end
    if type(spec) ~= "string" then
        return nil, { string.format("unsupported value type '%s'", type(spec)) }
    end

    local positive, negative = {}, {}
    local saw_all = false

    for raw in spec:gmatch("[^,]+") do
        local token = raw:match("^%s*(.-)%s*$"):lower()
        if token ~= "" then
            local negate = false
            if token:sub(1, 1) == "-" then
                negate = true
                token  = token:sub(2)
            end

            local resolved = resolve(token)
            if resolved == nil then
                table.insert(warnings, string.format("unknown token '%s' ignored", token))
            elseif resolved == "off" or (resolved == "all" and negate) then
                -- an off-token, or `-all`, resets everything seen so far
                positive, negative, saw_all = {}, {}, false
            elseif resolved == "all" then
                saw_all = true
                for id in pairs(all_classified()) do positive[id] = true end
            else
                local target = negate and negative or positive
                for id in pairs(resolved) do target[id] = true end
            end
        end
    end

    if saw_all and next(negative) == nil then
        return true, warnings
    end

    for id in pairs(negative) do positive[id] = nil end
    if next(positive) == nil then return nil, warnings end

    return positive, warnings
end

-- Count of ids in a resolved filter, for logging
function weapons.count(filter)
    if filter == true or filter == nil then return nil end
    local n = 0
    for _ in pairs(filter) do n = n + 1 end
    return n
end

return weapons
