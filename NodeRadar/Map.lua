local ADDON, NR = ...

-- Measured on Forever 1.60.1.70862: addons cannot point the minimap's mouseover anywhere
-- but the real cursor. The client resolves that mouseover once per frame, before
-- OnUpdate, for wherever the minimap was drawn - so a point is read by moving the minimap
-- under the resting cursor in one frame and asking C_TooltipInfo.GetMinimapMouseover()
-- in the next. Alpha 0 keeps the reading intact and no GameTooltip is shown for it.
--
-- For the frames a reading takes the minimap is invisible and out of the player's way;
-- between readings it is back in its place.

local Map = {}
NR.Map = Map

local function isSecret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end
NR.IsSecret = isSecret

-- The client prefixes a node above or below the player with a height arrow texture
-- and colours quest lines; a node has to read the same name either way.
function NR.Plain(text)
	text = text:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|H.-|h(.-)|h", "%1")
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|n", " ")
	return strtrim(text)
end

Map.available = C_TooltipInfo ~= nil and type(C_TooltipInfo.GetMinimapMouseover) == "function"
	and type(Minimap.UpdateBlips) == "function"

-- far enough off every screen that nothing of the map is drawn
local PARK = -10000
-- a second refresh of the blips after the map came home, once the client has settled
local BLIP_REFRESH_DELAY = 0.1
-- A cursor that moved more than this many pixels since the map was placed was read
-- somewhere between the two points, so the reading does not count.
local CURSOR_DRIFT_PX = 2
-- how far down the minimap's frame tree addon pins and buttons are looked for
local CHILD_DEPTH = 4
-- Alpha does not reach the icons the client draws itself - nodes, town and quest
-- markers, the player arrow - so they are shrunk out of sight while the map is away.
-- On 70862 searches with the icons at this scale place nodes as precisely as without.
local ICON_HIDE_SCALE = 0.01

-- Minimap addons hook these on the minimap itself and put it straight back - SexyMap
-- re-anchors it after every SetPoint and clamps it to the screen. The frame type's own
-- methods skip those hooks, which is how SexyMap moves it too.
local frameMethods = getmetatable(Minimap).__index
local function call(method, ...)
	return frameMethods[method](Minimap, ...)
end

local held
local iconScale = 1
local iconHidden = false

-- The client offers no getter for the icon scale, so whatever another addon sets is
-- remembered to be put back.
if type(Minimap.SetIconScale) == "function" then
	hooksecurefunc(Minimap, "SetIconScale", function(_, scale)
		if not iconHidden and type(scale) == "number" then iconScale = scale end
	end)
end

function Map:IsHeld()
	return held ~= nil
end

-- Whether the map is away from its place right now, under the cursor for a reading.
function Map:IsAway()
	return held ~= nil and held.away
end

-- The client delivers a reading's mouseover tooltip up to a few frames late, when the
-- map may be home again; anything within this window still belongs to the reading.
local LATE_TOOLTIP_SECONDS = 0.5

function Map:JustRead()
	return held ~= nil and (held.away or GetTime() - (held.homeAt or -math.huge)
		< LATE_TOOLTIP_SECONDS)
end

-- Frames the client protects cannot be moved in combat.
function Map:CanChange()
	return not InCombatLockdown() or not Minimap:IsProtected()
end

-- Addon pins and buttons hang under the minimap and travel with it: a mouse-enabled one
-- under the cursor takes the mouseover from the map, and one that opts out of its
-- parent's alpha stays visible. Both are switched off while the map is away.
local function mute(frame, depth)
	if depth > CHILD_DEPTH then return end
	for _, child in ipairs({ frame:GetChildren() }) do
		if child.IsMouseEnabled and child:IsMouseEnabled() then
			held.mouse[child] = true
			child:EnableMouse(false)
		end
		if child.IsIgnoringParentAlpha and child:IsIgnoringParentAlpha() then
			held.alpha[child] = true
			child:SetIgnoreParentAlpha(false)
		end
		mute(child, depth + 1)
	end
	for _, region in ipairs({ frame:GetRegions() }) do
		if region.IsIgnoringParentAlpha and region:IsIgnoringParentAlpha() then
			held.alpha[region] = true
			region:SetIgnoreParentAlpha(false)
		end
	end
end

