local ADDON, NR = ...

local Options = {}
NR.Options = Options

local db
local window, toggleButton, settings

-- Templates differ between client generations, so labels are built by hand and only
-- the three oldest, universally present templates are used.
local function checkbox(parent, label, y, get, set)
	local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	box:SetPoint("TOPLEFT", 20, y)
	box:SetSize(26, 26)

	local text = box:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	text:SetPoint("LEFT", box, "RIGHT", 4, 0)
	text:SetText(label)

	box:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	box.Refresh = function(self) self:SetChecked(get()) end
	return box
end

local function slider(parent, label, minimum, maximum, step, format, y, get, set)
	local bar = CreateFrame("Slider", "NodeRadarSlider" .. label:gsub("%W", ""), parent,
		"OptionsSliderTemplate")
	bar:SetPoint("TOPLEFT", 24, y)
	bar:SetWidth(280)
	bar:SetMinMaxValues(minimum, maximum)
	bar:SetValueStep(step)
	if bar.SetObeyStepOnDrag then bar:SetObeyStepOnDrag(true) end

	local name = bar:GetName()
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

local function buildPanel()
	settings = CreateFrame("Frame")
	settings.name = "NodeRadar"

	local title = settings:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("NodeRadar")

	local note = settings:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	note:SetPoint("TOPLEFT", 16, -42)
	note:SetWidth(500)
	note:SetJustifyH("LEFT")
	note:SetText("Shows herb and ore nodes that really exist in minimap range. "
		.. "Needs the matching tracking ability to be active.")

	local controls = {}

	controls[#controls + 1] = checkbox(settings, "Show the control window", -76,
		function() return db.showWindow end,
		function(value) db.showWindow = value Options:ApplySettings() end)

	controls[#controls + 1] = checkbox(settings, "Show the radar grid", -104,
		function() return db.showGrid end,
		function(value) db.showGrid = value NR.Radar:ShowGrid(value) end)

	controls[#controls + 1] = checkbox(settings, "Show distance in yards", -132,
		function() return db.showDistances end,
		function(value) db.showDistances = value NR.Radar:ApplySettings() end)

	controls[#controls + 1] = checkbox(settings, "Start automatically on login", -160,
		function() return db.autoStart end,
		function(value) db.autoStart = value end)

	controls[#controls + 1] = slider(settings, "Radar radius", 100, 400, 10, "%d px", -212,
		function() return db.radius end,
		function(value) db.radius = value NR.Radar:ApplySettings() end)

	controls[#controls + 1] = slider(settings, "Icon size", 8, 40, 2, "%d px", -272,
		function() return db.iconSize end,
		function(value) db.iconSize = value NR.Radar:ApplySettings() end)

	controls[#controls + 1] = slider(settings, "Seconds between scans", 0.5, 10, 0.5, "%.1f s", -332,
		function() return db.scanInterval end,
		function(value) db.scanInterval = value end)

	local reset = CreateFrame("Button", nil, settings, "UIPanelButtonTemplate")
	reset:SetSize(150, 24)
	reset:SetPoint("TOPLEFT", 24, -400)
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

	-- Registration hands back the id that OpenToCategory expects; never overwrite the
	-- category's own ID field, GetID reads exactly that.
	if Settings and Settings.RegisterCanvasLayoutCategory then
		local category = Settings.RegisterCanvasLayoutCategory(settings, settings.name)
		Settings.RegisterAddOnCategory(category)
		Options.categoryID = category.GetID and category:GetID() or category
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(settings)
	end
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
	buildPanel()
	self:CreateWindow()
	self:ApplySettings()
end

function Options:Open()
	if Settings and Settings.OpenToCategory and self.categoryID then
		Settings.OpenToCategory(self.categoryID)
		return
	end
	if InterfaceOptionsFrame_OpenToCategory then
		-- the old call takes the panel name and lands on the wrong page the first time
		InterfaceOptionsFrame_OpenToCategory(settings.name)
		InterfaceOptionsFrame_OpenToCategory(settings.name)
	end
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
