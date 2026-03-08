# Recount Midnight (12.0.1) Migration Progress

## Status: IN PROGRESS

## Completed
- [x] TOC version bump (120001, IconTexture)
- [x] GetSpellInfo -> C_Spell.GetSpellInfo compat wrapper
- [x] SendChatMessage -> C_ChatInfo.SendChatMessage fallback
- [x] GetMouseFocus -> GetMouseFoci compat
- [x] UIFrameFade fallback
- [x] ColorPickerFrame retail compat (GUI_Realtime.lua)
- [x] IsInScenarioGroup fallback (deletion.lua)
- [x] table.getn -> # operator
- [x] ChatThrottleLib v29 -> v31
- [x] Ace3 libraries updated to latest upstream
- [x] FillLocalizedClassList -> LOCALIZED_CLASS_NAMES_MALE
- [x] BNGetFriendInfo -> C_BattleNet.GetFriendAccountInfo

## Current: C_DamageMeter Migration (CRITICAL)

### Problem
WoW 12.0 blocks addons from registering `COMBAT_LOG_EVENT_UNFILTERED`.
Both Details and Skada have migrated to Blizzard's server-side `C_DamageMeter` API.

### Plan
1. [x] Create `Tracker_DamageMeter.lua` - new parser using C_DamageMeter API
2. [x] Modify `Recount.lua` - conditionally use new parser on 12.0+
3. [x] Modify `Recount.toc` - add new file before Tracker.lua
4. [x] Handle secret values (issecretvalue) during active combat
5. [x] Disable/hide modes that can't be populated by C_DamageMeter

### What C_DamageMeter CAN provide (Recount modes that WILL work):
- Damage Done / DPS (type 0/1)
- Healing Done / HPS (type 2/3)
- Absorbs (type 4)
- Damage Taken (type 7)
- Interrupts (type 5)
- Dispels (type 6)
- Deaths (type 9)
- Per-spell breakdowns for all above
- Duration/active time from session durationSeconds

### What C_DamageMeter CANNOT provide (modes that will be DISABLED):
- Friendly Fire (no equivalent type)
- Overhealing (no equivalent type)
- DOT Uptime / HOT Uptime (no aura tracking)
- CC Breaks (no equivalent)
- Power Gains (mana/energy/rage/runic power)
- Per-hit stats (crit/miss/dodge/parry breakdown)
- Target breakdowns (who damaged whom)
- Element/school breakdowns
- Resurrections

### Key API Details
- Session types: 0=Overall, 1=Current, 2=Expired
- Damage types: 0=DamageDone, 1=DPS, 2=HealingDone, 3=HPS, 4=Absorbs, 5=Interrupts, 6=Dispels, 7=DamageTaken, 8=AvoidableDamageTaken, 9=Deaths
- Events: DAMAGE_METER_COMBAT_SESSION_UPDATED, DAMAGE_METER_CURRENT_SESSION_UPDATED, DAMAGE_METER_RESET
- Secret values: data is opaque during combat, use issecretvalue() to check
- Combat detection: PLAYER_REGEN_DISABLED/ENABLED (same as before)

## Testing
- [ ] Addon loads without errors
- [ ] Main window shows damage data after combat
- [ ] Per-spell breakdown works in detail view
- [ ] Fight segments rotate correctly
- [ ] Reset data works
- [ ] Modes that have data display correctly
- [ ] Modes without data are hidden/disabled gracefully
