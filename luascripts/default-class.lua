local modname = "default-class"
local version = "1.0"

-- Constants for teams, classes and weapons
local AXIS = 1
local ALLIES = 2
local MEDIC = 1
local SOLDIER = 0
local MP40 = 3
local THOMPSON = 8

function et_InitGame(levelTime, randomSeed, restart)
    et.RegisterModname(modname .. " " .. version)
end

function et_ClientUserinfoChanged(clientNum)
    -- Get current game state
    local gameState = tonumber(et.trap_Cvar_Get("gamestate"))
    
    -- Only proceed if game state is valid (GS >= 1)
    if not gameState or gameState < 1 then
        return
    end
    
    -- Get the client's current team, class, weapons and intended class
    local sessionTeam = tonumber(et.gentity_get(clientNum, "sess.sessionTeam"))
    local playerClass = tonumber(et.gentity_get(clientNum, "sess.playerType"))
    local latchedPlayerWeapon = tonumber(et.gentity_get(clientNum, "sess.latchPlayerWeapon"))
    local latchedPlayerType = tonumber(et.gentity_get(clientNum, "sess.latchPlayerType"))
    
    -- Check if the player is and intends to remain a Soldier with MP40/Thompson
    if (sessionTeam == AXIS or sessionTeam == ALLIES) and 
       playerClass == SOLDIER and 
       latchedPlayerType == SOLDIER and
       (latchedPlayerWeapon == MP40 or latchedPlayerWeapon == THOMPSON) then
        
        -- Set the player's class to Medic
        et.gentity_set(clientNum, "sess.latchPlayerType", MEDIC)
    end
end