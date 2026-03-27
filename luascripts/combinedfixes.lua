local modname = "combinedfixes"
local version = "1.2"

-- ============================================================
-- CONFIGURATION
-- ============================================================

-- [DEFAULT CLASS]
-- Forces players to Medic on team join if no class selected.
-- Effectively banning Soldier SMG
local ENABLE_DEFAULT_CLASS  = true

-- [GUID BLOCKER]
-- Block a specific GUID from joining teams. Will be moved to spectator and told to delete their etkey. 
-- This was needed for ETL (2025) LAN as users were using a shared guid. 
-- Check only occurs during warmup (gamestate 2)
local ENABLE_GUID_BLOCKER   = true
local GUID_BLOCKER_TARGETS  = {
    ["F2ECF20F3ED6A5A93F2C49EF239F4488"] = true,
}

-- [TECH PAUSE]
-- Adds a "techpause" command that pauses with a longer timeout than a regular pause
-- match_timeoutlength is managed here rather than in the match config to prevent
-- ETLegacy config validation from unloading the competitive config on cvar change
local ENABLE_TECH_PAUSE  = true
local TECH_PAUSE_LENGTH  = 600
local TECH_PAUSE_COUNT   = 1     -- techpauses allowed per team per half
local PAUSE_LENGTH       = 120

-- [TEAM LOCK]
-- Locks teams on round start in stopwatch; re-locks after unpause
local ENABLE_TEAM_LOCK      = true

-- [CONNECTION BANS]
-- GUIDs rejected at connect (uncomment entries to enable)
local BANNED_GUIDS = {
    --["12345"] = true,
    --["ABCDE"] = true,
}

-- IPs rejected at connect; prefix matching supported (e.g. "10.0.0." bans entire /24)
local BANNED_IPS = {
    --["127.0.0.1"] = true,
    --["192.168.1."] = true,
}

local BAN_REASON = "Banned."

-- [SPAWN INVUL]
-- Auto-enabled when CS_CONFIGNAME contains "1on1" (i.e. the legacy1 1on1 configs)
local SPAWN_INVUL_SECONDS = 1   -- shield duration in seconds

-- [SAVE/LOAD]
-- hazz' /save and /load. Enabled when CS_CONFIGNAME contains any of these
local SAVELOAD_KEYWORDS = { "practice", "test", "trickjump", "tj" }

-- [VOTE BANS]
-- GUIDs blocked from calling votes
-- Certain players just can't behave themselves and will spam call vote for surrender.
local VOTE_BANNED_GUIDS = {
    --["12345"] = true,
    --["ABCDE"] = true,
}

local VOTE_BAN_MESSAGE = "You've been banned from calling votes. Talk to knux"

-- [COMMAND LOGGING]
-- Logs callvote, rcon and ref commands issued by clients to the log file
-- rcon is handled at the engine level before et_ClientCommand, so it cannot be intercepted here.
local ENABLE_COMMAND_LOGGING = true
local COMMAND_LOG_VOTES      = true   -- log callvote/vote commands
local COMMAND_LOG_REF        = true   -- log ref commands

-- [LOGGING]
-- Leave empty to auto-detect: <fs_homepath>/legacy/combinedfixes.log
-- local LOG_FILEPATH = "/legacy/homepath/legacy/stats/game_stats.log"
local LOG_FILEPATH = ""

-- [ENV OVERRIDES]
-- Any setting above can be overridden by an environment variable of the same
-- name used in Docker (e.g. CF_TECH_PAUSE, CF_BANNED_GUIDS).
-- Unset variables are silently ignored and the defaults above apply.
local function env_bool(name, default)
    local v = os.getenv(name)
    if v == "true"  then return true  end
    if v == "false" then return false end
    return default
end

