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

-- Resolve at call time so a runtime replacement of the API is honored.
local function SaveBindings(...) return (_G.SaveBindings or _G.AttemptToSaveBindings)(...) end

local L = LibStub("AceLocale-3.0"):GetLocale("Bartender4")

-- Static Popup for safety
StaticPopupDialogs["BARTENDER4_CONFIRM_KEYBIND_COPY"] = {
	text = L["Are you sure you want to overwrite your current keybindings with those from %s? This cannot be undone."],
	button1 = _G.YES,
	button2 = _G.NO,
	OnAccept = function(self, data)
		if BT4KC:CopyBindingsFrom(data) then
			Bartender4:Print((L["Keybindings copied from %s."]):format(data))
			Bartender4.db.profile.keybindCopySource = nil
			LibStub("AceConfigRegistry-3.0"):NotifyChange("Bartender4")
		end
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
	self:RegisterEvent("UPDATE_BINDINGS", "SaveCurrentBindings")
	self:RegisterEvent("PLAYER_LOGOUT", "OnPlayerLogout")
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

function BT4KC:CopyBindingsFrom(charKey)
	if InCombatLockdown() then
		Bartender4:Print(L["Cannot copy keybindings during combat."])
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

	-- Clear existing BT4 bindings
	for _, action in ipairs(GetAllBT4BindingActions()) do
		local k1, k2, k3, k4 = GetBindingKey(action)
		local boundKeys = { k1, k2, k3, k4 }
		for i = 1, 4 do
			local key = boundKeys[i]
			if key and key ~= "" then
				local ok = SetBinding(key)
				if not ok then
					bindingFailed = true
					failedCount = failedCount + 1
				end
			end
		end
	end

	-- Apply copied bindings
	for action, keys in pairs(bindings) do
		-- legacy: older saves stored a bare string instead of an array
		if type(keys) == "string" and keys ~= "" then
			keys = { keys }
		end

		if type(keys) == "table" then
			for i = 1, 4 do
				local key = keys[i]
				if key and key ~= "" then
					local ok = SetBinding(key, action)
					if not ok then
						bindingFailed = true
						failedCount = failedCount + 1
					end
				end
			end
		end
	end

	SaveBindings(GetCurrentBindingSet() or 1)
	if bindingFailed then return nil, failedCount else return true end
end

function BT4KC:SetupOptions()
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
							StaticPopup_Show("BARTENDER4_CONFIRM_KEYBIND_COPY", source, nil, source)
						end
					end,
				},
			},
		}
	end
	Bartender4:RegisterModuleOptions("KeyBindCopy", self.options)
end
