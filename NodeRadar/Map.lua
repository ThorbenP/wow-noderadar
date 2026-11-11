local ADDON, NR = ...

-- Measured on Forever 1.60.1.70862: addons cannot point the minimap's mouseover anywhere
-- but the real cursor. The client resolves that mouseover once per frame, before
-- OnUpdate, for wherever the minimap was drawn - so a point is read by moving the minimap
-- under the resting cursor in one frame and asking C_TooltipInfo.GetMinimapMouseover()
-- in the next. A hidden map still reads, and no GameTooltip is shown for it.
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
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[%w_]+:", ""):gsub("|r", ""):gsub("|n", " ")
	return strtrim(text)
end

Map.available = C_TooltipInfo ~= nil and type(C_TooltipInfo.GetMinimapMouseover) == "function"
	and type(Minimap.UpdateBlips) == "function"

-- far enough off every screen that nothing of the map is drawn
local PARK = -10000
-- a second refresh of the blips after the map came home, once the client has settled
local BLIP_REFRESH_DELAY = 0.1
-- A cursor that ended more than this many pixels from where the map was placed for it
-- was read somewhere between the two points, so the reading does not count.
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

-- Below an alpha of 1 the client redraws the map's terrain empty and keeps it so until
-- the player moves (NodeSight 1.9.0 and Lueur 1.5.0 players saw it too). So the map hides
-- behind a transparent mask, which covers what the client draws - terrain and blips -
-- while its own frames and textures take alpha 0.
local EMPTY_MASK = "Interface\\AddOns\\NodeRadar\\Empty.tga"
local SQUARE_MASK = "Interface\\Buttons\\WHITE8X8"
-- Forever's own round mask (Blizzard_Minimap Camelot skin, build 70245, after Lueur)
local FOREVER_MASK = "ui-hud-minimap-frame-generic-mask"
local CLASSIC_MASK = "Textures\\MinimapMask"

-- the mask a minimap addon gave the map; the client has no getter
local maskSet
-- set while NodeRadar puts a mask back, which is no addon's choice
local restoringMask = false
hooksecurefunc(Minimap, "SetMaskTexture", function(_, mask)
	if restoringMask or isSecret(mask) then return end
	if type(mask) == "string" or type(mask) == "number" then maskSet = mask end
end)

-- The mask the map wears at home: one an addon set after NodeRadar loaded, or else
-- Blizzard's for the map's shape. `known` says whether an addon set it.
function Map:HomeMask()
	if maskSet then return maskSet, true end
	if GetMinimapShape and GetMinimapShape() == "SQUARE" then return SQUARE_MASK, false end
	if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(FOREVER_MASK) then
		return FOREVER_MASK, false
	end
	return CLASSIC_MASK, false
end

-- A file added while the game runs is found only after a restart; without it the map
-- falls back to hiding by alpha.
local maskLoads
local function canMask()
	if maskLoads == nil then
		local probe = UIParent:CreateTexture(nil, "BACKGROUND")
		probe:Hide()
		maskLoads = probe:SetTexture(EMPTY_MASK) == true
			and type(frameMethods.SetMaskTexture) == "function"
		if NR.Log then
			NR.Log("the minimap hides during readings behind %s", maskLoads and "an empty mask"
				or "alpha 0 - restart the game to load the empty mask")
		end
	end
	return maskLoads
end

-- Buttons shown only while the cursor is over the map - LibDBIcon's, SexyMap's - fade
-- in when a reading puts the map under it, and fade out at home a moment later. Shrunk
-- to this scale they do both out of sight, and stay shrunk until hidden again: at least
-- SETTLE_MIN after the map came home, at most SETTLE_MAX, or at once when the cursor is
-- on the map. After Lueur.
local SHRINK_SCALE = 0.001
local SETTLE_MIN, SETTLE_MAX = 1.5, 3
-- shrunk frame -> its own scale; outlives the reading that shrank it
local shrunk = {}

local function locked(object)
	return InCombatLockdown() and object.IsProtected and object:IsProtected()
end

local function unseen(object, alpha)
	return alpha == 0 or not object:IsShown()
end

local function shrink(frame)
	if shrunk[frame] or not frame.IsObjectType or not frame:IsObjectType("Frame")
		or locked(frame) then
		return
	end
	local scale = frame:GetScale()
	if isSecret(scale) then return end
	shrunk[frame] = scale
	frame:SetScale(SHRINK_SCALE)
end

