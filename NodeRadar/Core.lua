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
-- A blip's hit area is far wider than the cluster spacing, so a sample can pick up the
-- tooltip of a node that belongs somewhere else entirely. A confirmation is therefore
-- attributed to the candidate of that exact node id nearest the sample point, within
-- this radius, rather than to whatever sat in the cluster being probed.
local MATCH_PX = 8
-- standing on a node puts its icon under the player marker, where it says nothing
local MIN_DISTANCE = 5
-- an unconfirmed cluster is probed around its aimed point as well, in case another
-- blip covers it
local PROBE = {
	{ 0, 0, "center" },
	{ 5, 0, "east" }, { -5, 0, "west" },
	{ 0, 5, "north" }, { 0, -5, "south" },
}
-- Debug mode places these in world coordinates around wherever you stood when you
-- switched it on, using real node types so they travel, rotate and colour exactly
-- like a confirmed node. Offsets are yards, the pairs are GatherMate's db type and
-- node id, chosen to span the skill range.
local TEST_NODES = {
	{ 25, 0, "Mining", 201 },
	{ -25, 0, "Herb Gathering", 401 },
	{ 0, 55, "Mining", 221 },
	{ 0, -55, "Herb Gathering", 432 },
	{ 60, 55, "Mining", 224 },
	{ -60, 45, "Herb Gathering", 437 },
}

-- Skill needed to gather a node, keyed by GatherMate's node ids. Values are taken
-- from the Icy Veins and Warcraft Tavern TBC profession guides, which agree on every
-- entry; ooze covered variants carry their base ore's requirement. Nodes whose
-- requirement could not be verified are deliberately absent - a missing entry means
-- no judgement is made rather than a guessed one.
local REQUIRED_SKILL = {
	["Mining"] = {
		[201] = 1, [202] = 65, [203] = 125, [204] = 75, [205] = 155,
		[206] = 175, [207] = 175, [208] = 230, [209] = 75, [210] = 155,
		[211] = 230, [212] = 275, [213] = 245, [214] = 245, [215] = 275,
		[217] = 230, [221] = 300, [222] = 325, [223] = 350, [224] = 375,
	},
	["Herb Gathering"] = {
		[401] = 1, [402] = 1, [403] = 1, [404] = 70, [405] = 70,
		[407] = 85, [408] = 115, [409] = 115, [410] = 120, [411] = 125,
		[412] = 150, [413] = 170, [414] = 170, [415] = 185, [416] = 195,
		[417] = 205, [418] = 205, [420] = 220, [421] = 230, [422] = 235,
		[423] = 245, [424] = 270, [425] = 250, [426] = 270, [427] = 270,
		[428] = 270, [429] = 290, [431] = 300, [432] = 300, [433] = 315,
		[434] = 325, [435] = 340, [437] = 375, [438] = 350, [439] = 365,
		[440] = 325, [441] = 335,
	},
}

-- the tracking abilities whose blips this addon can read; GatherMate matches them by
-- name on some clients and by texture on others, so both are compared
local TRACKING_SPELLS = { [2580] = "Mining", [2383] = "Herb Gathering" }

local defaults = {
	radius = 120,
	iconSize = 20,
	nodeAlpha = 1,
	gridAlpha = 0.25,
	scanInterval = 5,
	colorBySkill = true,
	showSparkle = true,
	showDistances = true,
	showGrid = true,
	showWindow = true,
	autoStart = false,
	pauseInCombat = false,
	debugLog = false,
	debugTestNodes = false,
	windowPoint = { "CENTER", "CENTER", 0, 220 },
}
NR.defaults = defaults

local GatherMate, HBD, minimapSize
local nodes, clusters, hits, entries = {}, {}, {}, {}
local zoneID, playerX, playerY
local mapRadius, halfWidth, halfHeight
local rotateMinimap, scanRange
local sinceScan, sinceRebuild = 0, 0
local wasBlocked = false
-- hits age on this clock, which only advances while scanning is actually possible:
-- a held mouse button means "cannot look", never "the node is gone"
local scanClock = 0
local running = false
local trackingWarned = false
local shownCount = 0
local skillRank = {}
local db

