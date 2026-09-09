local ADDON, NR = ...

if not NR.Scanner or not NR.Radar or not NR.Options or not NR.Dump then
	print("|cff33ff99NodeRadar|r |cffff4444a file did not load - check BugSack|r")
	return
end

local Scanner, Radar = NR.Scanner, NR.Radar

-- diagnostics name the version they came from, so a report can be placed
local metadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
NR.version = metadata and metadata(ADDON, "Version") or "?"

local GATHER_TYPES = { "Herb Gathering", "Mining" }
local BURST = 30
-- how often the candidate list and the hold reason are re-read, in seconds
local REBUILD_INTERVAL = 0.25
-- A candidate that read as empty is not worth asking again straight away: a node takes
-- minutes to spawn, so nothing is lost by leaving that spot alone this long.
local MISS_COOLDOWN = 15
-- The client's blip range is an assumption taken from GatherMate's setting, so a
-- candidate that read as empty from far away is asked again once this much closer.
local APPROACH_YARDS = 15
-- Two confirmed candidates of one node id no further apart than this could have been
-- answered by a single blip's hit area, so the pair is worth recording.
local DOUBLE_PX = 40
-- Quiet between passes. Without it, walking into a dense area brings new candidates
-- into range faster than a pass takes, and the minimap would be under the cursor
-- continuously.
local PASS_COOLDOWN = 2
-- how long the automatic blip measurement waits before it may run again
local MEASURE_COOLDOWN = 60
-- Bumped whenever the shape or meaning of what /nr debug records changes, which
-- discards the stored snapshots: comparing readings across formats misleads.
local DIAG_FORMAT = 3
-- how many snapshots and blip measurements are kept
local DIAG_KEPT = 6
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
	recheckSeconds = 3,
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
local mapRadius, halfWidth, halfHeight, pixelsPerYard
local rotateMinimap, scanRange
local sinceRebuild = 0
local lastMeasure, measureRequested = -MEASURE_COOLDOWN, false
local lastPass = -PASS_COOLDOWN
-- When each candidate was last aimed at, and from how far: kept per node key rather
-- than on the candidate, so walking out of range and back does not reset the wait.
local probed = {}
-- Why scanning is on hold, held between ticks so the log carries one line per change
-- and the hit clock knows whether to advance. One hold is worth telling every user
-- about rather than only a debug log, so it is named: with no tracking ability up the
-- radar cannot work at all, and nothing on screen would say why.
local pauseReason, clockFrozen
local NO_TRACKING = "no gathering tracking is active"
-- hits age on this clock, which only advances while scanning is actually possible:
-- a held mouse button means "cannot look", never "the node is gone"
local scanClock = 0
local running = false
local shownCount = 0
local skillRank = {}
local db

local function out(msg)
	print("|cff33ff99NodeRadar|r " .. msg)
end

local function warn(msg)
	out("|cffffaa00" .. msg .. "|r")
end

local function stamped(msg)
	out("|cff888888[" .. date("%H:%M:%S") .. "]|r " .. msg)
end

-- an empty render, without allocating a table to say so
local EMPTY = {}

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
	local zone = currentZone()
	if not zone or zone == 0 then return false end
	if zone ~= zoneID then
		zoneID = zone
		-- GatherMate's coords are zone-local, so the keys would otherwise collide
		wipe(probed)
	end

	local zoom = Minimap:GetZoom()
	local indoors = GetCVar("minimapZoom") + 0 == zoom and "outdoor" or "indoor"
	mapRadius = minimapSize[indoors][zoom] / 2
	halfWidth, halfHeight = Minimap:GetWidth() / 2, Minimap:GetHeight() / 2
	pixelsPerYard = halfWidth / mapRadius
	rotateMinimap = GetCVar("rotateMinimap") == "1"
	scanRange = detectionRange()
	return true
end

-- offsets are in minimap-local units, matching how the client draws its blips
-- Callers looping over candidates pass facing in: it is one value for the whole loop,
-- and GetPlayerFacing per candidate was the cost of not saying so.
local function minimapOffset(xDist, yDist, facing)
	if rotateMinimap then
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

-- Nothing can be confirmed without a gathering tracking active: the client draws no
-- blips for a type it is not tracking, so there is nothing to hover. `tracked` holds
-- the types whose blips the client is drawing, and every type when the client offers
-- no way to tell - so one lookup answers both questions and no caller needs a branch.
local tracked, trackingKnown = {}, false
local trackingNames

local function trackingNameMap()
	if trackingNames then return trackingNames end

	local names, complete = {}, true
	for spellID, dbType in pairs(TRACKING_SPELLS) do
		local name, _, texture = GetSpellInfo(spellID)
		if name then names[name] = dbType end
		if texture then names[texture] = dbType end
		-- spell data can still be missing right after login; that must not be cached
		if not name and not texture then complete = false end
	end
	if complete then trackingNames = names end
	return names
