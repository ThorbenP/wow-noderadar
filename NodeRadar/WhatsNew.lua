local ADDON, NR = ...

-- A note shown once to players who updated, never to a fresh install. A new notice
-- gets a new id.
local WhatsNew = {}
NR.WhatsNew = WhatsNew

local NOTICE_ID = "3.1.0-stand-in"
local WIDTH = 460
-- after login, so the note does not drown in the loading chat
local SHOW_DELAY = 4

local TITLE = "NodeRadar 3.1.0 - the minimap blink is almost gone"
local BODY = table.concat({
	"Great news! I was able to make major improvements, and the minimap flicker should "
		.. "now be significantly less noticeable.",
	"",
	"Since Blizzard changed how addons may read the minimap, NodeRadar has to borrow it "
		.. "for a split second to find nodes - that was the blink you kept seeing. It still "
		.. "does, but now a stand-in takes the minimap's place for that moment:",
	"",
	"- the same terrain, with your minimap frame or skin (SexyMap and others too)",
	"- your addon buttons, quest pins, node and group icons, arrow and coordinates",
	"- nothing flashes at your mouse cursor any more",
	"",
	"Also new:",
	"- New nodes reach the radar faster, usually about a second after they appear on "
		.. "the minimap - even while you steer with the mouse.",
	"- Nodes you leave behind disappear from the radar right away.",
	"",
	"Something still looks off? Type /nr debug and send me the report on GitHub or "
		.. "CurseForge. Thanks for sticking with NodeRadar!",
}, "\n")

local function build(db)
	local frame = CreateFrame("Frame", "NodeRadarWhatsNewFrame", UIParent)
	frame:SetPoint("TOP", 0, -140)
	frame:SetFrameStrata("DIALOG")
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	NR.StyleWindow(frame)
	-- Escape closes it like any panel
	table.insert(UISpecialFrames, frame:GetName())

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -14)
	title:SetPoint("TOPRIGHT", -32, -14)
	title:SetJustifyH("LEFT")
	title:SetText(TITLE)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 0, 0)

	local body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
	body:SetWidth(WIDTH - 32)
	body:SetJustifyH("LEFT")
	body:SetSpacing(2)
	body:SetText(BODY)

	local ok = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	ok:SetSize(110, 24)
	ok:SetPoint("BOTTOM", 0, 14)
	ok:SetText("Got it")
	ok:SetScript("OnClick", function() frame:Hide() end)

	frame:SetSize(WIDTH, 14 + title:GetStringHeight() + 12 + body:GetStringHeight() + 52)
	-- seen once closed, however it is closed; a session ended before that shows it again
	frame:SetScript("OnHide", function() db.noticeSeen = NOTICE_ID end)
	return frame
end

function WhatsNew:Offer(db, freshInstall)
	if freshInstall then db.noticeSeen = NOTICE_ID end
	if db.noticeSeen == NOTICE_ID then return end
	C_Timer.After(SHOW_DELAY, function() build(db):Show() end)
end