ENABLE_DEFAULT_CLASS    = env_bool("CF_DEFAULT_CLASS",      ENABLE_DEFAULT_CLASS)
ENABLE_GUID_BLOCKER     = env_bool("CF_GUID_BLOCKER",       ENABLE_GUID_BLOCKER)
ENABLE_TECH_PAUSE       = env_bool("CF_TECH_PAUSE",         ENABLE_TECH_PAUSE)
TECH_PAUSE_LENGTH       = tonumber(os.getenv("CF_TECH_PAUSE_LENGTH"))   or TECH_PAUSE_LENGTH
TECH_PAUSE_COUNT        = tonumber(os.getenv("CF_TECH_PAUSE_COUNT"))    or TECH_PAUSE_COUNT
PAUSE_LENGTH            = tonumber(os.getenv("CF_PAUSE_LENGTH"))        or PAUSE_LENGTH
ENABLE_TEAM_LOCK        = env_bool("CF_TEAM_LOCK",          ENABLE_TEAM_LOCK)
ENABLE_COMMAND_LOGGING  = env_bool("CF_COMMAND_LOGGING",    ENABLE_COMMAND_LOGGING)
COMMAND_LOG_VOTES       = env_bool("CF_COMMAND_LOG_VOTES",  COMMAND_LOG_VOTES)
COMMAND_LOG_REF         = env_bool("CF_COMMAND_LOG_REF",    COMMAND_LOG_REF)
SPAWN_INVUL_SECONDS     = tonumber(os.getenv("CF_SPAWN_INVUL_SECONDS")) or SPAWN_INVUL_SECONDS
BAN_REASON              = os.getenv("CF_BAN_REASON")                    or BAN_REASON
LOG_FILEPATH            = os.getenv("CF_LOG_FILEPATH")                  or LOG_FILEPATH

local function _merge_csv_guids(env_name, target)
    local v = os.getenv(env_name)
    if not v or v == "" then return end
    for item in string.gmatch(v, "[^,]+") do
        item = string.upper(string.match(item, "^%s*(.-)%s*$"))
        if item ~= "" then target[item] = true end
    end
end

local function _merge_csv_ips(env_name, target)
    local v = os.getenv(env_name)
    if not v or v == "" then return end
    for item in string.gmatch(v, "[^,]+") do
        item = string.match(item, "^%s*(.-)%s*$")
        if item ~= "" then target[item] = true end
    end
end

_merge_csv_guids("CF_GUID_BLOCKER_TARGETS", GUID_BLOCKER_TARGETS)
_merge_csv_guids("CF_BANNED_GUIDS",         BANNED_GUIDS)
_merge_csv_ips  ("CF_BANNED_IPS",           BANNED_IPS)
_merge_csv_guids("CF_VOTE_BANNED_GUIDS",    VOTE_BANNED_GUIDS)

-- ============================================================ --
-- ============================================================ --
-- ============================================================ --

local TEAM_AXIS       = 1
local TEAM_ALLIES     = 2
local TEAM_SPECTATOR  = 3
local CLASS_MEDIC     = 1
local CLASS_SOLDIER   = 0
local WEAPON_MP40     = 3
local WEAPON_THOMPSON = 8
local CV_SVS_PAUSE    = 16

local _logFilePath = nil  -- resolved in et_InitGame

local function log(message)
    local ms   = et.trap_Milliseconds() % 1000
    local line = string.format("[%s.%03d] [COMBINEDFIXES] %s\n", os.date("%Y-%m-%d %H:%M:%S"), ms, message)
    et.G_Print(line)
    if not _logFilePath then return end
    local file, err = io.open(_logFilePath, "a")
    if file then
        file:write(line)
        file:close()
    else
        et.G_Print(string.format("[COMBINEDFIXES] Failed to open log file: %s\n", err or "unknown"))
    end
end

local function getGamestate()
    return tonumber(et.trap_Cvar_Get("gamestate"))
end

local function guidInTable(guid, t)
    if not guid or guid == "" then return false end
    return t[string.upper(guid)] == true
end

local function cleanIP(ip)
    if not ip or ip == "" then return nil end
    return string.match(ip, "^([%d%.]+)") or ip
end

local function cfgHasWord(cfgname, word)
    return string.match(cfgname, "%f[%a%d]" .. word .. "%f[^%a%d]") ~= nil
end

local function isIPBanned(ip)
    local cleaned = cleanIP(ip)
    if not cleaned then return false end
    if BANNED_IPS[cleaned] then return true end
    for bannedIP, _ in pairs(BANNED_IPS) do
        if string.find(cleaned, bannedIP, 1, true) == 1 then return true end
    end
    return false
end


-- ============================================================
-- MODULE: DEFAULT CLASS
-- ============================================================

