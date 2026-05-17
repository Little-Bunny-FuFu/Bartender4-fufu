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

-- ---------------------------------------------------------------------------
-- Keybind export/import wire format (Phase 1). See the Keybind Import/Export
-- plan, sections 0.6 (security) and 0.8 (wire contract):
--   <prefix><EncodeForPrint(CompressDeflate(Serialize(
--            { v=, kind=, bindings={ [action]={k1..k4} } } )))>
-- Security: NO loadstring/load is ever applied to imported data -- LibSerialize
-- deserializes a binary format (no code execution) and the deserialized table
-- is NEVER used directly: DeserializeBindings rebuilds a fresh, fully
-- type/length/charset-validated table that is the only thing handed onward.
-- ---------------------------------------------------------------------------
local LibSerialize = LibStub("LibSerialize", true)
local LibDeflate   = LibStub("LibDeflate", true)
local AceGUI       = LibStub("AceGUI-3.0", true)
local KB_WIRE_PREFIX  = "!BT4KB1!"
local KB_WIRE_VERSION = 1
local KB_WIRE_KIND    = "bt4kb-keys"
local KB_MAX_IMPORT   = 200000  -- raw paste cap; defends the editbox path
local KB_MAX_ACTION   = 64      -- max action-string length
local KB_MAX_KEY      = 32      -- max key-token length
local KB_MAX_KEYS     = 4       -- GetBindingKey returns up to 4 keys
local KB_MAX_DECOMPRESSED = 1048576  -- [fufu sec M-001] inflated-byte cap (deflate-bomb DoS)
local KB_MAX_ENTRIES      = 1024     -- [fufu sec M-002] entry-cardinality cap (universe < 500)

-- Reject |, control chars and non-ASCII. Action/key tokens are constrained
-- printable-ASCII (see GetAllBT4BindingActions); space (0x20) is allowed
-- because action strings contain it (e.g. "CLICK BT4Button1:Keybind").
local function KB_IsCleanToken(s)
	return s:find("[^ -~]") == nil and s:find("|", 1, true) == nil
end

-- Returns: string (prefixed, paste-safe) | nil, errMsg
function BT4KC:SerializeBindings(bindings)
	if not (LibSerialize and LibDeflate) then
		return nil, L["Keybind import/export libraries are missing."]
	end
	local payload = { v = KB_WIRE_VERSION, kind = KB_WIRE_KIND, bindings = bindings }
	local serialized = LibSerialize:Serialize(payload)
	local compressed = LibDeflate:CompressDeflate(serialized)
	local encoded    = LibDeflate:EncodeForPrint(compressed)
	return KB_WIRE_PREFIX .. encoded
end

