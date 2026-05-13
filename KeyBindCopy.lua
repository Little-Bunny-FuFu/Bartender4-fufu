--[[
	Copyright (c) 2009-2017, Hendrik "Nevcairiel" Leppkes < h.leppkes at gmail dot com >
	All rights reserved.
]]
local _, Bartender4 = ...
local BT4KC = Bartender4:NewModule("KeyBindCopy", "AceEvent-3.0")

-- GLOBALS: Bartender4DB, UnitName, GetRealmName, GetBindingKey, SetBinding, SaveBindings, AttemptToSaveBindings, GetCurrentBindingSet, InCombatLockdown
-- GLOBALS: StaticPopupDialogs, StaticPopup_Show, GetCurrentBindingSet

local _G = _G
local pairs, ipairs, next, type = pairs, ipairs, next, type
local format = string.format
local GetBindingKey = GetBindingKey
local SetBinding = SetBinding
local GetCurrentBindingSet = GetCurrentBindingSet
local InCombatLockdown = InCombatLockdown

-- Capability gate: older Classic Era builds may lack GetCurrentBindingSet
-- entirely. Without it, per-character binding slots aren't supported and the
-- entire copy / save / restore pipeline is meaningless. Flag once at load.
local UNSUPPORTED = (type(GetCurrentBindingSet) ~= "function")

-- Resolve at call time so a runtime replacement of the API is honored.
local function SaveBindings(...) return (_G.SaveBindings or _G.AttemptToSaveBindings)(...) end

local L = LibStub("AceLocale-3.0"):GetLocale("Bartender4")

