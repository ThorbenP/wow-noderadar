local ADDON, NR = ...

-- While a reading has the minimap away, a stand-in covers its place: the minimap's own
-- terrain tiles around the player at its zoom - indoors and off the two continents the
-- world map's art - dots for the known nodes and the group, the player arrow, and a
-- picture of everything hanging on the map taken as it left. After the map is back the
-- stand-in lingers over it and fades out.

local StandIn = {}
NR.StandIn = StandIn

-- held over the returned map while the client redraws its blips, then faded out
local HOLD = 0.2
local FADE = 0.3
-- the world map's colours are brighter than the minimap's
local WORLD_ART_SHADE = 0.6
-- One minimap tile covers this many yards each way. The client loads the tiles only by
-- file id (MinimapTiles.lua), not by path.
local TILE_YARDS = 1600 / 3
local CONTINENT_TILES = { [0] = "Azeroth", [1] = "Kalimdor" }
-- under the art, where a zone has none; the world shows through
local GROUND_ALPHA = 0.35
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SQUARE_MASK = "Interface\\Buttons\\WHITE8X8"
local ARROW_ATLAS = "MinimapArrow"
-- the client's player arrow at icon scale 1, in minimap units
local ARROW_SIZE = 20
-- The client's own blip art, 32-pixel cells: a tracked node is the gold-rimmed yellow
-- dot, a group member the dot of its class, in class id order. Sizes are a cell at icon
-- scale 1, in minimap units.
local NODE_BLIP = "Interface\\Minimap\\ObjectIcons"
local NODE_BLIP_COORDS = { 0, 0.125, 0.125, 0.25 }
local NODE_BLIP_SIZE = 14
local GROUP_BLIPS = "Interface\\Minimap\\PartyRaidBlips"
local GROUP_BLIP_COLUMNS, GROUP_BLIP_ROWS = 8, 4
local GROUP_BLIP_SIZE = 16
-- the picture of the map's frames: generations walked, regions copied at most, and how
-- slow a picture is logged
local SNAPSHOT_DEPTH = 6
local MAX_COPIES = 400
local SLOW_SNAPSHOT_MS = 4

local frame
local homeAt
local failed = false

local function isSecret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

local function mask()
	local set, byAddon = NR.Map:HomeMask()
	if byAddon then return set end
	if GetMinimapShape and GetMinimapShape() == "SQUARE" then return SQUARE_MASK end
	return CIRCLE_MASK
end

-- A region's centre relative to the minimap's centre and its size, in minimap units; nil
-- for one that is not on screen.
local function measure(region)
	local x, y = region:GetCenter()
	local mx, my = Minimap:GetCenter()
	if not x or not mx or isSecret(x) or isSecret(y) then return nil end
	local own, map = region:GetEffectiveScale(), Minimap:GetEffectiveScale()
	return x * own / map - mx, y * own / map - my, region:GetWidth() * own / map,
		region:GetHeight() * own / map
end

local function build()
	frame = CreateFrame("Frame", nil, UIParent)
	frame:EnableMouse(false)
	frame:Hide()
	frame.mask = frame:CreateMaskTexture()
	frame.mask:SetAllPoints()
	frame.ground = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
	frame.ground:SetAllPoints()
	frame.ground:SetColorTexture(0, 0, 0, GROUND_ALPHA)
	frame.ground:AddMaskTexture(frame.mask)
	frame.tiles = {}
	frame.blips = {}
	frame.holders = {}
	frame.arrow = frame:CreateTexture(nil, "OVERLAY", nil, 7)
	frame.arrow:SetPoint("CENTER")
end

