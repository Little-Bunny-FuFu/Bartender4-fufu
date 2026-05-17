--[[
	Copyright (c) 2009-2017, Hendrik "Nevcairiel" Leppkes < h.leppkes at gmail dot com >
	All rights reserved.
]]
local _, Bartender4 = ...
local BT4KC = Bartender4:NewModule("KeyBindCopy", "AceEvent-3.0")

-- GLOBALS: Bartender4DB, UnitName, GetRealmName, GetBindingKey, SetBinding, SaveBindings, AttemptToSaveBindings, GetCurrentBindingSet, InCombatLockdown
-- GLOBALS: GetNumBindings, GetBinding, LoadBindings, StaticPopupDialogs, StaticPopup_Show, geterrorhandler
-- GLOBALS: CreateFrame, UIParent, BackdropTemplateMixin, KeyboundDialog, KeyboundDialogCheck
-- GLOBALS: UIDropDownMenu_CreateInfo, UIDropDownMenu_AddButton, UIDropDownMenu_Initialize, ToggleDropDownMenu, CloseDropDownMenus

local _G = _G
local pairs, ipairs, next, type = pairs, ipairs, next, type
local sort = table.sort
local format = string.format
local GetBindingKey = GetBindingKey
local SetBinding = SetBinding
local GetCurrentBindingSet = GetCurrentBindingSet
local InCombatLockdown = InCombatLockdown
local GetNumBindings, GetBinding, LoadBindings = GetNumBindings, GetBinding, LoadBindings
local CreateFrame = CreateFrame

-- Capability gate: older Classic Era builds may lack GetCurrentBindingSet
-- entirely. Without it, per-character binding slots aren't supported and the
-- entire copy / save / restore pipeline is meaningless. Flag once at load.
local UNSUPPORTED = (type(GetCurrentBindingSet) ~= "function")

-- Resolve at call time so a runtime replacement of the API is honored.
local function SaveBindings(...) return (_G.SaveBindings or _G.AttemptToSaveBindings)(...) end

local L = LibStub("AceLocale-3.0"):GetLocale("Bartender4")
local LKB = LibStub("LibKeyBound-1.0", true)

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
		if BT4KC.RefreshKeyboundDialogUI then BT4KC:RefreshKeyboundDialogUI() end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

-- Confirm popup for the promote action. The old AceConfig button used
-- `confirm=true`; the raw dialog button needs an explicit StaticPopup.
StaticPopupDialogs["BARTENDER4_CONFIRM_PROMOTE_KEYBINDS"] = {
	text = L["This will overwrite your account-wide keybindings with your current character-specific keybindings. Continue?"],
	button1 = _G.YES,
	button2 = _G.NO,
	OnAccept = function() BT4KC:PromoteCharToAccount() end,
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
	-- Attach our controls to LibKeyBound's "Binding Mode" dialog. The callback
	-- fires on every Activate() (every dialog open); the UI build it triggers
	-- is one-shot/idempotent, the refresh runs each open.
	if LKB and LKB.RegisterCallback then
		LKB.RegisterCallback(self, "LIBKEYBOUND_ENABLED", "OnKeyBoundEnabled")
	end
	-- Combat flips the dialog buttons' enable-state (and is exactly when the
	-- in-function guards reject a click). LibKeyBound toggles the dialog's
	-- visibility on REGEN, but :Show() on an already-shown dialog fires no
	-- OnShow, so the OnShow hook alone cannot keep the annex truthful across
	-- combat entered while it is open. Refresh on the transitions directly
	-- (RefreshKeyboundDialogUI is a no-op until built and while hidden).
	self:RegisterEvent("PLAYER_REGEN_DISABLED", "RefreshKeyboundDialogUI")
	self:RegisterEvent("PLAYER_REGEN_ENABLED", "RefreshKeyboundDialogUI")
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
			-- Bartender4DB is untrusted (hand-edited / stale / corrupt): a
			-- non-table `data` would error on `.savedBindings`, and a non-string
			-- key must not become a selectable copy source.
			if type(key) == "string" and key ~= myKey and type(data) == "table"
				and type(data.savedBindings) == "table" and next(data.savedBindings) then
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
	if type(bindings) ~= "table" then
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
		-- `bindings` is another character's saved DB -- untrusted. Only string
		-- action names are safe to feed into GetBindingKey/SetBinding; keep the
		-- full union (no local allow-list) so a source with a different bar
		-- layout still copies in full.
		for action in pairs(bindings) do
			if type(action) == "string" then
				clearSet[action] = true
			end
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

			if type(action) == "string" and type(keys) == "table" then
				for i = 1, 4 do
					local key = keys[i]
					if type(key) == "string" and key ~= "" then
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
	if not prevSuppress then
		local AB = Bartender4:GetModule("ActionBars", true)
		if AB and AB.FlushPendingReassign then AB:FlushPendingReassign() end
	end
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