local function defaultClass_clientUserinfoChanged(clientNum)
    if not ENABLE_DEFAULT_CLASS then return end

    local gameState = getGamestate()
    if not gameState or gameState < 1 then return end

    local sessionTeam = tonumber(et.gentity_get(clientNum, "sess.sessionTeam"))
    local playerClass = tonumber(et.gentity_get(clientNum, "sess.playerType"))
    local latchedWeapon = tonumber(et.gentity_get(clientNum, "sess.latchPlayerWeapon"))
    local latchedType   = tonumber(et.gentity_get(clientNum, "sess.latchPlayerType"))

    if (sessionTeam == TEAM_AXIS or sessionTeam == TEAM_ALLIES) and
       playerClass == CLASS_SOLDIER and
       latchedType == CLASS_SOLDIER and
       (latchedWeapon == WEAPON_MP40 or latchedWeapon == WEAPON_THOMPSON) then
        et.gentity_set(clientNum, "sess.latchPlayerType", CLASS_MEDIC)
    end
end

-- ============================================================
-- MODULE: GUID BLOCKER
-- ============================================================

local function guidBlocker_sendWarning(clientNum, name)
    local msg = string.format("^1WARNING: ^7%s, please close your game, delete your etkey and reconnect", name)
    et.trap_SendServerCommand(-1, "chat \"" .. msg .. "\"")
    log("Warning message sent to " .. name)
end

local function guidBlocker_check(clientNum)
    if not ENABLE_GUID_BLOCKER then return false end
    if getGamestate() ~= 2 then return false end

    local userinfo = et.trap_GetUserinfo(clientNum)
    if not userinfo or userinfo == "" then return false end

    local guid = et.Info_ValueForKey(userinfo, "cl_guid")
    local name = et.Info_ValueForKey(userinfo, "name")

    if guidInTable(guid, GUID_BLOCKER_TARGETS) then
        et.gentity_set(clientNum, "sess.sessionTeam", TEAM_SPECTATOR)
        guidBlocker_sendWarning(clientNum, name)
        return true
    end

    return false
end

-- ============================================================
-- MODULE: PAUSE / TEAM LOCK
-- ============================================================

local roundStarted       = false
local techPauseUsed      = { [TEAM_AXIS] = 0, [TEAM_ALLIES] = 0 }
local techPauseTeam      = nil
local _spawnInvulActive  = false
local _saveLoadActive    = false
local _saveLoadPositions = {}
local _saveLoadSprints   = {}

local function lockTeams()
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "ref lock r\n")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "ref lock b\n")
    roundStarted = true
end

local function unlockTeams()
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "ref unlock r\n")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "ref unlock b\n")
end

local function pause_runFrame(levelTime)
    if not ENABLE_TEAM_LOCK then return end

    local gs = tonumber(et.trap_Cvar_Get("gamestate")) or -1
    if gs == 0 then
        -- GS_PLAYING: lock teams once per round
        if not roundStarted then lockTeams() end
    else
        -- GS_WARMUP or GS_INTERMISSION: ensure teams are unlocked
        if roundStarted then
            unlockTeams()
        end
        roundStarted = false
    end
end

local function pause_clientCommand(clientNum, cmd)
    if cmd == "techpause" or cmd == "tp" then
        if not ENABLE_TECH_PAUSE then return 0 end
        local team = tonumber(et.gentity_get(clientNum, "sess.sessionTeam"))
        if team ~= TEAM_AXIS and team ~= TEAM_ALLIES then return 1 end
        if techPauseUsed[team] >= TECH_PAUSE_COUNT then
            et.trap_SendServerCommand(clientNum, "cp \"Your team has no techpauses remaining\"")
            return 1
        end
        techPauseUsed[team] = techPauseUsed[team] + 1
        techPauseTeam = team
        local name      = et.Info_ValueForKey(et.trap_GetUserinfo(clientNum), "name")
        local teamName  = team == TEAM_AXIS and "^iAxis^7" or "^dAllies^7"
        local remaining = TECH_PAUSE_COUNT - techPauseUsed[team]
        et.trap_SendServerCommand(-1, "print \"[TECHPAUSE by " .. name .. "^7 for " .. teamName .. ": ^1" .. remaining .. "^7 Remaining]\n\"")
        et.trap_Cvar_Set("match_timeoutlength", TECH_PAUSE_LENGTH)
        unlockTeams()
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "ref pause\n")
        return 1
    elseif cmd == "techunpause" or cmd == "tup" then
        if not ENABLE_TECH_PAUSE then return 0 end
        local team = tonumber(et.gentity_get(clientNum, "sess.sessionTeam"))
        if team ~= techPauseTeam then
            et.trap_SendServerCommand(clientNum, "cp \"Only the team that called the techpause can unpause\"")
            return 1
        end
        local name     = et.Info_ValueForKey(et.trap_GetUserinfo(clientNum), "name")
        local teamName = team == TEAM_AXIS and "^iAxis^7" or "^dAllies^7"
        et.trap_SendServerCommand(-1, "print \"[TECHPAUSE ended by " .. name .. "^7 for " .. teamName .. "]\n\"")
        techPauseTeam = nil
        et.trap_Cvar_Set("match_timeoutlength", PAUSE_LENGTH)
        roundStarted = false
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "ref unpause\n")
        return 1
    elseif cmd == "pause" and ENABLE_TEAM_LOCK then
        unlockTeams()
    elseif cmd == "unpause" and ENABLE_TEAM_LOCK then
        roundStarted = false
    end
    return 0
