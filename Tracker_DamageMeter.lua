-- Tracker_DamageMeter.lua
-- C_DamageMeter-based parser for WoW 12.0+ (Midnight)
-- Replaces COMBAT_LOG_EVENT_UNFILTERED tracking with Blizzard's server-side damage meter API

local Recount = _G.Recount

-- Only load on Midnight (12.0+)
if not C_DamageMeter then
	return
end

local AceLocale = LibStub("AceLocale-3.0")
local L = AceLocale:GetLocale("Recount")

local revision = tonumber(string.sub("$Revision: 1609 $", 12, -3))
if Recount.Version < revision then
	Recount.Version = revision
end

local pairs = pairs
local ipairs = ipairs
local GetTime = GetTime
local UnitName = UnitName
local UnitClass = UnitClass
local UnitLevel = UnitLevel
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local IsInRaid = IsInRaid
local issecretvalue = issecretvalue
local string_format = string.format
local string_find = string.find

-- Mark that we're using the new parser
Recount.UseDamageMeter = true
local DEBUG = false

local function SafeDebugText(value)
	if value == nil then
		return "nil"
	end
	if issecretvalue and issecretvalue(value) then
		return "<secret>"
	end
	local ok, text = pcall(tostring, value)
	if ok then
		return text
	end
	return "<unprintable>"
end

local function DP(msg)
	if DEBUG then
		print("|cFF00FF00[Recount DM]|r " .. SafeDebugText(msg))
	end
end

local function DE(msg)
	print("|cFF00FF00[Recount DM]|r " .. SafeDebugText(msg))
end

-- DamageMeterType enum values
local DM_DamageDone = 0
local DM_HealingDone = 2
local DM_Absorbs = 4
local DM_Interrupts = 5
local DM_Dispels = 6
local DM_DamageTaken = 7
local DM_Deaths = 9

-- SessionType enum
local DM_Overall = 0
local DM_Current = 1

local dmFrame = CreateFrame("Frame")
Recount.dmFrame = dmFrame

local dbCombatants

-- Track state
local combatSessionID = nil -- The actual combat session ID (non-zero)
local updateTicker = nil
local IsSecret
local SafeCombatCall
local PROXY_PREFIX = "__RECOUNT_DM__"
local GENERIC_FIGHT_NAME = "Trash Combat"
local overallBaseline = {}

local TRACKED_TOTAL_FIELDS = {
	"Damage",
	"Healing",
	"Absorbs",
	"DamageTaken",
	"Interrupts",
	"Dispels",
	"DeathCount",
	"ActiveTime",
	"TimeDamage",
	"TimeHeal",
}

local TRACKED_RATE_FIELDS = {
	"DamagePerSecond",
	"HealingPerSecond",
	"AbsorbPerSecond",
	"DamageTakenPerSecond",
}

-- Secret value display cache, keyed by mode then combatant name.
-- Raw secret values are only used for UI text while synthetic numeric values drive sorting.
local secretDisplayValues = {}
local secretBarValues = {}

local function ClearSecretDisplayValues()
	for _, modeData in pairs(secretDisplayValues) do
		wipe(modeData)
	end
end

local function ClearSecretBarValues()
	for _, modeData in pairs(secretBarValues) do
		if modeData.entries then
			wipe(modeData.entries)
		end
		modeData.maxValue = nil
		modeData.maxPerSec = nil
	end
end

local function ClearOverallBaseline()
	wipe(overallBaseline)
end

local function CaptureOverallBaseline()
	ClearOverallBaseline()
	if not dbCombatants then
		return
	end

	for name, who in pairs(dbCombatants) do
		local fightData = who and who.Fights and who.Fights.OverallData
		local baseline = {}
		for _, field in ipairs(TRACKED_TOTAL_FIELDS) do
			baseline[field] = fightData and fightData[field] or 0
		end
		overallBaseline[name] = baseline
	end
end

local function GetOverallBaseline(who, field)
	if not who or not field or not who.Name then
		return 0
	end

	local baseline = overallBaseline[who.Name]
	if not baseline then
		baseline = {}
		overallBaseline[who.Name] = baseline
	end

	if baseline[field] == nil then
		local fightData = who.Fights and who.Fights.OverallData
		baseline[field] = fightData and fightData[field] or 0
	end

	return baseline[field] or 0
end

