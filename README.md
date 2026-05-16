# Bartender4-fufu

An **unofficial personal fork** of [Bartender4](https://github.com/Nevcairiel/Bartender4)
by Hendrik "Nevcairiel" Leppkes, adding cross-character keybind copying plus a
performance patch to the action-button hot path.

> **Not affiliated with or endorsed by Nevcairiel or the Bartender4 project.**
> This is a personal modification maintained by Little-Bunny-FuFu. For the
> official, supported addon, use upstream Bartender4. See **License & attribution**
> below — this fork claims no rights over Bartender4's code.

## Why this fork exists

Stock Bartender4 stores keybindings per WoW binding set, but offers no way to
*copy* one character's Bartender4 keybinds onto another. If you maintain a
consistent bar layout across many alts, every new character means rebinding by
hand. This fork adds that copy path, and along the way patches a measurable
performance cost in the shared button library.

## What it adds

### 1. Cross-character keybind copy

A new module (`KeyBindCopy.lua`) plus controls in the **"Binding Mode" dialog**
— the box that opens from **Bartender4 options → the "Key Bindings" button**.
This is the same LibKeyBound dialog you use to bind keys to your bars (mouse
over a button and press the key, inside that window).

> **Not** Blizzard's "Quick Keybind Mode" (the ESC-menu feature with a "Reset
> to Defaults" button). Bartender4 buttons — fork *or* stock — do not
> participate in Blizzard Quick Keybind Mode, so mousing over them there does
> nothing. Use the **Key Bindings button** in Bartender4's own options. The
> `/kb` slash *should* open this dialog, but on some clients another addon or
> Blizzard intercepts `/kb`; the options button is the reliable entry point.

- **Character Specific Keybindings** (the dialog's checkbox) — switches WoW to
  the per-character binding set for this character. The *first* time you enable
  it, your current account-wide bindings are snapshotted into the character set
  so you don't start from a blank slate. Toggling off restores the account set;
  toggling back on restores your saved character set (not a re-copy).
- **Copy Character Keybinds to Account** (button) — promotes the current
  character-specific bindings into the account-wide set as well, so toggling
  *Character Specific Keybindings* off preserves them. Overwrites account
  bindings (confirm dialog).
- **Copy Keybinds from Character** (button → character menu) — pick another
  character that has logged in with this fork (on its per-character set) and
  copy its saved Bartender4 bindings onto the current character. Confirm
  dialog; overwrites this character's Bartender4 keybinds.

How it works: while the per-character binding set is active, the module mirrors
your Bartender4 button bindings into the addon's saved variables (debounced on
`UPDATE_BINDINGS`, flushed on logout). Other characters can then read that
snapshot as a copy source. The copy is combat-locked, re-verifies the binding-set
context across the (async) confirmation popup, and suppresses the mid-rewrite
save cascade so a half-applied state can't be persisted.

Bindings live in `Bartender4DB` (the standard Bartender4 saved variable) under
the per-character scope; no new saved-variables file is introduced.

> **Caveat:** "Copy Keybinds from Character" replaces *all* Bartender4 keybinds
> on the target character and unbinds any non-Bartender4 command currently
> sitting on a key the source uses. This cannot be undone. The confirmation
> dialog states this.

### 2. LibActionButton-1.0 performance patch

The fork ships a perf-patched, fork-owned copy of `LibActionButton-1.0` (the
library every Bartender4 button is built on). It coalesces event storms
(loot/AH/cooldown/usable bursts) into one deferred update per frame, replaces
full-button scans for proc-glow with O(1) reverse-map dispatch, and range-polls
only range-relevant buttons. It also fixes a latent stock bug (an undefined
`FlyoutHasSpell` global that errored on any flyout button + proc-glow event).
Behavior is otherwise stock-equivalent; details and the multi-reviewer history
are in the project notes.

## Installing

This is a **drop-in replacement** for Bartender4, not an add-on alongside it:

1. Remove or disable stock **Bartender4** first. Both use the same
   `Bartender4DB` saved variables — do not run both at once.
2. Download the latest `Bartender4-fufu` zip from the
   [Releases](https://github.com/Little-Bunny-FuFu/Bartender4-fufu/releases)
   page and extract it into
   `World of Warcraft/_retail_/Interface/AddOns/`. You should end up with an
   `AddOns/Bartender4-fufu/` folder containing `Bartender4-fufu.toc`.
   *(Alternatively, copy the `Bartender4-fufu` source folder there directly.)*
3. Enable **Bartender4-fufu** at the character select / addons screen.

Your existing Bartender4 profile and settings carry over (same saved variable).

## Upstream & credits

- **Bartender4** — © 2009–2017 Hendrik "Nevcairiel" Leppkes. All rights
  reserved. <https://github.com/Nevcairiel/Bartender4>
- **LibActionButton-1.0** — Nevcairiel. <https://github.com/Nevcairiel/LibActionButton-1.0>
- Ace3 and the other vendored libraries retain their own authors and licenses.

All credit for Bartender4 itself belongs to Nevcairiel and the Bartender4
contributors. This fork's only original contributions are the keybind-copy
module, the options controls wiring it up, and the LibActionButton perf hunks.

## License & attribution

Bartender4 is distributed by its author under **"All rights reserved"** (see
the upstream `.toc`). **This fork does not relicense Bartender4 and grants no
rights over its code.** It is a personal modification, distributed only via
this GitHub repository and a private World of Warcraft guild, for personal /
on-request use.

It is **deliberately not** published to CurseForge, WoWInterface, Wago, or any
public addon listing, and will not be without first contacting the upstream
author (Nevcairiel) for permission. Provided as-is, no warranty; may be removed
at any time.

If you are the Bartender4 copyright holder and want this fork taken down or
changed, contact <fufu@fufutopia.com> and it will be actioned promptly.

## AI-assistance disclosure

The diagnosis, the keybind-copy implementation, and the performance patch were
developed with AI coding assistance (Claude, with cross-checks from additional
review models) under human direction and in-game validation. Noted here for
transparency, consistent with the companion
[SimpleAssistedCombatIcon-fufu](https://github.com/Little-Bunny-FuFu/SimpleAssistedCombatIcon-fufu)
fork.