end

local function refreshTracking()
	wipe(tracked)
	local api = C_Minimap
	trackingKnown = (api and api.GetNumTrackingTypes and api.GetTrackingInfo) and true or false
	if not trackingKnown then
		for _, dbType in ipairs(GATHER_TYPES) do tracked[dbType] = true end
		return
	end

	local names = trackingNameMap()
	for index = 1, api.GetNumTrackingTypes() do
		local first, second, third = api.GetTrackingInfo(index)
		local name, texture, active
		if type(first) == "table" then
			name, texture, active = first.name, first.texture, first.active
		else
			name, texture, active = first, second, third
		end
		if active then
			local dbType = names[name] or names[texture]
			if dbType then tracked[dbType] = true end
		end
	end
end

local function rebuildCandidates()
	local zx, zy = HBD:GetZoneCoordinatesFromWorld(playerX, playerY, zoneID)
	if not zx then return end

	refreshTracking()

	local seen = {}
	for _, dbType in ipairs(GATHER_TYPES) do
		if tracked[dbType] then
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
	end

	for key in pairs(nodes) do
		if not seen[key] then
			nodes[key] = nil
			hits[key] = nil
		end
	end
end

local diag = { ringHits = {}, samples = 0, tooltips = 0, matched = 0, stolen = {},
	log = { list = {}, seen = {} }, confirmations = { list = {}, seen = {} },
	doubles = { list = {}, seen = {} }, unclaimed = { list = {}, seen = {} } }

-- Distinct entries only, newest kept: one node hit fifty times would otherwise crowd
-- out every other blip the scan saw. Membership is a lookup rather than a walk of the
-- list, because this runs per sample.
local LOG_CAP = 40