-- Fork-safe per-character binding-set transition. Ported verbatim (logic and
-- rationale) from the former Options.lua "Character Specific Keybinds" toggle;
-- it is now the single implementation, driven by the rewired LibKeyBound
-- "Binding Mode" dialog checkbox. `enable` true => character set (2), false =>
-- account set (1). Immediate and committed (SaveBindings is part of the
-- transition), matching the old options-panel toggle's behaviour.
function BT4KC:SetCharacterSpecific(enable)
	if InCombatLockdown() then return end

	-- Raw integer set ids: account == 1, character == 2.
	local targetSet  = enable and 2 or 1
	local currentSet = GetCurrentBindingSet() or 1

	if targetSet == currentSet then
		-- Already in desired state (e.g., stale checkbox); just refresh.
		if enable then
			Bartender4.db.char.charBindingsInitialized = true
		end
		LibStub("AceConfigRegistry-3.0"):NotifyChange("Bartender4")
		return
	end

	-- Suppress the ActionBars:ReassignBindings -> SaveBindings cascade during
	-- the whole transition. Each SetBinding / LoadBindings call below fires
	-- UPDATE_BINDINGS, and a cascade SaveBindings firing between LoadBindings(N)
	-- and the trailing SaveBindings(N) could persist to the wrong on-disk slot.
	-- Save-and-restore (not nil-out) so a nested transition's outer suppression
	-- isn't cancelled by the inner clear. pcall + restore keeps the flag from
	-- sticking on error.
	local _prevSuppress = Bartender4._suppressBindingCascade
	Bartender4._suppressBindingCascade = true
	local _ok, _err = pcall(function()
	if enable and not Bartender4.db.char.charBindingsInitialized then
		-- First-time activation: snapshot current (account) bindings and copy
		-- them onto set 2. The init flag is what stops a later toggle OFF->ON
		-- from overwriting character-specific customizations (bindings imported
		-- via "Copy Keybinds from Character" or rebound while set 2 was active).
		-- To force a re-copy after the first activation (e.g. to recover from a
		-- corrupted set 2 left by older buggy code), run
		--   /run Bartender4.db.char.charBindingsInitialized = false
		-- then toggle OFF and ON.
		--
		-- Use GetBindingKey (up to 4 keys) instead of GetBinding's 2-key tuple
		-- -- the original v0 snapshot loop only captured key1/key2 and is the
		-- most likely source of historical alt-slot wipes on this character.
		local snapshot = {}
		for i = 1, GetNumBindings() do
			local command = GetBinding(i)
			if command then
				local k1, k2, k3, k4 = GetBindingKey(command)
				if k1 or k2 or k3 or k4 then
					snapshot[command] = { k1, k2, k3, k4 }
				end
			end
		end

		-- Activate set 2 BEFORE the restore loop. Each SetBinding fires
		-- UPDATE_BINDINGS, and ActionBars:ReassignBindings may call
		-- SaveBindings(GetCurrentBindingSet()). Activating set 2 first
		-- guarantees those cascading writes hit disk[2] and cannot corrupt the
		-- account set on disk[1].
		SaveBindings(1)
		LoadBindings(2)
		SaveBindings(2)

		-- Clear EVERY key currently bound in set 2's in-memory state before
		-- applying the snapshot. A per-command unbind would leak bindings for
		-- commands present in set 2's loaded disk state but absent from the
		-- snapshot. The clear also guarantees slot order on re-apply:
		-- SetBinding's slot-fill behaviour when a command already has bindings
		-- is opaque, and that was the observed alt-slot wipe.
		for i = 1, GetNumBindings() do
			local command = GetBinding(i)
			if command then
				local e1, e2, e3, e4 = GetBindingKey(command)
				if e1 and e1 ~= "" then SetBinding(e1) end
				if e2 and e2 ~= "" then SetBinding(e2) end
				if e3 and e3 ~= "" then SetBinding(e3) end
				if e4 and e4 ~= "" then SetBinding(e4) end
			end
		end

		for command, keys in pairs(snapshot) do
			for i = 1, 4 do
				local key = keys[i]
				if key and key ~= "" then
					SetBinding(key, command)
				end
			end
		end

		SaveBindings(2)
		Bartender4.db.char.charBindingsInitialized = true
	elseif enable then
		-- Subsequent activation: restore the user's previously-saved set 2 from
		-- disk. Preserves character-specific customizations across OFF/ON.
		SaveBindings(1)
		LoadBindings(2)
		SaveBindings(2)
	else
		-- Switching character -> account. Flush set 2 (preserve in-memory edits
		-- since the last save), then load and activate set 1.
		SaveBindings(2)
		LoadBindings(1)
		SaveBindings(1)
	end
	end)
	Bartender4._suppressBindingCascade = _prevSuppress
	if not _prevSuppress then
		local AB = Bartender4:GetModule("ActionBars", true)
		if AB and AB.FlushPendingReassign then AB:FlushPendingReassign() end
	end
	if not _ok then
		-- Surface to BugSack / scriptErrors AND show a clean in-game summary.
		(geterrorhandler() or function() end)(_err)
		Bartender4:Print(L["Internal error during binding-set transition; your bindings may be in a partial state. See the error log for details."])
	end

	LibStub("AceConfigRegistry-3.0"):NotifyChange("Bartender4")
