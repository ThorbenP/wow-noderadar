local ADDON, NR = ...

if not NR.Scanner or not NR.Radar or not NR.Options then
	print("|cff33ff99NodeRadar|r |cffff4444a file did not load - check BugSack|r")
	return
end

local Scanner, Radar = NR.Scanner, NR.Radar

local GATHER_TYPES = { "Herb Gathering", "Mining" }
local BURST = 30
-- minimap blips are roughly 12px wide, so a coarser grid starts missing them
local GRID_STEP = 9
local BLIND_HIT_TTL = 8

local defaults = {
	radius = 120,
	iconSize = 16,
	scanInterval = 3,
	showDistances = true,
	showGrid = true,
	showWindow = true,
	autoStart = false,
	windowPoint = { "CENTER", "CENTER", 0, 220 },
}
NR.defaults = defaults
-- an unconfirmed candidate gets probed around its aimed point too, in case the blip
-- sits a few pixels off or another blip covers it
local PROBE = {
	{ 0, 0, "center" },
	{ 5, 0, "east" }, { -5, 0, "west" },
	{ 0, 5, "north" }, { 0, -5, "south" },
}
-- A blind hit's position is the sample point, so it is only as precise as the grid.
-- Sampling this pattern around the estimate and taking the centroid of the hits
-- measures the blip instead of merely touching it.
local REFINE = {
	{ 0, 0 }, { 4, 0 }, { -4, 0 }, { 0, 4 }, { 0, -4 },
	{ 4, 4 }, { 4, -4 }, { -4, 4 }, { -4, -4 },
}
-- once refined, two hits this close are the same blip
local MERGE_YARDS = 15

local GatherMate, HBD, minimapSize
local nodes, hits, entries = {}, {}, {}
local zoneID, playerX, playerY
local mapRadius, halfWidth, halfHeight
local rotateMinimap
local grid, gridCursor, gridRadius = nil, 1, nil
local blindCounter = 0
local forceBlind = false
local scanRange
local blindMode = false
local sinceScan, sinceRebuild = 0, 0
-- hits age on this clock, which only advances while scanning is actually possible:
-- a held mouse button means "cannot look", never "the node is gone"
local scanClock = 0
local running = false
local db

-- a hit has to outlive one scan cycle, otherwise every icon blinks out shortly
-- before its next confirmation
local function hitTTL()
	return db.scanInterval + 1.5
end

local function out(msg)
	print("|cff33ff99NodeRadar|r " .. msg)
end

local function rotate(x, y, facing)
	local s, c = math.sin(facing), math.cos(facing)
	return x * c - y * s, x * s + y * c
end

local function currentZone()
	local id = HBD:GetPlayerZone()
	return GatherMate.phasing[id] or id
end

-- blips exist only within the client's tracking range, so candidates beyond it can
-- never be confirmed; GatherMate already carries that distance as a user setting
local function detectionRange()
	local profile = GatherMate.db and GatherMate.db.profile
	local range = profile and profile.trackDistance or 100
	return math.min(range, mapRadius)
end

local function refreshGeometry()
	zoneID = currentZone()
	if not zoneID or zoneID == 0 then return false end
	playerX, playerY = HBD:GetPlayerWorldPosition()
	if not playerX then return false end

	local zoom = Minimap:GetZoom()
	local indoors = GetCVar("minimapZoom") + 0 == zoom and "outdoor" or "indoor"
	mapRadius = minimapSize[indoors][zoom] / 2

	halfWidth, halfHeight = Minimap:GetWidth() / 2, Minimap:GetHeight() / 2
	rotateMinimap = GetCVar("rotateMinimap") == "1"

	scanRange = detectionRange()
	local radius = (scanRange / mapRadius) * halfWidth
	if radius ~= gridRadius then
		gridRadius, grid = radius, nil
	end
	return true
end

