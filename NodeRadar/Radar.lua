local ADDON, NR = ...

local Radar = {}
NR.Radar = Radar

local RING = "Interface\\AddOns\\NodeRadar\\Ring.tga"
local RING_FRACTIONS = { 1 / 3, 2 / 3, 1 }
local GRID_COLOR = { 0.6, 0.9, 0.7 }
-- how long a newly confirmed node is highlighted
local SPARKLE_SECONDS = 8
local SPARKLE_TEXTURE = "Interface\\Cooldown\\star4"

local frame, grid
-- pins are kept per node key, not per index: the render order is not stable, and a
-- running animation must stay with its own node
local pins, free, active = {}, {}, {}
local db
local range = 0

local function createPin()
	local pin = CreateFrame("Frame", nil, frame)
	pin.icon = pin:CreateTexture(nil, "ARTWORK")
	pin.icon:SetAllPoints()
	pin.label = pin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	pin.label:SetPoint("TOP", pin, "BOTTOM", 0, 2)

	pin.sparkle = pin:CreateTexture(nil, "OVERLAY")
	pin.sparkle:SetTexture(SPARKLE_TEXTURE)
	pin.sparkle:SetBlendMode("ADD")
	pin.sparkle:SetPoint("CENTER")
	pin.sparkle:Hide()

	local group = pin.sparkle:CreateAnimationGroup()
	group:SetLooping("REPEAT")
	local spin = group:CreateAnimation("Rotation")
	spin:SetDegrees(360)
	spin:SetDuration(1.5)
	local fade = group:CreateAnimation("Alpha")
	fade:SetDuration(0.75)
	fade:SetSmoothing("IN_OUT")
	if fade.SetFromAlpha then
		fade:SetFromAlpha(1)
		fade:SetToAlpha(0.3)
	end
	local rise = group:CreateAnimation("Alpha")
	rise:SetDuration(0.75)
	rise:SetStartDelay(0.75)
	rise:SetSmoothing("IN_OUT")
	if rise.SetFromAlpha then
		rise:SetFromAlpha(0.3)
		rise:SetToAlpha(1)
	end
	pin.sparkleAnim = group

	pin:SetSize(db.iconSize, db.iconSize)
	return pin
end

local function acquirePin()
	local pin = table.remove(free)
	return pin or createPin()
end

local function setSparkle(pin, sparkling)
	if sparkling == pin.sparkling then return end
	pin.sparkling = sparkling
	if sparkling then
		pin.sparkle:Show()
		pin.sparkleAnim:Play()
	else
		pin.sparkleAnim:Stop()
		pin.sparkle:Hide()
	end
end

local function line(width, height)
	local texture = frame:CreateTexture(nil, "BACKGROUND")
	texture:SetSize(width, height)
	return texture
end

local function buildGrid()
	grid = { rings = {}, labels = {}, lines = {} }

	for index in ipairs(RING_FRACTIONS) do
		local ring = frame:CreateTexture(nil, "BACKGROUND")
		ring:SetTexture(RING)
		ring:SetPoint("CENTER")
		grid.rings[index] = ring

		local label = frame:CreateFontString(nil, "BACKGROUND", "GameFontDisableSmall")
		label:SetPoint("CENTER", frame, "CENTER", 0, 0)
		grid.labels[index] = label
	end

	grid.lines.horizontal = line(1, 1)
	grid.lines.horizontal:SetPoint("CENTER")
	grid.lines.vertical = line(1, 1)
	grid.lines.vertical:SetPoint("CENTER")

	-- heading marker: the radar turns with the player, so the top edge is always forward
	local heading = frame:CreateTexture(nil, "ARTWORK")
	heading:SetTexture("Interface\\Minimap\\MinimapArrow")
	heading:SetSize(16, 16)
	grid.heading = heading
end

function Radar:Init(savedDB)
	db = savedDB
	frame = CreateFrame("Frame", "NodeRadarFrame", UIParent)
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	frame:SetFrameStrata("MEDIUM")
	frame:Hide()
	buildGrid()
	self:ApplySettings()
end

