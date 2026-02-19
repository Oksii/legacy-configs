local modname = "spawn-invul-1sec"
local version = "1.0"

spawnShield = 1 -- seconds
levelTime = 0

function et_InitGame(levelTime, randomSeed, restart)
    et.RegisterModname(modname .. " " .. version)
end

function et_RunFrame(lvltime)
    levelTime = lvltime
end

function et_ClientSpawn(clientNum, revived)
    et.gentity_set(clientNum, "ps.powerups", 1, levelTime + spawnShield * 1000)
end
