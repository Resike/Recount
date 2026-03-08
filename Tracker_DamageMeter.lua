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
local date = date
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

-- Secret value display cache, keyed by mode then combatant name.
-- Raw secret values are only used for UI text while synthetic numeric values drive sorting.
local secretDisplayValues = {}

local function ClearSecretDisplayValues()
	for _, modeData in pairs(secretDisplayValues) do
		wipe(modeData)
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

local function GetSecretValue(modeKey, combatantName)
	local modeData = secretDisplayValues[modeKey]
	return modeData and modeData[combatantName] or nil
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
		rosterCache[playerName] = { name = playerName, class = playerClass }
	end

	-- Add group/raid members
	local numGroup = GetNumGroupMembers and GetNumGroupMembers() or 0
	local prefix = IsInRaid and IsInRaid() and "raid" or "party"
	for i = 1, numGroup do
		local unit = prefix .. i
		local uName = UnitName(unit)
		if uName then
			local _, uClass = UnitClass(unit)
			rosterCache[uName] = { name = uName, class = uClass }
		end
	end
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

	-- Try roster matching by order (best effort during combat)
	RefreshRosterCache()
	local rosterNames = {}
	for rName in pairs(rosterCache) do
		rosterNames[#rosterNames + 1] = rName
	end
	table.sort(rosterNames)
	if orderIndex and rosterNames[orderIndex] then
		return rosterNames[orderIndex]
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
local function GetSpellSource(dmType, guid)
	local ok, sourceData

	if combatSessionID then
		ok, sourceData = pcall(C_DamageMeter.GetCombatSessionSourceFromID, combatSessionID, dmType, guid)
		if ok and sourceData and sourceData.combatSpells and #sourceData.combatSpells > 0 then
			return sourceData
		end
	end

	ok, sourceData = pcall(C_DamageMeter.GetCombatSessionSourceFromType, DM_Current, dmType, guid)
	if ok and sourceData and sourceData.combatSpells and #sourceData.combatSpells > 0 then
		return sourceData
	end

	ok, sourceData = pcall(C_DamageMeter.GetCombatSessionSourceFromType, DM_Overall, dmType, guid)
	if ok and sourceData and sourceData.combatSpells and #sourceData.combatSpells > 0 then
		return sourceData
	end

	return nil
end

-- Add spell breakdown data for a combatant
local function AddSpellBreakdown(who, dmType, datatypeAttacks)
	if not who then return end

	local guid = who.GUID
	if not guid or IsSecret(guid) then
		DP("  No GUID for spell lookup: " .. (who.Name or "?"))
		return
	end

	local sourceData = GetSpellSource(dmType, guid)
	if not sourceData or not sourceData.combatSpells then
		DP("  No spell source data for " .. (who.Name or "?") .. " dmType=" .. dmType .. " guid=" .. guid)
		return
	end

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

			if datatypeAttacks and who.Fights then
				for _, fightKey in ipairs({"CurrentFightData", "OverallData"}) do
					local fightData = who.Fights[fightKey]
					if fightData then
						fightData[datatypeAttacks] = fightData[datatypeAttacks] or {}
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
					end
				end
			end
			spellCount = spellCount + 1
		end
	end
	DP("  Spells for " .. (who.Name or "?") .. " dmType=" .. dmType .. ": " .. spellCount)
end

-- Snapshot current DM data into CurrentFightData (replace, not accumulate)
local function SnapshotSession(verbose)
	local sessionDuration = 0
	local foundAny = false

	ClearSecretDisplayValues()

	local session = GetSession(DM_DamageDone)
	if not session or not session.combatSources then
		if verbose then DP("  No DamageDone session found") end
		return false
	end

	if verbose then DP("  DamageDone: " .. #session.combatSources .. " sources") end

	if session.durationSeconds then
		sessionDuration = GetDisplayNumber(session.durationSeconds, 1)
	end
	if sessionDuration <= 0 and Recount.InCombatT2 then
		sessionDuration = math.max(0.1, GetTime() - Recount.InCombatT2)
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
				who.Fights.CurrentFightData.Damage = amount
				who.Fights.CurrentFightData.DamagePerSecond = dps
				who.Fights.OverallData.Damage = amount
				who.Fights.OverallData.DamagePerSecond = dps
				who.LastFightIn = Recount.db2.FightNum
				foundAny = true

				if who.Name then
					StoreSecretValue("Damage", who.Name, source.totalAmount, source.amountPerSecond, source.name)
					if verbose and (IsSecret(source.totalAmount) or IsSecret(source.amountPerSecond)) then
						DP("  Stored damage secrets for: " .. who.Name)
					end
				elseif verbose and (IsSecret(source.totalAmount) or IsSecret(source.amountPerSecond)) then
					DP("  who.Name is nil, cannot store damage secrets")
				end

				if source.isLocalPlayer and Recount.FightingWho == "" then
					Recount.FightingWho = "Combat"
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
				who.Fights.OverallData.ActiveTime = sessionDuration
				who.Fights.OverallData.TimeDamage = sessionDuration
				who.Fights.OverallData.TimeHeal = sessionDuration
			end
		end
	end

	local function ProcessType(dmType, dataField, rateField, secretKey)
		local s = GetSession(dmType)
		if s and s.combatSources then
			for idx, source in ipairs(s.combatSources) do
				local who = GetOrCreateCombatant(source, idx)
				if who then
					local amount = GetDisplayNumber(source.totalAmount, idx)
					local perSec = rateField and GetDisplayNumber(source.amountPerSecond, idx) or 0
					if amount > 0 or perSec > 0 then
						who.Fights.CurrentFightData[dataField] = amount
						who.Fights.OverallData[dataField] = amount
						if rateField then
							who.Fights.CurrentFightData[rateField] = perSec
							who.Fights.OverallData[rateField] = perSec
						end
						who.LastFightIn = Recount.db2.FightNum
						foundAny = true
						if who.Name and secretKey then
							StoreSecretValue(secretKey, who.Name, source.totalAmount, source.amountPerSecond, source.name)
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

-- Full parse: snapshot + copy to OverallData + spell breakdowns
local function ParseSessionFull()
	DP("ParseSessionFull: combatSessionID=" .. tostring(combatSessionID))
	local foundAny = SnapshotSession(true)

	if foundAny then
		-- Copy CurrentFightData to OverallData
		for _, who in pairs(dbCombatants) do
			if who.LastFightIn == Recount.db2.FightNum and who.Fights and who.Fights.CurrentFightData then
				who.Fights.OverallData = who.Fights.OverallData or {}
				local cur = who.Fights.CurrentFightData
				local ovr = who.Fights.OverallData
				for _, field in ipairs({"Damage", "DamagePerSecond", "Healing", "HealingPerSecond", "Absorbs", "AbsorbPerSecond", "DamageTaken", "DamageTakenPerSecond", "Interrupts", "Dispels", "DeathCount", "ActiveTime", "TimeDamage", "TimeHeal"}) do
					if cur[field] and cur[field] > 0 then
						if field == "DamagePerSecond" or field == "HealingPerSecond" or field == "AbsorbPerSecond" or field == "DamageTakenPerSecond" then
							ovr[field] = cur[field]
						else
							ovr[field] = (ovr[field] or 0) + cur[field]
						end
					end
				end
			end
		end

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
				Recount.FightingWho = "Combat"
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
			Recount.FightingWho = "Combat"
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

	local modeName = modeData[1]
	local modeCategory = modeData[7]

	if modeName == L["DPS"] then
		return GetSecretValue("Damage", combatantName), true
	end

	if modeCategory == "Damage" then
		return GetSecretValue("Damage", combatantName), false
	end

	if modeCategory == "Healing" then
		return GetSecretValue("Healing", combatantName), false
	end

	if modeCategory == "DamageTaken" then
		return GetSecretValue("DamageTaken", combatantName), false
	end

	if modeName == L["Absorbs"] then
		return GetSecretValue("Absorbs", combatantName), false
	end

	if modeName == L["Deaths"] then
		return GetSecretValue("Deaths", combatantName), false
	end

	return nil, nil
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
	local entry, useRate = GetMainWindowSecretEntry(modeData, combatantName)
	if not entry then
		return nil
	end

	local valueText = FormatRealtimeValue(useRate and entry.perSec or entry.value)
	if not valueText then
		return nil
	end

	if useRate then
		return valueText
	end

	local barText = self.db and self.db.profile and self.db.profile.MainWindow and self.db.profile.MainWindow.BarText
	if barText and barText.PerSec then
		local perSecText = FormatRealtimeValue(entry.perSec)
		if perSecText then
			return string_format("%s (%s)", valueText, perSecText)
		end
	end

	return valueText
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