-- Static Popup for safety
StaticPopupDialogs["BARTENDER4_CONFIRM_KEYBIND_COPY"] = {
	text = L["Are you sure you want to overwrite your current keybindings with those from %s? This cannot be undone."],
	button1 = _G.YES,
	button2 = _G.NO,
	OnAccept = function(self, data)
		-- data carries {charKey, expectedSet} captured at popup-open time so
		-- OnAccept can verify the binding-set context hasn't changed between
		-- Show and accept (StaticPopup_Show is async; the user could toggle
		-- Character Specific Keybinds in between, which would otherwise cause
		-- the copied bindings to be written to the wrong on-disk slot).
		local charKey, expectedSet
		if type(data) == "table" then
			charKey, expectedSet = data.charKey, data.expectedSet
		else
			charKey = data -- legacy: string-only data from older callers
		end
		if expectedSet and (GetCurrentBindingSet() or 1) ~= expectedSet then
			Bartender4:Print(L["Binding set changed since this dialog was opened; keybind copy cancelled."])
			return
		end
		local ok, failedCount = BT4KC:CopyBindingsFrom(charKey, expectedSet)
		if not ok then
			Bartender4:Print((L["Could not copy keybindings from %s."]):format(tostring(charKey)))
			return
		end
		if failedCount and failedCount > 0 then
			Bartender4:Print((L["Keybindings copied from %s (%d failed)."]):format(charKey, failedCount))
		else
			Bartender4:Print((L["Keybindings copied from %s."]):format(charKey))
		end
		Bartender4.db.profile.keybindCopySource = nil
		LibStub("AceConfigRegistry-3.0"):NotifyChange("Bartender4")
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local s_allBindingActions = nil
local function GetAllBT4BindingActions()
	if s_allBindingActions then return s_allBindingActions end
	local actions = {}
	local ActionBarsMod = Bartender4:GetModule("ActionBars")
	
	-- 1. Custom Bartender4 Keybinds
	for _, i in ipairs(ActionBarsMod.LIST_ACTIONBARS) do
		for k = 1, 12 do
			actions[#actions + 1] = ("CLICK BT4Button%d:Keybind"):format(((i-1)*12)+k)
		end
	end
	for k = 1, 10 do
		actions[#actions + 1] = ("CLICK BT4PetButton%d:LeftButton"):format(k)
		actions[#actions + 1] = ("CLICK BT4StanceButton%d:LeftButton"):format(k)
	end

	-- 2. Blizzard Default Bindings that Bartender4 intercepts (e.g. Bar 3 is MULTIACTIONBAR3)
	local BLIZZ_MAPPINGS = {
		[1] = "ACTIONBUTTON%d",
		[3] = "MULTIACTIONBAR3BUTTON%d",
		[4] = "MULTIACTIONBAR4BUTTON%d",
		[5] = "MULTIACTIONBAR2BUTTON%d",
		[6] = "MULTIACTIONBAR1BUTTON%d",
		[13] = "MULTIACTIONBAR5BUTTON%d",
		[14] = "MULTIACTIONBAR6BUTTON%d",
		[15] = "MULTIACTIONBAR7BUTTON%d",
	}
	for _, i in ipairs(ActionBarsMod.LIST_ACTIONBARS) do
		if BLIZZ_MAPPINGS[i] then
			for k = 1, 12 do
				actions[#actions + 1] = BLIZZ_MAPPINGS[i]:format(k)
			end
		end
	end
	for k = 1, 10 do
		actions[#actions + 1] = ("BONUSACTIONBUTTON%d"):format(k) -- Pet Bar
		actions[#actions + 1] = ("SHAPESHIFTBUTTON%d"):format(k) -- Stance Bar
	end

	s_allBindingActions = actions
	return actions
end

function BT4KC:OnEnable()
	if UNSUPPORTED then return end
	self:RegisterEvent("UPDATE_BINDINGS", "SaveCurrentBindings")
	self:RegisterEvent("PLAYER_LOGOUT", "OnPlayerLogout")
	-- PLAYER_ENTERING_WORLD clears _loggingOut if a queued logout was cancelled
	-- (queue pop, BG entry, /afk cancel). Without this, the flag would stay
	-- true for the rest of the session and SaveCurrentBindings would silently
	-- no-op on every UPDATE_BINDINGS, losing edits made post-cancel.
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnPlayerEnteringWorld")
	self:SaveCurrentBindings()
end

local function tCompare(t1, t2)
	if type(t1) ~= type(t2) then return false end
	if type(t1) ~= "table" then return t1 == t2 end
	for k, v in pairs(t1) do
		if not tCompare(v, t2[k]) then return false end
	end
	for k in pairs(t2) do
		if t1[k] == nil then return false end
	end
	return true
end

function BT4KC:SaveCurrentBindings()
	-- Debounce: coalesce a burst of UPDATE_BINDINGS into a single save.
	-- The cancellable timer handle (vs. C_Timer.After) lets OnPlayerLogout
	-- cancel a pending save so it can't fire post-logout against torn-down
	-- AceDB state. The _loggingOut short-circuit covers UPDATE_BINDINGS that
	-- Blizzard may fire during logout shutdown.
	if self._loggingOut or self._saveTimer then return end
	self._saveTimer = C_Timer.NewTimer(0.5, function()
		self._saveTimer = nil
		self:DoSaveCurrentBindings()
	end)
end

function BT4KC:OnPlayerLogout()
	-- PLAYER_LOGOUT is the last reliable SavedVariables write window. Cancel
	-- any pending debounced save, mark the module as logging-out so a late
	-- UPDATE_BINDINGS doesn't re-arm the timer, then flush synchronously.
	self._loggingOut = true
	if self._saveTimer then
		self._saveTimer:Cancel()
		self._saveTimer = nil
	end
	self:DoSaveCurrentBindings()
end

function BT4KC:OnPlayerEnteringWorld()
	-- A queued logout that the user cancelled (e.g., queue pop, BG entry,
	-- /afk cancel) leaves _loggingOut stuck true with no PLAYER_LOGOUT to
	-- balance it. PLAYER_ENTERING_WORLD reliably fires after such cancels,
	-- so we use it to lift the gate.
	self._loggingOut = nil
end

function BT4KC:DoSaveCurrentBindings()
	-- Only save when the per-character binding set (2) is active. On set 1 the
	-- active bindings ARE the account-wide bindings; writing them into
	-- db.char.savedBindings would expose account-wide bindings as a per-character
	-- copy source for other characters (see GetAvailableCharacters / CopyBindingsFrom).
	if (GetCurrentBindingSet() or 1) ~= 2 then return end

	-- Mark the character as initialized so a future toggle ON via our UI won't
	-- clobber pre-existing bindings (set up either at login, via Blizzard's UI,
	-- or via our own first-time copy).
	Bartender4.db.char.charBindingsInitialized = true

	local saved = {}
	for _, action in ipairs(GetAllBT4BindingActions()) do
		local k1, k2, k3, k4 = GetBindingKey(action)
		if k1 then
			saved[action] = { k1, k2, k3, k4 }
		end
	end
	
	-- Change detection: only update if data is different to avoid excessive SavedVariables churn
	if not tCompare(saved, Bartender4.db.char.savedBindings) then
		Bartender4.db.char.savedBindings = saved
	end
end

function BT4KC:GetCurrentCharKey()
	return UnitName("player") .. " - " .. GetRealmName()
end

function BT4KC:GetAvailableCharacters()
	local rawDB = _G["Bartender4DB"]
	local chars = {}
	if rawDB and rawDB.char then
		local myKey = self:GetCurrentCharKey()
		for key, data in pairs(rawDB.char) do
			if key ~= myKey and data.savedBindings and next(data.savedBindings) then
				chars[key] = key
			end
		end
	end
	return chars
end

function BT4KC:CopyBindingsFrom(charKey, expectedSet)
	if InCombatLockdown() then
		Bartender4:Print(L["Cannot copy keybindings during combat."])
		return false
	end

	-- Re-verify binding-set context. The popup OnAccept already checks this,
	-- but defending here covers other callers and any further drift between
	-- the OnAccept check and our SaveBindings call below.
	if expectedSet and (GetCurrentBindingSet() or 1) ~= expectedSet then
		Bartender4:Print(L["Binding set changed since this dialog was opened; keybind copy cancelled."])
		return false
	end

	local rawDB = _G["Bartender4DB"]
	if not rawDB or not rawDB.char or not rawDB.char[charKey] then
		Bartender4:Print(L["Error: Character data not found for %s."]:format(charKey))
		return false
	end
	
	local bindings = rawDB.char[charKey].savedBindings
	if not bindings then
		Bartender4:Print(L["Error: No saved bindings found for %s."]:format(charKey))
		return false
	end

	local bindingFailed, failedCount = false, 0

	-- Suppress the ActionBars:ReassignBindings -> SaveBindings cascade during
	-- the multi-step rewrite. Each SetBinding below fires UPDATE_BINDINGS, and
	-- without suppression a mid-rewrite cascade SaveBindings could persist a
	-- half-applied state to disk. Save-and-restore the flag (not just nil-out)
	-- so nested transitions don't have their outer suppression cancelled by an
	-- inner clear. pcall + restore keeps the flag from sticking on error.
	local prevSuppress = Bartender4._suppressBindingCascade
	Bartender4._suppressBindingCascade = true
	local ok, err = pcall(function()
		-- Build the clear set as the union of the local action universe AND
		-- the source's recorded actions. If the source character had a
		-- different LIST_ACTIONBARS layout, the local s_allBindingActions list
		-- alone would leave stale bindings on actions the source doesn't know
		-- about. Conversely, the local list covers actions the source unbound
		-- but exist locally.
		local clearSet = {}
		for _, action in ipairs(GetAllBT4BindingActions()) do
			clearSet[action] = true
		end
		for action in pairs(bindings) do
			clearSet[action] = true
		end

		-- Clear existing bindings on the union set.
		for action in pairs(clearSet) do
			local k1, k2, k3, k4 = GetBindingKey(action)
			local boundKeys = { k1, k2, k3, k4 }
			for i = 1, 4 do
				local key = boundKeys[i]
				if key and key ~= "" then
					local r = SetBinding(key)
					if not r then
						bindingFailed = true
						failedCount = failedCount + 1
					end
				end
			end
		end

		-- Apply copied bindings. Pre-unbind each key globally before re-binding
		-- it to the new action; this matches the pattern in Options.lua and
		-- prevents leaving displaced non-BT4 commands in opaque slot states
		-- (SetBinding's slot-fill behavior when the key is already bound to a
		-- different command is not documented).
		for action, keys in pairs(bindings) do
			-- legacy: older saves stored a bare string instead of an array
			if type(keys) == "string" and keys ~= "" then
				keys = { keys }
			end

			if type(keys) == "table" then
				for i = 1, 4 do
					local key = keys[i]
					if key and key ~= "" then
						SetBinding(key)
						local r = SetBinding(key, action)
						if not r then
							bindingFailed = true
							failedCount = failedCount + 1
						end
					end
				end
			end
		end

		SaveBindings(GetCurrentBindingSet() or 1)
	end)
	Bartender4._suppressBindingCascade = prevSuppress
	if not ok then
		-- Surface to BugSack / BugGrabber / scriptErrors so the error and its
		-- traceback are captured. Then print a fork-specific chat summary so
		-- the user knows a Lua error occurred (without BugSack they'd only see
		-- the standard error popup, which is easy to miss in combat or under
		-- other UI noise). Return false so the popup OnAccept falls into its
		-- existing "Could not copy from %s" branch and the source selector
		-- stays populated for a retry -- same behavior as the early-return
		-- hard fails above (combat, missing data).
		(geterrorhandler() or function() end)(err)
		Bartender4:Print(L["Internal error during keybind copy; your bindings may be in a partial state. See the error log for details."])
		return false
	end

	-- Return contract: `true, failedCount` on success (failedCount == 0 means
	-- full success; > 0 means partial). Reserve `false` for hard fails (combat,
	-- missing data, pcall trap) handled in the early returns above. This avoids
	-- OnAccept routing partial-success through the "Could not copy" branch.
	return true, failedCount
end

function BT4KC:SetupOptions()
	if UNSUPPORTED then
		-- Surface a one-line explanation in the options tree on clients that
		-- don't support per-character binding sets (e.g., older Classic Era
		-- builds where GetCurrentBindingSet doesn't exist) rather than silently
		-- hiding the group.
		self.options = {
			type = "group",
			name = L["Copy Keybinds from Character"],
			guiInline = true,
			args = {
				unsupported = {
					order = 1,
					type = "description",
					name = L["Per-character keybinds are not supported on this WoW client."],
				},
			},
		}
		Bartender4:RegisterModuleOptions("KeyBindCopy", self.options)
		return
	end
	if not self.options then
		self.options = {
			type = "group",
			name = L["Copy Keybinds from Character"],
			guiInline = true,
			hidden = function() return (GetCurrentBindingSet() or 1) ~= 2 end,
			args = {
				note = {
					order = 1,
					type = "description",
					name = L["Copy Bartender4 keybindings from another character. The source character must have logged in at least once with this version of Bartender4.\n"],
				},
				source = {
					order = 2,
					type = "select",
					name = L["Source Character"],
					desc = L["Select the character to copy keybindings from."],
					width = "full",
					get = function()
						local source = Bartender4.db.profile.keybindCopySource
						if not source then return nil end
						local chars = self:GetAvailableCharacters()
						return chars[source] and source or nil
					end,
					set = function(info, value) Bartender4.db.profile.keybindCopySource = value end,
					values = function()
						return self:GetAvailableCharacters()
					end,
				},
				copy = {
					order = 3,
					type = "execute",
					name = L["Copy Keybinds"],
					desc = L["Copy keybindings from the selected character. This will overwrite your current Bartender4 keybindings."],
					disabled = function()
						return not Bartender4.db.profile.keybindCopySource or InCombatLockdown()
					end,
					func = function()
						local source = Bartender4.db.profile.keybindCopySource
						if source then
							-- Capture the current binding set at popup-open time and pass
							-- it through `data` so OnAccept can verify the user hasn't
							-- toggled between Show and accept.
							local popupData = { charKey = source, expectedSet = GetCurrentBindingSet() or 1 }
							StaticPopup_Show("BARTENDER4_CONFIRM_KEYBIND_COPY", source, nil, popupData)
						end
					end,
				},
			},
		}
	end
	Bartender4:RegisterModuleOptions("KeyBindCopy", self.options)
end
