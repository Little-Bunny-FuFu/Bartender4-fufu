--[[
	Copyright (c) 2009-2017, Hendrik "Nevcairiel" Leppkes < h.leppkes at gmail dot com >
	All rights reserved.
]]
local _, Bartender4 = ...
local BT4KC = Bartender4:NewModule("KeyBindCopy", "AceEvent-3.0")

-- GLOBALS: Bartender4DB, UnitName, GetRealmName, GetBindingKey, SetBinding, SaveBindings, GetCurrentBindingSet, InCombatLockdown

local _G = _G
local select, pairs, ipairs, next = select, pairs, ipairs, next
local GetBindingKey = GetBindingKey
local SetBinding = SetBinding
local SaveBindings = SaveBindings or AttemptToSaveBindings
local GetCurrentBindingSet = GetCurrentBindingSet

local s_allBindingActions = nil
local function GetAllBT4BindingActions()
	if s_allBindingActions then return s_allBindingActions end
	local actions = {}
	local ActionBarsMod = Bartender4:GetModule("ActionBars")
	for _, i in ipairs(ActionBarsMod.LIST_ACTIONBARS) do
		for k = 1, 12 do
			actions[#actions + 1] = ("CLICK BT4Button%d:Keybind"):format(((i-1)*12)+k)
		end
	end
	for k = 1, 10 do
		actions[#actions + 1] = ("CLICK BT4PetButton%d:LeftButton"):format(k)
		actions[#actions + 1] = ("CLICK BT4StanceButton%d:LeftButton"):format(k)
	end
	s_allBindingActions = actions
	return actions
end

function BT4KC:OnEnable()
	self:RegisterEvent("UPDATE_BINDINGS", "SaveCurrentBindings")
	self:SaveCurrentBindings()
end

function BT4KC:SaveCurrentBindings()
	local saved = {}
	for _, action in ipairs(GetAllBT4BindingActions()) do
		local keys = { GetBindingKey(action) }
		if #keys > 0 then
			saved[action] = keys
		end
	end
	Bartender4.db.char.savedBindings = saved
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
		Bartender4:Print("Cannot copy keybindings during combat.")
		return false
	end

	local rawDB = _G["Bartender4DB"]
	if not rawDB or not rawDB.char or not rawDB.char[charKey] then return false end
	local bindings = rawDB.char[charKey].savedBindings
	if not bindings then return false end

	-- Clear existing BT4 bindings
	for _, action in ipairs(GetAllBT4BindingActions()) do
		local boundKeys = { GetBindingKey(action) }
		for _, key in ipairs(boundKeys) do
			if key ~= "" then
				SetBinding(key)
			end
		end
	end

	-- Apply copied bindings
	for action, keys in pairs(bindings) do
		for _, key in ipairs(keys) do
			SetBinding(key, action)
		end
	end

	SaveBindings(GetCurrentBindingSet() or 1)
	return true
end