local function anchorsOf(frame)
	local list = {}
	for index = 1, frame:GetNumPoints() do list[index] = { frame:GetPoint(index) } end
	return list
end

local function sameAnchors(a, b)
	if #a ~= #b then return false end
	for index, point in ipairs(a) do
		for field = 1, 5 do
			if point[field] ~= b[index][field] then return false end
		end
	end
	return true
end

-- up to a few frame names for the log; map pins come by the hundred and mostly unnamed
local LOGGED_NAMES = 3

local function summary(frames)
	local names = {}
	for _, frame in ipairs(frames) do
		local name = frame:GetName()
		if type(name) == "string" and not isSecret(name) and #names < LOGGED_NAMES then
			names[#names + 1] = name
		end
	end
	return string.format("%d (%s%s)", #frames, table.concat(names, ", "),
		#frames > #names and ", ..." or "")
end

-- LibDBIcon and SexyMap place a minimap button - HereBeDragons a map pin - at an offset
-- worked out from the map's width at that moment; one placed while the map is shrunk for
-- a reading would stay off its place, so it gets back the anchor it had before.
local function restoreButtons()
	local moved, appeared = {}, {}
	for child, before in pairs(held.buttons) do
		if not sameAnchors(before, anchorsOf(child)) then
			child:ClearAllPoints()
			for _, point in ipairs(before) do child:SetPoint(unpack(point)) end
			moved[#moved + 1] = child
		end
	end
	for _, child in ipairs({ Minimap:GetChildren() }) do
		if not held.buttons[child] then appeared[#appeared + 1] = child end
	end
	wipe(held.buttons)
	if not NR.Log then return end
	if #moved > 0 then NR.Log("minimap frames put back after the reading: %s", summary(moved)) end
	if #appeared > 0 then
		NR.Log("minimap frames that appeared during the reading, maybe off their place: %s",
			summary(appeared))
	end
end

local function applyIconScale(shrunk)
	if type(Minimap.SetIconScale) ~= "function" or shrunk == iconHidden then return end
	if shrunk then
		iconHidden = true
		Minimap:SetIconScale(ICON_HIDE_SCALE)
	else
		Minimap:SetIconScale(iconScale)
		iconHidden = false
	end
end

-- Out of sight and out of the player's way: invisible, above every frame, unclamped so
-- it can sit anywhere, deaf to clicks and the wheel - which would ping or zoom - but not
-- to hover, which is what produces the mouseover.
local function goAway()
	held.points = anchorsOf(Minimap)
	for _, child in ipairs({ Minimap:GetChildren() }) do held.buttons[child] = anchorsOf(child) end
	held.width, held.height = Minimap:GetSize()
	held.ownAlpha = Minimap:GetAlpha()
	held.strata = Minimap:GetFrameStrata()
	held.clamped = Minimap:IsClampedToScreen()
	held.clicks = Minimap:IsMouseClickEnabled()
	held.wheel = Minimap:IsMouseWheelEnabled()

	call("SetAlpha", 0)
	Minimap:SetFrameStrata("TOOLTIP")
	call("SetClampedToScreen", false)
	Minimap:SetMouseClickEnabled(false)
	Minimap:EnableMouseWheel(false)
	Minimap:SetMouseMotionEnabled(true)
	applyIconScale(true)
	mute(Minimap, 1)
	held.away = true
end

-- a refresh that comes after a reading has taken the map away again would be wasted
local function refreshBlips()
	if held and held.away then return end
	Minimap:UpdateBlips()
end

local function comeHome()
	call("ClearAllPoints")
	for _, point in ipairs(held.points) do call("SetPoint", unpack(point)) end
	call("SetSize", held.width, held.height)
	call("SetAlpha", held.ownAlpha)
	Minimap:SetFrameStrata(held.strata)
	call("SetClampedToScreen", held.clamped)
	Minimap:SetMouseClickEnabled(held.clicks)
	Minimap:EnableMouseWheel(held.wheel)
	applyIconScale(false)
	for frame in pairs(held.mouse) do frame:EnableMouse(true) end
	for region in pairs(held.alpha) do region:SetIgnoreParentAlpha(true) end
	wipe(held.mouse)
	wipe(held.alpha)
	restoreButtons()
	held.away = false
	held.homeAt = GetTime()
	-- The client applies the home size a frame late, and a refresh now alone left the
	-- blips from before the burst on the map - NPCs long left behind - until its own
	-- next refresh.
	Minimap:UpdateBlips()
	C_Timer.After(0, refreshBlips)
	C_Timer.After(BLIP_REFRESH_DELAY, refreshBlips)
end

-- After a burst: back in its own place, as the player left it.
function Map:GoHome()
	if held.away then comeHome() end
end

-- The minimap's size on screen, in pixels.
function Map:HomePixels()
	if held and held.away then return held.width * Minimap:GetEffectiveScale() end
	return Minimap:GetWidth() * Minimap:GetEffectiveScale()
end

-- Allows readings. The map stays in its place and goes away only for the frames a
-- reading takes; its place is taken anew each time, so the player may move it between.
function Map:Hold()
	if not held then held = { mouse = {}, alpha = {}, buttons = {}, away = false } end
	return true
end

function Map:Release()
	if not held then return true end
	if held.away then
		if not self:CanChange() then return false end
		comeHome()
	end
	held = nil
	return true
end

-- Whether the map is away and `pixels` across, ready to go under the cursor.
function Map:Ready(pixels)
	return held.away and math.abs(Minimap:GetWidth() * Minimap:GetEffectiveScale() - pixels) < 0.01
end

-- The client applies a new icon scale only a frame later - until then it draws the
-- blips at full size. So the map is made invisible, shrunk and resized off screen, a
-- frame before it goes under the cursor. The new size takes effect only once the map
-- is on screen; the scanner lets that first frame under the cursor pass unread.
function Map:Prepare(pixels)
	if not held.away then goAway() end
	self:Resize(pixels)
	call("ClearAllPoints")
	call("SetPoint", "CENTER", UIParent, "BOTTOMLEFT", PARK, PARK)
end

-- `pixels` across; only while the map is away.
function Map:Resize(pixels)
	local size = pixels / Minimap:GetEffectiveScale()
	call("SetSize", size, size)
end

-- Puts the prepared minimap so that the point (ox, oy) - in map units from its centre -
-- lies under the cursor.
function Map:Place(ox, oy)
	local scale = Minimap:GetEffectiveScale()
	local cursorX, cursorY = GetCursorPosition()
	call("ClearAllPoints")
	call("SetPoint", "CENTER", UIParent, "BOTTOMLEFT", cursorX / scale - ox, cursorY / scale - oy)
	Minimap:UpdateBlips()
	held.cursorX, held.cursorY = cursorX, cursorY
end

-- Where the cursor sits now relative to the map's centre, in map units. The cursor may
-- have moved since the map was placed, and another addon may have moved the map; the
-- mouseover belongs to this point, not to the one aimed at.
function Map:CursorOffset()
	local scale = Minimap:GetEffectiveScale()
	local cursorX, cursorY = GetCursorPosition()
	local mapX, mapY = Minimap:GetCenter()
	return cursorX / scale - mapX, cursorY / scale - mapY
end

-- Every name under the cursor, or nil and why the reading does not count. The mouse
-- focus is no witness: the client moves it only when the mouse moves, not when the map
-- moves under a resting cursor. What counts is that the cursor stayed put and lies on
-- the map.
function Map:Read()
	local cursorX, cursorY = GetCursorPosition()
	if math.abs(cursorX - held.cursorX) > CURSOR_DRIFT_PX
		or math.abs(cursorY - held.cursorY) > CURSOR_DRIFT_PX then
		return nil, "the cursor moved"
	end
	local ox, oy = self:CursorOffset()
	local half = Minimap:GetWidth() / 2
	if math.abs(ox) > half or math.abs(oy) > half then return nil, "the cursor is off the map" end
	local data = C_TooltipInfo.GetMinimapMouseover()
	if data == nil then return {} end
	if isSecret(data) or type(data) ~= "table" or isSecret(data.lines) then
		return nil, "the mouseover reads secret"
	end
	local names = {}
	for _, line in ipairs(type(data.lines) == "table" and data.lines or {}) do
		local text = type(line) == "table" and line.leftText or nil
		if isSecret(text) then return nil, "a mouseover line reads secret" end
		if type(text) == "string" then
			for row in text:gmatch("[^\n]+") do
				local name = NR.Plain(row)
				if name ~= "" then names[#names + 1] = name end
			end
		end
	end
	return names
end