local function ResetSnapshotCombatant(who)
	if not who or not who.Fights then
		return
	end

	local currentFight = who.Fights.CurrentFightData
	local overallFight = who.Fights.OverallData
	if not currentFight or not overallFight then
		return
	end

	for _, field in ipairs(TRACKED_TOTAL_FIELDS) do
		currentFight[field] = 0
		overallFight[field] = GetOverallBaseline(who, field)
	end

	for _, field in ipairs(TRACKED_RATE_FIELDS) do
		currentFight[field] = 0
		overallFight[field] = 0
	end

	who.LastFightIn = nil
end

local function ResetSnapshotData()
	if not dbCombatants then
		return
	end

	for _, who in pairs(dbCombatants) do
		ResetSnapshotCombatant(who)
	end
end

local function StoreSecretValue(modeKey, combatantName, rawValue, rawPerSec, rawLabel)
	if not modeKey or not combatantName then return end
	if not IsSecret(rawValue) and not IsSecret(rawPerSec) then return end

	local modeData = secretDisplayValues[modeKey]
	if not modeData then
		modeData = {}
		secretDisplayValues[modeKey] = modeData
	end

	modeData[combatantName] = {
		value = rawValue,
		perSec = rawPerSec,
		label = rawLabel,
	}
end

local function StoreSecretBarValue(modeKey, combatantName, rawValue, rawPerSec, rank)
	if not modeKey or not combatantName then
		return
	end

	local modeData = secretBarValues[modeKey]
	if not modeData then
		modeData = { entries = {} }
		secretBarValues[modeKey] = modeData
	end

	modeData.entries[combatantName] = {
		value = rawValue,
		perSec = rawPerSec,
		rank = rank,
	}
end

local function SetSecretBarScale(modeKey, rawMaxValue, rawMaxPerSec)
	if not modeKey then
		return
	end

	local modeData = secretBarValues[modeKey]
	if not modeData then
		modeData = { entries = {} }
		secretBarValues[modeKey] = modeData
	end

	modeData.maxValue = rawMaxValue
	modeData.maxPerSec = rawMaxPerSec
end

local function GetSecretValue(modeKey, combatantName)
	local modeData = secretDisplayValues[modeKey]
	return modeData and modeData[combatantName] or nil
end

local function GetSecretBarValue(modeKey, combatantName)
	local modeData = secretBarValues[modeKey]
	return modeData and modeData.entries and modeData.entries[combatantName] or nil
end

local function GetMainWindowModeKey(modeData)
	local modeName = modeData and modeData[1]
	local modeCategory = modeData and modeData[7]

	if modeName == L["DPS"] then
		return "Damage", true
	end
	if modeCategory == "Damage" then
		return "Damage", false
	end
	if modeCategory == "Healing" then
		return "Healing", false
	end
	if modeCategory == "DamageTaken" then
		return "DamageTaken", false
	end
	if modeName == L["Absorbs"] then
		return "Absorbs", false
	end
	if modeName == L["Interrupts"] then
		return "Interrupts", false
	end
	if modeName == L["Dispels"] then
		return "Dispels", false
	end
	if modeName == L["Deaths"] then
		return "Deaths", false
	end

	return nil, false
end

local function IsProxyCombatantName(name)
	return type(name) == "string" and string_find(name, "^" .. PROXY_PREFIX) ~= nil
end

local function ClearProxyCombatants()
	if not dbCombatants then return end

	for name in pairs(dbCombatants) do
		if IsProxyCombatantName(name) then
			dbCombatants[name] = nil
		end
	end
end

local function MoveNamedState(map, oldName, newName)
	if not map or not oldName or not newName or oldName == newName then
		return
	end

	if map[oldName] and map[newName] == nil then
		map[newName] = map[oldName]
	end
	map[oldName] = nil
end

local function RenameCombatant(oldName, newName)
	if not dbCombatants or not oldName or not newName or oldName == newName then
		return dbCombatants and dbCombatants[newName] or nil
	end

	local who = dbCombatants[oldName]
	if not who then
		return dbCombatants[newName]
	end

	if dbCombatants[newName] and dbCombatants[newName] ~= who then
		return dbCombatants[newName]
	end

	dbCombatants[oldName] = nil
	who.Name = newName
	dbCombatants[newName] = who

	for _, modeData in pairs(secretDisplayValues) do
		MoveNamedState(modeData, oldName, newName)
	end
	for _, modeData in pairs(secretBarValues) do
		if modeData and modeData.entries then
			MoveNamedState(modeData.entries, oldName, newName)
		end
	end
	MoveNamedState(overallBaseline, oldName, newName)

	return who
end

-- Safe value access for secret values
local function SafeNumber(val)
	if val == nil then return 0 end
	if issecretvalue and issecretvalue(val) then return 0 end
	return tonumber(val) or 0