-- One piece of map art at art units (x, y) from the map's top left, w by h, its picture
-- filling (umax, vmax) of its file: the part inside the stand-in's square.
local function lay(art, file, x, y, w, h, umax, vmax, layer, sublevel)
	local left, top = (x - art.x) * art.scaleX, (art.y - y) * art.scaleY
	local right, bottom = left + w * art.scaleX, top - h * art.scaleY
	local l, r = math.max(left, -art.halfWidth), math.min(right, art.halfWidth)
	local t, b = math.min(top, art.halfHeight), math.max(bottom, -art.halfHeight)
	if l >= r or b >= t then return end
	art.used = art.used + 1
	local tile = frame.tiles[art.used]
	if not tile then
		tile = frame:CreateTexture()
		tile:AddMaskTexture(frame.mask)
		frame.tiles[art.used] = tile
	end
	tile:SetDrawLayer(layer, sublevel)
	tile:SetVertexColor(art.shade, art.shade, art.shade)
	if tile.file ~= file then
		tile.file = file
		tile:SetTexture(file, nil, nil, "TRILINEAR")
	end
	tile:SetTexCoord((l - left) / (right - left) * umax, (r - left) / (right - left) * umax,
		(top - t) / (top - bottom) * vmax, (top - b) / (top - bottom) * vmax)
	tile:SetSize(r - l, t - b)
	tile:ClearAllPoints()
	tile:SetPoint("TOPLEFT", frame, "CENTER", l, t)
	tile:Show()
end

-- smallest power of two from 16 holding `size`, as the client stores a partial tile
local function fileSize(size)
	local file = 16
	while file < size do file = file * 2 end
	return file
end

-- Explored areas come as tiles of the art's tile size, the last of each row and column
-- partly filled.
local function layExplored(art, info, tileWidth, tileHeight)
	local columns = math.ceil(info.textureWidth / tileWidth)
	local rows = math.ceil(info.textureHeight / tileHeight)
	for row = 1, rows do
		local h, fileH = tileHeight, tileHeight
		if row == rows then
			h = info.textureHeight - tileHeight * (rows - 1)
			fileH = fileSize(h)
		end
		for column = 1, columns do
			local w, fileW = tileWidth, tileWidth
			if column == columns then
				w = info.textureWidth - tileWidth * (columns - 1)
				fileW = fileSize(w)
			end
			lay(art, info.fileDataIDs[(row - 1) * columns + column],
				info.offsetX + tileWidth * (column - 1), info.offsetY + tileHeight * (row - 1),
				w, h, w / fileW, h / fileH, "ARTWORK", info.isDrawOnTopLayer and 1 or 0)
		end
	end
end

local art = {}

-- The minimap tiles around the player, in tile units: the column grows eastward, the row
-- southward. False where the client has none to lay.
local function layTiles(perYard)
	if IsIndoors() then return false end
	local north, west, _, instance = UnitPosition("player")
	if type(north) ~= "number" or isSecret(north) or isSecret(west) or isSecret(instance) then
		return false
	end
	local tiles = NR.MINIMAP_TILES[CONTINENT_TILES[instance]]
	if not tiles then return false end
	art.shade = 1
	art.scaleX, art.scaleY = TILE_YARDS * perYard, TILE_YARDS * perYard
	art.x, art.y = 32 - west / TILE_YARDS, 32 - north / TILE_YARDS
	local reachX, reachY = art.halfWidth / art.scaleX, art.halfHeight / art.scaleY
	for column = math.floor(art.x - reachX), math.floor(art.x + reachX) do
		for row = math.floor(art.y - reachY), math.floor(art.y + reachY) do
			local file = tiles[column * 64 + row]
			if file then lay(art, file, column, row, 1, 1, 1, 1, "BACKGROUND", 0) end
		end
	end
	return true
end