local function sizePin(pin)
	pin:SetSize(db.iconSize, db.iconSize)
	pin.sparkle:SetSize(db.iconSize * 2.2, db.iconSize * 2.2)
end

function Radar:ApplySettings()
	local radius = db.radius
	frame:SetSize(radius * 2, radius * 2)

	-- axes read as heavier than a curve at the same alpha, the marker as lighter
	local red, green, blue = GRID_COLOR[1], GRID_COLOR[2], GRID_COLOR[3]
	local alpha = db.gridAlpha
	for _, entry in ipairs(grid.rings) do
		entry:SetVertexColor(red, green, blue, alpha)
	end
	grid.lines.horizontal:SetColorTexture(red, green, blue, alpha * 0.7)
	grid.lines.vertical:SetColorTexture(red, green, blue, alpha * 0.7)
	grid.heading:SetVertexColor(red, green, blue, math.min(1, alpha * 1.8))
	for _, label in ipairs(grid.labels) do
		label:SetAlpha(math.min(1, alpha * 2.2))
	end

	for index, fraction in ipairs(RING_FRACTIONS) do
		-- the texture's ring sits at 125 of 128 units, so it is scaled to the full box
		local diameter = radius * 2 * fraction * (128 / 125)
		grid.rings[index]:SetSize(diameter, diameter)
		grid.labels[index]:SetPoint("CENTER", frame, "CENTER", 0, radius * fraction - 7)
	end

	grid.lines.horizontal:SetSize(radius * 2, 1)
	grid.lines.vertical:SetSize(1, radius * 2)
	grid.heading:ClearAllPoints()
	grid.heading:SetPoint("BOTTOM", frame, "TOP", 0, -8)

	for _, pin in pairs(pins) do
		sizePin(pin)
	end

	self:ShowGrid(db.showGrid)
end

function Radar:ShowGrid(shown)
	for _, ring in ipairs(grid.rings) do ring:SetShown(shown) end
	for _, label in ipairs(grid.labels) do label:SetShown(shown and db.showDistances) end
	grid.lines.horizontal:SetShown(shown)
	grid.lines.vertical:SetShown(shown)
	grid.heading:SetShown(shown)
end

-- ring captions only make sense once the scan range is known, and it follows
-- GatherMate's tracking distance
function Radar:SetRange(yards)
	if yards == range then return end
	range = yards
	for index, fraction in ipairs(RING_FRACTIONS) do
		grid.labels[index]:SetFormattedText("%d", yards * fraction)
	end
end

function Radar:SetShown(shown)
	frame:SetShown(shown)
	if not shown then self:Render({}) end
end

-- entries carry unit-circle coordinates, so the radar stays independent of its radius
function Radar:Render(entries)
	local now = GetTime()
	wipe(active)

	for _, entry in ipairs(entries) do
		local pin = pins[entry.key]
		if not pin then
			pin = acquirePin()
			pins[entry.key] = pin
			sizePin(pin)
		end
		active[entry.key] = true

		pin.icon:SetTexture(entry.texture)
		-- red means your gathering skill is below what the node needs
		if entry.tooLow and db.colorBySkill then
			pin.icon:SetVertexColor(1, 0.42, 0.42)
		else
			pin.icon:SetVertexColor(1, 1, 1)
		end
		pin.icon:SetAlpha(db.nodeAlpha)
		pin.label:SetAlpha(db.nodeAlpha)
		pin:ClearAllPoints()
		pin:SetPoint("CENTER", frame, "CENTER", entry.rx * db.radius, entry.ry * db.radius)
		if db.showDistances then
			pin.label:SetFormattedText("%d", entry.distance)
			pin.label:Show()
		else
			pin.label:Hide()
		end

		setSparkle(pin, db.showSparkle and entry.appearedAt ~= nil
			and now - entry.appearedAt < SPARKLE_SECONDS)
		pin:Show()
	end

	for key, pin in pairs(pins) do
		if not active[key] then
			setSparkle(pin, false)
			pin:Hide()
			pins[key] = nil
			free[#free + 1] = pin
		end
	end
end