end

-- Get a numeric value for display/sorting, handling secret values
-- For secret values: uses order-based synthetic value since arithmetic is blocked
-- orderIndex: 1-based index from the sorted combatSources array (1 = highest)
local function GetDisplayNumber(val, orderIndex)
	if val == nil then return 0 end
	if not (issecretvalue and issecretvalue(val)) then
		return tonumber(val) or 0
	end
	-- Value is secret - use synthetic value based on sort order
	-- API returns sources sorted highest-first, so index 1 = top
	return math.max(1, 1000 - (orderIndex or 1))
end

local function SafeString(val)
	if val == nil then return nil end
	if issecretvalue and issecretvalue(val) then return nil end
	return tostring(val)
end

IsSecret = function(val)
	return val ~= nil and issecretvalue and issecretvalue(val)
end

local function GetEnClass(classFilename)
	if not classFilename or classFilename == "" then return "UNKNOWN" end
	if issecretvalue and issecretvalue(classFilename) then return "UNKNOWN" end
	return classFilename:upper()
end

-- Build a roster lookup table for name resolution during combat
local rosterCache = {}
local rosterCacheTime = 0

local function RefreshRosterCache()
	local now = GetTime()
	if now - rosterCacheTime < 2 then return end -- refresh at most every 2 sec
	rosterCacheTime = now
	wipe(rosterCache)

	-- Add self
	local playerName = UnitName("player")
	if playerName then
		local _, playerClass = UnitClass("player")
		rosterCache[playerName] = {
			name = playerName,
			class = playerClass,
			role = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player") or nil,
		}
	end

	-- Add group/raid members
	local numGroup = GetNumGroupMembers and GetNumGroupMembers() or 0
	local prefix = IsInRaid and IsInRaid() and "raid" or "party"
	for i = 1, numGroup do
		local unit = prefix .. i
		local uName = UnitName(unit)
		if uName then
			local _, uClass = UnitClass(unit)
			rosterCache[uName] = {
				name = uName,
				class = uClass,
				role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit) or nil,
			}
		end
	end
end

local function ResolveUniqueRosterName(source)
	RefreshRosterCache()

	local desiredClass = GetEnClass(source.classFilename)
	if desiredClass == "UNKNOWN" or desiredClass == "MOB" then
		return nil
	end

	local desiredRole = SafeString(source.role)
	local playerName = UnitName("player")
	local classMatch
	local classCount = 0
	local roleMatch
	local roleCount = 0

	for name, rosterEntry in pairs(rosterCache) do
		if name ~= playerName and rosterEntry.class == desiredClass then
			classMatch = name
			classCount = classCount + 1
			if desiredRole and desiredRole ~= "" and rosterEntry.role == desiredRole then
				roleMatch = name
				roleCount = roleCount + 1
			end
		end
	end

	if desiredRole and desiredRole ~= "" and roleCount == 1 then
		return roleMatch
	end

	if classCount == 1 then
		return classMatch
	end

	return nil
end

-- Resolve a combatant name from source, handling secret values
local function ResolveName(source, orderIndex)
	-- Try direct access first (non-secret)
	local name = SafeString(source.name)
	if name then return name end

	-- Name is secret - use known info to identify the player
	if source.isLocalPlayer then
		return UnitName("player")
	end

	local rosterName = ResolveUniqueRosterName(source)
	if rosterName then
		return rosterName
	end

	-- For other live group members, keep an opaque internal key and render the
	-- secret name directly in the UI. Realtime session rows are damage-sorted, so
	-- guessing from party order is unreliable and causes identity swaps.
	local guid = SafeString(source.sourceGUID)
	if guid then
		return PROXY_PREFIX .. guid
	end

	return PROXY_PREFIX .. tostring(orderIndex or 0)
end