end

-- ============================================================
-- MODULE: CONNECTION / VOTE BANS
-- ============================================================

local function shouldEnforceBans()
    local servername = et.trap_Cvar_Get("sv_hostname") or ""
    return not string.find(string.lower(servername), "gather", 1, true)
end

local function connBan_clientConnect(clientNum, firstTime, isBot)
    if isBot == 1 then return nil end

    local servername = et.trap_Cvar_Get("sv_hostname") or ""
    local enforce    = shouldEnforceBans()
    local userinfo   = et.trap_GetUserinfo(clientNum)
    local guid       = et.Info_ValueForKey(userinfo, "cl_guid")

    if enforce then
        if guidInTable(guid, BANNED_GUIDS) then
            log(string.format("Connection rejected: Banned GUID %s on server '%s'", guid, servername))
            return BAN_REASON
        end

        local ip = et.Info_ValueForKey(userinfo, "ip")
        if isIPBanned(ip) then
            log(string.format("Connection rejected: Banned IP %s on server '%s'", ip, servername))
            return BAN_REASON
        end
    end

    -- Log if a GUID-blocked player connects
    if ENABLE_GUID_BLOCKER and guidInTable(guid, GUID_BLOCKER_TARGETS) then
        log("Detected GUID-blocked player connecting (client " .. clientNum .. ") - Will enforce when gamestate becomes 2")
    end

    return nil
end

local function connBan_clientBegin(clientNum)
    if not shouldEnforceBans() then return end

    local userinfo = et.trap_GetUserinfo(clientNum)
    local ip       = et.Info_ValueForKey(userinfo, "ip")
    local guid     = et.Info_ValueForKey(userinfo, "cl_guid")

    if isIPBanned(ip) then
        local servername = et.trap_Cvar_Get("sv_hostname") or ""
        log(string.format("Kicking at begin: Banned IP %s with GUID %s on server '%s'", ip, guid or "unknown", servername))
        et.trap_DropClient(clientNum, BAN_REASON, 2147483647)
    end
end

local function voteBan_clientCommand(clientNum, cmd)
    if cmd == "callvote" or cmd == "vote" then
        local guid = et.Info_ValueForKey(et.trap_GetUserinfo(clientNum), "cl_guid")
        if guidInTable(guid, VOTE_BANNED_GUIDS) then
            et.trap_SendServerCommand(clientNum, "cp \"" .. VOTE_BAN_MESSAGE .. "\"")
            return 1
        end
    end
    return 0
end

-- ============================================================
-- MODULE: SPAWN INVUL
-- ============================================================

local function spawnInvul_init()
    local raw     = et.trap_GetConfigstring(et.CS_CONFIGNAME) or ""
    local cfgname = string.gsub(raw, "%^%d", "")  -- strip ET color codes
    _spawnInvulActive = string.find(cfgname, "1on1", 1, true) ~= nil
    if _spawnInvulActive then
        log(string.format("Spawn invul enabled (%.1f sec) [config: %s]", SPAWN_INVUL_SECONDS, cfgname))
    end
end

local function spawnInvul_clientSpawn(clientNum)
    if not _spawnInvulActive then return end
    et.gentity_set(clientNum, "ps.powerups", 1, et.trap_Milliseconds() + SPAWN_INVUL_SECONDS * 1000)
end

-- ============================================================
-- MODULE: SAVE/LOAD
-- ============================================================