local function out(msg)
	print("|cff33ff99NodeRadar|r " .. msg)
end

local function stamped(msg)
	out("|cff888888[" .. date("%H:%M:%S") .. "]|r " .. msg)
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

-- The skill list only reports expanded headers, so a collapsed profession header
-- leaves the rank unknown. That is handled by making no judgement at all rather
-- than assuming the worst.
local function refreshSkills()
	wipe(skillRank)
	local locale = LibStub and LibStub("AceLocale-3.0", true)
	local L = locale and locale:GetLocale("GatherMate2", true)
	if not L then return end

	local professions = { [L["Mining"]] = "Mining", [L["Herbalism"]] = "Herb Gathering" }
	for index = 1, GetNumSkillLines() do
		local name, header, _, rank = GetSkillLineInfo(index)
		local dbType = name and not header and professions[name]
		if dbType then skillRank[dbType] = rank end
	end
end

local function skillTooLow(dbType, nodeID)
	local required = REQUIRED_SKILL[dbType] and REQUIRED_SKILL[dbType][nodeID]
	local rank = skillRank[dbType]
	return required ~= nil and rank ~= nil and rank < required
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
	local entry = string.format("%s owner=%s | %s",
		matched and "MATCH" or "NOMATCH", Scanner:LastOwner(), (text:gsub("\n", " / ")))
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
	-- claims the candidate it belongs to
	wipe(taken)
	for _, entry in ipairs(found) do
		local chosen, closest
		for key, node in pairs(nodes) do
			if node.ox and not taken[key]
				and node.dbType == entry.dbType and node.nodeID == entry.nodeID then
				local dx, dy = node.ox - ox, node.oy - oy
				local distance = dx * dx + dy * dy
				if distance <= MATCH_PX * MATCH_PX and (not closest or distance < closest) then
					chosen, closest = key, distance
				end
			end
		end

		-- nothing of that id nearby: only an unambiguous cluster may take it, which is
		-- how a spot the database calls copper gets shown as the tin that spawned there
		if not chosen and #cluster.members == 1 and not taken[cluster.members[1]] then
			chosen = cluster.members[1]
		end

		if chosen then
			taken[chosen] = true
			local node = nodes[chosen]
			node.nodeID = entry.nodeID
			local previous = hits[chosen]
			hits[chosen] = { wx = node.wx, wy = node.wy, seenAt = scanClock,
				texture = textureFor(entry.dbType, entry.nodeID),
				tooLow = skillTooLow(entry.dbType, entry.nodeID),
				appearedAt = previous and previous.appearedAt or GetTime() }
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
			node.ox, node.oy = ox, oy
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

	if db.debugLog then
		local confirmed = 0
		for _, cluster in ipairs(clusters) do
			if cluster.confirmed then confirmed = confirmed + 1 end
		end
		stamped(string.format("scan: %d clusters (%d confirmed), %d samples queued, %d shown",
			#clusters, confirmed, #pending, shownCount))
	end

	Scanner:Submit(pending)
end

local function render()
	local facing = GetPlayerFacing()
	if not facing then return end

	local ttl = db.scanInterval + 1.5
	wipe(entries)
	for key, hit in pairs(hits) do
		if not hit.test and scanClock - hit.seenAt > ttl then
			hits[key] = nil
		else
			local xDist, yDist = playerX - hit.wx, playerY - hit.wy
			local distance = math.sqrt(xDist * xDist + yDist * yDist)
			if distance <= scanRange and distance >= MIN_DISTANCE then
				local rx, ry = rotate(xDist, yDist, facing)
				entries[#entries + 1] = {
					key = key,
					rx = rx / scanRange,
					ry = -ry / scanRange,
					distance = distance,
					texture = hit.texture,
					tooLow = hit.tooLow,
					appearedAt = hit.appearedAt,
				}
			end
		end
	end
	shownCount = #entries
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

	local isBlocked, reason = Scanner:IsBlocked()
	if not isBlocked then
		scanClock = scanClock + elapsed
		if wasBlocked and db.debugLog then stamped("scanning resumed") end
	elseif not wasBlocked and db.debugLog then
		stamped("scanning paused: " .. tostring(reason))
	end
	wasBlocked = isBlocked

	-- The interval keeps running through a pause, so the time already waited is not
	-- lost and a pass starts the moment scanning becomes possible again - but only if
	-- the pause outlasted whatever was left of the interval.
	sinceScan = sinceScan + elapsed
	if sinceScan >= db.scanInterval and not isBlocked and not Scanner:IsBusy() then
		sinceScan = 0
		queueScan()
	end

	render()
end)

-- Nothing can be confirmed without a gathering tracking active: the client draws no
-- blips, so there is nothing to hover. Returns nil when none is active, and true when
-- the client offers no way to tell - in which case no warning is given.
local function gatherTrackingActive()
	local api = C_Minimap
	if not (api and api.GetNumTrackingTypes and api.GetTrackingInfo) then return true end

	local wanted = {}
	for spellID, dbType in pairs(TRACKING_SPELLS) do
		local name, _, texture = GetSpellInfo(spellID)
		if name then wanted[name] = dbType end
		if texture then wanted[texture] = dbType end
	end

	for index = 1, api.GetNumTrackingTypes() do
		local first, second, third = api.GetTrackingInfo(index)
		local name, texture, active
		if type(first) == "table" then
			name, texture, active = first.name, first.texture, first.active
		else
			name, texture, active = first, second, third
		end
		if active and (wanted[name] or wanted[texture]) then return name end
	end
end

local function warnMissingTracking()
	out("|cffffaa00no gathering tracking is active - turn on Find Minerals or Find "
		.. "Herbs, otherwise the client draws no blips and nothing can be confirmed|r")
end

-- called on every tracking change, so it only speaks when the state actually flips
local function checkTracking()
	if not running then return end
	if gatherTrackingActive() then
		if trackingWarned then
			trackingWarned = false
			out("gathering tracking is active again")
		end
	elseif not trackingWarned then
		trackingWarned = true
		warnMissingTracking()
	end
end

-- test nodes are ordinary hits that never expire, so every step of the display -
-- world position, rotation, distance, skill colour - is exercised
function NR.SetTestNodes(enabled)
	for key, hit in pairs(hits) do
		if hit.test then hits[key] = nil end
	end
	if not enabled then return end

	local px, py = HBD:GetPlayerWorldPosition()
	if not px then
		out("|cffffaa00no world position available, test nodes not placed|r")
		return
	end

	for index, test in ipairs(TEST_NODES) do
		hits["test:" .. index] = {
			wx = px + test[1], wy = py + test[2], test = true, seenAt = 0,
			appearedAt = GetTime(),
			texture = textureFor(test[3], test[4]),
			tooLow = skillTooLow(test[3], test[4]),
		}
	end
	out(#TEST_NODES .. " test nodes placed around you")
end

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
	trackingWarned = not gatherTrackingActive()
	if trackingWarned then warnMissingTracking() end
	running = true
	sinceScan, sinceRebuild = 0, 0.25
	Radar:SetShown(true)
	driver:Show()
	if db.debugTestNodes then NR.SetTestNodes(true) end
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
	-- the single debug switch became two
	if NodeRadarDB.debugMode ~= nil then
		NodeRadarDB.debugLog = NodeRadarDB.debugMode
		NodeRadarDB.debugTestNodes = NodeRadarDB.debugMode
		NodeRadarDB.debugMode = nil
	end
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
	Scanner.pauseInCombat = db.pauseInCombat
	refreshSkills()

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
loader:RegisterEvent("SKILL_LINES_CHANGED")
loader:RegisterEvent("MINIMAP_UPDATE_TRACKING")
loader:SetScript("OnEvent", function(_, event)
	if event == "SKILL_LINES_CHANGED" then
		if initialized then refreshSkills() end
		return
	elseif event == "MINIMAP_UPDATE_TRACKING" then
		if initialized then checkTracking() end
		return
	end
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
		skillRank = { mining = skillRank["Mining"], herbalism = skillRank["Herb Gathering"] },
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
