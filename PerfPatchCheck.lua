--[[
	[fufu] LibActionButton-1.0 performance-patch health check.

	The fork ships a performance-patched copy of LibActionButton-1.0 (Phases 1,
	2, 2.1, 2.2 -- see Bartender4-fufu.md "LibActionButton perf patch"). That
	patch can silently stop applying if:
	  * a packager / library updater re-pulled libs/ and overwrote the patched
	    file with upstream stock (the .pkgmeta external is commented out to
	    prevent this, but a manual library tool could still do it), or
	  * another loaded addon embeds a higher-versioned LibActionButton-1.0 that
	    wins the LibStub version race.

	The patched copy sets lib._fufuPerfPatch. This file converts the otherwise
	silent failure into a single visible login warning. It prints NOTHING on
	success (no chat spam) -- absence of a warning means the patch is active.

	This is a fufu-owned file, deliberately NOT inside libs/, so a libs/ re-pull
	cannot remove the canary itself.
]]

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self)
	self:UnregisterAllEvents()

	local LAB = LibStub and LibStub("LibActionButton-1.0", true)
	if LAB and not LAB._fufuPerfPatch then
		local out = DEFAULT_CHAT_FRAME or ChatFrame1
		if out then
			out:AddMessage("|cffff2020Bartender4-fufu:|r the LibActionButton "
				.. "performance patch is NOT active -- this session is running "
				.. "unoptimized stock LibActionButton. Likely cause: libs/ were "
				.. "re-pulled, or another addon's copy won the LibStub race. "
				.. "See Bartender4-fufu.md \"LibActionButton perf patch\".")
		end
	end
end)
