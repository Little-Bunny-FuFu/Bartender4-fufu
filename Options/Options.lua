--[[
	Copyright (c) 2009-2017, Hendrik "Nevcairiel" Leppkes < h.leppkes at gmail dot com >
	All rights reserved.
]]
local _, Bartender4 = ...
local L = LibStub("AceLocale-3.0"):GetLocale("Bartender4")

local AceConfigDialog = LibStub("AceConfigDialog-3.0")

local error, select, pairs = error, select, pairs
local WoWClassicEra = (WOW_PROJECT_ID == WOW_PROJECT_CLASSIC)
local WoWBCC = (WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC)
local WoWClassic = (WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE)
local WoWRetail = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)
local function SaveBindings(...) return (_G.SaveBindings or _G.AttemptToSaveBindings)(...) end

-- GLOBALS: LibStub, UnitHasVehicleUI, GetModifiedClick, SetModifiedClick, SaveBindings, AttemptToSaveBindings, LoadBindings, GetCurrentBindingSet, InCombatLockdown

local getFunc, setFunc
do
	function getFunc(info)
		return (info.arg and Bartender4.db.profile[info.arg] or Bartender4.db.profile[info[#info]])
	end

	function setFunc(info, value)
		local key = info.arg or info[#info]
		Bartender4.db.profile[key] = value
	end
end

local s_HookedKeyBound, s_KeyBoundHookShowBTOptions
local KB = LibStub("LibKeyBound-1.0")
local LDBIcon = LibStub("LibDBIcon-1.0", true)
local LibDualSpec = (not WoWClassicEra) and LibStub("LibDualSpec-1.0", true)

local function generateOptions()
	Bartender4.options = {
		type = "group",
		name = "Bartender4",
		icon = "Interface\\Icons\\INV_Drink_05",
		childGroups = "tree",
		plugins = {},
		args = {
			lock = {
				order = 1,
				type = "toggle",
				name = L["Lock"],
				desc = L["Lock all bars."],
				get = function() return Bartender4.Locked end,
				set = function(info, value) Bartender4[value and "Lock" or "Unlock"](Bartender4) end,
				width = "half",
			},
			buttonlock = {
				order = 2,
				type = "toggle",
				name = L["Button Lock"],
				desc = L["Lock the button contents from being dragged off. When locked, actions can still be dragged by holding Shift."] .. "\n\n" .. L["NOTE: When the buttons are unlocked, actions will always trigger on key release, instead of key press."],
				get = function() return Bartender4.db.profile.buttonlock end,
				set = function(info, value)
					Bartender4.db.profile.buttonlock = value
					Bartender4.Bar:ForAll("ForAll", "SetAttribute", "buttonlock", value)
					if not value then
						Bartender4:Print(L["Buttons are unlocked. While unlocked, actions will always execute on key release, instead of key press."])
					end
				end,
			},
			minimapIcon = {
				order = 3,
				type = "toggle",
				name = L["Minimap Icon"],
				desc = L["Show a Icon to open the config at the Minimap"],
				get = function() return not Bartender4.db.profile.minimapIcon.hide end,
				set = function(info, value) Bartender4.db.profile.minimapIcon.hide = not value; LDBIcon[value and "Show" or "Hide"](LDBIcon, "Bartender4") end,
				disabled = function() return not LDBIcon end,
			},
			kb = {
				order = 4,
				type = "execute",
				name = L["Key Bindings"],
				desc = L["Switch to key-binding mode"],
				func = function()
					KB:Toggle()
					AceConfigDialog:Close("Bartender4")

					if KeyboundDialog and not s_HookedKeyBound then
						KeyboundDialog:HookScript("OnHide", function() if s_KeyBoundHookShowBTOptions then AceConfigDialog:Open("Bartender4") s_KeyBoundHookShowBTOptions = nil end end)
						s_HookedKeyBound = true
					end

					s_KeyBoundHookShowBTOptions = true
				end,
			},
			charspecbindings = {
				order = 5,
				type = "toggle",
				name = L["Character Specific Keybinds"],
				desc = L["Use character-specific keybindings for this character instead of the account-wide keybindings.\n\nThe first time you switch this on, your current account bindings are copied to the character set so you don't start from scratch."],
				width = "full",
				-- Capability gate: GetCurrentBindingSet is absent on older
				-- Classic Era builds. Without it the toggle has nothing
				-- meaningful to switch between, and the set() handler below
				-- would call a nil global. Hide the entire option in that case.
				hidden = function() return type(GetCurrentBindingSet) ~= "function" end,
				disabled = InCombatLockdown,
				get = function() return (GetCurrentBindingSet() or 1) == 2 end,
				set = function(info, value)
					if InCombatLockdown() then return end

					-- Raw integer set ids: account == 1, character == 2.
					local targetSet  = value and 2 or 1
					local currentSet = GetCurrentBindingSet() or 1

					if targetSet == currentSet then
						-- Already in desired state (e.g., stale `get`); just refresh.
						if value then
							Bartender4.db.char.charBindingsInitialized = true
						end
						LibStub("AceConfigRegistry-3.0"):NotifyChange("Bartender4")
						return
					end

					-- Suppress the ActionBars:ReassignBindings -> SaveBindings
					-- cascade during the whole transition. Each SetBinding /
					-- LoadBindings call below fires UPDATE_BINDINGS, and a
					-- cascade SaveBindings firing between LoadBindings(N) and
					-- the trailing SaveBindings(N) could persist to the wrong
					-- on-disk slot. Save-and-restore (not nil-out) so a nested
					-- transition's outer suppression isn't cancelled by the
					-- inner clear. pcall + restore keeps the flag from sticking.
					local _prevSuppress = Bartender4._suppressBindingCascade
					Bartender4._suppressBindingCascade = true
					local _ok, _err = pcall(function()
					if value and not Bartender4.db.char.charBindingsInitialized then
						-- First-time activation: snapshot current (account) bindings
						-- and copy them onto set 2.
						--
						-- The flag gate is what stops a later toggle OFF->ON from
						-- overwriting any character-specific customizations -- e.g.,
						-- bindings imported via "Copy Keybinds from Character" or
						-- manually rebound while set 2 was active. To force a re-copy
						-- after the first activation (for example, to recover from a
						-- corrupted set 2 left over from older buggy versions of this
						-- code), run
						--   /run Bartender4.db.char.charBindingsInitialized = false
						-- then toggle OFF and ON.
						--
						-- Use GetBindingKey (up to 4 keys) instead of GetBinding's
						-- 2-key tuple -- the original v0 snapshot loop only captured
						-- key1/key2 and is the most likely source of historical alt-
						-- slot wipes on this character.
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

						-- Activate set 2 BEFORE the restore loop. Each SetBinding
						-- fires UPDATE_BINDINGS, and ActionBars:ReassignBindings
						-- (registered for that event) may call
						-- SaveBindings(GetCurrentBindingSet()). Activating set 2
						-- first guarantees those cascading writes hit disk[2] and
						-- cannot corrupt the account set on disk[1].
						SaveBindings(1)
						LoadBindings(2)
						SaveBindings(2)

						-- Clear EVERY key currently bound in set 2's in-memory state
						-- before applying the snapshot. A per-command unbind would leak
						-- bindings for commands that exist in set 2's loaded disk state
						-- but are absent from the snapshot (stale defaults, actions the
						-- user has unbound on set 1). The clear also guarantees slot
						-- order when re-applying the snapshot: SetBinding's slot-fill
						-- behavior when a command already has bindings is opaque, and
						-- that was the observed alt-slot wipe.
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
					elseif value then
						-- Subsequent activation: restore the user's previously-saved
						-- set 2 from disk. Preserves character-specific customizations
						-- (e.g., from "Copy Keybinds from Character" or manual edits
						-- made while on set 2) across OFF/ON cycles.
						SaveBindings(1)
						LoadBindings(2)
						SaveBindings(2)
					else
						-- Switching character -> account. Flush set 2 (preserve any
						-- in-memory edits since the last save), then load and activate
						-- set 1.
						SaveBindings(2)
						LoadBindings(1)
						SaveBindings(1)
					end
					end)
					Bartender4._suppressBindingCascade = _prevSuppress
					if not _ok then
						-- Surface to BugSack / scriptErrors AND show a clean
						-- in-game summary AND continue to NotifyChange so the
						-- UI doesn't stay stale on a half-applied state.
						(geterrorhandler() or function() end)(_err)
						Bartender4:Print(L["Internal error during binding-set transition; your bindings may be in a partial state. See the error log for details."])
					end

					LibStub("AceConfigRegistry-3.0"):NotifyChange("Bartender4")
				end,
			},
			charspecpromote = {
				order = 6,
				type = "execute",
				name = L["Copy Character Keybinds to Account"],
				desc = L["Save your current character-specific keybindings into the account set as well, so toggling Character Specific Keybinds OFF will preserve them. Overwrites your existing account-wide keybindings."],
				width = "full",
				disabled = function() return InCombatLockdown() or (GetCurrentBindingSet() or 1) ~= 2 end,
				hidden = function() return type(GetCurrentBindingSet) ~= "function" or (GetCurrentBindingSet() or 1) ~= 2 end,
				confirm = true,
				confirmText = L["This will overwrite your account-wide keybindings with your current character-specific keybindings. Continue?"],
				func = function()
					if InCombatLockdown() then return end
					if (GetCurrentBindingSet() or 1) ~= 2 then return end
					-- Promote: write current set 2 in-memory bindings into disk[1] so
					-- the account set has the same data as the character set, then
					-- reactivate set 2. After this, toggling per-character OFF will
					-- preserve the user's bindings because both sets are in sync.
					local _prevSuppress = Bartender4._suppressBindingCascade
					Bartender4._suppressBindingCascade = true
					local _ok, _err = pcall(function()
						SaveBindings(1)  -- memory->disk[1]; this also activates set 1
						LoadBindings(2)  -- memory<-disk[2] (should equal current memory)
						SaveBindings(2)  -- reactivate set 2
					end)
					Bartender4._suppressBindingCascade = _prevSuppress
					if not _ok then
						(geterrorhandler() or function() end)(_err)
						Bartender4:Print(L["Internal error during keybind promote; your bindings may be in a partial state. See the error log for details."])
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("Bartender4")
				end,
			},
			bars = {
				order = 20,
				type = "group",
				name = L["Action Bars"],
				args = {
					options = {
						type = "group",
						order = 0,
						name = function(info) if info.uiType == "dialog" then return "" else return L["Bar Options"] end end,
						guiInline = true,
						args = {
							blizzardVehicle = {
								order = 1,
								type = "toggle",
								name = L["Use Blizzard Vehicle UI"],
								desc = L["Enable the use of the Blizzard Vehicle UI, hiding any Bartender4 bars in the meantime."],
								width = "full",
								hidden = not UnitHasVehicleUI,
								get = getFunc,
								set = function(info, value)
									if UnitHasVehicleUI("player") then
										Bartender4:Print(L["You have to exit the vehicle in order to be able to change the Vehicle UI settings."])
										return
									end
									Bartender4.db.profile.blizzardVehicle = value
									Bartender4:UpdateBlizzardVehicle()
								end,
							},
							onkeydown = {
								order = 2,
								type = "toggle",
								name = L["Toggle actions on key press instead of release"],
								desc = L["Toggles actions immediately when you press the key, and not only on release. Note that the buttons need to be locked for actions to run on key press."],
								get = function(info)
									if WoWRetail or WoWBCC then
										return GetCVarBool("ActionButtonUseKeyDown")
									else
										return Bartender4.db.profile.onkeydown
									end
								end,
								set = function(info, value)
									if WoWRetail or WoWBCC then
										SetCVar("ActionButtonUseKeyDown", value)
									else
										Bartender4.db.profile.onkeydown = value
										Bartender4.Bar:ForAll("UpdateButtonConfig")
									end
								end,
								width = "full",
							},
							spellCastVFX = {
								order = 3,
								type = "toggle",
								name = L["Show Spell Cast VFX on action buttons"],
								desc = L["Shows the miniature cast bar on action buttons when casting spells."],
								get = function(info) return Bartender4.db.profile.spellCastVFX end,
								set = function(info, value)
									Bartender4.db.profile.spellCastVFX = value
									Bartender4.Bar:ForAll("UpdateButtonConfig")
								end,
								hidden = WoWClassic,
								width = "full",
							},
							selfcastmodifier = {
								order = 10,
								type = "toggle",
								name = L["Self-Cast by modifier"],
								desc = L["Toggle the use of the modifier-based self-cast functionality."],
								get = getFunc,
								set = function(info, value)
									Bartender4.db.profile.selfcastmodifier = value
									Bartender4.Bar:ForAll("UpdateSelfCast")
								end,
							},
							setselfcastmod = {
								order = 20,
								type = "select",
								name = L["Self-Cast Modifier"],
								desc = L["Select the Self-Cast Modifier"],
								get = function(info) return GetModifiedClick("SELFCAST") end,
								set = function(info, value) SetModifiedClick("SELFCAST", value); SaveBindings(GetCurrentBindingSet() or 1) end,
								values = { NONE = L["None"], ALT = L["ALT"], SHIFT = L["SHIFT"], CTRL = L["CTRL"] },
							},
							selfcast_nl = {
								order = 30,
								type = "description",
								name = "",
							},
							focuscastmodifier = {
								order = 50,
								type = "toggle",
								name = L["Focus-Cast by modifier"],
								desc = L["Toggle the use of the modifier-based focus-cast functionality."],
								get = getFunc,
								set = function(info, value)
									Bartender4.db.profile.focuscastmodifier = value
									Bartender4.Bar:ForAll("UpdateSelfCast")
								end,
							},
							setfocuscastmod = {
								order = 60,
								type = "select",
								name = L["Focus-Cast Modifier"],
								desc = L["Select the Focus-Cast Modifier"],
								get = function(info) return GetModifiedClick("FOCUSCAST") end,
								set = function(info, value) SetModifiedClick("FOCUSCAST", value); SaveBindings(GetCurrentBindingSet() or 1) end,
								values = { NONE = L["None"], ALT = L["ALT"], SHIFT = L["SHIFT"], CTRL = L["CTRL"] },
							},
							focuscast_nl = {
								order = 70,
								type = "description",
								name = "",
							},
							selfcastrightclick = {
								order = 80,
								type = "toggle",
								name = L["Right-click Self-Cast"],
								desc = L["Toggle the use of the right-click self-cast functionality."],
								get = getFunc,
								set = function(info, value)
									Bartender4.db.profile.selfcastrightclick = value
									Bartender4.Bar:ForAll("UpdateSelfCast")
								end,
							},
							rightclickselfcast_nl = {
								order = 90,
								type = "description",
								name = "",
							},
							range = {
								order = 100,
								name = L["Out of Range Indicator"],
								desc = L["Configure how the Out of Range Indicator should display on the buttons."],
								type = "select",
								style = "dropdown",
								get = function()
									return Bartender4.db.profile.outofrange
								end,
								set = function(info, value)
									Bartender4.db.profile.outofrange = value
									Bartender4.Bar:ForAll("UpdateButtonConfig")
								end,
								values = { none = L["No Display"], button = L["Full Button Mode"], hotkey = L["Hotkey Mode"] },
							},
							tooltip = {
								order = 110,
								name = L["Button Tooltip"],
								type = "select",
								desc = L["Configure the Button Tooltip."],
								values = { ["disabled"] = L["Disabled"], ["nocombat"] = L["Disabled in Combat"], ["enabled"] = L["Enabled"] },
								get = function() return Bartender4.db.profile.tooltip end,
								set = function(info, value)
									Bartender4.db.profile.tooltip = value
									Bartender4.Bar:ForAll("UpdateButtonConfig")
								end,
							},
							flyoutBackground = {
								order = 120,
								type = "toggle",
								name = L["Hide Flyout Background"],
								desc = L["Hide the background of the spell flyout frame."],
								get = function()
									return not Bartender4.db.profile.flyoutBackground
								end,
								set = function(info, value)
									Bartender4.db.profile.flyoutBackground = not value
									if LibStub("LibActionButton-1.0").flyoutHandler then
										LibStub("LibActionButton-1.0").flyoutHandler.Background:SetShown(not value)
									end
								end,
								hidden = WoWClassic,
							},
							colors = {
								order = 130,
								type = "group",
								guiInline = true,
								name = L["Colors"],
								get = function(info)
									local color = Bartender4.db.profile.colors[info[#info]]
									return color.r, color.g, color.b
								end,
								set = function(info, r, g, b)
									local color = Bartender4.db.profile.colors[info[#info]]
									color.r, color.g, color.b = r, g, b
									Bartender4.Bar:ForAll("UpdateButtonConfig")
								end,
								args = {
									range = {
										order = 1,
										type = "color",
										name = L["Out of Range Indicator"],
										desc = L["Specify the Color of the Out of Range Indicator"],
									},
									mana = {
										order = 2,
										type = "color",
										name = L["Out of Mana Indicator"],
										desc = L["Specify the Color of the Out of Mana Indicator"],
									},
								},
							},
							header_target = {
								order = 300,
								type = "header",
								name = L["Mouse-Over Casting"],
							},
							mouseovermod = {
								order = 301,
								type = "select",
								name = L["Mouse-Over Casting Modifier"],
								desc = L["Select a modifier for Mouse-Over Casting"],
								get = function(info) return Bartender4.db.profile.mouseovermod end,
								set = function(info, value) Bartender4.db.profile.mouseovermod = value; Bartender4.Bar:ForAll("UpdateStates") end,
								values = { NONE = L["None"], ALT = L["ALT"], SHIFT = L["SHIFT"], CTRL = L["CTRL"] },
							},
							mouseovermod_desc = {
								order = 302,
								type = "description",
								name = "\n" .. L["\"None\" as modifier means its always active, and no modifier is required.\n\nRemember to enable Mouse-Over Casting for the individual bars, on the \"State Configuration\" tab, if you want it to be active for a specific bar."],
							},
						},
					},
				},
			},
			uibars = {
				order = 20,
				type = "group",
				name = L["UI Bars"],
				desc = L["Bars for Action Bar related UI elements"],
				args = {
				},
			},
			faq = {
				name = L["FAQ"],
				desc = L["Frequently Asked Questions"],
				type = "group",
				order = 1000,
				args = {
					line3 = {
						type = "description",
						name = "|cffffd200" .. L["How do I change the Bartender4 Keybindings?"] .. "|r",
						order = 3,
					},
					line4 = {
						type = "description",
						name = L["You can either click the KeyBound button in the options, or use the |cffffff78/kb|r chat command to open the keyBound control. Alternatively, you can also use the Blizzard Keybinding Interface."] .. "\n\n" .. L["Once open, simply hover the button you want to bind, and press the key you want to be bound to that button. The keyBound tooltip and on-screen status will inform you about already existing bindings to that button, and the success of your binding attempt."],
						order = 4,
					},
					line5 = WoWClassic and {
						type = "description",
						name = "\n|cffffd200" .. L["My BagBar does not have the Keyring on it, how do i get it back?"] .. "|r",
						order = 5,
					} or nil,
					line6 = WoWClassic and {
						type = "description",
						name = L["Its simple! Just check the Keyring option in the BagBars configuration menu, and it'll appear next to your bags."],
						order = 6,
					} or nil,
					line7 = {
						type = "description",
						name = "\n|cffffd200" .. L["I've found a bug! Where do I report it?"] .. "|r",
						order = 7,
					},
					line8 = {
						type = "description",
						name = L["You can report bugs or give suggestions on the project page at |cffffff78https://www.wowace.com/projects/bartender4|r or on GitHub at |cffffff78https://github.com/Nevcairiel/Bartender4|r"],
						order = 8,
					},
					line10 = {
						type = "description",
						name = L["When reporting a bug, make sure you include the |cffffff78steps on how to reproduce the bug|r, supply any |cffffff78error messages|r with stack traces if possible, give the |cffffff78revision number|r of Bartender4 the problem occured in and state whether you are using an |cffffff78English client or otherwise|r."],
						order = 10,
					},
					line11 = {
						type = "description",
						name = "\n|cffffd200" .. L["Who wrote this cool addon?"] .. "|r",
						order = 11,
					},
					line12= {
						type = "description",
						name = L["Bartender4 was written by Nevcairiel of EU-Zirkel des Cenarius. He will accept cookies as compensation for his hard work!"],
						order = 12,
					},
				},
			},
		},
	}
	Bartender4.options.plugins.profiles = { profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(Bartender4.db) }
	for k,v in Bartender4:IterateModules() do
		if v.SetupOptions then
			v:SetupOptions()
		end
	end
	if LibDualSpec then
		LibDualSpec:EnhanceOptions(Bartender4.options.plugins.profiles.profiles, Bartender4.db)
	end
end

local function getOptions()
	if not Bartender4.options then
		generateOptions()
		-- let the generation function be GCed
		generateOptions = nil
	end
	return Bartender4.options
end

function Bartender4:ChatCommand(input)
	if InCombatLockdown() then
		self:Print(L["Cannot access options during combat."])
		return
	end
	if not input or input:trim() == "" then
		LibStub("AceConfigDialog-3.0"):Open("Bartender4")
	else
		LibStub("AceConfigCmd-3.0").HandleCommand(Bartender4, "bt", "Bartender4", input)
	end
end

function Bartender4:SetupOptions()
	LibStub("AceConfig-3.0"):RegisterOptionsTable("Bartender4", getOptions)

	-- set default size
	AceConfigDialog:SetDefaultSize("Bartender4", 660, 650)

	-- expand both bar sections
	AceConfigDialog:GetStatusTable("Bartender4").groups = { groups = { bars = true, uibars = true } }

	-- setup slash commands
	self:RegisterChatCommand( "bt", "ChatCommand")
	self:RegisterChatCommand( "bt4", "ChatCommand")
	self:RegisterChatCommand( "bartender", "ChatCommand")
	self:RegisterChatCommand( "bartender4", "ChatCommand")
end

function Bartender4:RegisterModuleOptions(key, table)
	if not self.options then
		error("Options table has not been created yet, respond to the callback!", 2)
	end
	self.options.plugins[key] = { [key] = table }
end

function Bartender4:RegisterBarOptions(id, table)
	if not self.options then
		error("Options table has not been created yet, respond to the callback!", 2)
	end
	self.options.args.uibars.args[id] = table
end

function Bartender4:RegisterActionBarOptions(id, table)
	if not self.options then
		error("Options table has not been created yet, respond to the callback!", 2)
	end
	self.options.args.bars.args[id] = table
end

local optionParent = {}
function optionParent:NewCategory(category, data)
	self.table[category] = data
end

local ov = nil
function optionParent:AddElement(category, element, data, ...)
	local lvl = self.table[category]
	for i = 1, select('#', ...) do
		local key = select(i, ...)
		if not (lvl.args[key] and lvl.args[key].args) then
			error(("Sub-Level Key %s does not exist in options group or is no sub-group."):format(key), ov and 3 or 2)
		end
		lvl = lvl.args[key]
	end

	lvl.args[element] = data
end

function optionParent:AddElementGroup(category, data, ...)
	ov = true
	for k,v in pairs(data) do
		self:AddElement(category, k, v, ...)
	end
	ov = nil
end

function Bartender4:NewOptionObject(otbl)
	if not otbl then otbl = {} end
	local tbl = { table = otbl }
	for k, v in pairs(optionParent) do
		tbl[k] = v
	end

	return tbl
end