end

-- Promote: write the current set-2 in-memory bindings into disk[1] so the
-- account set matches the character set, then reactivate set 2. After this,
-- toggling per-character OFF preserves the user's bindings (both sets in sync).
-- Ported verbatim from the former Options.lua "Copy Character Keybinds to
-- Account" button.
function BT4KC:PromoteCharToAccount()
	if InCombatLockdown() then return end
	if (GetCurrentBindingSet() or 1) ~= 2 then return end
	local _prevSuppress = Bartender4._suppressBindingCascade
	Bartender4._suppressBindingCascade = true
	local _ok, _err = pcall(function()
		SaveBindings(1)  -- memory->disk[1]; this also activates set 1
		LoadBindings(2)  -- memory<-disk[2] (should equal current memory)
		SaveBindings(2)  -- reactivate set 2
	end)
	Bartender4._suppressBindingCascade = _prevSuppress
	if not _prevSuppress then
		local AB = Bartender4:GetModule("ActionBars", true)
		if AB and AB.FlushPendingReassign then AB:FlushPendingReassign() end
	end
	if not _ok then
		(geterrorhandler() or function() end)(_err)
		Bartender4:Print(L["Internal error during keybind promote; your bindings may be in a partial state. See the error log for details."])
	end
	LibStub("AceConfigRegistry-3.0"):NotifyChange("Bartender4")
end

-- LibKeyBound fires LIBKEYBOUND_ENABLED on every Activate() (every time the
-- "Binding Mode" dialog opens). By then LibKeyBound:Initialize() has created
-- the global KeyboundDialog frame, so this is the safe point to lazily (once)
-- attach our controls and (every open) refresh their state.
function BT4KC:OnKeyBoundEnabled()
	if UNSUPPORTED then return end
	self:EnsureKeyboundDialogUI()
	self:RefreshKeyboundDialogUI()
