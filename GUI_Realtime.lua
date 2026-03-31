local Recount = _G.Recount

local Graph = LibStub:GetLibrary("LibGraph-2.0")
local AceLocale = LibStub("AceLocale-3.0")
local L = AceLocale:GetLocale("Recount")

local revision = tonumber(string.sub("$Revision: 1484 $", 12, -3))
if Recount.Version < revision
	then Recount.Version = revision
end

local debugstack = debugstack
local ipairs = ipairs
local math = math
local pairs = pairs
local string = string
local strsub = strsub
local table = table

local GetScreenHeight = GetScreenHeight
local GetScreenWidth = GetScreenWidth
local LD = LibStub("LibDropdown-1.0")

local ColorPickerFrame = ColorPickerFrame
local CreateFrame = CreateFrame

local UIFrameFade = UIFrameFade or function(frame, fadeInfo)
	if fadeInfo.mode == "OUT" then
		frame:SetAlpha(0)
	end
	if fadeInfo.finishedFunc then
		fadeInfo.finishedFunc(fadeInfo.finishedArg1)
	end
end

local UIParent = UIParent
local OpacitySliderFrame = OpacitySliderFrame

local WOW_RETAIL = WOW_PROJECT_ID == WOW_PROJECT_MAINLINE

local me = {}

local FreeWindows = {}
local WindowNum = 1

local Log2 = math.log(2)

function me:ResizeRealtimeWindow()
	self.Graph:SetWidth(self:GetWidth() - 3)
	self.Graph:SetHeight(self:GetHeight() - 33)
	self:UpdateTitle()
end

function me:DetermineGridSpacing()
	local MaxValue = self.Graph:GetMaxValue()
	local Spacing, Inbetween

	if MaxValue < 25 then
		Spacing = -1
	else
		Spacing = math.log(MaxValue / 100) / Log2
	end

	Inbetween = math.ceil(Spacing) - Spacing

	if Inbetween == 0 then
		Inbetween = 1
	end

	Spacing = 25 * math.pow(2, math.floor(Spacing))

	self.Graph:SetGridSpacing(1.0, Spacing)
	self.Graph:SetGridColorSecondary({0.5, 0.5, 0.5, 0.5 * Inbetween})
end

function Recount:UpdateTitle(theFrame)
	if theFrame:IsShown() then
		if theFrame.UpdateTitle then theFrame:UpdateTitle() else
			Recount:Print("Function UpdateTitle missing, please report stack!")
			Recount:Print(debugstack(2, 3, 2))
		end
	end
end