-- Returns: cleanTable { [action]={k1,..} } | nil, errMsg
-- Fail-closed at every stage; returns/applies nothing on any failure.
function BT4KC:DeserializeBindings(str)
	if not (LibSerialize and LibDeflate) then
		return nil, L["Keybind import/export libraries are missing."]
	end
	if type(str) ~= "string" or str == "" then
		return nil, L["No import string provided."]
	end
	if #str > KB_MAX_IMPORT then
		return nil, L["Import string is too large."]
	end
	str = str:match("^%s*(.-)%s*$") or str  -- strip paste whitespace/newlines
	-- [fufu] prefix/version probe assumes a single ASCII version digit
	-- (!BT4KB<d>!); a multi-digit bump must keep the prefix length stable
	-- or update KB_WIRE_PREFIX and the str:sub(1, 6) discriminator together.
	if str:sub(1, #KB_WIRE_PREFIX) ~= KB_WIRE_PREFIX then
		if str:sub(1, 6) == "!BT4KB" then
			return nil, L["This keybind string was made with a different version of Bartender4-fufu."]
		end
		return nil, L["This is not a Bartender4-fufu keybind string."]
	end
	local decoded = LibDeflate:DecodeForPrint(str:sub(#KB_WIRE_PREFIX + 1))
	if not decoded then
		return nil, L["Import string is corrupt or truncated."]
	end
	local decompressed = LibDeflate:DecompressDeflate(decoded)
	if not decompressed then
		return nil, L["Import string is corrupt or truncated."]
	end
	if #decompressed > KB_MAX_DECOMPRESSED then  -- [fufu sec M-001] deflate-bomb cap
		return nil, L["Import string is too large."]
	end
	local ok, payload = LibSerialize:Deserialize(decompressed)
	if not ok then
		return nil, L["Import string is corrupt or truncated."]
	end
	if type(payload) ~= "table"
		or payload.v ~= KB_WIRE_VERSION
		or payload.kind ~= KB_WIRE_KIND
		or type(payload.bindings) ~= "table" then
		return nil, L["This keybind string is not valid or is for a different feature."]
	end
	-- Rebuild a FRESH clean table; never hand on the raw deserialized one
	-- (security 0.6). Bad individual entries are skipped, not fatal; a
	-- payload yielding zero usable entries is rejected so a malformed or
	-- empty string can never silently wipe bindings via the union-clear.
	local clean, sawAny, count = {}, false, 0
	for action, keys in pairs(payload.bindings) do
		count = count + 1
		if count > KB_MAX_ENTRIES then  -- [fufu sec M-002] bound rebuild cardinality
			return nil, L["This keybind string is not valid or is for a different feature."]
		end
		if type(action) == "string" and #action > 0 and #action <= KB_MAX_ACTION
			and KB_IsCleanToken(action) and type(keys) == "table" then
			local list, n = {}, 0
			for i = 1, KB_MAX_KEYS do
				local k = keys[i]
				if type(k) == "string" and k ~= "" and #k <= KB_MAX_KEY and KB_IsCleanToken(k) then
					n = n + 1
					list[n] = k
				end
			end
			if n > 0 then
				clean[action] = list
				sawAny = true
			end
		end
	end
	if not sawAny then
		return nil, L["This keybind string is not valid or is for a different feature."]
	end
	return clean
end


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
		local sourceType, charKey, setName, expectedSet
		if type(data) == "table" then
			sourceType = data.sourceType
			charKey, setName, expectedSet = data.charKey, data.name, data.expectedSet
		else
			charKey = data -- legacy: string-only data from older callers
		end
		if expectedSet and (GetCurrentBindingSet() or 1) ~= expectedSet then
			Bartender4:Print(L["Binding set changed since this dialog was opened; keybind copy cancelled."])
			return
		end
		local ok, failedCount, srcLabel
		if sourceType == "set" then
			srcLabel = setName
			ok, failedCount = BT4KC:CopyBindingsFromSet(setName, expectedSet)
		else
			srcLabel = charKey
			ok, failedCount = BT4KC:CopyBindingsFrom(charKey, expectedSet)
		end
		if not ok then
			Bartender4:Print((L["Could not copy keybindings from %s."]):format(tostring(srcLabel)))
			return
		end
		if failedCount and failedCount > 0 then
			Bartender4:Print((L["Keybindings copied from %s (%d failed)."]):format(srcLabel, failedCount))
		else
			Bartender4:Print((L["Keybindings copied from %s."]):format(srcLabel))
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

-- Confirm popup for keybind IMPORT (Step 6). Mirrors the COPY popup async
-- pattern: expectedSet captured at open, re-checked in OnAccept (the user
-- could toggle Character Specific Keybinds between Show and accept).
StaticPopupDialogs["BARTENDER4_CONFIRM_KEYBIND_IMPORT"] = {
	text = L["Import these keybindings? This replaces your current Bartender4 keybinds on this character. This cannot be undone."],
	button1 = _G.YES,
	button2 = _G.NO,
	OnAccept = function(_, data)
		if type(data) ~= "table" or type(data.clean) ~= "table" then return end
		if InCombatLockdown() then
			Bartender4:Print(L["Cannot copy keybindings during combat."])
			return
		end
		if (GetCurrentBindingSet() or 1) ~= 2 then
			Bartender4:Print(L["Keybind copy/import requires per-character keybinds to be active."])
			return
		end
		if data.expectedSet and (GetCurrentBindingSet() or 1) ~= data.expectedSet then
			Bartender4:Print(L["Binding set changed since this dialog was opened; keybind copy cancelled."])
			return
		end
		local ok, failedCount = BT4KC:DoApplyBindings(data.clean)
		if not ok then
			Bartender4:Print(L["Could not import keybindings."])
			return
		end
		if failedCount and failedCount > 0 then
			Bartender4:Print((L["Keybindings imported (%d failed)."]):format(failedCount))
		else
			Bartender4:Print(L["Keybindings imported."])
		end
		if BT4KC.RefreshKeyboundDialogUI then BT4KC:RefreshKeyboundDialogUI() end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

-- Confirm popup: overwrite an existing named keybind set (Step 6 save-as).
StaticPopupDialogs["BARTENDER4_CONFIRM_KEYBIND_SETSAVE"] = {
	text = L["A keybind set named '%s' already exists. Overwrite it?"],
	button1 = _G.YES,
	button2 = _G.NO,
	OnAccept = function(_, data)
		if type(data) ~= "table" then return end
		local ok, saved = BT4KC:SaveKeybindSet(data.name, data.bindings)
		if ok then
			Bartender4:Print((L["Saved keybind set '%s'."]):format(tostring(saved)))
			if BT4KC.RefreshKeyboundDialogUI then BT4KC:RefreshKeyboundDialogUI() end
		else
			Bartender4:Print(L["Invalid set name."])
		end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

-- Blizzard default binding action that BT4 bar `i` intercepts (e.g. BT4
-- Bar 3 drives MULTIACTIONBAR3). Module scope so ActionsForBar and
-- GetAllBT4BindingActions share ONE source of truth (CLAUDE.md rule #2).
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

-- Action strings owned by BT4 action-bar `i`: its 12 CLICK BT4Button slots
-- plus, if BT4 intercepts a Blizzard bar at that index, the 12 mapped
-- Blizzard actions. Single source of truth for the full-universe
-- enumeration AND Step 6 granular export.
function BT4KC:ActionsForBar(i)
	local a = {}
	for k = 1, 12 do
		a[#a + 1] = ("CLICK BT4Button%d:Keybind"):format(((i-1)*12)+k)
	end
	if BLIZZ_MAPPINGS[i] then
		for k = 1, 12 do
			a[#a + 1] = BLIZZ_MAPPINGS[i]:format(k)
		end
	end
	return a
end

-- Pet bar action family (CLICK BT4PetButton + Blizzard BONUSACTIONBUTTON).
function BT4KC:PetActions()
	local a = {}
	for k = 1, 10 do
		a[#a + 1] = ("CLICK BT4PetButton%d:LeftButton"):format(k)
		a[#a + 1] = ("BONUSACTIONBUTTON%d"):format(k)
	end
	return a
end

-- Stance bar action family (CLICK BT4StanceButton + Blizzard SHAPESHIFTBUTTON).
function BT4KC:StanceActions()
	local a = {}
	for k = 1, 10 do
		a[#a + 1] = ("CLICK BT4StanceButton%d:LeftButton"):format(k)
		a[#a + 1] = ("SHAPESHIFTBUTTON%d"):format(k)
	end
	return a
end

local function KB_AppendAll(dst, src)
	for _, v in ipairs(src) do dst[#dst + 1] = v end
end

local s_allBindingActions = nil
local function GetAllBT4BindingActions()
	if s_allBindingActions then return s_allBindingActions end
	local actions = {}
	local ActionBarsMod = Bartender4:GetModule("ActionBars")
	-- Composed from the SAME ActionsForBar/PetActions/StanceActions helpers
	-- Step 6 granular export uses. The produced SET of action strings is
	-- identical to the previous implementation; only ORDER differs (grouped
	-- per-bar incl. its intercepted Blizzard mapping, then pet, then stance).
	-- Both consumers (BuildCurrentBindingsTable, DoApplyBindings clear-union)
	-- treat this as an unordered set, so the reordering is behavior-neutral
	-- (CLAUDE.md rule #2: consumers traced before the data-shape change).
	for _, i in ipairs(ActionBarsMod.LIST_ACTIONBARS) do
		KB_AppendAll(actions, BT4KC:ActionsForBar(i))
	end
	KB_AppendAll(actions, BT4KC:PetActions())
	KB_AppendAll(actions, BT4KC:StanceActions())
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

-- [fufu] Single constructor for "the current BT4 bindings as a table",
-- shape { [action] = { k1, k2, k3, k4 } } -- the SAME shape consumed by
-- DoApplyBindings / GetAvailableCharacters (CLAUDE.md rule #2). Shared by
-- DoSaveCurrentBindings (auto-save) and the Step 6 export (read-only --
-- export needs no set/combat gate).
function BT4KC:BuildCurrentBindingsTable()
	local saved = {}
	for _, action in ipairs(GetAllBT4BindingActions()) do
		local k1, k2, k3, k4 = GetBindingKey(action)
		if k1 then
			saved[action] = { k1, k2, k3, k4 }
		end
	end
	return saved
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

	local saved = self:BuildCurrentBindingsTable()

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

-- ---------------------------------------------------------------------------
-- [fufu] Account-wide named keybind set store (Phase 1). Sets live in
-- Bartender4.db.global.savedKeybindSets, keyed by sanitized display name:
--   [name] = { bindings = { [action]={k1..k4} }, meta = { created, char } }
-- `bindings` is the SAME shape as db.char.savedBindings so a named set
-- feeds the existing hardened DoApplyBindings path unchanged (rule #2).
-- ---------------------------------------------------------------------------
local KB_MAX_SETNAME = 50

local function KB_DeepCopy(t)
	if type(t) ~= "table" then return t end
	local c = {}
	for k, v in pairs(t) do c[k] = KB_DeepCopy(v) end
	return c
end

function BT4KC:GetSavedKeybindSets()
	local g = Bartender4.db and Bartender4.db.global
	if not g then return {} end
	if type(g.savedKeybindSets) ~= "table" then
		g.savedKeybindSets = {}
	end
	return g.savedKeybindSets
end

-- Returns: true, sanitizedName | false. Overwrite-by-name is allowed (the
-- Step 6 UI confirms on collision). A DEEP COPY is stored so a later
-- mutation of the caller's table (e.g. the live auto-save table) cannot
-- corrupt a saved set; KB_IsCleanToken (Step 2) rejects |/control/non-ASCII.
function BT4KC:SaveKeybindSet(name, bindings)
	if type(name) ~= "string" then return false end
	name = name:match("^%s*(.-)%s*$") or name
	if name == "" or #name > KB_MAX_SETNAME or not KB_IsCleanToken(name) then
		return false
	end
	if type(bindings) ~= "table" then return false end
	local store = self:GetSavedKeybindSets()
	store[name] = {
		bindings = KB_DeepCopy(bindings),
		meta = { created = time(), char = self:GetCurrentCharKey() },
	}
	return true, name
end

function BT4KC:DeleteKeybindSet(name)
	local store = self:GetSavedKeybindSets()
	if store[name] ~= nil then
		store[name] = nil
		return true
	end
	return false
end

-- Ordered, typed copy-source list for the annex picker: real characters
-- (via the hardened GetAvailableCharacters -- its foreign-DB type guards
-- are NOT duplicated or weakened here, only consumed) then account-wide
-- named keybind sets. type="char" -> {key,label}; type="set" -> {name,label}.
function BT4KC:GetCopySources()
	local list = {}
	local chars = self:GetAvailableCharacters()
	local ckeys = {}
	for k in pairs(chars) do ckeys[#ckeys + 1] = k end
	sort(ckeys)
	for _, k in ipairs(ckeys) do
		list[#list + 1] = { type = "char", key = k, label = k }
	end
	local sets = self:GetSavedKeybindSets()
	local skeys = {}
	for n in pairs(sets) do
		if type(n) == "string" then skeys[#skeys + 1] = n end
	end
	sort(skeys)
	for _, n in ipairs(skeys) do
		list[#list + 1] = { type = "set", name = n, label = "[" .. L["Set"] .. "] " .. n }
	end
	return list
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

	return self:DoApplyBindings(bindings)
end

-- Shared hardened binding-write path. Extracted verbatim from
-- CopyBindingsFrom (Step 3) so copy-from-character AND keybind import use
-- ONE implementation (no second SetBinding loop): union-clear (local action
-- universe + payload actions, string-typed only) -> pre-unbind + re-bind ->
-- SaveBindings, all under cascade suppression + pcall + the combat-exit
-- FlushPendingReassign drain + partial-failure counting. The CALLER must
-- have already passed the combat and binding-set guards. `bindings` is
-- untrusted (foreign DB or imported); only string action/key entries are
-- acted on. Returns: true, failedCount (0 = full, >0 = partial); false is
-- reserved for the pcall-trap hard fail (matches the early-return fails).
function BT4KC:DoApplyBindings(bindings)
	-- [fufu sec H-001] Complete-mediation binding-set-2 floor at the single
	-- write chokepoint. Applying on set 1 (account-wide) would clobber
	-- every character's account bindings (plan 0.6). The annex UI already
	-- disables copy on set 1 and callers re-check expectedSet, but this
	-- enforces the invariant HERE for ALL callers -- incl. the Step 6
	-- import path -- rather than delegating it to UI/caller state.
	if (GetCurrentBindingSet() or 1) ~= 2 then
		Bartender4:Print(L["Keybind copy/import requires per-character keybinds to be active."])
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

-- Apply an account-wide named keybind set through the SAME hardened
-- DoApplyBindings path as copy-from-character. Mirrors the CopyBindingsFrom
-- combat + binding-set guards (applying onto set 1 would clobber the
-- account-wide bindings). The stored bindings were deep-copied + sanitized
-- at SaveKeybindSet time and DoApplyBindings re-applies its own string
-- type-guards, so this is double-validated. Returns (true,failedCount)/false.
function BT4KC:CopyBindingsFromSet(name, expectedSet)
	if InCombatLockdown() then
		Bartender4:Print(L["Cannot copy keybindings during combat."])
		return false
	end
	if expectedSet and (GetCurrentBindingSet() or 1) ~= expectedSet then
		Bartender4:Print(L["Binding set changed since this dialog was opened; keybind copy cancelled."])
		return false
	end
	local sets = self:GetSavedKeybindSets()
	local entry = sets and sets[name]
	if type(entry) ~= "table" or type(entry.bindings) ~= "table" then
		Bartender4:Print((L["Error: No saved bindings found for %s."]):format(tostring(name)))
		return false
	end
	return self:DoApplyBindings(entry.bindings)
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
	local sources = BT4KC:GetCopySources()
	local lastType
	for _, src in ipairs(sources) do
		if src.type ~= lastType then
			local title = UIDropDownMenu_CreateInfo()
			title.isTitle = true
			title.notCheckable = true
			title.text = (src.type == "char") and L["Characters"] or L["Saved Sets"]
			UIDropDownMenu_AddButton(title, level)
			lastType = src.type
		end
		local entry = src
		local info = UIDropDownMenu_CreateInfo()
		info.text = entry.label
		info.notCheckable = true
		info.func = function()
			-- Reuse the hardened confirm path. Capture the binding set at
			-- popup-open time so OnAccept can detect a mid-dialog toggle
			-- (StaticPopup_Show is async).
			local expectedSet = (GetCurrentBindingSet() or 1)
			local popupData
			if entry.type == "set" then
				popupData = { sourceType = "set", name = entry.name, expectedSet = expectedSet }
			else
				popupData = { charKey = entry.key, expectedSet = expectedSet }
			end
			StaticPopup_Show("BARTENDER4_CONFIRM_KEYBIND_COPY", entry.label, nil, popupData)
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
		if #BT4KC:GetCopySources() == 0 then return end
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
		local hasSources = #self:GetCopySources() > 0
		if (not combat) and onSet2 and hasSources then
			self._copyFromBtn:Enable()
		else
			self._copyFromBtn:Disable()
		end
	end
end

-- Standalone AceGUI keybind Import/Export window (Step 6). NOT parented to /
-- hooked on KeyboundDialog or LibKeyBound callbacks (shared-lib lifecycle
-- hazard -- see fork lessons). Built once, reused (Hide on close, not
-- Release). Export is read-only (no combat/set gate). Import routes through
-- the hardened DoApplyBindings (intrinsic set-2 floor + the OnAccept combat
-- + expectedSet guards) -- no second SetBinding loop.
function BT4KC:OpenImportExportWindow()
	if not (LibSerialize and LibDeflate) then
		Bartender4:Print(L["Keybind import/export libraries are missing."])
		return
	end
	if not AceGUI then return end
	if self._ieFrame then
		self._ieFrame.frame:Show()
		return
	end

	local f = AceGUI:Create("Frame")
	f:SetTitle(L["Bartender4-fufu Keybind Import/Export"])
	f:SetLayout("Flow")
	f:SetWidth(560)
	f:SetHeight(460)
	-- Reuse: hide (do not Release) so the frame and its widgets persist.
	f:SetCallback("OnClose", function(widget) widget.frame:Hide() end)
	self._ieFrame = f

	local selected = {}   -- [barKey]=true, tracked from the multiselect dropdown

	local allCB = AceGUI:Create("CheckBox")
	allCB:SetLabel(L["All bars"])
	allCB:SetValue(true)
	allCB:SetFullWidth(true)
	f:AddChild(allCB)

	local barDD = AceGUI:Create("Dropdown")
	barDD:SetLabel(L["Bars to export"])
	barDD:SetMultiselect(true)
	barDD:SetFullWidth(true)
	local barList = {}
	local ABMod = Bartender4:GetModule("ActionBars")
	-- Order the dropdown to match BT4's "Action Bars" options section
	-- exactly: mirror Options/ActionBar.lua module:CreateBarOption's order
	-- (default 10+barID; on Retail the module-exposed BLIZZARD_BAR_MAP
	-- remaps Bar 2-8, Class Bars 7-10 -> 13+barID, Bonus(2) -> 19).
	-- RE-MERGE WATCH-ITEM: if upstream changes that order formula, mirror
	-- the change here (same discipline as the LibActionButton perf patch).
	local RETAIL = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)
	local function barOrderValue(id)
		local barID = tonumber(id)
		if RETAIL then
			if barID == 7 or barID == 8 or barID == 9 or barID == 10 then
				return 13 + barID
			elseif ABMod.BLIZZARD_BAR_MAP[barID] then
				return 10 + ABMod.BLIZZARD_BAR_MAP[barID]
			elseif barID == 2 then
				return 19
			end
		end
		return 10 + barID
	end
	local bars = {}
	for _, i in ipairs(ABMod.LIST_ACTIONBARS) do
		local key = "bar" .. i
		barList[key] = ABMod:GetBarName(i)
		bars[#bars + 1] = { key = key, ord = barOrderValue(i) }
	end
	sort(bars, function(a, b) return a.ord < b.ord end)
	local barOrder = {}
	for _, b in ipairs(bars) do barOrder[#barOrder + 1] = b.key end
	barList["pet"] = L["Pet Bar"]
	barOrder[#barOrder + 1] = "pet"
	barList["stance"] = L["Stance Bar"]
	barOrder[#barOrder + 1] = "stance"
	barDD:SetList(barList, barOrder)
	barDD:SetDisabled(true)
	barDD:SetCallback("OnValueChanged", function(_, _, key, checked)
		selected[key] = checked and true or nil
	end)
	f:AddChild(barDD)
	allCB:SetCallback("OnValueChanged", function(_, _, val)
		barDD:SetDisabled(val and true or false)
		if val then
			-- All re-checked: clear the per-bar selection so the greyed-out
			-- dropdown does not keep showing a stale listing. Functionally
			-- moot (selectedBindings() short-circuits to the full table when
			-- All is checked) but the stale display confused a tester.
			for k in pairs(selected) do selected[k] = nil end
			for _, k in ipairs(barOrder) do barDD:SetItemValue(k, false) end
		end
	end)

	local box = AceGUI:Create("MultiLineEditBox")
	box:SetLabel(L["Keybind string"])
	box:SetFullWidth(true)
	box:SetNumLines(8)
	box:DisableButton(true)
	f:AddChild(box)

	local function selectedBindings()
		local all = BT4KC:BuildCurrentBindingsTable()
		if allCB:GetValue() then return all end
		local want = {}
		for key, on in pairs(selected) do
			if on then
				if key == "pet" then
					for _, a in ipairs(BT4KC:PetActions()) do want[a] = true end
				elseif key == "stance" then
					for _, a in ipairs(BT4KC:StanceActions()) do want[a] = true end
				else
					local bi = tonumber(key:match("^bar(%d+)$"))
					if bi then
						for _, a in ipairs(BT4KC:ActionsForBar(bi)) do want[a] = true end
					end
				end
			end
		end
		local out = {}
		for action, keys in pairs(all) do
			if want[action] then out[action] = keys end
		end
		return out
	end

	local exportBtn = AceGUI:Create("Button")
	exportBtn:SetText(L["Export"])
	exportBtn:SetWidth(170)
	exportBtn:SetCallback("OnClick", function()
		local t = selectedBindings()
		if not next(t) then
			Bartender4:Print(L["No keybindings to export for the current selection."])
			return
		end
		local str, err = BT4KC:SerializeBindings(t)
		if not str then
			Bartender4:Print(err or L["Keybind import/export libraries are missing."])
			return
		end
		box:SetText(str)
		if box.editBox then
			box.editBox:SetFocus()
			box.editBox:HighlightText()
		end
	end)
	f:AddChild(exportBtn)

	local importBtn = AceGUI:Create("Button")
	importBtn:SetText(L["Import"])
	importBtn:SetWidth(170)
	importBtn:SetCallback("OnClick", function()
		local clean, err = BT4KC:DeserializeBindings(box:GetText())
		if not clean then
			Bartender4:Print(err or L["This is not a Bartender4-fufu keybind string."])
			return
		end
		StaticPopup_Show("BARTENDER4_CONFIRM_KEYBIND_IMPORT", nil, nil,
			{ clean = clean, expectedSet = (GetCurrentBindingSet() or 1) })
	end)
	f:AddChild(importBtn)

	local nameBox = AceGUI:Create("EditBox")
	nameBox:SetLabel(L["Save as named set"])
	nameBox:SetWidth(260)
	nameBox:DisableButton(true)
	f:AddChild(nameBox)

	local function doSave(bindings)
		if not bindings or not next(bindings) then
			Bartender4:Print(L["Nothing to save for the current selection."])
			return
		end
		local nm = nameBox:GetText() or ""
		local trimmed = nm:match("^%s*(.-)%s*$") or nm
		if self:GetSavedKeybindSets()[trimmed] then
			StaticPopup_Show("BARTENDER4_CONFIRM_KEYBIND_SETSAVE", trimmed, nil,
				{ name = trimmed, bindings = bindings })
			return
		end
		local ok, saved = self:SaveKeybindSet(trimmed, bindings)
		if ok then
			Bartender4:Print((L["Saved keybind set '%s'."]):format(tostring(saved)))
			if self.RefreshKeyboundDialogUI then self:RefreshKeyboundDialogUI() end
		else
			Bartender4:Print(L["Invalid set name."])
		end
	end

	local saveSelBtn = AceGUI:Create("Button")
	saveSelBtn:SetText(L["Save selection as set"])
	saveSelBtn:SetWidth(200)
	saveSelBtn:SetCallback("OnClick", function() doSave(selectedBindings()) end)
	f:AddChild(saveSelBtn)

	local saveImpBtn = AceGUI:Create("Button")
	saveImpBtn:SetText(L["Save pasted string as set"])
	saveImpBtn:SetWidth(220)
	saveImpBtn:SetCallback("OnClick", function()
		local clean, err = BT4KC:DeserializeBindings(box:GetText())
		if not clean then
			Bartender4:Print(err or L["This is not a Bartender4-fufu keybind string."])
			return
		end
		doSave(clean)
	end)
	f:AddChild(saveImpBtn)

	local note = AceGUI:Create("Label")
	note:SetText(L["Importing replaces the keybinds on every action the string covers AND every Bartender4 action on this character (a single-bar string still re-derives via that union). Requires per-character keybinds (set 2); blocked in combat."])
	note:SetFullWidth(true)
	f:AddChild(note)
end