end

local function BuildSourceMenu(_, level)
	if not level then return end
	local chars = BT4KC:GetAvailableCharacters()
	local keys = {}
	for k in pairs(chars) do keys[#keys + 1] = k end
	sort(keys)
	for _, key in ipairs(keys) do
		local info = UIDropDownMenu_CreateInfo()
		info.text = key
		info.notCheckable = true
		info.func = function()
			-- Reuse the existing confirm path. Capture the binding set at
			-- popup-open time so OnAccept can detect a mid-dialog toggle
			-- (StaticPopup_Show is async).
			local popupData = { charKey = key, expectedSet = (GetCurrentBindingSet() or 1) }
			StaticPopup_Show("BARTENDER4_CONFIRM_KEYBIND_COPY", key, nil, popupData)
			CloseDropDownMenus()
		end
		UIDropDownMenu_AddButton(info, level)
	end
end

-- Build (once) the controls attached to LibKeyBound's "Binding Mode" dialog,
-- and rewire the dialog's stock "Character Specific Keybindings" checkbox to
-- the fork-safe transition. Idempotent: guarded by _kbUIBuilt.
function BT4KC:EnsureKeyboundDialogUI()
	if self._kbUIBuilt then return end
	local dialog = _G.KeyboundDialog
	if not dialog then return end  -- retry on a later LIBKEYBOUND_ENABLED

	-- Annex: a child panel hung directly below the stock dialog. Parenting to
	-- the dialog makes it show/hide and drag with it; anchoring BELOW it means
	-- we never reflow LibKeyBound's own widgets (keeps the lib pristine -- the
	-- whole reason this lives addon-side instead of in the library).
	local annex = CreateFrame("Frame", "BT4KCKeyboundAnnex", dialog,
		BackdropTemplateMixin and "BackdropTemplate" or nil)
	annex:SetFrameStrata("DIALOG")
	annex:SetPoint("TOPLEFT", dialog, "BOTTOMLEFT", 0, 4)
	annex:SetPoint("TOPRIGHT", dialog, "BOTTOMRIGHT", 0, 4)
	annex:SetHeight(86)
	-- The dialog is SetClampedToScreen(true) but the annex hangs ~90px BELOW
	-- it; without extending the clamp, the annex (its only controls) can be
	-- dragged off the bottom of the screen and become unreachable. Negative
	-- bottom inset moves the clamp boundary outward to cover the child.
	dialog:SetClampRectInsets(0, 0, 0, -90)
	annex:SetBackdrop{
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
		tileSize = 32,
		edgeSize = 32,
	}

	local promoteBtn = CreateFrame("Button", "BT4KCPromoteButton", annex, "UIPanelButtonTemplate")
	promoteBtn:SetHeight(22)
	promoteBtn:SetPoint("TOPLEFT", annex, "TOPLEFT", 16, -16)
	promoteBtn:SetPoint("TOPRIGHT", annex, "TOPRIGHT", -16, -16)
	promoteBtn:SetText(L["Copy Character Keybinds to Account"])
	promoteBtn:SetScript("OnClick", function()
		if InCombatLockdown() then
			Bartender4:Print(L["Cannot copy keybindings during combat."])
			return
		end
		StaticPopup_Show("BARTENDER4_CONFIRM_PROMOTE_KEYBINDS")
	end)

	local copyFromBtn = CreateFrame("Button", "BT4KCCopyFromButton", annex, "UIPanelButtonTemplate")
	copyFromBtn:SetHeight(22)
	copyFromBtn:SetPoint("TOPLEFT", promoteBtn, "BOTTOMLEFT", 0, -8)
	copyFromBtn:SetPoint("TOPRIGHT", promoteBtn, "BOTTOMRIGHT", 0, -8)
	copyFromBtn:SetText(L["Copy Keybinds from Character"])

	local sourceMenu = CreateFrame("Frame", "BT4KCSourceMenu", UIParent, "UIDropDownMenuTemplate")
	copyFromBtn:SetScript("OnClick", function(btn)
		if InCombatLockdown() then
			Bartender4:Print(L["Cannot copy keybindings during combat."])
			return
		end
		if not next(BT4KC:GetAvailableCharacters()) then return end
		UIDropDownMenu_Initialize(sourceMenu, BuildSourceMenu, "MENU")
		ToggleDropDownMenu(1, nil, sourceMenu, btn, 0, 0)
	end)

	self._kbAnnex = annex
	self._promoteBtn = promoteBtn
	self._copyFromBtn = copyFromBtn

	-- Rewire the stock "Character Specific Keybindings" checkbox to the
	-- fork-safe transition (snapshot / clear / cascade-suppress / init-flag),
	-- replacing LibKeyBound's naive LoadBindings/SaveBindings. SetScript (not
	-- HookScript) so the unsafe stock handler does NOT also run.
	--
	-- UICheckButtonTemplate flips :GetChecked() BEFORE OnClick, so it already
	-- reflects the user's intended new state. SetCharacterSpecific performs an
	-- immediate, committed transition; RefreshKeyboundDialogUI then re-derives
	-- the checkbox from the *actual* active set, so combat / no-op / failure
	-- snaps the visual back to truth.
	--
	-- LibKeyBound's own Okay (SaveBindings(set)) / Cancel
	-- (LoadBindings(GetCurrentBindingSet())) recompute their target at click
	-- time, so leaving them untouched is safe: after our transition the active
	-- set already equals the checkbox state, so Okay is a redundant re-save and
	-- Cancel only discards in-mode key edits, never the set switch (consistent
	-- with the fork's "toggle is immediate" model).
	local check = _G.KeyboundDialogCheck
	if check then
		check:SetScript("OnClick", function(cb)
			BT4KC:SetCharacterSpecific(cb:GetChecked() and true or false)
			BT4KC:RefreshKeyboundDialogUI()
		end)
	end

	-- Refresh whenever the dialog goes hidden->shown (a genuine reopen, and
	-- the combat-end Hide -> next Show cycle). This does NOT cover combat
	-- entered while the dialog is already visible (:Show() on a shown frame
	-- fires no OnShow) -- the PLAYER_REGEN_* handlers (OnEnable) cover that.
	-- HookScript is additive: LibKeyBound's own OnShow (a sound) still runs.
	dialog:HookScript("OnShow", function() BT4KC:RefreshKeyboundDialogUI() end)

	self._kbUIBuilt = true
end

-- Re-derive every dynamic bit of the dialog UI from the *actual* engine state:
-- the checkbox from the active binding set, the buttons' enabled state from
-- combat / set / available-source-character. Called on dialog open, after the
-- checkbox toggle, and after a copy completes.
function BT4KC:RefreshKeyboundDialogUI()
	if not self._kbUIBuilt then return end
	-- Nothing visible to refresh if the dialog is off-screen; this also makes
	-- the PLAYER_REGEN_* handlers free outside an open binding session.
	local _kbd = _G.KeyboundDialog
	if not _kbd or not _kbd:IsShown() then return end
	local onSet2 = (GetCurrentBindingSet() or 1) == 2
	local combat = InCombatLockdown()

	local check = _G.KeyboundDialogCheck
	if check then check:SetChecked(onSet2) end

	if self._promoteBtn then
		if (not combat) and onSet2 then
			self._promoteBtn:Enable()
		else
			self._promoteBtn:Disable()
		end
	end
	if self._copyFromBtn then
		-- Parity with the old AceConfig group, which was hidden unless set 2
		-- was active: copying a source character's bindings while on set 1
		-- would overwrite the account-wide set, which is not the intent.
		local hasChars = next(self:GetAvailableCharacters()) ~= nil
		if (not combat) and onSet2 and hasChars then
			self._copyFromBtn:Enable()
		else
			self._copyFromBtn:Disable()
		end
	end
end
