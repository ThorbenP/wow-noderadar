local ADDON, NR = ...

if not NR.Scanner or not NR.Radar or not NR.Options then
	print("|cff33ff99NodeRadar|r |cffff4444a file did not load - check BugSack|r")
	return
end

local Scanner, Radar = NR.Scanner, NR.Radar

local GATHER_TYPES = { "Herb Gathering", "Mining" }
local BURST = 30
-- Two nodes can share almost the same spot, and one blip is wider than that
-- distance. Candidates this close therefore share a single sample point, and the
-- tooltip's lines say which of them are actually there.
local CLUSTER_PX = 4
-- an unconfirmed cluster is probed around its aimed point as well, in case another
-- blip covers it
local PROBE = {
	{ 0, 0, "center" },
	{ 5, 0, "east" }, { -5, 0, "west" },
	{ 0, 5, "north" }, { 0, -5, "south" },
}

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

local GatherMate, HBD, minimapSize
local nodes, clusters, hits, entries = {}, {}, {}, {}
local zoneID, playerX, playerY
local mapRadius, halfWidth, halfHeight
local rotateMinimap, scanRange
local sinceScan, sinceRebuild = 0, 0
-- hits age on this clock, which only advances while scanning is actually possible:
-- a held mouse button means "cannot look", never "the node is gone"
local scanClock = 0
local running = false
local db

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

