local ADDON, NR = ...

local Dump = {}
NR.Dump = Dump

local WIDTH, HEIGHT = 760, 520

local frame, editBox

-- A read-only-in-practice edit box is the only way an addon can hand text to the
-- clipboard: saved variables reach disk on reload or logout, which is too late for
-- something that has already stopped happening.
local function build()
	frame = CreateFrame("Frame", "NodeRadarDumpFrame", UIParent)
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()

	NR.StyleWindow(frame)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 14, -12)
	title:SetText("NodeRadar diagnostics")
	frame.title = title

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPRIGHT", -34, -18)
	hint:SetText("all selected - Ctrl+C to copy, Escape to close")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 0, 0)

	local scroll = CreateFrame("ScrollFrame", "NodeRadarDumpScroll", frame,
		"UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -40)
	scroll:SetPoint("BOTTOMRIGHT", -32, 12)

	editBox = CreateFrame("EditBox", nil, scroll)
	editBox:SetMultiLine(true)
	editBox:SetAutoFocus(false)
	-- the default cap would silently truncate a snapshot
	editBox:SetMaxBytes(0)
	editBox:SetFontObject("ChatFontNormal")
	editBox:SetWidth(WIDTH - 60)
	editBox:SetScript("OnEscapePressed", function() frame:Hide() end)
	scroll:SetScrollChild(editBox)
end

function Dump:Show(text, title)
	if not frame then build() end
	frame.title:SetText(title or "NodeRadar diagnostics")
	editBox:SetText(text)
	editBox:SetCursorPosition(0)
	frame:Show()
	editBox:SetFocus()
	editBox:HighlightText()
end

function Dump:IsShown()
	return frame and frame:IsShown()
end