-- Find or create a combatant from C_DamageMeter source data
local function GetOrCreateCombatant(source, orderIndex)
	if not source then return nil end

	local name = ResolveName(source, orderIndex)
	if not name then return nil end

	local guid = SafeString(source.sourceGUID)
	local classFilename = GetEnClass(source.classFilename)

	if guid then
		for existingName, existingCombatant in pairs(dbCombatants) do
			if existingCombatant and existingCombatant.GUID == guid then
				if existingName ~= name and not IsProxyCombatantName(name) then
					return RenameCombatant(existingName, name)
				end
				return existingCombatant
			end
		end
	end

	if dbCombatants[name] then
		local who = dbCombatants[name]
		if guid and not who.GUID then
			who.GUID = guid
		end
		return who
	end

	local combatant = {}
	combatant.Name = name
	combatant.GUID = guid
	combatant.Owner = false
	combatant.enClass = classFilename
	combatant.level = UnitLevel("player") or 1

	if source.isLocalPlayer then
		combatant.type = "Self"
		local _
		_, combatant.enClass = UnitClass("player")
		combatant.level = UnitLevel("player")
	elseif classFilename ~= "UNKNOWN" and classFilename ~= "MOB" and classFilename ~= "" then
		combatant.type = "Grouped"
	else
		combatant.type = "Ungrouped"
	end

	combatant.Fights = {}
	combatant.Fights.OverallData = {}
	Recount:InitFightData(combatant.Fights.OverallData)
	combatant.Fights.CurrentFightData = {}
	Recount:InitFightData(combatant.Fights.CurrentFightData)

	combatant.TimeWindows = {}
	combatant.TimeLast = {}
	combatant.LastEvents = {}
	combatant.LastEventTimes = {}
	combatant.LastEventType = {}
	combatant.LastEventIncoming = {}
	combatant.LastEventHealth = {}
	combatant.LastEventHealthMax = {}
	combatant.NextEventNum = 1
	combatant.Pet = {}

	dbCombatants[name] = combatant
	DP("Created combatant: " .. name .. " type=" .. combatant.type .. " class=" .. combatant.enClass)
	return combatant
end

-- Fetch a session - try combat session ID, then Current type, then Overall type
local function GetSession(dmType)
	local ok, session

	-- Try by specific combat session ID first
	if combatSessionID then
		ok, session = pcall(C_DamageMeter.GetCombatSessionFromID, combatSessionID, dmType)
		if ok and session and session.combatSources and #session.combatSources > 0 then
			return session
		end
	end

	-- Try Current session type
	ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, DM_Current, dmType)
	if ok and session and session.combatSources and #session.combatSources > 0 then
		return session
	end

	-- Try Overall session type
	ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, DM_Overall, dmType)
	if ok and session and session.combatSources and #session.combatSources > 0 then
		return session
	end

	return nil
end

-- Get spell source data for a combatant
local function GetSpellSource(dmType, guid, sessionType)
	local ok, sourceData

	if sessionType == DM_Overall then
		ok, sourceData = pcall(C_DamageMeter.GetCombatSessionSourceFromType, DM_Overall, dmType, guid)
		if ok and sourceData and sourceData.combatSpells and #sourceData.combatSpells > 0 then
			return sourceData
		end
		return nil
	elseif sessionType == DM_Current then
		ok, sourceData = pcall(C_DamageMeter.GetCombatSessionSourceFromType, DM_Current, dmType, guid)
		if ok and sourceData and sourceData.combatSpells and #sourceData.combatSpells > 0 then
			return sourceData
		end
		return nil
	end

	if combatSessionID then
		ok, sourceData = pcall(C_DamageMeter.GetCombatSessionSourceFromID, combatSessionID, dmType, guid)
		if ok and sourceData and sourceData.combatSpells and #sourceData.combatSpells > 0 then
			return sourceData
		end
	end

	return nil
end

local function ApplySpellBreakdown(fightData, sourceData, datatypeAttacks)
	if not fightData or not datatypeAttacks or not sourceData or not sourceData.combatSpells then
		return 0
	end

	fightData[datatypeAttacks] = fightData[datatypeAttacks] or {}
	wipe(fightData[datatypeAttacks])

	local spellCount = 0
	for _, spell in ipairs(sourceData.combatSpells) do
		local spellID = spell.spellID
		local amount = SafeNumber(spell.totalAmount)
		if spellID and amount > 0 then
			local spellName
			if C_Spell and C_Spell.GetSpellInfo then
				local info = C_Spell.GetSpellInfo(spellID)
				spellName = info and info.name
			end
			spellName = spellName or ("Spell " .. spellID)

			fightData[datatypeAttacks][spellName] = {
				count = 1,
				amount = amount,
				Details = {
					["Hit"] = {
						count = 1,
						amount = amount,
						max = amount,
						min = amount,
					}
				}
			}
			spellCount = spellCount + 1
		end
	end

	return spellCount
end