local function logDistinct(log, entry)
	if log.seen[entry] then return end
	log.seen[entry] = true

	local list = log.list
	list[#list + 1] = entry
	if #list > LOG_CAP then
		log.seen[list[1]] = nil
		table.remove(list, 1)
	end
end

local function logTooltip(matched, text)
	logDistinct(diag.log, string.format("%s owner=%s | %s",
		matched and "MATCH" or "NOMATCH", Scanner:LastOwner(), (text:gsub("\n", " / "))))
end

-- which sample point earned a confirmation, and how far the candidate it was
-- attributed to sat from that point: a confirmation from a probe ring at the edge of
-- MATCH_PX is one a neighbouring blip could have produced
local function logConfirm(key, ring, ox, oy, node, closest)
	logDistinct(diag.confirmations, string.format(
		"%s ring=%s sample=%.1f/%.1f node=%.1f/%.1f d=%s",
		key, tostring(ring), ox, oy, node.ox, node.oy,
		closest and string.format("%.1fpx", math.sqrt(closest)) or "sole member"))
end

local found, taken = {}, {}

local function scanSample(payload, text, ox, oy, stolen)
	diag.samples = diag.samples + 1
	if not text then
		-- A pin sitting on the spot being probed hides the blip's tooltip behind its
		-- own, so the sample reads as empty. Counted per frame, because whether it
		-- happens depends on when GatherMate last re-enabled its pins.
		if stolen then diag.stolen[stolen] = (diag.stolen[stolen] or 0) + 1 end
		return
	end
	diag.tooltips = diag.tooltips + 1

	identifyAll(text, found)
	logTooltip(#found > 0, text)
	if #found == 0 then return end

	local cluster = clusters[payload.cluster]
	if not cluster then return end

	diag.matched = diag.matched + 1
	diag.ringHits[payload.ring] = (diag.ringHits[payload.ring] or 0) + 1

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

		if not chosen then
			-- The tooltip proves a node is there, yet no candidate fits its id and the
			-- cluster is too ambiguous to hand it to. Worth seeing: it is a node the
			-- radar cannot show at all.
			logDistinct(diag.unclaimed, string.format(
				"%s %d named at %.1f/%.1f, claimed by nothing (cluster of %d)",
				entry.dbType, entry.nodeID, ox, oy, #cluster.members))
		else
			taken[chosen] = true
			local node = nodes[chosen]
			logConfirm(chosen, payload.ring, ox, oy, node, closest)

			-- which probe ring actually answers for this spot: a blip offset from the
			-- database position answers from one side only
			local seen = probed[chosen]
			if seen then
				seen.rings = seen.rings or {}
				seen.rings[payload.ring] = (seen.rings[payload.ring] or 0) + 1
			end
			node.nodeID = entry.nodeID
			local previous = hits[chosen]
			hits[chosen] = { wx = node.wx, wy = node.wy, seenAt = scanClock,
				texture = textureFor(entry.dbType, entry.nodeID),
				tooLow = skillTooLow(entry.dbType, entry.nodeID),
				appearedAt = previous and previous.appearedAt or GetTime() }
		end
	end
end

-- A candidate is worth a sample when nothing is known about it yet, when a confirmed
-- node is due for the recheck that would notice it being gathered, or when its last
-- reading was empty and either the cooldown has run out or the player has closed in
-- far enough that the client may draw a blip it would not have drawn before.
local function candidateDue(key, distance)
	local seen = probed[key]
	if not seen then return true end
	if hits[key] then
		return scanClock - seen.at >= db.recheckSeconds
	end
	return scanClock - seen.at >= MISS_COOLDOWN
		or seen.distance - distance >= APPROACH_YARDS
end

-- Candidates that land on the same handful of pixels are one sample point: the blip
-- is wider than the distance between them, so probing each separately would hit the
-- same blip several times over.
local function buildClusters()
	wipe(clusters)
	local facing = GetPlayerFacing()
	for key, node in pairs(nodes) do
		local ox, oy = minimapOffset(playerX - node.wx, playerY - node.wy, facing)
		if ox then
			node.ox, node.oy = ox, oy
			local dx, dy = playerX - node.wx, playerY - node.wy
			node.distance = math.sqrt(dx * dx + dy * dy)
			local due = candidateDue(key, node.distance)
			local seen = probed[key]
			local order = seen and seen.at or -1
			local target
			for _, cluster in ipairs(clusters) do
				local dx, dy = cluster.ox - ox, cluster.oy - oy
				if dx * dx + dy * dy <= CLUSTER_PX * CLUSTER_PX then
					target = cluster
					break
				end
			end
			-- confirmedKey names the member whose id the tooltip actually gave, which is
			-- the only one worth aiming a measurement at
			if target then
				target.members[#target.members + 1] = key
				target.confirmedKey = target.confirmedKey or (hits[key] and key)
				target.due = target.due or due
				target.order = math.min(target.order, order)
			else
				clusters[#clusters + 1] = { ox = ox, oy = oy, members = { key },
					confirmedKey = hits[key] and key, due = due, order = order }
			end
		end
	end
end

-- No API exposes the size of a client tracking blip's hit area, yet CLUSTER_PX,
-- MATCH_PX and the probe spacing all describe it. A cross of sample points walked one
-- pixel at a time across a confirmed node measures that area, and where its centre
-- sits relative to the database coordinate the cross was aimed at. Sweeping every
-- confirmed cluster answers the question that matters: two aims resolving to the same
-- centre are one blip claimed twice.
-- No API exposes the hit area of a client tracking blip, yet CLUSTER_PX, MATCH_PX and
-- the probe spacing all describe it - and the blip does not have to sit where the
-- database says. A grid answers both at once: a cross cannot locate a blip it does not
-- run through, which is exactly the case worth measuring. The step is smaller than the
-- hit area measured so far, so no blip inside the grid can slip between samples.
local MEASURE_SPAN = 15
local MEASURE_STEP = 3
local measuring

local function measureSteps()
	local steps = {}
	for step = -MEASURE_SPAN, MEASURE_SPAN, MEASURE_STEP do
		steps[#steps + 1] = step
	end
	return steps
end

local MEASURE_AXIS = measureSteps()

-- One picture per target: rows run north to south, columns west to east, and the
-- aimed-at point is the middle cell.
local function measureGrid(target)
	local rows = {}
	for row = #MEASURE_AXIS, 1, -1 do
		local marks = {}
		for column = 1, #MEASURE_AXIS do
			local cell = target.grid[MEASURE_AXIS[column]]
			marks[#marks + 1] = (cell and cell[MEASURE_AXIS[row]]) and "#" or
				(MEASURE_AXIS[row] == 0 and MEASURE_AXIS[column] == 0 and "+" or ".")
		end
		rows[#rows + 1] = "  " .. table.concat(marks)
	end
	return rows
end

-- Separate patches of hits are separate blips, so they are reported separately: one
-- patch offset from the aimed point is a database coordinate that is simply wrong,
-- while two patches mean a second node of the same kind is nearby.
local function measurePatches(target)
	local seen, patches = {}, {}
	local function key(x, y) return x .. ":" .. y end

	for _, x in ipairs(MEASURE_AXIS) do
		for _, y in ipairs(MEASURE_AXIS) do
			local column = target.grid[x]
			if column and column[y] and not seen[key(x, y)] then
				local patch = { minX = x, maxX = x, minY = y, maxY = y, cells = 0,
					sumX = 0, sumY = 0 }
				local stack = { { x, y } }
				seen[key(x, y)] = true
				while #stack > 0 do
					local cell = table.remove(stack)
					local cx, cy = cell[1], cell[2]
					patch.cells = patch.cells + 1
					patch.sumX, patch.sumY = patch.sumX + cx, patch.sumY + cy
					patch.minX, patch.maxX = math.min(patch.minX, cx), math.max(patch.maxX, cx)
					patch.minY, patch.maxY = math.min(patch.minY, cy), math.max(patch.maxY, cy)
					for _, step in ipairs({ { MEASURE_STEP, 0 }, { -MEASURE_STEP, 0 },
						{ 0, MEASURE_STEP }, { 0, -MEASURE_STEP } }) do
						local nx, ny = cx + step[1], cy + step[2]
						local neighbour = target.grid[nx]
						if neighbour and neighbour[ny] and not seen[key(nx, ny)] then
							seen[key(nx, ny)] = true
							stack[#stack + 1] = { nx, ny }
						end
					end
				end
				patches[#patches + 1] = patch
			end
		end
	end
	return patches
end

local function measureReport()
	local results = {}
	for _, target in ipairs(measuring.targets) do
		local patches = measurePatches(target)
		results[#results + 1] = string.format("%s %d aimed=%.1f/%.1f: %d blip patch(es)",
			target.dbType, target.nodeID, target.ox, target.oy, #patches)

		for index, patch in ipairs(patches) do
			local cx = patch.sumX / patch.cells
			local cy = patch.sumY / patch.cells
			results[#results + 1] = string.format(
				"  patch %d: centre%+.1f/%+.1f px (%.0fyd off the database spot), "
				.. "spans %dx%dpx, %d cells",
				index, cx, cy, math.sqrt(cx * cx + cy * cy) / measuring.pixelsPerYard,
				patch.maxX - patch.minX + MEASURE_STEP,
				patch.maxY - patch.minY + MEASURE_STEP, patch.cells)
		end
		for _, row in ipairs(measureGrid(target)) do
			results[#results + 1] = row
		end
	end

	NodeRadarDB.blip = type(NodeRadarDB.blip) == "table" and not NodeRadarDB.blip.takenAt
		and NodeRadarDB.blip or {}
	table.insert(NodeRadarDB.blip, {
		takenAt = date("%Y-%m-%d %H:%M:%S"),
		zone = zoneID,
		automatic = measuring.automatic or false,
		pixelsPerYard = measuring.pixelsPerYard,
		span = MEASURE_SPAN,
		step = MEASURE_STEP,
		targets = results,
	})
	while #NodeRadarDB.blip > DIAG_KEPT do
		table.remove(NodeRadarDB.blip, 1)
	end

	-- an automatic run happens because something looked wrong, so it says so quietly
	-- rather than filling the chat with a grid per target
	if measuring.automatic then
		out(string.format("blip measurement stored (%d node(s)) - /nr debug keeps it",
			#measuring.targets))
	else
		for _, line in ipairs(results) do out(line) end
	end
end

local function measureSample(payload, text)
	local target = measuring.targets[payload.target]
	local hit = false
	if text then
		identifyAll(text, found)
		for _, entry in ipairs(found) do
			if entry.dbType == target.dbType and entry.nodeID == target.nodeID then
				hit = true
				break
			end
		end
	end
	target.grid[payload.x] = target.grid[payload.x] or {}
	target.grid[payload.x][payload.y] = hit
end

local function measureDone(completed)
	if completed then
		measureReport()
	elseif not measuring.automatic then
		warn("blip measurement dropped - stand still, keep the mouse off the minimap, retry")
	end
	measuring = nil
end

-- diagnostics: sizes the client's blip hit area, which every spacing constant in this
-- file assumes a value for. Runs on request, and by itself the first time a node looks
-- like it is being drawn twice - that is when the answer is worth having.
local function measureBlip(automatic)
	if Scanner:IsBusy() then
		if not automatic then warn("a scan is running - try again in a moment") end
		return
	end
	if not mapRadius or not playerX then
		if not automatic then warn("no position available - start the scan first") end
		return
	end
	buildClusters()

	-- An automatic run measures only the pair that looked doubled: every confirmed
	-- cluster in range would take several seconds of samples for no extra answer.
	local targets = {}
	for _, cluster in ipairs(clusters) do
		if cluster.confirmedKey and (not automatic or suspect[cluster.confirmedKey]) then
			local node = nodes[cluster.confirmedKey]
			targets[#targets + 1] = { ox = cluster.ox, oy = cluster.oy,
				dbType = node.dbType, nodeID = node.nodeID, grid = {} }
		end
	end
	if #targets == 0 then
		if not automatic then
			warn("no confirmed node to measure - let a scan confirm one first")
		end
		return
	end

	local points = {}
	for index, target in ipairs(targets) do
		for _, x in ipairs(MEASURE_AXIS) do
			for _, y in ipairs(MEASURE_AXIS) do
				points[#points + 1] = { ox = target.ox + x, oy = target.oy + y,
					payload = { target = index, x = x, y = y } }
			end
		end
	end

	measuring = { targets = targets, pixelsPerYard = pixelsPerYard, automatic = automatic }
	lastMeasure = scanClock
	out(string.format("measuring %d confirmed node(s)%s, %d samples - hold still",
		#targets, automatic and " after a node read twice" or "", #points))
	Scanner:Submit(points, measureSample, measureDone)
end

-- Two confirmed candidates of the same node id, close enough that one blip's hit area
-- could have answered for both: the signature of a single node drawn twice. Recorded
-- as it happens, because it does not last long enough to go and ask for - and the
-- first sighting asks for the measurement that settles it.
local suspect = {}

local function logDoubles()
	for keyA in pairs(hits) do
		local a = nodes[keyA]
		if a and a.ox then
			for keyB in pairs(hits) do
				local b = nodes[keyB]
				if b and b.ox and keyA < keyB
					and a.dbType == b.dbType and a.nodeID == b.nodeID then
					local dx, dy = a.ox - b.ox, a.oy - b.oy
					local px = math.sqrt(dx * dx + dy * dy)
					if px <= DOUBLE_PX then
						logDistinct(diag.doubles, string.format(
							"%s %d twice: %.1f/%.1f and %.1f/%.1f, %.1fpx (%.0fyd) apart",
							a.dbType, a.nodeID, a.ox, a.oy, b.ox, b.oy, px, px / pixelsPerYard))
						if scanClock - lastMeasure >= MEASURE_COOLDOWN then
							if not measureRequested then wipe(suspect) end
							measureRequested = true
							suspect[keyA], suspect[keyB] = true, true
						end
					end
				end
			end
		end
	end
end

-- cheap enough to ask every tick, and it keeps buildClusters off the tick entirely
-- while nothing has changed
local function anyDue()
	for key, node in pairs(nodes) do
		local dx, dy = playerX - node.wx, playerY - node.wy
		if candidateDue(key, math.sqrt(dx * dx + dy * dy)) then return true end
	end
end

-- measured from the end of a pass, so a long pass does not eat its own quiet time
local function passDone()
	lastPass = scanClock
end

local function queueScan()
	if scanClock - lastPass < PASS_COOLDOWN then return end
	if not anyDue() then return end
	buildClusters()
	logDoubles()

	local pending = {}
	for index, cluster in ipairs(clusters) do
		if not cluster.due then
			-- nothing can have changed for this one yet
		elseif cluster.confirmedKey then
			pending[#pending + 1] = { ox = cluster.ox, oy = cluster.oy, order = cluster.order,
				recheck = true, payload = { cluster = index, ring = "center" } }
		else
			for _, probe in ipairs(PROBE) do
				pending[#pending + 1] = { ox = cluster.ox + probe[1], oy = cluster.oy + probe[2],
					order = cluster.order, payload = { cluster = index, ring = probe[3] } }
			end
		end
	end

	-- Rechecks come first: a node already on the radar disappears from it if its
	-- recheck is crowded out, while a spot that read empty can wait another tick.
	-- Within each group the longest unasked goes first, so nothing starves.
	table.sort(pending, function(a, b)
		if a.recheck ~= b.recheck then return a.recheck == true end
		return a.order < b.order
	end)
	for index = #pending, BURST + 1, -1 do
		pending[index] = nil
	end

	-- recorded before the pass runs, so the next tick does not queue the same cluster
	-- again while its samples are still being read
	for _, point in ipairs(pending) do
		for _, key in ipairs(clusters[point.payload.cluster].members) do
			local seen = probed[key]
			if seen then
				seen.at, seen.distance = scanClock, nodes[key].distance
				seen.count = seen.count + 1
			else
				probed[key] = { at = scanClock, distance = nodes[key].distance, count = 1 }
			end
		end
	end

	if db.debugLog then
		local confirmed = 0
		for _, cluster in ipairs(clusters) do
			if cluster.confirmedKey then confirmed = confirmed + 1 end
		end
		stamped(string.format("scan: %d clusters (%d confirmed), %d samples queued, %d shown",
			#clusters, confirmed, #pending, shownCount))
	end

	Scanner:Submit(pending, scanSample, passDone)
end

-- Entries are a pool, not fresh tables: at 60 frames a second one table per shown
-- node is the addon's largest source of garbage. Radar:Render is told the count, so
-- the slots past it simply stay untouched.
local function render()
	local facing = GetPlayerFacing()
	if not facing then return end

	local ttl = db.recheckSeconds + 2
	local count = 0
	for key, hit in pairs(hits) do
		if not hit.test and scanClock - hit.seenAt > ttl then
			hits[key] = nil
		else
			local xDist, yDist = playerX - hit.wx, playerY - hit.wy
			local distance = math.sqrt(xDist * xDist + yDist * yDist)
			if distance <= scanRange and distance >= MIN_DISTANCE then
				local rx, ry = rotate(xDist, yDist, facing)
				count = count + 1
				local entry = entries[count]
				if not entry then
					entry = {}
					entries[count] = entry
				end
				entry.key, entry.rx, entry.ry = key, rx / scanRange, -ry / scanRange
				entry.distance, entry.texture = distance, hit.texture
				entry.tooLow, entry.appearedAt = hit.tooLow, hit.appearedAt
			end
		end
	end
	shownCount = count
	Radar:Render(entries, count)
end

-- One source for why nothing is being scanned, asked in the order that matters: a
-- type the client does not draw can never be confirmed, a spot with no spawn point
-- nearby has nothing to aim at, and only then does it matter whether looking is
-- possible at all. The second return says whether the hit clock stops - it does while
-- looking is impossible, so confirmed nodes outlive the wait, but not while there is
-- nothing in range, where no hit is left to expire.
local function holdReason()
	if measuring then
		-- the pass belongs to the measurement, so confirmed nodes must outlive it
		return "measuring the blip hit area", true
	end
	if not next(tracked) then
		return NO_TRACKING, false
	end
	if not next(nodes) then
		return "no node in range", false
	end
	local isBlocked, reason = Scanner:IsBlocked()
	if isBlocked then return reason, true end
end

local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(_, elapsed)
	playerX, playerY = HBD:GetPlayerWorldPosition()
	if not playerX then
		wipe(hits)
		Radar:Render(EMPTY, 0)
		return
	end

	-- The candidate list, the reason scanning is on hold and which candidates are due
	-- all change far slower than a frame, so they share this tick: asking the client
	-- for them sixty times a second is what made an idle radar cost anything at all.
	sinceRebuild = sinceRebuild + elapsed
	if sinceRebuild >= REBUILD_INTERVAL then
		sinceRebuild = 0
		if not refreshGeometry() then
			wipe(hits)
			Radar:Render(EMPTY, 0)
			return
		end
		rebuildCandidates()

		local reason, freeze = holdReason()
		if reason ~= pauseReason then
			if reason == NO_TRACKING then
				warn("no gathering tracking is active - turn on Find Minerals or Find "
					.. "Herbs, otherwise the client draws no blips and nothing can be confirmed")
			elseif pauseReason == NO_TRACKING then
				out("gathering tracking is active again")
			end
			if db.debugLog then
				stamped(reason and ("scanning paused: " .. reason) or "scanning resumed")
			end
		end
		pauseReason, clockFrozen = reason, freeze

		-- Asked on the tick, not on an interval: a pass carries only the candidates
		-- something can have changed for, so a spot already read stays unasked and a
		-- new one is aimed at within a quarter second rather than at the next interval.
		if not reason and not Scanner:IsBusy() then
			if measureRequested then
				measureRequested = false
				measureBlip(true)
			else
				queueScan()
			end
		end
	end
	if not mapRadius then return end

	-- per frame, so the clock the cooldowns and the hit TTL run on keeps real time
	if not clockFrozen then
		scanClock = scanClock + elapsed
	end

	-- nothing to draw and nothing coming: the display is already empty
	if pauseReason and not next(hits) then return end
	render()
end)

-- test nodes are ordinary hits that never expire, so every step of the display -
-- world position, rotation, distance, skill colour - is exercised
function NR.SetTestNodes(enabled)
	for key, hit in pairs(hits) do
		if hit.test then hits[key] = nil end
	end
	if not enabled then return end

	local px, py = HBD:GetPlayerWorldPosition()
	if not px then
		warn("no world position available, test nodes not placed")
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
	wipe(probed)
	Radar:SetShown(false)
	NR.Options:Refresh()
end

function NR.Start()
	running = true
	-- no reason yet, so the first tick reports whatever it finds - including a missing
	-- tracking ability, the one hold the user has to hear about
	pauseReason, clockFrozen = nil, false
	sinceRebuild = REBUILD_INTERVAL
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
	-- scanInterval paced every pass; the same number now paces the recheck of a node
	-- already found, which is the only thing still on a clock
	if NodeRadarDB.scanInterval ~= nil then
		NodeRadarDB.recheckSeconds = NodeRadarDB.scanInterval
		NodeRadarDB.scanInterval = nil
	end
	-- Snapshots from an older format read as the current one but mean different
	-- things, so they are dropped rather than mixed into a fresh set of readings.
	if NodeRadarDB.debugFormat ~= DIAG_FORMAT then
		NodeRadarDB.debugFormat = DIAG_FORMAT
		NodeRadarDB.debug, NodeRadarDB.blip = nil, nil
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
		warn("no SetMouseClickEnabled - falling back to muting the click handlers")
	end
	if not Scanner.canHideBlips then
		warn("no SetBlipTexture - blips stay visible during the scan")
	end
	if not Scanner.canHideArrow then
		warn("no SetPlayerTexture - the player arrow stays visible during the scan")
	end
	if not Scanner.canHideClassBlips then
		warn("no SetClassBlipTexture - party blips stay visible during the scan")
	end
	return true
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("SKILL_LINES_CHANGED")
loader:SetScript("OnEvent", function(_, event)
	if event == "SKILL_LINES_CHANGED" then
		if initialized then refreshSkills() end
		return
	end
	if initialize() and db.autoStart then NR.Start() end
end)

-- Diagnostics for what stays visible while the minimap is hidden. Blizzard draws its
-- blips outside the frame hierarchy, so each kind needs its own texture swapped; an
-- addon pin is a child frame instead, and one that ignores parent alpha survives the
-- hide as well.
local MINIMAP_TEXTURE_CALLS = {
	"SetBlipTexture", "SetClassBlipTexture", "SetPlayerTexture",
	"SetPOIArrowTexture", "SetStaticPOIArrowTexture", "SetCorpsePOIArrowTexture",
	"SetIconTexture", "UpdateBlips",
	"GetBlipTexture", "GetClassBlipTexture", "GetPlayerTexture",
	"GetPOIArrowTexture", "GetStaticPOIArrowTexture", "GetCorpsePOIArrowTexture",
}

local function reportMinimap()
	local available, missing = {}, {}
	for _, name in ipairs(MINIMAP_TEXTURE_CALLS) do
		if type(Minimap[name]) == "function" then
			local shown = name
			if name:find("^Get") then
				local ok, value = pcall(Minimap[name], Minimap)
				shown = name .. "=" .. (ok and tostring(value) or "error")
			end
			available[#available + 1] = shown
		else
			missing[#missing + 1] = name
		end
	end

	local children = {}
	for _, child in ipairs({ Minimap:GetChildren() }) do
		if child:IsShown() then
			local flags = ""
			if child.IsMouseEnabled and child:IsMouseEnabled() then flags = flags .. " mouse" end
			if child.IsIgnoringParentAlpha and child:IsIgnoringParentAlpha() then
				flags = flags .. " ignoresParentAlpha"
			end
			children[#children + 1] = ((child.GetName and child:GetName()) or "unnamed")
				.. flags
		end
	end

	NodeRadarDB.minimap = {
		takenAt = date("%Y-%m-%d %H:%M:%S"),
		available = available,
		missing = missing,
		shownChildren = children,
	}
	out("minimap: " .. #available .. " calls available, " .. #missing .. " missing, "
		.. #children .. " visible child frames - stored for /nr debug")
	for _, name in ipairs(missing) do out("  missing: " .. name) end
	for _, entry in ipairs(children) do out("  child: " .. entry) end
end

-- The snapshot is built as text, which is what both consumers want: the window hands
-- it to the clipboard, and the saved copy is read as text too.
local function append(lines, format, ...)
	lines[#lines + 1] = select("#", ...) > 0 and string.format(format, ...) or format
end

local function appendList(lines, title, list)
	if #list == 0 then return end
	append(lines, "")
	append(lines, "%s (%d):", title, #list)
	for _, entry in ipairs(list) do
		append(lines, "  %s", entry)
	end
end

local function countedList(map)
	local parts = {}
	for name, count in pairs(map) do
		parts[#parts + 1] = string.format("%s=%d", name, count)
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, " ") or "none"
end

local function snapshotLines()
	local lines = {}
	append(lines, "NodeRadar %s snapshot %s", NR.version or "", date("%Y-%m-%d %H:%M:%S"))
	append(lines, "zone=%s radius=%.1f range=%s px/yd=%.3f rotate=%s",
		tostring(zoneID), mapRadius or 0, tostring(scanRange), pixelsPerYard or 0,
		tostring(rotateMinimap))
	append(lines, "onHold=%s  recheck=%.1fs  missCooldown=%ds approach=%dyd pass=%ds",
		pauseReason or "no", db.recheckSeconds, MISS_COOLDOWN, APPROACH_YARDS, PASS_COOLDOWN)
	append(lines, "spacing: cluster=%dpx match=%dpx probe=%dpx",
		CLUSTER_PX, MATCH_PX, PROBE[2][1])
	append(lines, "skill: mining=%s herbalism=%s",
		tostring(skillRank["Mining"]), tostring(skillRank["Herb Gathering"]))
	append(lines, "tracking: known=%s mining=%s herbalism=%s",
		tostring(trackingKnown), tostring(tracked["Mining"] or false),
		tostring(tracked["Herb Gathering"] or false))
	append(lines, "samples=%d tooltips=%d matched=%d", diag.samples, diag.tooltips, diag.matched)
	append(lines, "rings: %s", countedList(diag.ringHits))
	append(lines, "tooltips taken by other frames: %s", countedList(diag.stolen))

	local shown = {}
	for key, hit in pairs(hits) do
		local dx, dy = playerX - hit.wx, playerY - hit.wy
		shown[#shown + 1] = string.format("%s d=%.1fyd wx=%.1f wy=%.1f",
			key, math.sqrt(dx * dx + dy * dy), hit.wx, hit.wy)
	end
	table.sort(shown)
	appendList(lines, "on the radar", shown)

	local candidates, facing = {}, GetPlayerFacing()
	for key, node in pairs(nodes) do
		local dx, dy = playerX - node.wx, playerY - node.wy
		local ox, oy = minimapOffset(dx, dy, facing)
		local seen = probed[key]
		local rings = seen and seen.rings and countedList(seen.rings) or "-"
		candidates[#candidates + 1] = string.format(
			"%s %d d=%.0fyd off=%.1f/%.1f probes=%d %s rings=%s",
			node.dbType, node.nodeID, math.sqrt(dx * dx + dy * dy), ox or 0, oy or 0,
			seen and seen.count or 0, hits[key] and "CONFIRMED" or "missing", rings)
	end
	table.sort(candidates)
	appendList(lines, "candidates", candidates)

	local sizes = {}
	for index, cluster in ipairs(clusters) do
		sizes[index] = string.format("%d%s", #cluster.members,
			cluster.confirmedKey and "c" or "")
	end
	if #sizes > 0 then
		append(lines, "")
		append(lines, "clusters (member count, c = confirmed): %s", table.concat(sizes, " "))
	end

	appendList(lines, "drawn twice", diag.doubles.list)
	appendList(lines, "tooltips nothing could claim", diag.unclaimed.list)
	appendList(lines, "confirmations", diag.confirmations.list)
	appendList(lines, "distinct tooltips seen", diag.log.list)

	if type(NodeRadarDB.blip) == "table" then
		for _, run in ipairs(NodeRadarDB.blip) do
			append(lines, "")
			append(lines, "blip measurement %s zone=%s%s step=%dpx span=%dpx",
				run.takenAt, tostring(run.zone), run.automatic and " (automatic)" or "",
				run.step or 1, run.span or 0)
			for _, entry in ipairs(run.targets) do
				append(lines, "  %s", entry)
			end
		end
	end

	if type(NodeRadarDB.minimap) == "table" then
		local report = NodeRadarDB.minimap
		append(lines, "")
		append(lines, "minimap probe %s", report.takenAt)
		append(lines, "  available: %s", table.concat(report.available, " "))
		append(lines, "  missing: %s",
			#report.missing > 0 and table.concat(report.missing, " ") or "none")
		for _, child in ipairs(report.shownChildren) do
			append(lines, "  child: %s", child)
		end
	end

	return lines
end

local function writeDiagnostics()
	if not playerX or not mapRadius then
		warn("no position yet - start the scan and let a pass run first")
		return
	end

	local lines = snapshotLines()

	NodeRadarDB.debug = type(NodeRadarDB.debug) == "table" and NodeRadarDB.debug or {}
	table.insert(NodeRadarDB.debug, lines)
	while #NodeRadarDB.debug > DIAG_KEPT do
		table.remove(NodeRadarDB.debug, 1)
	end

	NR.Dump:Show(table.concat(lines, "\n"),
		string.format("NodeRadar diagnostics - snapshot %d", #NodeRadarDB.debug))
end

SLASH_NODERADAR1 = "/nr"
SLASH_NODERADAR2 = "/noderadar"
SlashCmdList["NODERADAR"] = function(msg)
	if not initialize() then return end

	local cmd = string.lower(strtrim(msg or ""))
	if cmd == "debug" then
		writeDiagnostics()
		return
	elseif cmd == "clear" then
		NodeRadarDB.debug, NodeRadarDB.blip = nil, nil
		wipe(diag.ringHits)
		wipe(diag.stolen)
		for _, log in ipairs({ diag.log, diag.confirmations, diag.doubles, diag.unclaimed }) do
			wipe(log.list)
			wipe(log.seen)
		end
		diag.samples, diag.tooltips, diag.matched = 0, 0, 0
		out("diagnostics cleared")
		return
	elseif cmd == "blip" then
		measureBlip()
		return
	elseif cmd == "minimap" then
		reportMinimap()
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
