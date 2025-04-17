local modname = "techpause"
local version = "0.0"

local CV_SVS_PAUSE       = 16
local techPauseLength    = 600   -- minimum pause length is 15s delay + 10s countdown, no matter the setting.
local defaultPauseLength = 30    -- minimum pause length is 15s delay + 10s countdown, no matter the setting.

function et_ClientCommand(clientNum, cmd)
	if cmd == "techpause" then	
		local serverToggles = tonumber(et.trap_GetConfigstring(et.CS_SERVERTOGGLES))
		
		-- pausing
		if (serverToggles & CV_SVS_PAUSE) == 0 then
			et.trap_Cvar_Set("match_timeoutlength", techPauseLength)
			et.trap_SendConsoleCommand(et.EXEC_APPEND, "ref pause")
		
		-- unpausing 
		else
			et.trap_Cvar_Set("match_timeoutlength", defaultPauseLength)
			et.trap_SendConsoleCommand(et.EXEC_APPEND, "ref unpause")
		end
		
		return 1
	end
	
	return 0
end

function et_InitGame()
    et.RegisterModname(modname .. " " .. version)
end