local function settle(now)
	if not next(shrunk) then return end
	local waited = GetTime() - (held and held.homeAt or -math.huge)
	if not now and waited < SETTLE_MIN then return end
	local over = Minimap:IsMouseOver()
	for frame, scale in pairs(shrunk) do
		local alpha = frame:GetAlpha()
		if (now or over or waited > SETTLE_MAX or isSecret(alpha) or unseen(frame, alpha))
			and not locked(frame) then
			frame:SetScale(scale)
			shrunk[frame] = nil
		end
	end
end

local function hideOwn(object)
	if held.own[object] ~= nil or isSecret(object) then return end
	local alpha = object:GetAlpha()
	if isSecret(alpha) or locked(object) then return end
	held.own[object] = alpha
	object:SetAlpha(0)
	if unseen(object, alpha) then shrink(object) end
end

-- The map's own frames and textures, which the mask leaves visible. Every frame of a
-- reading: a button an addon shows when the cursor is over the map, and a pin it adds
-- meanwhile, go out of sight again.
local function hideOwnAll()
	for object in pairs(held.own) do
		local alpha = object:GetAlpha()
		if not isSecret(alpha) and alpha > 0 then
			object:SetAlpha(0)
			shrink(object)
		end
	end
	local count = Minimap:GetNumChildren()
	if count == held.ownChildren then return end
	held.ownChildren = count
	for _, child in ipairs({ Minimap:GetChildren() }) do hideOwn(child) end
	for _, region in ipairs({ Minimap:GetRegions() }) do hideOwn(region) end
end

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

-- Frames outside the minimap's tree but anchored into it - Blizzard's coordinates and LFG
-- eye, a skin's border - travel with it to the cursor without taking its alpha. They are
-- looked for among UIParent's children and in the minimap's cluster; deeper in UIParent
-- would cost a walk of every addon's frames per burst.
local CLUSTER_DEPTH = 3
-- generations between a region and the minimap that still count as inside it
local INSIDE_DEPTH = 10

local function usable(object)
	return object ~= nil and not isSecret(object) and type(object) == "table"
		and not (object.IsForbidden and object:IsForbidden())
end

local function insideMinimap(object)
	for _ = 1, INSIDE_DEPTH do
		if object == Minimap then return true end
		object = object:GetParent()
		if not usable(object) then return false end
	end
	return false
end

local function anchoredToMinimap(frame, answered)
	if answered[frame] ~= nil then return answered[frame] end
	answered[frame] = false
	-- anchors may be any region; a Line refuses the point getters
	local ok, points = pcall(frame.GetNumPoints, frame)
	if not ok or isSecret(points) or type(points) ~= "number" then return false end
	for index = 1, points do
		local got, _, relative = pcall(frame.GetPoint, frame, index)
		if got and usable(relative) and (insideMinimap(relative) or relative.GetNumPoints
			and anchoredToMinimap(relative, answered)) then
			answered[frame] = true
			return true
		end
	end
	return false
end

