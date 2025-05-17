--[[
    ET:Legacy GUID Blocker
    
    Forces players with a specific GUID to spectator team
    and instructs them to delete their etkey and reconnect
    
    Only active during gameplay (gamestate 2)
]]--

local MODULE_NAME = "guid-blocker"
local VERSION = "1.0.0"

local TARGET_GUID = "F2ECF20F3ED6A5A93F2C49EF239F4488"
local TEAM_SPECTATOR = 3

local function log(message)
    et.G_LogPrint(MODULE_NAME .. ": " .. message .. "\n")
end

local function sendWarningMessage(clientNum, playerName)
    local message = string.format("^1WARNING: ^7%s, please close your game, delete your etkey and reconnect", playerName)
    et.trap_SendServerCommand(-1, "chat \"" .. message .. "\"")
    log("Warning message sent to " .. playerName)
end

local function isActiveGamestate()
    local gamestate = tonumber(et.trap_Cvar_Get("gamestate"))
    return gamestate == 2
end

local function checkGuid(clientNum)
    -- Skip if not in active gamestate
    if not isActiveGamestate() then return false end
    
    local userinfo = et.trap_GetUserinfo(clientNum)
    if not userinfo or userinfo == "" then return false end
    
    local guid = string.upper(et.Info_ValueForKey(userinfo, "cl_guid"))
    local name = et.Info_ValueForKey(userinfo, "name")
    
    if guid == TARGET_GUID then
        -- Force player to spectator
        et.gentity_set(clientNum, "sess.sessionTeam", TEAM_SPECTATOR)
        
        sendWarningMessage(clientNum, name)
        return true
    end
    
    return false
end


function et_InitGame(levelTime, randomSeed, restart)
    et.RegisterModname(MODULE_NAME .. " " .. VERSION)
    log("Initialized - Will be active only during gamestate 2")
end


function et_ClientConnect(clientNum, firstTime, isBot)
    if isBot then return nil end
    
    local userinfo = et.trap_GetUserinfo(clientNum)
    local guid = string.upper(et.Info_ValueForKey(userinfo, "cl_guid"))
    
    if guid == TARGET_GUID then
        log("Detected blocked GUID connecting (client " .. clientNum .. ") - Will enforce when gamestate becomes 2")
    end
    
    return nil
end

function et_ClientBegin(clientNum)
    checkGuid(clientNum)
end

function et_ClientUserinfoChanged(clientNum)
    checkGuid(clientNum)
end

function et_ClientCommand(clientNum, command)
    if not isActiveGamestate() then return 0 end

    local userinfo = et.trap_GetUserinfo(clientNum)
    local guid = string.upper(et.Info_ValueForKey(userinfo, "cl_guid"))
    
    if guid == TARGET_GUID and (command == "team" or command == "setteam") then
        et.gentity_set(clientNum, "sess.sessionTeam", TEAM_SPECTATOR)
        
        local name = et.Info_ValueForKey(userinfo, "name")
        
        sendWarningMessage(clientNum, name)
        return 1
    end

    return 0
end

function et_RunFrame(levelTime)
    if not isActiveGamestate() then return end
    
    if levelTime % 5000 == 0 then
        for clientNum = 0, et.trap_Cvar_Get("sv_maxclients") - 1 do
            if et.gentity_get(clientNum, "pers.connected") == 2 then
                local userinfo = et.trap_GetUserinfo(clientNum)
                local guid = string.upper(et.Info_ValueForKey(userinfo, "cl_guid"))
                local team = et.gentity_get(clientNum, "sess.sessionTeam")
                
                if guid == TARGET_GUID and team ~= TEAM_SPECTATOR then
                    local name = et.Info_ValueForKey(userinfo, "name")
                    log("Forced " .. name .. " to spectator (gamestate 2 periodic check)")
                    et.gentity_set(clientNum, "sess.sessionTeam", TEAM_SPECTATOR)
                    sendWarningMessage(clientNum, name)
                end
            end
        end
    end
end