-- Add spell breakdown data for a combatant
local function AddSpellBreakdown(who, dmType, datatypeAttacks)
	if not who then return end

	local guid = who.GUID
	if not guid or IsSecret(guid) then
		DP("  No GUID for spell lookup: " .. (who.Name or "?"))
		return
	end

	local currentSource = GetSpellSource(dmType, guid, DM_Current)
	if currentSource then
		ApplySpellBreakdown(who.Fights and who.Fights.CurrentFightData, currentSource, datatypeAttacks)
	end

	local overallSource = GetSpellSource(dmType, guid, DM_Overall)
	if not overallSource or not overallSource.combatSpells then
		DP("  No spell source data for " .. (who.Name or "?") .. " dmType=" .. dmType .. " guid=" .. guid)
		return
	end

	local spellCount = ApplySpellBreakdown(who.Fights and who.Fights.OverallData, overallSource, datatypeAttacks)
	DP("  Spells for " .. (who.Name or "?") .. " dmType=" .. dmType .. ": " .. spellCount)
end

-- Snapshot current DM data into CurrentFightData (replace, not accumulate)
local function SnapshotSession(verbose)
	local sessionDuration = 0
	local foundAny = false

	ClearSecretDisplayValues()
	ClearSecretBarValues()
	ResetSnapshotData()

	local session = GetSession(DM_DamageDone)
	if not session or not session.combatSources then
		if verbose then DP("  No DamageDone session found") end
		return false
	end

	if verbose then DP("  DamageDone: " .. #session.combatSources .. " sources") end
	SetSecretBarScale("Damage", session.maxAmount, session.combatSources[1] and session.combatSources[1].amountPerSecond or nil)

	if session.durationSeconds then
		sessionDuration = GetDisplayNumber(session.durationSeconds, 1)
	end
	if sessionDuration <= 0 and Recount.InCombatT2 then
		sessionDuration = math.max(0.1, GetTime() - Recount.InCombatT2)
	end

	local function SetTrackedValue(who, dataField, amount, rateField, perSec)
		if not who or not who.Fights then
			return
		end

		local currentFight = who.Fights.CurrentFightData
		local overallFight = who.Fights.OverallData
		if not currentFight or not overallFight then
			return
		end

		currentFight[dataField] = amount
		overallFight[dataField] = GetOverallBaseline(who, dataField) + amount
		if rateField then
			currentFight[rateField] = perSec
			overallFight[rateField] = perSec
		end
	end

	local hasSecrets = false
	for i, source in ipairs(session.combatSources) do
		-- Check if values are secret (API sorts sources highest-first)
		local isSecretAmount = IsSecret(source.totalAmount)
		if isSecretAmount then hasSecrets = true end

		if verbose and i == 1 then
			DP("  First source secret check: name=" .. tostring(IsSecret(source.name)) .. " amount=" .. tostring(isSecretAmount))
		end

		local who = GetOrCreateCombatant(source, i)
		if who then
			local amount = GetDisplayNumber(source.totalAmount, i)
			local dps = GetDisplayNumber(source.amountPerSecond, i)
			if amount > 0 or dps > 0 then
				SetTrackedValue(who, "Damage", amount, "DamagePerSecond", dps)
				who.LastFightIn = Recount.db2.FightNum
				foundAny = true

					if who.Name then
						StoreSecretValue("Damage", who.Name, source.totalAmount, source.amountPerSecond, source.name)
						StoreSecretBarValue("Damage", who.Name, source.totalAmount, source.amountPerSecond, i)
						if verbose and (IsSecret(source.totalAmount) or IsSecret(source.amountPerSecond)) then
							DP("  Stored damage secrets for: " .. who.Name)
						end
				elseif verbose and (IsSecret(source.totalAmount) or IsSecret(source.amountPerSecond)) then
					DP("  who.Name is nil, cannot store damage secrets")
				end

				if source.isLocalPlayer and Recount.FightingWho == "" then
					Recount.FightingWho = GENERIC_FIGHT_NAME
				end
			end
		end
	end

	if verbose then
		DP("  hasSecrets=" .. tostring(hasSecrets) .. " foundAny=" .. tostring(foundAny))
	end

	if sessionDuration > 0 then
		for _, who in pairs(dbCombatants) do
			if who.LastFightIn == Recount.db2.FightNum then
				who.Fights.CurrentFightData.ActiveTime = sessionDuration
				who.Fights.CurrentFightData.TimeDamage = sessionDuration
				who.Fights.CurrentFightData.TimeHeal = sessionDuration
				who.Fights.OverallData.ActiveTime = GetOverallBaseline(who, "ActiveTime") + sessionDuration
				who.Fights.OverallData.TimeDamage = GetOverallBaseline(who, "TimeDamage") + sessionDuration
				who.Fights.OverallData.TimeHeal = GetOverallBaseline(who, "TimeHeal") + sessionDuration
			end
		end
	end

	local function ProcessType(dmType, dataField, rateField, secretKey)
		local s = GetSession(dmType)
		if s and s.combatSources then
			if secretKey then
				SetSecretBarScale(secretKey, s.maxAmount, s.combatSources[1] and s.combatSources[1].amountPerSecond or nil)
			end
			for idx, source in ipairs(s.combatSources) do
				local who = GetOrCreateCombatant(source, idx)
				if who then
					local amount = GetDisplayNumber(source.totalAmount, idx)
					local perSec = rateField and GetDisplayNumber(source.amountPerSecond, idx) or 0
					if amount > 0 or perSec > 0 then
						SetTrackedValue(who, dataField, amount, rateField, perSec)
						who.LastFightIn = Recount.db2.FightNum
						foundAny = true
						if who.Name and secretKey then
							StoreSecretValue(secretKey, who.Name, source.totalAmount, source.amountPerSecond, source.name)
							StoreSecretBarValue(secretKey, who.Name, source.totalAmount, source.amountPerSecond, idx)
						end
					end
				end
			end
		end
	end

	ProcessType(DM_HealingDone, "Healing", "HealingPerSecond", "Healing")
	ProcessType(DM_Absorbs, "Absorbs", "AbsorbPerSecond", "Absorbs")
	ProcessType(DM_DamageTaken, "DamageTaken", "DamageTakenPerSecond", "DamageTaken")
	ProcessType(DM_Interrupts, "Interrupts", nil, "Interrupts")
	ProcessType(DM_Dispels, "Dispels", nil, "Dispels")
	ProcessType(DM_Deaths, "DeathCount", nil, "Deaths")

	Recount.NewData = true
	return foundAny
end

-- Full parse: final snapshot + spell breakdowns
local function ParseSessionFull()
	DP("ParseSessionFull: combatSessionID=" .. tostring(combatSessionID))
	local foundAny = SnapshotSession(true)

	if foundAny then
		-- Spell breakdowns
		for _, who in pairs(dbCombatants) do
			if who.LastFightIn == Recount.db2.FightNum then
				AddSpellBreakdown(who, DM_DamageDone, "Attacks")
				AddSpellBreakdown(who, DM_HealingDone, "Heals")
			end
		end
	end

	DP("ParseSessionFull: foundAny=" .. tostring(foundAny))
	return foundAny
end

-- Real-time update during combat
local tickCount = 0
local function UpdateTick()
	SafeCombatCall("UpdateTick", function()
		if not Recount.InCombat then
			if updateTicker then
				updateTicker:Cancel()
				updateTicker = nil
			end
			return
		end

		tickCount = tickCount + 1
		local found = SnapshotSession(tickCount <= 2) -- verbose on first two ticks
		if tickCount <= 3 then
			DP("UpdateTick #" .. tickCount .. ": found=" .. tostring(found) .. " sessionID=" .. tostring(combatSessionID))
		end

		if found then
			if Recount.FightingWho == "" then
				Recount.FightingWho = GENERIC_FIGHT_NAME
			end
			Recount.NewData = true
			if Recount.RefreshMainWindow then
				Recount:RefreshMainWindow()
			end
		end
	end)
end

local function StartUpdateTicker()
	if updateTicker then
		updateTicker:Cancel()
	end
	tickCount = 0
	DP("Starting update ticker")
	updateTicker = C_Timer.NewTicker(0.5, UpdateTick)
end

local function StopUpdateTicker()
	if updateTicker then
		updateTicker:Cancel()
		updateTicker = nil
	end
end

-- Called when combat ends
local function OnCombatEnd()
	StopUpdateTicker()
	DP("OnCombatEnd: InCombat=" .. tostring(Recount.InCombat) .. " sessionID=" .. tostring(combatSessionID))

	C_Timer.After(0.5, function()
		DP("End timer fired: InCombat=" .. tostring(Recount.InCombat))

		-- Clear secret display values - real values are now available
		ClearSecretDisplayValues()
		ClearProxyCombatants()

		-- Reset CurrentFightData before final parse
		for _, who in pairs(dbCombatants) do
			if who.LastFightIn == Recount.db2.FightNum and who.Fights and who.Fights.CurrentFightData then
				for _, f in ipairs({"Damage", "DamagePerSecond", "Healing", "HealingPerSecond", "Absorbs", "AbsorbPerSecond", "DamageTaken", "DamageTakenPerSecond", "Interrupts", "Dispels", "DeathCount", "ActiveTime", "TimeDamage", "TimeHeal"}) do
					who.Fights.CurrentFightData[f] = 0
				end
			end
		end

		ParseSessionFull()

		if Recount.FightingWho == "" then
			Recount.FightingWho = GENERIC_FIGHT_NAME
		end

		DP("Calling LeaveCombat, FightingWho=" .. Recount.FightingWho)
		Recount:LeaveCombat(GetTime())
		Recount:FullRefreshMainWindow()

		-- Keep combatSessionID for potential post-combat queries, but it will be reset on next combat
	end)
end

-- Event handlers
local function OnEvent(self, event, ...)
	if event == "PLAYER_REGEN_DISABLED" then
		if not Recount.db.profile.GlobalDataCollect or not Recount.CurrentDataCollect then
			DP("REGEN_DISABLED but data collect is off: Global=" .. tostring(Recount.db.profile.GlobalDataCollect) .. " Current=" .. tostring(Recount.CurrentDataCollect))
			return
		end
		DP("PLAYER_REGEN_DISABLED - combat start")
		combatSessionID = nil
		ClearSecretDisplayValues()
		ClearProxyCombatants()
		Recount:PutInCombat()
		CaptureOverallBaseline()
		StartUpdateTicker()

	elseif event == "PLAYER_REGEN_ENABLED" then
		DP("PLAYER_REGEN_ENABLED - InCombat=" .. tostring(Recount.InCombat))
		if not Recount.InCombat then return end
		OnCombatEnd()

	elseif event == "DAMAGE_METER_COMBAT_SESSION_UPDATED" then
		local dmType, sessionId = ...
		-- Only track non-zero session IDs (0 is the "overall" session)
		if sessionId and sessionId > 0 then
			combatSessionID = sessionId
		end

	elseif event == "DAMAGE_METER_CURRENT_SESSION_UPDATED" then
		Recount.NewData = true

	elseif event == "DAMAGE_METER_RESET" then
		DP("DAMAGE_METER_RESET")
		ClearOverallBaseline()
		if not Recount._resettingData then
			Recount:ResetData()
		end

	elseif event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
		Recount:BossFound()
	end
end

dmFrame:SetScript("OnEvent", OnEvent)

function Recount:InitDamageMeterTracker()
	dbCombatants = Recount.db2.combatants
	DP("InitDamageMeterTracker called, available=" .. tostring(C_DamageMeter.IsDamageMeterAvailable()))

	dmFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
	dmFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
	dmFrame:RegisterEvent("DAMAGE_METER_COMBAT_SESSION_UPDATED")
	dmFrame:RegisterEvent("DAMAGE_METER_CURRENT_SESSION_UPDATED")
	dmFrame:RegisterEvent("DAMAGE_METER_RESET")
	dmFrame:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")

	DP("Init complete")
end

local originalResetDataUnsafe = Recount.ResetDataUnsafe
function Recount:ResetDataUnsafe()
	DP("ResetDataUnsafe called")
	Recount._resettingData = true
	if originalResetDataUnsafe then
		originalResetDataUnsafe(self)
	end
	Recount._resettingData = false
	dbCombatants = Recount.db2.combatants
	combatSessionID = nil
	ClearSecretDisplayValues()
	ClearProxyCombatants()
	ClearOverallBaseline()
	DP("ResetDataUnsafe complete")
end

local function FormatRealtimeValue(value)
	if value == nil then
		return nil
	end

	if IsSecret(value) then
		local ok, text = pcall(string_format, "%.0f", value)
		if ok and text then
			return text
		end

		ok, text = pcall(string_format, "%s", value)
		if ok and text then
			return text
		end

		return nil
	end

	return Recount:FormatLongNums(value)
end

local function GetMainWindowSecretEntry(modeData, combatantName)
	if not modeData or not combatantName then
		return nil, nil
	end

	local modeKey, useRate = GetMainWindowModeKey(modeData)
	if not modeKey then
		return nil, nil
	end

	return GetSecretValue(modeKey, combatantName), useRate
end

function Recount:GetMainWindowBarLabelOverride(combatant, modeIndex, rank)
	if not self.UseDamageMeter or not self.InCombat then
		return nil
	end

	local combatantName = type(combatant) == "table" and combatant.Name or combatant
	if not combatantName then
		return nil
	end

	local modeData = self.MainWindowData and self.MainWindowData[modeIndex]
	local entry = select(1, GetMainWindowSecretEntry(modeData, combatantName))
	local label = entry and entry.label
	if not label then
		return nil
	end

	if self.db.profile.MainWindow.BarText.RankNum and rank then
		local ok, text = pcall(string_format, "%d. %s", rank, label)
		if ok and text then
			return text
		end
	end

	return label
end

function Recount:GetMainWindowBarTextOverride(combatant, modeIndex)
	if not self.UseDamageMeter or not self.InCombat then
		return nil
	end

	local combatantName = type(combatant) == "table" and combatant.Name or combatant
	if not combatantName then
		return nil
	end

	local modeData = self.MainWindowData and self.MainWindowData[modeIndex]
	local modeCategory = modeData and modeData[7]
	if modeCategory == "Healing" and self.db and self.db.profile and self.db.profile.MergeAbsorbs then
		local healingEntry = GetSecretValue("Healing", combatantName)
		local absorbEntry = GetSecretValue("Absorbs", combatantName)
		if healingEntry or absorbEntry then
			local healingValueText = FormatRealtimeValue(healingEntry and healingEntry.value)
			local absorbValueText = FormatRealtimeValue(absorbEntry and absorbEntry.value)

			if healingEntry and absorbEntry and not IsSecret(healingEntry.value) and not IsSecret(absorbEntry.value) then
				healingValueText = Recount:FormatLongNums(SafeNumber(healingEntry.value) + SafeNumber(absorbEntry.value))
				absorbValueText = nil
			end

			if healingValueText then
				local valueText = absorbValueText and string_format("%s + %s", healingValueText, absorbValueText) or healingValueText
				return valueText
			end
		end
	end

	local entry, useRate = GetMainWindowSecretEntry(modeData, combatantName)
	if not entry then
		return nil
	end

	local valueText = FormatRealtimeValue(useRate and entry.perSec or entry.value)
	if not valueText then
		return nil
	end

	return valueText
end

function Recount:GetMainWindowBarValueOverride(combatant, modeIndex)
	if not self.UseDamageMeter or not self.InCombat then
		return nil
	end

	local combatantName = type(combatant) == "table" and combatant.Name or combatant
	if not combatantName then
		return nil
	end

	local modeData = self.MainWindowData and self.MainWindowData[modeIndex]
	local modeCategory = modeData and modeData[7]

	if modeCategory == "Healing" and self.db and self.db.profile and self.db.profile.MergeAbsorbs then
		return nil
	end

	local modeKey, useRate = GetMainWindowModeKey(modeData)
	if not modeKey then
		return nil
	end

	local modeBarData = secretBarValues[modeKey]
	local entry = GetSecretBarValue(modeKey, combatantName)
	if not modeBarData or not entry then
		return nil
	end

	local value = useRate and entry.perSec or entry.value
	local maxValue = useRate and modeBarData.maxPerSec or modeBarData.maxValue
	if value == nil or maxValue == nil then
		return nil
	end

	return value, maxValue
end

function Recount:HasMainWindowLiveEntry(combatant, modeIndex)
	if not self.UseDamageMeter or not self.InCombat then
		return false
	end

	local combatantName = type(combatant) == "table" and combatant.Name or combatant
	if not combatantName then
		return false
	end

	local modeData = self.MainWindowData and self.MainWindowData[modeIndex]
	local modeCategory = modeData and modeData[7]
	if modeCategory == "Healing" and self.db and self.db.profile and self.db.profile.MergeAbsorbs then
		return GetSecretBarValue("Healing", combatantName) ~= nil or GetSecretBarValue("Absorbs", combatantName) ~= nil
	end

	local modeKey = GetMainWindowModeKey(modeData)
	if not modeKey then
		return false
	end

	return GetSecretBarValue(modeKey, combatantName) ~= nil
end

function Recount:GetMainWindowSortRankOverride(combatant, modeIndex)
	if not self.UseDamageMeter or not self.InCombat then
		return nil
	end

	local combatantName = type(combatant) == "table" and combatant.Name or combatant
	if not combatantName then
		return nil
	end

	local modeData = self.MainWindowData and self.MainWindowData[modeIndex]
	local modeCategory = modeData and modeData[7]
	if modeCategory == "Healing" and self.db and self.db.profile and self.db.profile.MergeAbsorbs then
		return nil
	end

	local modeKey = GetMainWindowModeKey(modeData)
	if not modeKey then
		return nil
	end

	local entry = GetSecretBarValue(modeKey, combatantName)
	return entry and entry.rank or nil
end

SafeCombatCall = function(context, func)
	local ok, err = xpcall(func, function(message)
		return SafeDebugText(message)
	end)

	if not ok then
		DE(context .. " error: " .. SafeDebugText(err))
	end

	return ok
end