-- The zone's world map art centred on the player.
local function layWorldArt(perYard)
	local map = C_Map.GetBestMapForUnit("player")
	local position = map and not isSecret(map) and C_Map.GetPlayerMapPosition(map, "player")
	if not position or isSecret(position) then return end
	if map ~= art.map then
		art.map = map
		art.layer = (C_Map.GetMapArtLayers(map) or {})[1]
		art.files = art.layer and C_Map.GetMapArtLayerTextures(map, 1)
		art.explored = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures(map)
			or {}
	end
	local px, py = position:GetXY()
	local mapWidth, mapHeight
	if C_Map.GetMapWorldSize then mapWidth, mapHeight = C_Map.GetMapWorldSize(map) end
	local layer = art.layer
	if not art.files or not art.files[1] or isSecret(px) or not mapWidth or mapWidth <= 0 then
		return
	end
	art.shade = WORLD_ART_SHADE
	art.scaleX = perYard * mapWidth / layer.layerWidth
	art.scaleY = perYard * mapHeight / layer.layerHeight
	art.x, art.y = px * layer.layerWidth, py * layer.layerHeight
	local columns = math.ceil(layer.layerWidth / layer.tileWidth)
	for row = 1, math.ceil(layer.layerHeight / layer.tileHeight) do
		for column = 1, columns do
			lay(art, art.files[(row - 1) * columns + column], (column - 1) * layer.tileWidth,
				(row - 1) * layer.tileHeight, layer.tileWidth, layer.tileHeight, 1, 1,
				"BACKGROUND", 0)
		end
	end
	for _, info in ipairs(art.explored) do
		if not info.isShownByMouseOver then
			layExplored(art, info, layer.tileWidth, layer.tileHeight)
		end
	end
end

-- The ground around the player at the minimap's zoom.
local function layArt()
	art.used, art.perYard = 0, nil
	local radius = C_Minimap.GetViewRadius()
	if type(radius) == "number" and not isSecret(radius) and radius > 0 then
		local width, height = frame:GetSize()
		local perYard = width / 2 / radius
		art.perYard, art.radius = perYard, radius
		art.halfWidth, art.halfHeight = width / 2, height / 2
		if not layTiles(perYard) then layWorldArt(perYard) end
	end
	for index = art.used + 1, #frame.tiles do frame.tiles[index]:Hide() end
end

-- The nodes on the radar and the group, where the minimap draws its blips: the client
-- gives addons neither its blips nor their textures.
local function layBlips()
	local used = 0
	local function dot(dx, dy, file, left, right, top, bottom, size)
		used = used + 1
		local blip = frame.blips[used]
		if not blip then
			blip = frame:CreateTexture(nil, "ARTWORK")
			blip:AddMaskTexture(frame.mask)
			frame.blips[used] = blip
		end
		blip:SetTexture(file)
		blip:SetTexCoord(left, right, top, bottom)
		blip:SetSize(size * frame.iconScale, size * frame.iconScale)
		blip:ClearAllPoints()
		blip:SetPoint("CENTER", frame, "CENTER", dx * art.perYard, dy * art.perYard)
		blip:Show()
	end
	local north, west = UnitPosition("player")
	if art.perYard and type(north) == "number" and not isSecret(north) and not isSecret(west) then
		local east = -west
		local reach = math.min(art.radius, NR.Scanner.NODE_RANGE)
		for _, hit in pairs(NR.hits or {}) do
			local dx, dy = hit.east - east, hit.north - north
			if dx * dx + dy * dy <= reach * reach then
				dot(dx, dy, NODE_BLIP, NODE_BLIP_COORDS[1], NODE_BLIP_COORDS[2], NODE_BLIP_COORDS[3],
					NODE_BLIP_COORDS[4], NODE_BLIP_SIZE)
			end
		end
		local prefix, count = IsInRaid() and "raid" or "party", GetNumGroupMembers()
		for index = 1, count do
			local unit = prefix .. index
			local n, w = UnitPosition(unit)
			if not UnitIsUnit(unit, "player") and type(n) == "number" and not isSecret(n)
				and not isSecret(w) then
				local cell = (select(3, UnitClass(unit)) or 5) - 1
				local column, row = cell % GROUP_BLIP_COLUMNS, math.floor(cell / GROUP_BLIP_COLUMNS)
				dot(-w - east, n - north, GROUP_BLIPS, column / GROUP_BLIP_COLUMNS,
					(column + 1) / GROUP_BLIP_COLUMNS, row / GROUP_BLIP_ROWS, (row + 1) / GROUP_BLIP_ROWS,
					GROUP_BLIP_SIZE)
			end
		end
	end
	for index = used + 1, #frame.blips do frame.blips[index]:Hide() end
