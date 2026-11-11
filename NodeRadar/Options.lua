local ADDON, NR = ...

local Options = {}
NR.Options = Options

local db
local window, toggleButton, settings

local function checkbox(parent, label, x, y, get, set)
	local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	box:SetPoint("TOPLEFT", x, y)
	box:SetSize(26, 26)

	local text = box:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	text:SetPoint("LEFT", box, "RIGHT", 4, 0)
	text:SetText(label)

	box:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	box.Refresh = function(self) self:SetChecked(get()) end
	return box
end

local function slider(parent, label, minimum, maximum, step, format, x, y, width, get, set)
	-- OptionsSliderTemplate is legacy FrameXML a client may have dropped
	local name = "NodeRadarSlider" .. label:gsub("%W", "")
	local legacy = C_XMLUtil.GetTemplateInfo("OptionsSliderTemplate") ~= nil
	local bar = CreateFrame("Slider", name, parent,
		legacy and "OptionsSliderTemplate" or "UISliderTemplate")
	if not legacy then
		bar:SetHeight(17)
		bar.Text = bar:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		bar.Text:SetPoint("BOTTOM", bar, "TOP", 0, 2)
	end
	bar:SetPoint("TOPLEFT", x, y)
	bar:SetWidth(width)
	bar:SetMinMaxValues(minimum, maximum)
	bar:SetValueStep(step)
	if bar.SetObeyStepOnDrag then bar:SetObeyStepOnDrag(true) end

	local low = bar.Low or _G[name .. "Low"]
	local high = bar.High or _G[name .. "High"]
	local caption = bar.Text or _G[name .. "Text"]
	if low then low:SetText(string.format(format, minimum)) end
	if high then high:SetText(string.format(format, maximum)) end

	local function updateCaption(value)
		if caption then caption:SetText(label .. ": " .. string.format(format, value)) end
	end

	bar:SetScript("OnValueChanged", function(self, value)
		value = math.floor(value / step + 0.5) * step
		updateCaption(value)
		set(value)
	end)
	bar.Refresh = function(self)
		local value = get()
		self:SetValue(value)
		updateCaption(value)
	end
	return bar
end

local function section(parent, label, y, width)
	local text = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	text:SetPoint("TOPLEFT", 16, y)
	text:SetText(label)

	local rule = parent:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(0.6, 0.9, 0.7, 0.25)
	rule:SetHeight(1)
	rule:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -3)
	rule:SetWidth(width)
end

-- Every NodeRadar window: a thin green rim behind a translucent black panel. The
-- sublevels fix which texture draws on top; within one level the client decides.
function NR.StyleWindow(frame)
	local border = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
	border:SetPoint("TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", 1, -1)
	border:SetColorTexture(0.6, 0.9, 0.7, 0.35)

	local background = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
	background:SetAllPoints()
	background:SetColorTexture(0, 0, 0, 0.88)
end

local LEFT, RIGHT = 20, 240
local SLIDER_WIDTH = 170

