local ADDON, NR = ...

local Radar = {}
NR.Radar = Radar

local RING = "Interface\\AddOns\\NodeRadar\\Ring.tga"
local RING_FRACTIONS = { 1 / 3, 2 / 3, 1 }
local GRID_COLOR = { 0.6, 0.9, 0.7 }
local GRID_ALPHA = 0.3

local frame, grid
local pins = {}
local db
local range = 0

local function createPin()
	local pin = CreateFrame("Frame", nil, frame)
	pin.icon = pin:CreateTexture(nil, "ARTWORK")
	pin.icon:SetAllPoints()
	pin.label = pin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	pin.label:SetPoint("TOP", pin, "BOTTOM", 0, 2)
	pin:SetSize(db.iconSize, db.iconSize)
	return pin
end

local function line(width, height)
	local texture = frame:CreateTexture(nil, "BACKGROUND")
	texture:SetColorTexture(GRID_COLOR[1], GRID_COLOR[2], GRID_COLOR[3], GRID_ALPHA * 0.7)
	texture:SetSize(width, height)
	return texture
end

local function buildGrid()
	grid = { rings = {}, labels = {}, lines = {} }

	for index in ipairs(RING_FRACTIONS) do
		local ring = frame:CreateTexture(nil, "BACKGROUND")
		ring:SetTexture(RING)
		ring:SetVertexColor(GRID_COLOR[1], GRID_COLOR[2], GRID_COLOR[3], GRID_ALPHA)
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
	heading:SetVertexColor(GRID_COLOR[1], GRID_COLOR[2], GRID_COLOR[3], 0.55)
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

function Radar:ApplySettings()
	local radius = db.radius
	frame:SetSize(radius * 2, radius * 2)

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

	for _, pin in ipairs(pins) do
		pin:SetSize(db.iconSize, db.iconSize)
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
	for index, entry in ipairs(entries) do
		local pin = pins[index]
		if not pin then
			pin = createPin()
			pins[index] = pin
		end
		pin.icon:SetTexture(entry.texture)
		pin:ClearAllPoints()
		pin:SetPoint("CENTER", frame, "CENTER", entry.rx * db.radius, entry.ry * db.radius)
		if db.showDistances then
			pin.label:SetFormattedText("%d", entry.distance)
			pin.label:Show()
		else
			pin.label:Hide()
		end
		pin:Show()
	end
	for index = #entries + 1, #pins do
		pins[index]:Hide()
	end
end