function me:UpdateTitle()
	self:DetermineGridSpacing()

	local Width, StartText, EndText
	Width = self:GetWidth() - 32
	StartText = self.TitleText
	EndText = " - "..Recount:FormatLongNums(self.Graph:GetValue(-0.05))

	self.Title:SetText(StartText..EndText)

	while self.Title:GetStringWidth() > Width do
		StartText = strsub(StartText, 1, #StartText - 1)
		self.Title:SetText(StartText.."..."..EndText)
	end
end

function me:SavePosition()
	local xOfs, yOfs = self:GetCenter() -- Elsia: This is clean code straight from ckknight's pitbull
	local s = self:GetEffectiveScale()
	local uis = UIParent:GetScale()
	xOfs = xOfs * s - GetScreenWidth() * uis / 2
	yOfs = yOfs * s - GetScreenHeight() * uis / 2

	if self.id and Recount.db.profile.RealtimeWindows[self.id] ~= nil then -- Elsia: Fixed bug for free'd realtime windows
		Recount.db.profile.RealtimeWindows[self.id][4] = xOfs / uis
		Recount.db.profile.RealtimeWindows[self.id][5] = yOfs / uis
		Recount.db.profile.RealtimeWindows[self.id][6] = self:GetWidth()
		Recount.db.profile.RealtimeWindows[self.id][7] = self:GetHeight()
		Recount.db.profile.RealtimeWindows[self.id][8] = true
	end
end

function me.FreeWindow(this)
	Recount:UnregisterTracking(this.id, this.who, this.tracking)
	table.insert(FreeWindows, this)
	Recount:CancelTimer(this.idtoken)
	if not Recount.profilechange then
		Recount.db.profile.RealtimeWindows[this.id][8] = false -- Elsia: set closed state
	end
end

function me.RestoreWindow(this)
	Recount.db.profile.RealtimeWindows[this.id][8] = true -- Elsia: it's open again
	Recount:RegisterTracking(this.id, this.who, this.tracking, this.Graph.AddTimeData, this.Graph)
	for i, v in ipairs(FreeWindows) do
		if v == this then
			table.remove(FreeWindows, i)
		end
	end
	this.UpdateTitle = me.UpdateTitle
	this.idtoken = Recount:ScheduleRepeatingTimer("UpdateTitle", 0.1, this)
end

function me:SetRealtimeColor()
	self.Graph:SetBarColors(Recount.Colors:GetColor("Realtime", self.TitleText.." Bottom"), Recount.Colors:GetColor("Realtime", self.TitleText.." Top"))
end

local WhichWindow
local Cur_Branch
local Cur_Name
local TempColor = {}

local function Color_Change()
	local r, g, b = ColorPickerFrame:GetColorRGB()

	TempColor.r = r
	TempColor.g = g
	TempColor.b = b
	if not ColorPickerFrame.hasOpacity then
		TempColor.a = nil
	else
		TempColor.a = WOW_RETAIL and ColorPickerFrame.Content.ColorPicker:GetColorAlpha() or 1.0 - OpacitySliderFrame:GetValue()
	end

	Recount.Colors:SetColor(Cur_Branch, Cur_Name, TempColor)
end

local function Opacity_Change()
	local r, g, b = ColorPickerFrame:GetColorRGB()
	local a = WOW_RETAIL and ColorPickerFrame.Content.ColorPicker:GetColorAlpha() or 1.0 - OpacitySliderFrame:GetValue()

	TempColor.r = r
	TempColor.g = g
	TempColor.b = b
	TempColor.a = a

	Recount.Colors:SetColor(Cur_Branch, Cur_Name, TempColor)
end


local colormenuframe

local function OpenColorPickerForEntry(branch, name, window)
	Cur_Branch = branch
	Cur_Name = name

	local color = Recount.Colors:GetColor("Realtime", name)

	TempColor.r = color.r
	TempColor.g = color.g
	TempColor.b = color.b
	TempColor.a = color.a

	ColorPickerFrame.hasOpacity = true
	ColorPickerFrame.opacity = color.a or 1
	ColorPickerFrame:SetColorRGB(color.r, color.g, color.b)
	ColorPickerFrame.func = Color_Change
	ColorPickerFrame.opacityFunc = Opacity_Change
	ColorPickerFrame.cancelFunc = function()
		Recount.Colors:SetColor(branch, name, TempColor)
	end

	ShowUIPanel(ColorPickerFrame)
end

local function Faded_Color(self)
	self:Release()
end

local function FadeColorMenu(frame)
	local fadeInfo = {}
	fadeInfo.mode = "OUT"
	fadeInfo.timeToFade = 0.1
	fadeInfo.finishedFunc = Faded_Color
	fadeInfo.finishedArg1 = frame
	UIFrameFade(frame, fadeInfo)
end

function Recount:ColorDropDownOpen(myframe)
	colormenuframe = colormenuframe and colormenuframe:Release()

	local coloropts = {
		type = "group",
		args = {
			topcolor = {
				order = 10,
				name = L["Top Color"],
				type = "execute",
				func = function()
					OpenColorPickerForEntry("Realtime", WhichWindow.TitleText.." Top", WhichWindow)
					if colormenuframe then
						FadeColorMenu(colormenuframe)
					end
				end,
			},
			bottomcolor = {
				order = 20,
				name = L["Bottom Color"],
				type = "execute",
				func = function()
					OpenColorPickerForEntry("Realtime", WhichWindow.TitleText.." Bottom", WhichWindow)
					if colormenuframe then
						FadeColorMenu(colormenuframe)
					end
				end,
			},
		}
	}

	colormenuframe = colormenuframe or LD:OpenAce3Menu(coloropts)
	colormenuframe:SetClampedToScreen(true)
	colormenuframe:SetAlpha(1.0)
	colormenuframe:Show()

	local leftPos = myframe:GetLeft() -- Elsia: Side code adapted from Mirror
	local rightPos = myframe:GetRight()
	local side
	local oside
	if not rightPos then
		rightPos = 0
	end
	if not leftPos then
		leftPos = 0
	end

	local rightDist = GetScreenWidth() - rightPos

	if leftPos and rightDist < leftPos then
		side = "TOPLEFT"
		oside = "TOPRIGHT"
	else
		side = "TOPRIGHT"
		oside = "TOPLEFT"
	end

	colormenuframe:ClearAllPoints()
	colormenuframe:SetPoint(oside, myframe, side, 0, 0)
end

function me:CreateRealtimeWindow(who, tracking, ending) -- Elsia: This function creates a new window and stores it. To other ways, either override it's storage or use the other function
	local theFrame = Recount:CreateFrame(nil, "", 232, 200, me.RestoreWindow, me.FreeWindow)

	theFrame:SetResizable(true)

	if theFrame.SetResizeBounds then
		theFrame:SetResizeBounds(150, 64, 400, 432)
	else
		theFrame:SetMinResize(150, 64)
		theFrame:SetMaxResize(400, 432)
	end

	theFrame:SetScript("OnSizeChanged", function(this)
		if (this.isResizing) then
			me.ResizeRealtimeWindow(this) -- Elsia: Changed self to this here to make it work!
		end
	end)

	if string.sub(who, 1, 1) ~= "!" then
		theFrame.TitleText = who..ending
	else
		theFrame.TitleText = ending
	end

	theFrame.Title:SetText(theFrame.TitleText.." - 0.0")

	theFrame.DragBottomRight = CreateFrame("Button", nil, theFrame)
	if not Recount.db.profile.Locked then
		theFrame.DragBottomRight:Show()
	else
		theFrame.DragBottomRight:Hide()
	end
	theFrame.DragBottomRight:SetFrameLevel( theFrame:GetFrameLevel() + 10)
	theFrame.DragBottomRight:SetNormalTexture("Interface\\AddOns\\Recount\\textures\\ResizeGripRight")
	theFrame.DragBottomRight:SetHighlightTexture("Interface\\AddOns\\Recount\\textures\\ResizeGripRight")
	theFrame.DragBottomRight:SetWidth(16)
	theFrame.DragBottomRight:SetHeight(16)
	theFrame.DragBottomRight:SetPoint("BOTTOMRIGHT", theFrame, "BOTTOMRIGHT", 0, 0)
	theFrame.DragBottomRight:EnableMouse(true)
	theFrame.DragBottomRight:SetScript("OnMouseDown", function(this, button)
		if (((not this:GetParent().isLocked) or (this:GetParent().isLocked == 0)) and (button == "LeftButton")) then
			this:GetParent().isResizing = true
			this:GetParent():StartSizing("BOTTOMRIGHT")
		end
	end) -- Elsia: Disallow resizing when locked
	theFrame.DragBottomRight:SetScript("OnMouseUp", function(this)
		if this:GetParent().isResizing == true then
			this:GetParent():StopMovingOrSizing()
			this:GetParent().isResizing = false
			this:GetParent():SavePosition()
		end
	end)

	theFrame.DragBottomLeft = CreateFrame("Button", nil, theFrame)
	if not Recount.db.profile.Locked then
		theFrame.DragBottomLeft:Show()
	else
		theFrame.DragBottomLeft:Hide()
	end
	theFrame.DragBottomLeft:SetFrameLevel( theFrame:GetFrameLevel() + 10)
	theFrame.DragBottomLeft:SetNormalTexture("Interface\\AddOns\\Recount\\textures\\ResizeGripLeft")
	theFrame.DragBottomLeft:SetHighlightTexture("Interface\\AddOns\\Recount\\textures\\ResizeGripLeft")
	theFrame.DragBottomLeft:SetWidth(16)
	theFrame.DragBottomLeft:SetHeight(16)
	theFrame.DragBottomLeft:SetPoint("BOTTOMLEFT", theFrame, "BOTTOMLEFT", 0, 0)
	theFrame.DragBottomLeft:EnableMouse(true)
	theFrame.DragBottomLeft:SetScript("OnMouseDown", function(this, button)
		if (((not this:GetParent().isLocked) or (this:GetParent().isLocked == 0)) and (button == "LeftButton")) then
			this:GetParent().isResizing = true
			this:GetParent():StartSizing("BOTTOMLEFT")
		end
	end) -- Elsia: Disallow resizing when locked
	theFrame.DragBottomLeft:SetScript("OnMouseUp", function(this)
		if this:GetParent().isResizing == true then
			this:GetParent():StopMovingOrSizing()
			this:GetParent().isResizing = false
			this:GetParent():SavePosition()
		end
	end)

	local g = Graph:CreateGraphRealtime("Recount_Realtime_"..who.."_"..tracking, theFrame, "BOTTOM", "BOTTOM", 0, 1, 197, 198)
	g:SetAutoScale(true)
	g:SetGridSpacing(1.0, 100)
	g:SetYMax(120)
	g:SetXAxis(-10, -0)
	g:SetMode("EXPFAST")
	g:SetDecay(0.5)
	g:SetFilterRadius(2)
	g:SetMinMaxY(100)
	g:SetBarColors(Recount.Colors:GetColor("Realtime", theFrame.TitleText.." Bottom"), Recount.Colors:GetColor("Realtime",theFrame.TitleText.." Top"))

	g:SetUpdateLimit(0.05)
	g:SetGridColorSecondary({0.5, 0.5, 0.5, 0.25})
	g:SetYLabels(true, true)
	g:SetGridSecondaryMultiple(1, 2)
	g.Window = theFrame

	g:EnableMouse(true)

	g:SetScript("OnMouseDown", function(self, button)
		WhichWindow = self.Window
		Recount:ColorDropDownOpen(WhichWindow)
	end)

	theFrame.DetermineGridSpacing = me.DetermineGridSpacing
	theFrame.Graph = g

	theFrame.id = "Realtime_"..who.."_"..tracking
	theFrame.who = who
	theFrame.ending = ending
	theFrame.tracking = tracking
	theFrame.SavePosition = me.SavePosition
	theFrame.ResizeRealtimeWindow = me.ResizeRealtimeWindow
	theFrame.UpdateTitle = me.UpdateTitle

	Recount.db.profile.RealtimeWindows[theFrame.id] = {who, tracking, ending}
	theFrame:StartMoving()
	theFrame:StopMovingOrSizing()
	theFrame:UpdateTitle()
	theFrame:SavePosition()

	Recount:RegisterTracking(theFrame.id, who, tracking, g.AddTimeData, g)

	--Need to add it to our window ordering system
	Recount:AddWindow(theFrame)

	theFrame.idtoken = Recount:ScheduleRepeatingTimer("UpdateTitle", 0.1, theFrame) -- (me.UpdateTitle

	Recount.Colors:RegisterFunction("Realtime", theFrame.TitleText.." Top", me.SetRealtimeColor, theFrame)
	Recount.Colors:RegisterFunction("Realtime", theFrame.TitleText.." Bottom", me.SetRealtimeColor, theFrame)

	return theFrame
end

function Recount:CreateRealtimeWindow(who, tracking, ending)

	local curID = "Realtime_"..who.."_"..tracking

	if Recount.db.profile.RealtimeWindows and Recount.db.profile.RealtimeWindows[curID] and Recount.db.profile.RealtimeWindows[curID][8] == true then -- Don't allow opening twice
		return
	end

	local Window = table.maxn(FreeWindows)
	if Window > 0 then
		if string.sub(who, 1, 1) ~= "!" then
			FreeWindows[Window].TitleText = who..ending
		else
			FreeWindows[Window].TitleText = ending
		end
		FreeWindows[Window].Title:SetText(FreeWindows[Window].TitleText.." - 0.0")
		FreeWindows[Window].id = curID
		FreeWindows[Window].who = who
		FreeWindows[Window].tracking = tracking
		FreeWindows[Window].tracking = tracking
		FreeWindows[Window].index = Window

		local f = FreeWindows[Window]
		if Recount.db.profile.RealtimeWindows and Recount.db.profile.RealtimeWindows[FreeWindows[Window].id] then
			Recount:RestoreRealtimeWindowPosition(f, Recount:RealtimeWindowPositionFromID(FreeWindows[Window].id))
		else
			f:SetWidth(200)
			f:SetHeight(232)
			f:ClearAllPoints()
			f:SetPoint("CENTER", UIParent)
		end
		me.ResizeRealtimeWindow(FreeWindows[Window])

		FreeWindows[Window]:UpdateTitle()
		Recount:RegisterTracking(FreeWindows[Window].id, who, tracking, FreeWindows[Window].Graph.AddTimeData, FreeWindows[Window].Graph)
		FreeWindows[Window].UpdateTitle = me.UpdateTitle
		FreeWindows[Window].idtoken = Recount:ScheduleRepeatingTimer("UpdateTitle", 0.1, FreeWindows[Window])
		local tempshowfunc = FreeWindows[Window].ShowFunc
		FreeWindows[Window].ShowFunc = nil
		FreeWindows[Window]:Show()
		FreeWindows[Window].ShowFunc = tempshowfunc

		Recount.Colors:UnregisterItem(FreeWindows[Window])
		Recount.Colors:RegisterFunction("Realtime", FreeWindows[Window].TitleText.." Top", me.SetRealtimeColor, FreeWindows[Window])
		Recount.Colors:RegisterFunction("Realtime", FreeWindows[Window].TitleText.." Bottom", me.SetRealtimeColor, FreeWindows[Window])

		Recount.db.profile.RealtimeWindows[FreeWindows[Window].id] = {who, tracking, ending}
		FreeWindows[Window]:SavePosition()

		table.remove(FreeWindows, Window)
	else
		if Recount.db.profile.RealtimeWindows and Recount.db.profile.RealtimeWindows[curID] then
			local x, y, width, height = Recount:RealtimeWindowPositionFromID(curID)
			local f = me:CreateRealtimeWindow(who, tracking, ending)
			Recount:RestoreRealtimeWindowPosition(f, x, y, width, height)
			f:ResizeRealtimeWindow()
			f:SavePosition()
		else
			local f = me:CreateRealtimeWindow(who, tracking, ending) -- Resike: What's this?
		end
	end
end

function Recount:RealtimeWindowPositionFromID(id)
	local x, y, width, height
	if Recount.db.profile.RealtimeWindows and Recount.db.profile.RealtimeWindows[id] then
		x = Recount.db.profile.RealtimeWindows[id][4]
		y = Recount.db.profile.RealtimeWindows[id][5]
		width = Recount.db.profile.RealtimeWindows[id][6]
		height = Recount.db.profile.RealtimeWindows[id][7]
	end
	return x, y, width, height
end

function Recount:RestoreRealtimeWindowPosition(f, x, y, width, height)
	local s = f:GetEffectiveScale() -- Elsia: Fixed position code, with inspiration from ckknight's handing in pitbull
	local uis = UIParent:GetScale()
	f:ClearAllPoints()
	f:SetPoint("CENTER", UIParent, "CENTER", x * uis / s, y * uis / s)
	f:SetWidth(width)
	f:SetHeight(height)
	f:ResizeRealtimeWindow()
	f:SavePosition()
end

function Recount:CreateRealtimeWindowSized(who, tracking, ending, x, y, width, height)
	local f = me:CreateRealtimeWindow(who, tracking, ending)
	Recount:RestoreRealtimeWindowPosition(f, x, y, width, height)
end

function Recount:CloseAllRealtimeWindows()
	Recount:HideRealtimeWindows()
end