-- offsets are in minimap-local units, matching how the client draws its blips
local function minimapOffset(xDist, yDist)
	if rotateMinimap then
		local facing = GetPlayerFacing()
		if not facing then return nil end
		xDist, yDist = rotate(xDist, yDist, facing)
	end
	return (xDist / mapRadius) * halfWidth, -(yDist / mapRadius) * halfHeight
end

local function worldFromOffset(ox, oy)
	local xDist = ox / halfWidth * mapRadius
	local yDist = -oy / halfHeight * mapRadius
	if rotateMinimap then
		local facing = GetPlayerFacing()
		if not facing then return nil end
		xDist, yDist = rotate(xDist, yDist, -facing)
	end
	return playerX - xDist, playerY - yDist
end

local function cleanName(text)
	return strtrim((text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
end

-- any line of the tooltip may carry the node; the others belong to whatever else
-- happens to sit under the cursor
local function identify(text)
	for line in text:gmatch("[^\n]+") do
		local name = cleanName(line)
		for _, dbType in ipairs(GATHER_TYPES) do
			local nodeID = GatherMate:GetIDForNode(dbType, name)
			if nodeID then return dbType, nodeID end
		end
	end
end

-- never fall back to an atlas: drawn without texture coordinates its whole grid of
-- icons gets squeezed into one pin
local function textureFor(dbType, nodeID)
	return GatherMate.nodeTextures[dbType][nodeID] or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function rebuildCandidates()
	local zx, zy = HBD:GetZoneCoordinatesFromWorld(playerX, playerY, zoneID)
	if not zx then return end

	local seen = {}
	for _, dbType in ipairs(GATHER_TYPES) do
		for coord, nodeID in GatherMate:FindNearbyNode(zoneID, zx, zy, dbType,
				forceBlind and 0 or scanRange) do
			local key = dbType .. coord
			seen[key] = true
			if not nodes[key] then
				local nzx, nzy = GatherMate:DecodeLoc(coord)
				local wx, wy = HBD:GetWorldCoordinatesFromZone(nzx, nzy, zoneID)
				if wx then
					nodes[key] = { dbType = dbType, nodeID = nodeID, wx = wx, wy = wy }
				end
			end
		end
	end

	for key in pairs(nodes) do
		if not seen[key] then nodes[key] = nil end
	end
end

local diag = { ringHits = {}, samples = 0, tooltips = 0, matched = 0, log = {} }

-- rolling record: the miss is intermittent, so it has to be caught whenever it happens
local function logTooltip(matched, ring, text)
	local entry = string.format("%s | %s",
		matched and "MATCH" or "NOMATCH", (text:gsub("\n", " / ")))
	local log = diag.log
	-- distinct texts only: a single node hit fifty times would otherwise crowd out
	-- every other blip the sweep saw
	for _, existing in ipairs(log) do
		if existing == entry then return end
	end
	log[#log + 1] = entry
	if #log > 40 then table.remove(log, 1) end
end

function Scanner.onSample(tag, text, ox, oy, ring)
	diag.samples = diag.samples + 1
	if not text then return end
	diag.tooltips = diag.tooltips + 1

	local dbType, nodeID = identify(text)
	logTooltip(dbType ~= nil, ring, text)
	if not dbType then return end
	diag.matched = diag.matched + 1
	if ring then diag.ringHits[ring] = (diag.ringHits[ring] or 0) + 1 end

	local node = nodes[tag]
	if node and node.dbType == dbType then
		node.nodeID = nodeID
		node.probes = 0
		hits[tag] = { wx = node.wx, wy = node.wy, texture = textureFor(dbType, nodeID),
			seenAt = scanClock, ttl = hitTTL() }
		return
	end

	-- A blip the database does not know about: its position comes from the sample
	-- itself and is therefore only as precise as one grid step. A nearby earlier hit
	-- is the same node, not a second one, so it is refreshed instead of duplicated.
	local wx, wy = worldFromOffset(ox, oy)
	if not wx then return end

	-- One blip is wider than the grid spacing, so several sample points hit the same
	-- node from up to a grid step away. The tolerance has to exceed that spacing or
	-- one node shows up as several icons; averaging pulls the estimate towards the
	-- centre of the hits.
	local tracked = tag and hits[tag]
	if tracked and tracked.blind then
		tracked.sumX = (tracked.sumX or 0) + wx
		tracked.sumY = (tracked.sumY or 0) + wy
		tracked.count = (tracked.count or 0) + 1
		tracked.seenAt, tracked.ttl = scanClock, BLIND_HIT_TTL
		tracked.texture = textureFor(dbType, nodeID)
		return
	end

	local tolerance = GRID_STEP / (halfWidth / mapRadius) * 1.5
	for _, hit in pairs(hits) do
		if hit.blind then
			local dx, dy = hit.wx - wx, hit.wy - wy
			if dx * dx + dy * dy <= tolerance * tolerance then
				hit.wx, hit.wy = (hit.wx + wx) / 2, (hit.wy + wy) / 2
				hit.seenAt, hit.ttl = scanClock, BLIND_HIT_TTL
				hit.texture = textureFor(dbType, nodeID)
				return
			end
		end
	end

	blindCounter = blindCounter + 1
	hits["blind:" .. blindCounter] = { wx = wx, wy = wy, blind = true,
		texture = textureFor(dbType, nodeID), seenAt = scanClock, ttl = BLIND_HIT_TTL }
end

local function buildGrid()
	-- the centre is always sampled: at a small radius the loop below yields nothing
	local points = { { ox = 0, oy = 0 } }
	for x = -gridRadius, gridRadius, GRID_STEP do
		for y = -gridRadius, gridRadius, GRID_STEP do
			if x * x + y * y <= gridRadius * gridRadius and (x ~= 0 or y ~= 0) then
				points[#points + 1] = { ox = x, oy = y }
			end
		end
	end
	return points
end

-- Fold each blind hit's accumulated sample points into its centroid, then drop hits
-- that converged onto the same blip.
local function settleBlindHits()
	for _, hit in pairs(hits) do
		if hit.blind and hit.count and hit.count > 0 then
			hit.wx, hit.wy = hit.sumX / hit.count, hit.sumY / hit.count
			hit.sumX, hit.sumY, hit.count = nil, nil, nil
			hit.refined = true
		end
	end

	for keyA, a in pairs(hits) do
		if a.blind and a.refined then
			for keyB, b in pairs(hits) do
				if keyA ~= keyB and b.blind and b.refined then
					local dx, dy = a.wx - b.wx, a.wy - b.wy
					if dx * dx + dy * dy <= MERGE_YARDS * MERGE_YARDS then
						hits[a.seenAt >= b.seenAt and keyB or keyA] = nil
					end
				end
			end
		end
	end
end

local function queueScan()
	local pending = {}
	local now = GetTime()
	settleBlindHits()
	for key, node in pairs(nodes) do
		local ox, oy = minimapOffset(playerX - node.wx, playerY - node.wy)
		if ox then
			local order = node.lastCheck or 0
			if hits[key] then
				pending[#pending + 1] = { ox = ox, oy = oy, tag = key, order = order, ring = "center" }
			else
				node.probes = (node.probes or 0) + 1
				for _, probe in ipairs(PROBE) do
					pending[#pending + 1] = { ox = ox + probe[1], oy = oy + probe[2],
						tag = key, order = order, ring = probe[3] }
				end
			end
		end
	end
	table.sort(pending, function(a, b) return a.order < b.order end)
	for index = #pending, BURST + 1, -1 do
		pending[index] = nil
	end

	for _, point in ipairs(pending) do
		nodes[point.tag].lastCheck = now
	end

	blindMode = #pending == 0

	-- known blind hits get measured first, discovery fills whatever budget is left
	if blindMode then
		for key, hit in pairs(hits) do
			if hit.blind then
				local ox, oy = minimapOffset(playerX - hit.wx, playerY - hit.wy)
				if ox then
					for _, offset in ipairs(REFINE) do
						pending[#pending + 1] = { ox = ox + offset[1], oy = oy + offset[2], tag = key }
					end
				end
			end
		end
	end

	if blindMode then
		grid = grid or buildGrid()
		for _ = #pending + 1, BURST do
			if gridCursor > #grid then gridCursor = 1 end
			pending[#pending + 1] = grid[gridCursor]
			gridCursor = gridCursor + 1
		end
	end

	Scanner:Submit(pending)
end

local function render()
	local facing = GetPlayerFacing()
	if not facing then return end

	Radar:SetRange(scanRange)
	wipe(entries)
	for key, hit in pairs(hits) do
		if scanClock - hit.seenAt > hit.ttl then
			hits[key] = nil
		else
			local xDist, yDist = playerX - hit.wx, playerY - hit.wy
			local distance = math.sqrt(xDist * xDist + yDist * yDist)
			if distance <= scanRange then
				local rx, ry = rotate(xDist, yDist, facing)
				entries[#entries + 1] = {
					rx = rx / scanRange,
					ry = -ry / scanRange,
					distance = distance,
					texture = hit.texture,
				}
			end
		end
	end
	Radar:Render(entries)
end

local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(_, elapsed)
	sinceRebuild = sinceRebuild + elapsed
	if sinceRebuild >= 0.25 then
		sinceRebuild = 0
		if not refreshGeometry() then
			wipe(hits)
			Radar:Render({})
			return
		end
		rebuildCandidates()
	end
	if not mapRadius then return end

	-- the radar redraws from the player position every frame, so icons keep
	-- tracking between the far rarer scans
	playerX, playerY = HBD:GetPlayerWorldPosition()
	if not playerX then
		Radar:Render({})
		return
	end

	if not Scanner:IsBlocked() then
		scanClock = scanClock + elapsed
	end

	sinceScan = sinceScan + elapsed
	if sinceScan >= db.scanInterval and not Scanner:IsBusy() then
		sinceScan = 0
		queueScan()
	end

	render()
end)

function NR.Stop()
	running = false
	driver:Hide()
	Scanner:Restore()
	Scanner:Abort()
	wipe(nodes)
	wipe(hits)
	Radar:SetShown(false)
	NR.Options:Refresh()
end

function NR.Start()
	running = true
	sinceScan, sinceRebuild = 0, 0.25
	Radar:SetShown(true)
	driver:Show()
	NR.Options:Refresh()
end

function NR.IsRunning()
	return running
end

local function applyDefaults(target, source)
	for key, value in pairs(source) do
		if target[key] == nil then
			target[key] = type(value) == "table" and CopyTable(value) or value
		end
	end
end

local initialized = false

local function initialize()
	if initialized then return true end

	NodeRadarDB = NodeRadarDB or {}
	applyDefaults(NodeRadarDB, defaults)
	db = NodeRadarDB

	local ace = LibStub and LibStub("AceAddon-3.0", true)
	GatherMate = ace and ace:GetAddon("GatherMate2", true)
	local display = GatherMate and GatherMate:GetModule("Display", true)
	HBD = GatherMate and GatherMate.HBD
	minimapSize = display and display.minimapSize

	if not (GatherMate and HBD and minimapSize) then
		out("|cffff4444GatherMate2 is not available - NodeRadar disabled|r")
		return false
	end

	Radar:Init(db)
	NR.Options:Init(db)
	initialized = true

	out("ready. /nr starts and stops the radar")
	if not Scanner.canSplitMouse then
		out("|cffffaa00no SetMouseClickEnabled - falling back to muting the click handlers|r")
	end
	if not Scanner.canHideBlips then
		out("|cffffaa00no SetBlipTexture - blips stay visible during the scan|r")
	end
	if not Scanner.canHideArrow then
		out("|cffffaa00no SetPlayerTexture - the player arrow stays visible during the scan|r")
	end
	return true
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
	if initialize() and db.autoStart then NR.Start() end
end)

local function writeDiagnostics()
	local shown = {}
	for key, hit in pairs(hits) do
		local distance = math.sqrt((playerX - hit.wx) ^ 2 + (playerY - hit.wy) ^ 2)
		shown[#shown + 1] = string.format("%s d=%.1fyd wx=%.1f wy=%.1f %s%s",
			key, distance, hit.wx, hit.wy,
			hit.blind and "blind" or "database", hit.refined and " refined" or "")
	end

	local candidates, confirmed = {}, 0
	for key, node in pairs(nodes) do
		local distance = math.sqrt((playerX - node.wx) ^ 2 + (playerY - node.wy) ^ 2)
		local ox, oy = minimapOffset(playerX - node.wx, playerY - node.wy)
		if hits[key] then confirmed = confirmed + 1 end
		candidates[#candidates + 1] = string.format("%s d=%.0fyd off=%.1f/%.1f probes=%d %s",
			node.dbType, distance, ox or 0, oy or 0, node.probes or 0,
			hits[key] and "CONFIRMED" or "missing")
	end

	-- copy, never reference: the live tables keep changing until logout and would
	-- otherwise be serialised in a later state than the counters
	local ringHits, log = {}, {}
	for ring, count in pairs(diag.ringHits) do ringHits[ring] = count end
	for index, entry in ipairs(diag.log) do log[index] = entry end

	NodeRadarDB = NodeRadarDB or {}
	-- snapshots accumulate so two modes can be compared from one session
	if type(NodeRadarDB.debug) ~= "table" or NodeRadarDB.debug.takenAt then
		NodeRadarDB.debug = {}
	end
	local snapshot = {
		mode = forceBlind and "forced blind" or (blindMode and "blind" or "targeted"),
		takenAt = date("%Y-%m-%d %H:%M:%S"),
		shownNodes = shown,
		zoom = Minimap:GetZoom(),
		minimapZoomCVar = GetCVar("minimapZoom"),
		mapRadius = mapRadius,
		scanRange = scanRange,
		pixelsPerYard = halfWidth and mapRadius and halfWidth / mapRadius,
		samples = diag.samples,
		tooltips = diag.tooltips,
		matched = diag.matched,
		ringHits = ringHits,
		tooltipLog = log,
		candidates = candidates,
		confirmed = confirmed,
		tracking = GetTrackingTexture and GetTrackingTexture() or "none",
		-- standalone mode would need these instead of GatherMate's helpers
		hasUnitPosition = type(UnitPosition) == "function",
		unitPosition = type(UnitPosition) == "function" and { UnitPosition("player") } or nil,
		hasTrackingInfo = C_Minimap and type(C_Minimap.GetTrackingInfo) == "function",
		numTrackingTypes = C_Minimap and C_Minimap.GetNumTrackingTypes
			and C_Minimap.GetNumTrackingTypes() or 0,
	}

	table.insert(NodeRadarDB.debug, snapshot)
	while #NodeRadarDB.debug > 6 do
		table.remove(NodeRadarDB.debug, 1)
	end
	out(string.format("snapshot %d (%s): %d nodes shown, %d/%d candidates confirmed, %d tooltips",
		#NodeRadarDB.debug, snapshot.mode, #shown, confirmed, #candidates, diag.tooltips))
end

SLASH_NODERADAR1 = "/nr"
SLASH_NODERADAR2 = "/noderadar"
SlashCmdList["NODERADAR"] = function(msg)
	if not initialize() then return end
	local cmd = string.lower(strtrim(msg or ""))
	if cmd == "debug" then
		writeDiagnostics()
		return
	elseif cmd == "options" or cmd == "config" then
		NR.Options:Open()
		return
	elseif cmd == "blind" then
		forceBlind = not forceBlind
		wipe(nodes)
		wipe(hits)
		out("blind sweep forced: " .. (forceBlind and "on - the database is ignored" or "off"))
		return
	end
	if running then
		NR.Stop()
		out("stopped")
	else
		NR.Start()
		out("running")
	end
end