local function cleanName(text)
	return strtrim((text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
end

-- The minimap tooltip lists everything under the cursor - three auctioneers in one
-- text is a measured case - so every line is examined and every node in it returned.
local function identifyAll(text, found)
	wipe(found)
	for line in text:gmatch("[^\n]+") do
		local name = cleanName(line)
		for _, dbType in ipairs(GATHER_TYPES) do
			local nodeID = GatherMate:GetIDForNode(dbType, name)
			if nodeID then
				found[#found + 1] = { dbType = dbType, nodeID = nodeID }
				break
			end
		end
	end
	return found
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
		for coord, nodeID in GatherMate:FindNearbyNode(zoneID, zx, zy, dbType, scanRange) do
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
		if not seen[key] then
			nodes[key] = nil
			hits[key] = nil
		end
	end
end

local diag = { ringHits = {}, samples = 0, tooltips = 0, matched = 0, log = {} }

local function logTooltip(matched, ring, text)
	local entry = string.format("%s | %s",
		matched and "MATCH" or "NOMATCH", (text:gsub("\n", " / ")))
	-- distinct texts only: one node hit fifty times would otherwise crowd out every
	-- other blip the scan saw
	for _, existing in ipairs(diag.log) do
		if existing == entry then return end
	end
	diag.log[#diag.log + 1] = entry
	if #diag.log > 40 then table.remove(diag.log, 1) end
end

local found, taken = {}, {}

function Scanner.onSample(tag, text, ox, oy, ring)
	diag.samples = diag.samples + 1
	if not text then return end
	diag.tooltips = diag.tooltips + 1

	identifyAll(text, found)
	logTooltip(#found > 0, ring, text)
	if #found == 0 then return end

	local cluster = tag and clusters[tag]
	if not cluster then return end

	diag.matched = diag.matched + 1
	if ring then diag.ringHits[ring] = (diag.ringHits[ring] or 0) + 1 end

	-- one sample can prove several nodes at once, so each node named in the tooltip
	-- claims the cluster member it fits best
	wipe(taken)
	for _, entry in ipairs(found) do
		local chosen
		for _, key in ipairs(cluster.members) do
			local node = nodes[key]
			if node and not taken[key] and node.dbType == entry.dbType then
				chosen = chosen or key
				if node.nodeID == entry.nodeID then
					chosen = key
					break
				end
			end
		end
		if chosen then
			taken[chosen] = true
			local node = nodes[chosen]
			node.nodeID = entry.nodeID
			hits[chosen] = { wx = node.wx, wy = node.wy, seenAt = scanClock,
				texture = textureFor(entry.dbType, entry.nodeID) }
		end
	end
end

-- Candidates that land on the same handful of pixels are one sample point: the blip
-- is wider than the distance between them, so probing each separately would hit the
-- same blip several times over.
local function buildClusters()
	wipe(clusters)
	for key, node in pairs(nodes) do
		local ox, oy = minimapOffset(playerX - node.wx, playerY - node.wy)
		if ox then
			local target
			for _, cluster in ipairs(clusters) do
				local dx, dy = cluster.ox - ox, cluster.oy - oy
				if dx * dx + dy * dy <= CLUSTER_PX * CLUSTER_PX then
					target = cluster
					break
				end
			end
			if target then
				target.members[#target.members + 1] = key
				target.confirmed = target.confirmed or hits[key] ~= nil
				target.order = math.min(target.order, nodes[key].lastCheck or 0)
			else
				clusters[#clusters + 1] = { ox = ox, oy = oy, members = { key },
					confirmed = hits[key] ~= nil, order = node.lastCheck or 0 }
			end
		end
	end
end

local function queueScan()
	buildClusters()

	local pending = {}
	for index, cluster in ipairs(clusters) do
		if cluster.confirmed then
			pending[#pending + 1] = { ox = cluster.ox, oy = cluster.oy,
				tag = index, ring = "center", order = cluster.order }
		else
			for _, probe in ipairs(PROBE) do
				pending[#pending + 1] = { ox = cluster.ox + probe[1], oy = cluster.oy + probe[2],
					tag = index, ring = probe[3], order = cluster.order }
			end
		end
	end

	table.sort(pending, function(a, b) return a.order < b.order end)
	for index = #pending, BURST + 1, -1 do
		pending[index] = nil
	end

	local now = GetTime()
	for _, point in ipairs(pending) do
		for _, key in ipairs(clusters[point.tag].members) do
			nodes[key].lastCheck = now
			nodes[key].probes = (nodes[key].probes or 0) + 1
		end
	end

	Scanner:Submit(pending)
end

local function render()
	local facing = GetPlayerFacing()
	if not facing then return end

	local ttl = db.scanInterval + 1.5
	wipe(entries)
	for key, hit in pairs(hits) do
		if scanClock - hit.seenAt > ttl then
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

	-- the radar redraws from the player position every frame, so icons keep tracking
	-- between the far rarer scans
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
	wipe(clusters)
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
		out("|cffff4444GatherMate2 is required and not available - NodeRadar disabled|r")
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
		shown[#shown + 1] = string.format("%s d=%.1fyd wx=%.1f wy=%.1f", key, distance, hit.wx, hit.wy)
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

	local clusterSizes = {}
	for index, cluster in ipairs(clusters) do
		clusterSizes[index] = #cluster.members
	end

	-- copy, never reference: the live tables keep changing until logout and would
	-- otherwise be serialised in a later state than the counters
	local ringHits, log = {}, {}
	for ring, count in pairs(diag.ringHits) do ringHits[ring] = count end
	for index, entry in ipairs(diag.log) do log[index] = entry end

	NodeRadarDB = NodeRadarDB or {}
	if type(NodeRadarDB.debug) ~= "table" or NodeRadarDB.debug.takenAt then
		NodeRadarDB.debug = {}
	end
	local snapshot = {
		takenAt = date("%Y-%m-%d %H:%M:%S"),
		zone = zoneID,
		mapRadius = mapRadius,
		scanRange = scanRange,
		pixelsPerYard = halfWidth and mapRadius and halfWidth / mapRadius,
		rotateMinimap = rotateMinimap,
		shownNodes = shown,
		candidates = candidates,
		clusterSizes = clusterSizes,
		confirmed = confirmed,
		samples = diag.samples,
		tooltips = diag.tooltips,
		matched = diag.matched,
		ringHits = ringHits,
		tooltipLog = log,
	}

	table.insert(NodeRadarDB.debug, snapshot)
	while #NodeRadarDB.debug > 6 do
		table.remove(NodeRadarDB.debug, 1)
	end

	out(string.format("snapshot %d: %d nodes shown, %d/%d candidates confirmed in %d clusters",
		#NodeRadarDB.debug, #shown, confirmed, #candidates, #clusters))
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
	end

	if running then
		NR.Stop()
		out("stopped")
	else
		NR.Start()
		out("running")
	end
end