end

local function follow()
	layArt()
	layBlips()
	local facing = GetPlayerFacing()
	if facing and not isSecret(facing) then frame.arrow:SetRotation(facing) end
	for _, holder in pairs(frame.holders) do
		for index = 1, holder.inUse and holder.textsUsed or 0 do
			local copy = holder.texts[index]
			local text = copy.source:GetText()
			if not isSecret(text) then copy:SetText(text) end
		end
	end
end

local function disable(err)
	failed = true
	if frame then frame:Hide() end
	if NR.Log then NR.Log("minimap stand-in turned off after an error: %s", tostring(err)) end
end

local function onUpdate()
	local ok, err = pcall(follow)
	if not ok then return disable(err) end
	if not homeAt then return end
	local faded = (GetTime() - homeAt - HOLD) / FADE
	if faded >= 1 then
		frame:Hide()
	elseif faded > 0 then
		frame:SetAlpha(1 - faded)
	end
end

-- Copies sit in holder frames at their sources' strata and level, so they stack as the
-- originals did; within a holder the draw layers order them.
local function holderFor(source)
	local strata, level = source:GetFrameStrata(), source:GetFrameLevel()
	local key = strata .. level
	local holder = frame.holders[key]
	if not holder then
		holder = CreateFrame("Frame", nil, frame)
		holder:SetAllPoints()
		holder.textures, holder.texts, holder.masks = {}, {}, {}
		frame.holders[key] = holder
	end
	if not holder.inUse then
		holder.inUse = true
		holder.texturesUsed, holder.textsUsed, holder.masksUsed = 0, 0, 0
		holder:SetFrameStrata(strata)
		holder:SetFrameLevel(level)
		holder:Show()
	end
	return holder
end

local function place(copy, region)
	local x, y, w, h = measure(region)
	if not x then error("not on screen") end
	copy:ClearAllPoints()
	copy:SetSize(w, h)
	copy:SetPoint("CENTER", frame, "CENTER", x, y)
end