local function saveLoad_init()
    local raw     = et.trap_GetConfigstring(et.CS_CONFIGNAME) or ""
    local cfgname = string.lower(string.gsub(raw, "%^%d", ""))
    _saveLoadActive    = false
    _saveLoadPositions = {}
    _saveLoadSprints   = {}
    for _, kw in ipairs(SAVELOAD_KEYWORDS) do
        if cfgHasWord(cfgname, kw) then
            _saveLoadActive = true
            break
        end
    end
    if _saveLoadActive then
        log("Save/load enabled [config: " .. cfgname .. "]")
    end
end

local function saveLoad_save(clientNum)
    _saveLoadPositions[clientNum] = et.gentity_get(clientNum, "ps.origin")
    _saveLoadSprints[clientNum]   = et.gentity_get(clientNum, "ps.stats", et.STAT_SPRINTTIME) + 0.0
end

local function saveLoad_load(clientNum)
    if not _saveLoadPositions[clientNum] then return end
    et.gentity_set(clientNum, "ps.origin",   _saveLoadPositions[clientNum])
    et.gentity_set(clientNum, "ps.velocity", {0, 0, 0})
    et.gentity_set(clientNum, "ps.stats",    et.STAT_SPRINTTIME, _saveLoadSprints[clientNum])
end

local function saveLoad_clientCommand(clientNum, cmd)
    if not _saveLoadActive then return 0 end
    if cmd == "save" then
        saveLoad_save(clientNum)
        return 1
    elseif cmd == "load" then
        saveLoad_load(clientNum)
        return 1
    end
    return 0
end

function et_InitGame(levelTime, randomSeed, restart)
    et.RegisterModname(modname .. " " .. version)
    if LOG_FILEPATH and LOG_FILEPATH ~= "" then
        _logFilePath = LOG_FILEPATH
    else
        local homepath = et.trap_Cvar_Get("fs_homepath") or ""
        _logFilePath = homepath .. "/legacy/combinedfixes.log"
    end
    local dir = string.match(_logFilePath, "^(.+)/[^/]+$")
    if dir then os.execute("mkdir -p " .. dir) end
    et.trap_Cvar_Set("match_timeoutlength", PAUSE_LENGTH)
    techPauseUsed = { [TEAM_AXIS] = 0, [TEAM_ALLIES] = 0 }
    techPauseTeam = nil
    spawnInvul_init()
    saveLoad_init()
    log("Initialized")
end

-- ============================================================
-- MODULE: COMMAND LOGGING
-- ============================================================

local function commandLog_clientCommand(clientNum, cmd)
    if not ENABLE_COMMAND_LOGGING then return end

    local shouldLog = (COMMAND_LOG_VOTES and (cmd == "callvote" or cmd == "vote"))
                   or (COMMAND_LOG_REF   and cmd == "ref")
    if not shouldLog then return end

    local userinfo = et.trap_GetUserinfo(clientNum)
    local name     = et.Info_ValueForKey(userinfo, "name")
    local guid     = et.Info_ValueForKey(userinfo, "cl_guid")

    local args = {}
    for i = 1, 8 do
        local arg = et.trap_Argv(i)
        if not arg or arg == "" then break end
        table.insert(args, arg)
    end
    local fullCmd = cmd .. (#args > 0 and (" " .. table.concat(args, " ")) or "")

    log(string.format("CLIENT_CMD client=%d name=%s guid=%s cmd=%s", clientNum, name, guid, fullCmd))
end

function et_ClientConnect(clientNum, firstTime, isBot)
    return connBan_clientConnect(clientNum, firstTime, isBot)
end

function et_ClientBegin(clientNum)
    guidBlocker_check(clientNum)
    connBan_clientBegin(clientNum)
end

function et_ClientUserinfoChanged(clientNum)
    defaultClass_clientUserinfoChanged(clientNum)
    guidBlocker_check(clientNum)
end

function et_ClientCommand(clientNum, command)
    local cmd = string.lower(et.trap_Argv(0))

    commandLog_clientCommand(clientNum, cmd)

    if pause_clientCommand(clientNum, cmd) == 1 then return 1 end
    if voteBan_clientCommand(clientNum, cmd) == 1 then return 1 end
    if saveLoad_clientCommand(clientNum, cmd) == 1 then return 1 end

    return 0
end

function et_ClientSpawn(clientNum, revived)
    spawnInvul_clientSpawn(clientNum)
end


function et_RunFrame(levelTime)
    pause_runFrame(levelTime)
end
