local ADDON, NR = ...

local Filter = {}
NR.Filter = Filter

local ROW_HEIGHT = 20
local COLUMN_WIDTH = 230
local TOP = -70

local db
local frame
local rows = {}

-- One row per item rather than per name: a copper vein and a copper deposit drop the
-- same ore, and the player chooses the ore. The lowest requirement of the names stands
-- for the row, the shortest name labels it until the item's own name has loaded.
local function groups()
	local byItem = {}
	for name, info in pairs(NR.localNodes) do
		local kind, skill, item = info[1], info[2], info[3]
		if item then
			local group = byItem[item]
			if not group then
				group = { item = item, kind = kind, skill = skill, name = name }
				byItem[item] = group
			end
			if skill and (not group.skill or skill < group.skill) then group.skill = skill end
			if #name < #group.name then group.name = name end
		end
	end

	local herbs, ores = {}, {}
	for _, group in pairs(byItem) do
		table.insert(group.kind == "herb" and herbs or ores, group)
	end
	local function bySkill(a, b)
		if (a.skill or 0) ~= (b.skill or 0) then return (a.skill or 0) < (b.skill or 0) end
		return a.name < b.name
	end
	table.sort(herbs, bySkill)
	table.sort(ores, bySkill)
	return herbs, ores
end

local function label(row)
	local name = C_Item.GetItemNameByID(row.group.item)
	if not name then C_Item.RequestLoadItemDataByID(row.group.item) end
	row.text:SetText(string.format("%s |cff888888(%s)|r", name or row.group.name,
		row.group.skill and tostring(row.group.skill) or "?"))
end

local function refresh()
	for _, row in ipairs(rows) do
		row.box:SetChecked(not db.hiddenItems[row.group.item])
		label(row)
	end
end

local function addRow(group, column, index)
	local box = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	box:SetSize(22, 22)
	box:SetPoint("TOPLEFT", 16 + (column - 1) * COLUMN_WIDTH, TOP - (index - 1) * ROW_HEIGHT)
	box:SetScript("OnClick", function(self)
		db.hiddenItems[group.item] = not self:GetChecked() or nil
	end)

	local icon = frame:CreateTexture(nil, "ARTWORK")
	icon:SetSize(16, 16)
	icon:SetPoint("LEFT", box, "RIGHT", 2, 0)
	icon:SetTexture(C_Item.GetItemIconByID(group.item))

	local text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	text:SetPoint("LEFT", icon, "RIGHT", 4, 0)

	rows[#rows + 1] = { box = box, text = text, group = group }
end

local function setAll(shown)
	for _, row in ipairs(rows) do
		db.hiddenItems[row.group.item] = not shown or nil
	end
	refresh()
end

local function build()
	local herbs, ores = groups()
	local height = math.max(#herbs, #ores) * ROW_HEIGHT - TOP + 56

	frame = CreateFrame("Frame", "NodeRadarFilterFrame", UIParent)
	frame:SetSize(COLUMN_WIDTH * 2 + 24, height)
	frame:SetFrameStrata("DIALOG")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()

	NR.StyleWindow(frame)

	local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -14)
	title:SetText("NodeRadar - herbs and ores on the radar")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)

	for column, caption in ipairs({ "Herbs", "Ores" }) do
		local header = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		header:SetPoint("TOPLEFT", 18 + (column - 1) * COLUMN_WIDTH, -44)
		header:SetText(caption)

		local rule = frame:CreateTexture(nil, "ARTWORK")
		rule:SetColorTexture(0.6, 0.9, 0.7, 0.25)
		rule:SetSize(COLUMN_WIDTH - 20, 1)
		rule:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -3)
	end

	for index, group in ipairs(herbs) do addRow(group, 1, index) end
	for index, group in ipairs(ores) do addRow(group, 2, index) end

	local all = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	all:SetSize(100, 24)
	all:SetPoint("BOTTOMLEFT", 16, 14)
	all:SetText("All")
	all:SetScript("OnClick", function() setAll(true) end)

	local none = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	none:SetSize(100, 24)
	none:SetPoint("LEFT", all, "RIGHT", 8, 0)
	none:SetText("None")
	none:SetScript("OnClick", function() setAll(false) end)

	frame:SetScript("OnShow", refresh)
	frame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
	frame:SetScript("OnEvent", function()
		if frame:IsShown() then refresh() end
	end)
	tinsert(UISpecialFrames, "NodeRadarFilterFrame")
end

function Filter:Init(savedDB)
	db = savedDB
end

-- opens beside the settings window rather than on top of it
function Filter:Open(anchor)
	if not frame then build() end
	if frame:IsShown() then
		frame:Hide()
		return
	end
	frame:ClearAllPoints()
	if anchor and anchor:IsShown() then
		frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 12, 0)
	else
		frame:SetPoint("CENTER")
	end
	frame:Show()
end