local function findFollowers(parent, depth, answered, found)
	for _, frame in ipairs({ parent:GetChildren() }) do
		if frame ~= Minimap and usable(frame) then
			if anchoredToMinimap(frame, answered) then
				if not insideMinimap(frame) then found[#found + 1] = frame end
			elseif parent ~= UIParent and depth < CLUSTER_DEPTH then
				findFollowers(frame, depth + 1, answered, found)
			end
		end
	end
end

local lastFollowers

local function followers()
	local found, answered = {}, {}
	findFollowers(UIParent, 1, answered, found)
	if MinimapCluster then findFollowers(MinimapCluster, 1, answered, found) end
	return found
end

local function hideFollowers(found)
	local hidden = {}
	for _, frame in ipairs(found) do
		local alpha = frame:GetAlpha()
		if not held.followers[frame] and not isSecret(alpha)
			and not (InCombatLockdown() and frame:IsProtected()) then
			hidden[#hidden + 1] = frame
			held.followers[frame] = alpha
			frame:SetAlpha(0)
			if frame:IsMouseEnabled() then
				held.mouse[frame] = true
				frame:EnableMouse(false)
			end
			mute(frame, 1)
		end
	end
	local logged = summary(hidden)
	if NR.Log and logged ~= lastFollowers then
		NR.Log("frames anchored to the minimap, hidden while it is away: %s", logged)
	end
	lastFollowers = logged
end

-- The minimap draws quest areas whatever its alpha, so a reading on a large map flashes
-- them across the screen; their tracking is off while the map is away. The client keeps
-- it on otherwise, so off at login is a session that ended mid-reading.
local function questAreasIndex()
	local filter = Enum.MinimapTrackingFilter and Enum.MinimapTrackingFilter.QuestPOIs
	if not filter or not C_Minimap.GetTrackingFilter then return nil end
	for index = 1, C_Minimap.GetNumTrackingTypes() do
		local info = C_Minimap.GetTrackingFilter(index)
		if type(info) == "table" and not isSecret(info) and info.filterID == filter then
			return index
		end
	end
end

local function hideQuestAreas()
	local index = questAreasIndex()
	local info = index and C_Minimap.GetTrackingInfo(index)
	if type(info) ~= "table" or isSecret(info) or info.active ~= true then return end
	NodeRadarDB.questAreasOff = true
	C_Minimap.SetTracking(index, false)
	held.questAreas = true
end

local function showQuestAreas()
	local index = questAreasIndex()
	if not index then return end
	C_Minimap.SetTracking(index, true)
	NodeRadarDB.questAreasOff = nil
end

local questAreasRestorer = CreateFrame("Frame")
questAreasRestorer:RegisterEvent("PLAYER_ENTERING_WORLD")
questAreasRestorer:SetScript("OnEvent", function()
	if NodeRadarDB and NodeRadarDB.questAreasOff and not (held and held.away) then
		showQuestAreas()
	end
end)

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
	local found = followers()
	NR.StandIn:Begin(iconScale, found)
	held.points = anchorsOf(Minimap)
	for _, child in ipairs({ Minimap:GetChildren() }) do held.buttons[child] = anchorsOf(child) end
	held.width, held.height = Minimap:GetSize()
	held.ownAlpha = Minimap:GetAlpha()
	held.strata = Minimap:GetFrameStrata()
	held.clamped = Minimap:IsClampedToScreen()
	held.clicks = Minimap:IsMouseClickEnabled()
	held.wheel = Minimap:IsMouseWheelEnabled()

	held.masked = canMask()
	if held.masked then
		call("SetMaskTexture", EMPTY_MASK)
		held.ownChildren = nil
		hideOwnAll()
	else
		call("SetAlpha", 0)
	end
	Minimap:SetFrameStrata("TOOLTIP")
	call("SetClampedToScreen", false)
	Minimap:SetMouseClickEnabled(false)
	Minimap:EnableMouseWheel(false)
	Minimap:SetMouseMotionEnabled(true)
	applyIconScale(true)
	mute(Minimap, 1)
	hideFollowers(found)
	hideQuestAreas()
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
	if held.masked then
		-- through the hooks: an addon that keeps its own mask on the map sees it go back
		restoringMask = true
		pcall(Minimap.SetMaskTexture, Minimap, (Map:HomeMask()))
		restoringMask = false
		for object, alpha in pairs(held.own) do object:SetAlpha(alpha) end
		wipe(held.own)
	else
		call("SetAlpha", held.ownAlpha)
	end
	Minimap:SetFrameStrata(held.strata)
	call("SetClampedToScreen", held.clamped)
	Minimap:SetMouseClickEnabled(held.clicks)
	Minimap:EnableMouseWheel(held.wheel)
	applyIconScale(false)
	for frame, alpha in pairs(held.followers) do frame:SetAlpha(alpha) end
	for frame in pairs(held.mouse) do frame:EnableMouse(true) end
	for region in pairs(held.alpha) do region:SetIgnoreParentAlpha(true) end
	wipe(held.followers)
	wipe(held.mouse)
	wipe(held.alpha)
	if held.questAreas then
		showQuestAreas()
		held.questAreas = nil
	end
	restoreButtons()
	NR.StandIn:End()
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
	if not held then
		held = { mouse = {}, alpha = {}, buttons = {}, followers = {}, own = {}, away = false }
	end
	return true
end

function Map:Release()
	if not held then return true end
	if held.away then
		if not self:CanChange() then return false end
		comeHome()
	end
	settle(true)
	held = nil
	return true
end

-- Every frame while the map is held: what addons show on it while away goes out of sight
-- again, and at home what was shrunk gets its size back once hidden.
function Map:Tick()
	if not held.away then
		settle(false)
	elseif held.masked then
		hideOwnAll()
	end
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

-- The cursor as sampled once per frame, and how far it moved since the frame before.
local cursor = { vx = 0, vy = 0 }

-- Whether the cursor moves as it did a frame earlier - resting counts - so that where it
-- will be when a reading is read can be foretold. Called once every frame.
function Map:CursorSteady()
	local x, y = GetCursorPosition()
	local steady = false
	if cursor.x then
		local vx, vy = x - cursor.x, y - cursor.y
		steady = math.abs(vx - cursor.vx) <= CURSOR_DRIFT_PX
			and math.abs(vy - cursor.vy) <= CURSOR_DRIFT_PX
		cursor.vx, cursor.vy = vx, vy
	end
	cursor.x, cursor.y = x, y
	return steady
end

-- Puts the prepared minimap so that the point (ox, oy) - in map units from its centre -
-- lies under the cursor `ahead` frames from now, when the reading is read: where the
-- cursor will be if it keeps moving as it did over the last frame.
function Map:Place(ox, oy, ahead)
	local scale = Minimap:GetEffectiveScale()
	local cursorX, cursorY = GetCursorPosition()
	cursorX, cursorY = cursorX + cursor.vx * ahead, cursorY + cursor.vy * ahead
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

local function isGrey(r, g, b)
	if isSecret(r) or isSecret(g) or isSecret(b) then return false end
	if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return false end
	return math.abs(r - g) < 0.1 and math.abs(g - b) < 0.1 and r < 0.9
end

-- the first few height arrows go to the log as read, for a client that draws them anew
local LOGGED_ARROWS = 3
local loggedArrows = 0

-- What a mouseover row says of its node's height: "above" or "below" the player, behind
-- the height arrow the client draws instead of a dot - the up arrow in the top half of
-- Minimap-PositionArrows - or "cave" for a name written in grey; false for neither.
local function heightOf(row, lineGrey)
	local arrow = row:match("|[TA][^|]*PositionArrow[^|]*|[ta]")
	if arrow then
		local lower, mark = arrow:lower(), nil
		if lower:find("down", 1, true) then
			mark = "below"
		elseif lower:find("up", 1, true) then
			mark = "above"
		else
			-- |Tpath:height:width:x:y:textureWidth:textureHeight:left:right:top:bottom|t
			local fields = {}
			for field in arrow:gmatch(":(%-?[%d%.]+)") do fields[#fields + 1] = tonumber(field) end
			local textureHeight, top = fields[6], fields[9]
			if textureHeight and top then mark = top >= textureHeight / 2 and "below" or "above" end
		end
		if loggedArrows < LOGGED_ARROWS and NR.Log then
			loggedArrows = loggedArrows + 1
			NR.Log("height arrow read as %s: %s", mark or "unknown", (arrow:gsub("|", "||")))
		end
		return mark or false
	end
	local r, g, b = row:match("|c%x%x(%x%x)(%x%x)(%x%x)")
	if r then return isGrey(tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255) and "cave" or false end
	local named = row:match("|cn([%w_]+):")
	if named then
		return (named:find("GRAY", 1, true) or named:find("DISABLED", 1, true)) and "cave" or false
	end
	return lineGrey and "cave" or false
end

-- Every name under the cursor and, per name, its height (heightOf), or nil and why the
-- reading does not count. The mouse
-- focus is no witness: the client moves it only when the mouse moves, not when the map
-- moves under a resting cursor. What counts is that the cursor stayed put and lies on
-- the map.
function Map:Read()
	-- a press since the map was placed: while the camera turns most frames resolve nothing
	if IsMouselooking() or IsMouseButtonDown() then return nil, "a mouse button went down" end
	local cursorX, cursorY = GetCursorPosition()
	if math.abs(cursorX - held.cursorX) > CURSOR_DRIFT_PX
		or math.abs(cursorY - held.cursorY) > CURSOR_DRIFT_PX then
		return nil, "the cursor moved"
	end
	local ox, oy = self:CursorOffset()
	local half = Minimap:GetWidth() / 2
	if math.abs(ox) > half or math.abs(oy) > half then return nil, "the cursor is off the map" end
	local data = C_TooltipInfo.GetMinimapMouseover()
	if data == nil then return {}, nil, {} end
	if isSecret(data) or type(data) ~= "table" or isSecret(data.lines) then
		return nil, "the mouseover reads secret"
	end
	local names, heights = {}, {}
	for _, line in ipairs(type(data.lines) == "table" and data.lines or {}) do
		local text = type(line) == "table" and line.leftText or nil
		if isSecret(text) then return nil, "a mouseover line reads secret" end
		if type(text) == "string" then
			local color = line.leftColor
			local lineGrey = not isSecret(color) and type(color) == "table"
				and isGrey(color.r, color.g, color.b)
			for row in text:gmatch("[^\n]+") do
				local name = NR.Plain(row)
				if name ~= "" then
					names[#names + 1] = name
					heights[#names] = heightOf(row, lineGrey)
				end
			end
		end
	end
	return names, nil, heights
end