local function copyMasks(holder, copy, region)
	for index = copy:GetNumMaskTextures(), 1, -1 do copy:RemoveMaskTexture(copy:GetMaskTexture(index)) end
	for index = 1, region:GetNumMaskTextures() do
		local real = region:GetMaskTexture(index)
		holder.masksUsed = holder.masksUsed + 1
		local mask = holder.masks[holder.masksUsed]
		if not mask then
			mask = holder:CreateMaskTexture()
			holder.masks[holder.masksUsed] = mask
		end
		mask:SetTexture(real:GetTexture(), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
		place(mask, real)
		copy:AddMaskTexture(mask)
	end
end

local function fillTexture(holder, copy, region, alpha)
	local atlas, file = region:GetAtlas(), region:GetTexture()
	if atlas and atlas ~= "" then copy:SetAtlas(atlas) elseif file then copy:SetTexture(file) else error("no picture") end
	copy:SetTexCoord(region:GetTexCoord())
	copy:SetVertexColor(region:GetVertexColor())
	copy:SetBlendMode(region:GetBlendMode())
	copy:SetDesaturated(region:IsDesaturated())
	if region.GetRotation then copy:SetRotation(region:GetRotation()) end
	copy:SetDrawLayer(region:GetDrawLayer())
	copy:SetAlpha(alpha)
	place(copy, region)
	copyMasks(holder, copy, region)
end

local function fillText(copy, region, alpha)
	local font, size, flags = region:GetFont()
	copy:SetFont(font, size * region:GetEffectiveScale() / Minimap:GetEffectiveScale(), flags)
	copy:SetText(region:GetText())
	copy:SetTextColor(region:GetTextColor())
	copy:SetShadowOffset(region:GetShadowOffset())
	copy:SetShadowColor(region:GetShadowColor())
	copy:SetJustifyH(region:GetJustifyH())
	copy:SetJustifyV(region:GetJustifyV())
	copy:SetDrawLayer(region:GetDrawLayer())
	copy:SetAlpha(alpha)
	place(copy, region)
	copy.source = region
end

local snap = {}
-- region failures listed per logged picture, and regions per frame in the session's first
-- description of the map's tree
local LOGGED_FAILURES = 5
local DESCRIBED_REGIONS = 6
local DESCRIBED_FRAMES = 30

local function describe(region)
	local name = region:GetDebugName()
	local atlas, file = region.GetAtlas and region:GetAtlas(), region.GetTexture and region:GetTexture()
	return string.format("%s [%s %s%s%s]", isSecret(name) and "?" or tostring(name),
		tostring(region:GetObjectType()), region.GetDrawLayer and tostring(region:GetDrawLayer()) or "",
		atlas and (" atlas " .. tostring(atlas)) or file and (" file " .. tostring(file)) or "",
		region:IsVisible() and "" or " hidden")
end

-- What hangs on the map, two generations deep, for a stand-in that misses a part.
local function describeTree()
	local parts = {}
	local function walk(source, depth)
		local regions = { source:GetRegions() }
		local listed = {}
		for index = 1, math.min(#regions, DESCRIBED_REGIONS) do
			local ok, text = pcall(describe, regions[index])
			listed[#listed + 1] = ok and text or "?"
		end
		if #parts >= DESCRIBED_FRAMES then return end
		parts[#parts + 1] = string.format("%s(%d regions: %s)", tostring(source:GetDebugName()),
			#regions, table.concat(listed, ", "))
		if depth < 2 then
			for _, child in ipairs({ source:GetChildren() }) do
				if child:IsVisible() then walk(child, depth + 1) end
			end
		end
	end
	walk(Minimap, 0)
	return table.concat(parts, "; ")
end

-- One region onto its holder; a region the stand-in cannot copy is left out alone.
local function copyRegion(source, region, alpha)
	local kind = region:GetObjectType()
	if kind ~= "Texture" and kind ~= "FontString" then return end
	if not region:IsVisible() or region:GetAlpha() * alpha <= 0 then return end
	if snap.copied >= MAX_COPIES then
		snap.capped = true
		return
	end
	local holder = holderFor(source)
	local ok, err
	if kind == "Texture" then
		holder.texturesUsed = holder.texturesUsed + 1
		local copy = holder.textures[holder.texturesUsed]
		if not copy then
			copy = holder:CreateTexture()
			holder.textures[holder.texturesUsed] = copy
		end
		ok, err = pcall(fillTexture, holder, copy, region, region:GetAlpha() * alpha)
		copy:SetShown(ok)
		if not ok then holder.texturesUsed = holder.texturesUsed - 1 end
	else
		holder.textsUsed = holder.textsUsed + 1
		local copy = holder.texts[holder.textsUsed]
		if not copy then
			copy = holder:CreateFontString()
			holder.texts[holder.textsUsed] = copy
		end
		ok, err = pcall(fillText, copy, region, region:GetAlpha() * alpha)
		copy:SetShown(ok)
		if not ok then holder.textsUsed = holder.textsUsed - 1 end
	end
	if ok then
		snap.copied = snap.copied + 1
	else
		snap.skipped = snap.skipped + 1
		if #snap.failures < LOGGED_FAILURES then
			snap.failures[#snap.failures + 1] = describe(region) .. ": " .. tostring(err)
		end
	end
end

local function copyFrame(source, depth)
	if isSecret(source) or (source.IsForbidden and source:IsForbidden()) or not source:IsVisible() then
		return
	end
	local alpha = source:GetEffectiveAlpha()
	if isSecret(alpha) or alpha <= 0 then return end
	snap.frames = snap.frames + 1
	for _, region in ipairs({ source:GetRegions() }) do
		-- a background of the map's own would cover the terrain; borders and skins it holds
		-- itself are copied
		if not isSecret(region) and (source ~= Minimap or region:GetDrawLayer() ~= "BACKGROUND")
			and not pcall(copyRegion, source, region, alpha) then
			snap.skipped = snap.skipped + 1
		end
	end
	if depth >= SNAPSHOT_DEPTH then return end
	for _, child in ipairs({ source:GetChildren() }) do copyFrame(child, depth + 1) end
end

-- A picture of everything hanging on the map - frame, skins, buttons, pins, texts - and
-- of `followers`, taken while all of it still stands in its place.
local function snapshot(followers)
	for _, holder in pairs(frame.holders) do
		holder.inUse = false
		holder:Hide()
	end
	snap.copied, snap.skipped, snap.frames, snap.capped = 0, 0, 0, false
	snap.failures = {}
	local started = debugprofilestop()
	copyFrame(Minimap, 0)
	for _, follower in ipairs(followers or {}) do copyFrame(follower, 1) end
	for _, holder in pairs(frame.holders) do
		if holder.inUse then
			for index = holder.texturesUsed + 1, #holder.textures do holder.textures[index]:Hide() end
			for index = holder.textsUsed + 1, #holder.texts do holder.texts[index]:Hide() end
		end
	end
	local took = debugprofilestop() - started
	local summary = string.format("%d regions of %d frames, %d left out%s", snap.copied,
		snap.frames, snap.skipped, snap.capped and ", capped" or "")
	if NR.Log and (summary ~= snap.logged or took > SLOW_SNAPSHOT_MS) then
		snap.logged = summary
		NR.Log("minimap stand-in copied %s in %.1f ms", summary, took)
		for _, failure in ipairs(snap.failures) do NR.Log("  left out %s", failure) end
	end
	if NR.Log and not snap.described then
		snap.described = true
		local ok, text = pcall(describeTree)
		NR.Log("minimap stand-in sources: %s", ok and text or tostring(text))
	end
end

local function begin(iconScale, followers)
	if not frame then build() end
	local x, y = Minimap:GetCenter()
	if not x then return end
	frame.iconScale = iconScale
	frame:SetScale(Minimap:GetEffectiveScale() / UIParent:GetEffectiveScale())
	frame:SetFrameStrata(Minimap:GetFrameStrata())
	frame:SetFrameLevel(Minimap:GetFrameLevel())
	frame:ClearAllPoints()
	frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
	frame:SetSize(Minimap:GetSize())
	frame.mask:SetTexture(mask(), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	local arrow = C_Texture.GetAtlasInfo(ARROW_ATLAS) ~= nil
	frame.arrow:SetShown(arrow)
	if arrow then
		frame.arrow:SetAtlas(ARROW_ATLAS)
		frame.arrow:SetSize(ARROW_SIZE * iconScale, ARROW_SIZE * iconScale)
	end
	snapshot(followers)
	follow()
	homeAt = nil
	frame:SetAlpha(1)
	frame:SetScript("OnUpdate", onUpdate)
	frame:Show()
end

-- Before the map leaves its place, while it and `followers` - frames outside its tree
-- anchored to it - still sit there as the player sees them. Nothing stands in for a map
-- the player has hidden.
function StandIn:Begin(iconScale, followers)
	if failed or not Minimap:IsVisible() or Minimap:GetEffectiveAlpha() == 0 then return end
	local ok, err = pcall(begin, iconScale, followers)
	if not ok then disable(err) end
end

-- The map is back in its place.
function StandIn:End()
	if frame and frame:IsShown() and not homeAt then homeAt = GetTime() end
end