local function buildWindow()
	settings = CreateFrame("Frame", "NodeRadarSettingsFrame", UIParent)
	settings:SetSize(460, 580)
	settings:SetPoint("CENTER")
	settings:SetFrameStrata("DIALOG")
	settings:SetMovable(true)
	settings:EnableMouse(true)
	settings:RegisterForDrag("LeftButton")
	settings:SetScript("OnDragStart", settings.StartMoving)
	settings:SetScript("OnDragStop", settings.StopMovingOrSizing)
	settings:Hide()

	NR.StyleWindow(settings)

	local title = settings:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -14)
	title:SetText("NodeRadar")

	local close = CreateFrame("Button", nil, settings, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)

	local note = settings:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	note:SetPoint("TOPLEFT", 16, -40)
	note:SetWidth(420)
	note:SetJustifyH("LEFT")
	note:SetText("Shows the herb and ore nodes on your minimap on a radar around your "
		.. "character. Needs Find Herbs or Find Minerals to be active. To read a node the "
		.. "minimap leaves its place for a moment.")

	local controls = {}
	local function add(control) controls[#controls + 1] = control end

	section(settings, "Radar", -74, 424)
	add(slider(settings, "Radar radius", 100, 400, 10, "%d px", LEFT + 4, -106, SLIDER_WIDTH,
		function() return db.radius end,
		function(value) db.radius = value NR.Radar:ApplySettings() end))
	add(slider(settings, "Icon size", 8, 64, 2, "%d px", RIGHT + 4, -106, SLIDER_WIDTH,
		function() return db.iconSize end,
		function(value) db.iconSize = value NR.Radar:ApplySettings() end))
	add(slider(settings, "Node opacity", 10, 100, 5, "%d%%", LEFT + 4, -152, SLIDER_WIDTH,
		function() return db.nodeAlpha * 100 end,
		function(value) db.nodeAlpha = value / 100 end))
	add(slider(settings, "Grid opacity", 5, 100, 5, "%d%%", RIGHT + 4, -152, SLIDER_WIDTH,
		function() return db.gridAlpha * 100 end,
		function(value) db.gridAlpha = value / 100 NR.Radar:ApplySettings() end))
	add(checkbox(settings, "Show distance in yards", LEFT, -188,
		function() return db.showDistances end,
		function(value) db.showDistances = value NR.Radar:ApplySettings() end))
	add(checkbox(settings, "Show the range rings and axes", RIGHT, -188,
		function() return db.showGrid end,
		function(value) db.showGrid = value NR.Radar:ShowGrid(value) end))

	section(settings, "Which nodes", -232, 424)
	add(checkbox(settings, "Hide when my skill is too low", LEFT, -262,
		function() return db.hideTooLow end,
		function(value) db.hideTooLow = value end))
	add(checkbox(settings, "Hide nodes giving no skill-up", RIGHT, -262,
		function() return db.hideTrivial end,
		function(value) db.hideTrivial = value end))
	local choose = CreateFrame("Button", nil, settings, "UIPanelButtonTemplate")
	choose:SetSize(200, 24)
	choose:SetPoint("TOPLEFT", LEFT + 4, -294)
	choose:SetText("Choose herbs and ores...")
	choose:SetScript("OnClick", function() NR.Filter:Open(settings) end)

	section(settings, "Hints", -338, 424)
	add(checkbox(settings, "Highlight a new node", LEFT, -368,
		function() return db.showSparkle end,
		function(value) db.showSparkle = value end))
	add(checkbox(settings, "Sound when a new node appears", RIGHT, -368,
		function() return db.playSound end,
		function(value) db.playSound = value end))
	add(checkbox(settings, "Frame in my skill's colour", LEFT, -398,
		function() return db.colorBySkill end,
		function(value) db.colorBySkill = value end))
	add(checkbox(settings, "Skill in the minimap tooltip", RIGHT, -398,
		function() return db.skillTooltip end,
		function(value) db.skillTooltip = value end))

	section(settings, "General", -442, 424)
	add(checkbox(settings, "Show the control window", LEFT, -472,
		function() return db.showWindow end,
		function(value) db.showWindow = value Options:ApplySettings() end))
	add(checkbox(settings, "Start automatically on login", RIGHT, -472,
		function() return db.autoStart end,
		function(value) db.autoStart = value end))
	add(checkbox(settings, "Hide the radar in combat", LEFT, -502,
		function() return db.hideInCombat end,
		function(value) db.hideInCombat = value end))

	local reset = CreateFrame("Button", nil, settings, "UIPanelButtonTemplate")
	reset:SetSize(150, 24)
	reset:SetPoint("BOTTOMLEFT", 20, 16)
	reset:SetText("Restore defaults")
	reset:SetScript("OnClick", function()
		for key, value in pairs(NR.defaults) do
			-- the control window is how the player reaches these settings, so a reset
			-- never takes it away from them
			if key ~= "showWindow" then
				db[key] = type(value) == "table" and CopyTable(value) or value
			end
		end
		NR.Radar:ApplySettings()
		Options:ApplySettings()
		settings.refresh()
	end)

	settings.refresh = function()
		for _, control in ipairs(controls) do control:Refresh() end
	end
	settings:SetScript("OnShow", settings.refresh)
	tinsert(UISpecialFrames, "NodeRadarSettingsFrame")
end

-- Players look for addon settings in the client's own options list, so there is an
-- entry there - as a shortcut into the one real window, never as a second copy of
-- the controls.
local function registerBlizzardEntry()
	local panel = CreateFrame("Frame")
	panel.name = "NodeRadar"

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("NodeRadar")

	local note = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	note:SetPoint("TOPLEFT", 16, -44)
	note:SetWidth(500)
	note:SetJustifyH("LEFT")
	note:SetText("Shows the herb and ore nodes on your minimap on a radar around your "
		.. "character. All settings live in NodeRadar's own window, reachable from the button "
		.. "below, from the gear on the control window, or with /nr options.")

	local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	open:SetSize(200, 24)
	open:SetPoint("TOPLEFT", 16, -96)
	open:SetText("Open NodeRadar settings")
	open:SetScript("OnClick", function() Options:Open() end)

	Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, panel.name))
end

function Options:CreateWindow()
	window = CreateFrame("Frame", "NodeRadarWindow", UIParent)
	window:SetSize(152, 48)
	window:SetMovable(true)
	window:EnableMouse(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relativePoint, x, y = self:GetPoint(1)
		db.windowPoint = { point, relativePoint, x, y }
	end)
	window:Hide()

	local background = window:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetColorTexture(0, 0, 0, 0.55)

	local title = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	title:SetPoint("TOP", 0, -4)
	title:SetText("NodeRadar")

	toggleButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	toggleButton:SetSize(108, 22)
	toggleButton:SetPoint("BOTTOMLEFT", 6, 6)
	toggleButton:SetScript("OnClick", function()
		if NR.IsRunning() then NR.Stop() else NR.Start() end
	end)

	local settingsButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	settingsButton:SetSize(24, 22)
	settingsButton:SetPoint("BOTTOMRIGHT", -6, 6)
	settingsButton:SetText("")

	local icon = settingsButton:CreateTexture(nil, "OVERLAY")
	icon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
	icon:SetSize(14, 14)
	icon:SetPoint("CENTER")

	settingsButton:SetScript("OnClick", function() Options:Open() end)
	settingsButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("NodeRadar settings")
		GameTooltip:Show()
	end)
	settingsButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function Options:Init(savedDB)
	db = savedDB
	buildWindow()
	registerBlizzardEntry()
	self:CreateWindow()
	self:ApplySettings()
end

function Options:Open()
	settings:SetShown(not settings:IsShown())
end

function Options:ApplySettings()
	if not window then return end
	window:ClearAllPoints()
	window:SetPoint(db.windowPoint[1], UIParent, db.windowPoint[2], db.windowPoint[3], db.windowPoint[4])
	window:SetShown(db.showWindow)
	self:Refresh()
end

function Options:Refresh()
	if toggleButton then
		toggleButton:SetText(NR.IsRunning() and "Stop scanning" or "Start scanning")
	end
	if settings and settings:IsShown() then settings.refresh() end
end
