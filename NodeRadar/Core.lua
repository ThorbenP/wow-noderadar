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
-- The client draws a node's blip at its own pace - sometimes the moment it comes into
-- range, sometimes seconds later, and nothing announces it. A candidate new to the
-- range is therefore looked at at once and keeps priority over everything else for
-- this long, which at one pass every PASS_COOLDOWN seconds is three or four looks.
-- After that it joins the ordinary queue, longest-unasked first.
local NEW_CANDIDATE_WINDOW = 10
-- Measured span of a blip's hit area. Two sample points closer than this that both
-- name the same node are looking at one blip: measured at 4-5px across, and observed
-- answering two points 5.6px apart, so it is not smaller than this.
local BLIP_PX = 6
-- Two confirmed nodes no further apart than this are recorded as a suspected pair.
-- Measured hit areas are a few pixels across, so anything at this range is either one
-- blip claimed twice or a misattributed tooltip; wider than this and genuine
-- neighbouring nodes would drown the log.
local DOUBLE_PX = 20
-- Quiet between passes, and the only throttle on how often a spot is asked about.
-- What a pass can carry is capped by BURST, and the longest-unasked cluster goes
-- first, so the rate per spot falls by itself as more candidates compete: two
-- clusters get every pass, fifty share them round-robin.
local PASS_COOLDOWN = 3
-- Bumped whenever the shape or meaning of what /nr debug records changes, which
-- discards the stored snapshots: comparing readings across formats misleads.
local DIAG_FORMAT = 3
-- how many snapshots and blip measurements are kept
local DIAG_KEPT = 6
-- Two nodes can share almost the same spot, and one blip covers that distance.
-- Candidates this close therefore share a single sample point, and the tooltip's lines
-- say which of them are actually there. Anything smaller than the hit area splits them
-- into clusters that one blip then answers separately, drawing that node twice.
local CLUSTER_PX = BLIP_PX
-- A database coordinate can sit well off the blip it describes, so a confirmation is
-- attributed to the candidate of that exact node id nearest the sample point, within
-- this radius, rather than only to the cluster being probed.
local MATCH_PX = 8
-- The hit clock stops while scanning is impossible, so a confirmation survives a
-- camera turn instead of expiring unseen. Held long enough that stops being a
-- kindness: a node gathered two minutes ago is gone whether or not anyone could
-- check, so a confirmation expires on the wall clock too.
local STALE_SECONDS = 30
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
local indoors, lastZoom = "outdoor", nil
local rotateMinimap, scanRange
local sinceRebuild = 0
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

-- The client keeps two zoom settings, one for outdoors and one for inside, and a cave
-- is 300 yards across where open ground is 466 - a third of the scale. Which setting
-- is active shows only in comparing the current zoom against both CVars, and when they
-- hold the same value, which is the default, that comparison always reads "outdoor".
-- Nudging the zoom makes the client write the active one; GatherMate does the same.
-- It is visible for a frame, so it runs on zoom changes rather than on every tick -
-- and entering or leaving a cave is a zoom change.
local function refreshIndoors()
	local zoom = Minimap:GetZoom()
	if GetCVar("minimapZoom") == GetCVar("minimapInsideZoom") then
		Minimap:SetZoom(zoom < 2 and zoom + 1 or zoom - 1)
	end
	indoors = GetCVar("minimapZoom") + 0 == Minimap:GetZoom() and "outdoor" or "indoor"
	Minimap:SetZoom(zoom)
	lastZoom = zoom
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
	if zoom ~= lastZoom then refreshIndoors() end
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
						nodes[key] = { dbType = dbType, nodeID = nodeID, wx = wx, wy = wy,
							inRangeSince = scanClock }
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
	probeRejected = 0,
	log = { list = {}, seen = {}, keys = {} },
	confirmations = { list = {}, seen = {}, keys = {} },
	doubles = { list = {}, seen = {}, keys = {} },
	unclaimed = { list = {}, seen = {}, keys = {} } }

-- Distinct entries only, newest kept: one node hit fifty times would otherwise crowd
-- out every other blip the scan saw. Membership is a lookup rather than a walk of the
-- list, because this runs per sample.
local LOG_CAP = 40

local function logDistinct(log, entry, dedupeKey)
	dedupeKey = dedupeKey or entry
	if log.seen[dedupeKey] then return end
	log.seen[dedupeKey] = true

	local list = log.list
	list[#list + 1] = entry
	log.keys[#log.keys + 1] = dedupeKey
	if #list > LOG_CAP then
		log.seen[log.keys[1]] = nil
		table.remove(log.keys, 1)
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
local function logConfirm(key, ring, ox, oy, node, closest, ownCluster)
	local distance = closest and string.format("%.1fpx", math.sqrt(closest)) or "sole member"
	local origin = ownCluster and "own" or "other"
	logDistinct(diag.confirmations,
		string.format("[%.0fs] %s ring=%s cluster=%s sample=%.1f/%.1f node=%.1f/%.1f d=%s",
			scanClock, key, tostring(ring), origin, ox, oy, node.ox, node.oy, distance),
		key .. ring .. origin .. distance)
end

local found, taken = {}, {}
-- where each node id has already been found during the current pass
local claimed = {}

-- squared distance from the sample point if this candidate could be what the tooltip
-- named, nil when it could not
local function candidateFit(key, entry, ox, oy)
	local node = nodes[key]
	if not node or not node.ox or taken[key] then return end
	if node.dbType ~= entry.dbType or node.nodeID ~= entry.nodeID then return end

	local dx, dy = node.ox - ox, node.oy - oy
	local distance = dx * dx + dy * dy
	if distance <= MATCH_PX * MATCH_PX then return distance end
end

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

	-- A probe sits five pixels off its own cluster, which in a crowded spot puts it
	-- closer to a neighbouring one. The blip it found then belongs to that neighbour,
	-- and crediting it here would place a node where none was seen. The neighbour gets
	-- a sample of its own, so nothing is lost by staying out of it.
	if payload.ring ~= "center" then
		local dx, dy = cluster.ox - ox, cluster.oy - oy
		local own = dx * dx + dy * dy
		for index, other in ipairs(clusters) do
			if index ~= payload.cluster then
				local ex, ey = other.ox - ox, other.oy - oy
				if ex * ex + ey * ey < own then
					diag.probeRejected = diag.probeRejected + 1
					return
				end
			end
		end
	end

	-- one sample can prove several nodes at once, so each node named in the tooltip
	-- claims the candidate it belongs to
	wipe(taken)
	for _, entry in ipairs(found) do
		local chosen, closest, ownCluster

		-- One blip answers every sample point inside its hit area, and each of those
		-- points would otherwise credit the candidate nearest itself - drawing one node
		-- as several. A second sighting of the same id from within that distance is the
		-- same blip, so it is recorded and skipped.
		local sameBlip = false
		for _, claim in ipairs(claimed[entry.dbType .. entry.nodeID] or EMPTY) do
			local dx, dy = claim.ox - ox, claim.oy - oy
			if dx * dx + dy * dy <= BLIP_PX * BLIP_PX then
				logDistinct(diag.doubles, string.format(
					"[%.0fs] one blip, two samples: %s %d at %.1f/%.1f and %.1f/%.1f, "
					.. "%.1fpx apart - second ignored",
					scanClock, entry.dbType, entry.nodeID, claim.ox, claim.oy, ox, oy,
					math.sqrt(dx * dx + dy * dy)),
					entry.dbType .. entry.nodeID .. "pair")
				sameBlip = true
				break
			end
		end

		-- A blip already attributed to a candidate stays with it. Which candidate is
		-- nearest shifts as the player moves, so with two candidates of one id in a
		-- cluster the credit would alternate between them, and both hits would be alive
		-- at once - one node, two icons.
		if not sameBlip then
			for _, key in ipairs(cluster.members) do
				if hits[key] then
					local distance = candidateFit(key, entry, ox, oy)
					if distance and (not closest or distance < closest) then
						chosen, closest, ownCluster = key, distance, true
					end
				end
			end
		end

		-- Only the cluster this sample was aimed at may claim the find. Searching every
		-- candidate instead put a blip on whichever one happened to be nearest, across
		-- cluster boundaries and up to MATCH_PX away - wider than a blip's hit area, so
		-- it was guesswork. A blip that truly belongs to another cluster is found by
		-- that cluster's own sample; every unconfirmed cluster gets one in turn.
		if not sameBlip and not chosen then
			for _, key in ipairs(cluster.members) do
				local distance = candidateFit(key, entry, ox, oy)
				if distance and (not closest or distance < closest) then
					chosen, closest, ownCluster = key, distance, true
				end
			end
		end

		-- Nothing of that id nearby, yet the sample proves a node is here: the aimed-at
		-- cluster takes it, nearest free member first. That is how a spot the database
		-- calls copper gets shown as the tin that spawned there.
		-- A probe sits five pixels off and, in a crowded cluster, guessing from one
		-- invents a node where nothing was seen - and the guess sticks, because it
		-- rewrites the candidate's id for every later pass. So a probe may only do this
		-- where there is nothing to guess: a cluster holding a single candidate. The
		-- centre sample is aimed at the cluster itself and may always. Either way it
		-- stands down once this pass has already placed that id somewhere.
		if not sameBlip and not chosen
			and (payload.ring == "center" or #cluster.members == 1)
			and not claimed[entry.dbType .. entry.nodeID] then
			local best
			for _, key in ipairs(cluster.members) do
				local node = nodes[key]
				if node and node.ox and not taken[key] then
					local dx, dy = node.ox - ox, node.oy - oy
					local distance = dx * dx + dy * dy
					if not best or distance < best then
						chosen, best, ownCluster = key, distance, true
					end
				end
			end
		end

		if sameBlip then
			-- one blip cannot prove two nodes
		elseif not chosen then
			-- The tooltip proves a node is there, yet no candidate fits its id and the
			-- cluster is too ambiguous to hand it to. Worth seeing: it is a node the
			-- radar cannot show at all.
			logDistinct(diag.unclaimed, string.format(
				"[%.0fs] %s %d named at %.1f/%.1f via %s, %.0fyd out, claimed by nothing "
				.. "(cluster of %d)",
				scanClock, entry.dbType, entry.nodeID, ox, oy, payload.ring,
				math.sqrt(ox * ox + oy * oy) / pixelsPerYard, #cluster.members),
				entry.dbType .. entry.nodeID .. string.format("%.0f/%.0f", ox, oy))
		else
			taken[chosen] = true
			local claimKey = entry.dbType .. entry.nodeID
			claimed[claimKey] = claimed[claimKey] or {}
			table.insert(claimed[claimKey], { ox = ox, oy = oy })

			local node = nodes[chosen]
			logConfirm(chosen, payload.ring, ox, oy, node, closest, ownCluster)

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
				confirmedAt = GetTime(),
				dbType = entry.dbType, nodeID = entry.nodeID,
				-- how this one was earned: the pair detector reports it without needing
				-- the live state, which is gone by the time anyone asks
				viaRing = payload.ring, viaOx = ox, viaOy = oy,
				viaDistance = closest and math.sqrt(closest) or nil,
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
	-- A confirmed node only needs watching often enough to notice it being gathered.
	-- An empty spot is asked again whenever there is capacity: a node can appear there
	-- at any moment, and holding one back buys nothing the pass cooldown does not.
	local seen = probed[key]
	if not seen then return true end
	if hits[key] then
		return scanClock - seen.at >= db.recheckSeconds
	end
	return true
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
			-- fresh in range goes ahead of the queue: scanClock only grows, so any
			-- negative order wins, and the newest of the fresh ones wins among them
			local order = seen and seen.at or -1
			local age = scanClock - node.inRangeSince
			if age < NEW_CANDIDATE_WINDOW then
				order = age - NEW_CANDIDATE_WINDOW - 1
			end
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
-- Reading a raster of sample points is how the blips that actually exist are found,
-- rather than assumed from the database. These two turn such a raster into something
-- readable: a picture of it, and the separate patches of hits within it.
local function gridAxis(span, step)
	local steps = {}
	for offset = -span, span, step do
		steps[#steps + 1] = offset
	end
	return steps
end

-- One picture per target: rows run north to south, columns west to east. A cell on
-- the axis origin is marked, so the reading can be placed.
local function measureGrid(target, axis)
	local rows = {}
	for row = #axis, 1, -1 do
		local marks = {}
		for column = 1, #axis do
			local cell = target.grid[axis[column]]
			if cell and cell[axis[row]] then
				marks[#marks + 1] = "#"
			elseif axis[row] == 0 and axis[column] == 0 then
				marks[#marks + 1] = "+"
			else
				marks[#marks + 1] = "."
			end
		end
		rows[#rows + 1] = "  " .. table.concat(marks)
	end
	return rows
end

-- Separate patches of hits are separate blips, so they are reported separately: one
-- patch offset from the aimed point is a database coordinate that is simply wrong,
-- while two patches mean a second node of the same kind is nearby.
local function measurePatches(target, axis, step)
	local seen, patches = {}, {}
	local function key(x, y) return x .. ":" .. y end

	for _, x in ipairs(axis) do
		for _, y in ipairs(axis) do
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
					for _, direction in ipairs({ { step, 0 }, { -step, 0 },
						{ 0, step }, { 0, -step } }) do
						local nx, ny = cx + direction[1], cy + direction[2]
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

-- Every candidate the database offers can be aimed at and answer nothing, which says
-- either that no node is there or that the coordinate is wrong - and the difference
-- decides whether this addon can work at all. A raster over the whole scan range
-- answers it without consulting the database: it finds the blips that actually exist,
-- and only then are they matched against what GatherMate expects.
local SWEEP_SPAN = 30
local SWEEP_STEP = 4
-- The offset between where a sample is aimed and where the blip answers is the open
-- question, and its relation to the step size decides what it is: unchanged means a
-- fixed offset that can be subtracted, growing with the step means the blip trails
-- the minimap and no correction is constant.
local sweepStep = SWEEP_STEP
-- how far the player may drift before the reading is no longer of one moment, in yards
local SWEEP_MAX_DRIFT = 3
local lastSweepRowMajor = false
local sweeping
local SWEEP_AXIS = gridAxis(SWEEP_SPAN, SWEEP_STEP)

local function sweepSample(payload, text, ox, oy)
	-- The raster is walked column by column over four seconds, so moving during it
	-- drags the blip across columns and the patch comes out wide and flat - a
	-- measurement of the walk, not of the blip.
	local dx, dy = playerX - sweeping.originX, playerY - sweeping.originY
	if dx * dx + dy * dy > SWEEP_MAX_DRIFT * SWEEP_MAX_DRIFT then
		sweeping.moved = true
		Scanner:Abort()
		return
	end
	-- Where the sample actually landed against where it was aimed. The scanner moves
	-- the minimap under a cursor it does not control, so any constant difference here
	-- is a calibration error in this addon, not a property of the blips.
	sweeping.aimX = sweeping.aimX + (ox - payload.x)
	sweeping.aimY = sweeping.aimY + (oy - payload.y)
	sweeping.aimed = sweeping.aimed + 1
	sweeping.placeError = math.max(sweeping.placeError, Scanner.lastPlaceError or 0)

	if not text then return end

	identifyAll(text, found)
	for _, entry in ipairs(found) do
		local id = entry.dbType .. " " .. entry.nodeID
		local seen = sweeping.blips[id]
		if not seen then
			seen = { dbType = entry.dbType, nodeID = entry.nodeID, grid = {} }
			sweeping.blips[id] = seen
			sweeping.order[#sweeping.order + 1] = id
		end
		seen.grid[payload.x] = seen.grid[payload.x] or {}
		seen.grid[payload.x][payload.y] = true
	end
end

-- the candidate the database would have offered for a blip found at this spot
local function nearestCandidate(ox, oy, dbType, nodeID)
	local bestKey, bestDistance, bestSameId
	for key, node in pairs(nodes) do
		if node.ox and node.dbType == dbType then
			local dx, dy = node.ox - ox, node.oy - oy
			local distance = math.sqrt(dx * dx + dy * dy)
			local sameId = node.nodeID == nodeID
			-- a candidate of the right sort outranks a closer one of the wrong sort
			if not bestKey or (sameId and not bestSameId)
				or (sameId == bestSameId and distance < bestDistance) then
				bestKey, bestDistance, bestSameId = key, distance, sameId
			end
		end
	end
	return bestKey, bestDistance, bestSameId
end

local function sweepReport()
	local lines = {}
	local inRange = 0
	for _ in pairs(nodes) do inRange = inRange + 1 end

	lines[#lines + 1] = string.format(
		"sweep %s zone=%s step=%dpx span=%dpx px/yd=%.3f %s, %d candidates in range, "
		.. "visited %s",
		date("%Y-%m-%d %H:%M:%S"), tostring(zoneID), sweepStep, SWEEP_SPAN,
		pixelsPerYard, indoors, inRange,
		sweeping.rowMajor and "row by row" or "column by column")
	lines[#lines + 1] = string.format(
		"  aim error: %.2f/%.2f px average over %d samples, worst minimap placement "
		.. "error %.2f px",
		sweeping.aimX / math.max(sweeping.aimed, 1),
		sweeping.aimY / math.max(sweeping.aimed, 1), sweeping.aimed, sweeping.placeError)

	local total = 0
	for _, id in ipairs(sweeping.order) do
		local blip = sweeping.blips[id]
		for _, patch in ipairs(measurePatches(blip, SWEEP_AXIS, sweepStep)) do
			total = total + 1
			local cx, cy = patch.sumX / patch.cells, patch.sumY / patch.cells
			local key, distance, sameId = nearestCandidate(cx, cy, blip.dbType, blip.nodeID)
			lines[#lines + 1] = string.format(
				"  %s at %.1f/%.1f (%.0fyd out), spans %dx%dpx over %d cells -> %s",
				id, cx, cy, math.sqrt(cx * cx + cy * cy) / pixelsPerYard,
				patch.maxX - patch.minX + sweepStep, patch.maxY - patch.minY + sweepStep,
				patch.cells,
				key and string.format("%s%s %.1fpx (%.0fyd) away", key,
					sameId and "" or " [different id]", distance, distance / pixelsPerYard)
					or "no candidate of that type in range")
		end

		-- the raster itself: the figures above cannot say which points answered, and
		-- that is what decides whether a patch is one blip or several in a row
		lines[#lines + 1] = string.format("  raster for %s (%d columns, %dpx apart):",
			id, #SWEEP_AXIS, sweepStep)
		for _, row in ipairs(measureGrid(blip, SWEEP_AXIS)) do
			lines[#lines + 1] = row
		end
	end

	lines[#lines + 1] = string.format("  %d blip patch(es) found", total)

	-- kept as a history: two runs are compared against each other, and overwriting the
	-- first with the second loses exactly the comparison it was taken for
	NodeRadarDB.sweep = type(NodeRadarDB.sweep) == "table"
		and type(NodeRadarDB.sweep[1]) == "table" and NodeRadarDB.sweep or {}
	table.insert(NodeRadarDB.sweep, lines)
	while #NodeRadarDB.sweep > 4 do
		table.remove(NodeRadarDB.sweep, 1)
	end

	NR.Dump:Show(table.concat(lines, "\n"), "NodeRadar - sweep")
end

local function sweepDone(completed)
	if completed then
		sweepReport()
	elseif sweeping.moved then
		warn("sweep abandoned - you moved. It reads one moment across four seconds, so "
			.. "it has to be taken standing still")
	else
		warn("sweep dropped - keep the mouse off the minimap and retry")
	end
	sweeping = nil
end

-- diagnostics: finds every blip in range, then asks the database about each
local function sweepBlips(step)
	sweepStep = step or SWEEP_STEP
	SWEEP_AXIS = gridAxis(SWEEP_SPAN, sweepStep)
	if Scanner:IsBusy() then
		warn("a scan is running - try again in a moment")
		return
	end
	if not mapRadius or not playerX then
		warn("no position available - start the scan first")
		return
	end
	buildClusters()

	sweeping = { blips = {}, order = {}, originX = playerX, originY = playerY,
		aimX = 0, aimY = 0, aimed = 0, placeError = 0 }
	-- Row-major, then column-major on the next run: a patch that follows the order the
	-- points are visited rather than the position of the blip is an artefact of how
	-- fast the minimap is being moved, not a reading of anything.
	local points = {}
	sweeping.rowMajor = not lastSweepRowMajor
	lastSweepRowMajor = sweeping.rowMajor
	if sweeping.rowMajor then
		for _, y in ipairs(SWEEP_AXIS) do
			for _, x in ipairs(SWEEP_AXIS) do
				points[#points + 1] = { ox = x, oy = y, payload = { x = x, y = y } }
			end
		end
	else
		for _, x in ipairs(SWEEP_AXIS) do
			for _, y in ipairs(SWEEP_AXIS) do
				points[#points + 1] = { ox = x, oy = y, payload = { x = x, y = y } }
			end
		end
	end

	out(string.format("sweeping %d points across the scan range - do not move for about "
		.. "%d seconds", #points, math.ceil(#points / 60)))
	Scanner:Submit(points, sweepSample, sweepDone)
end

-- diagnostics: sizes the client's blip hit area, which every spacing constant in this
-- file assumes a value for. Runs on request, and by itself the first time a node looks
-- like it is being drawn twice - that is when the answer is worth having.
local function describeHit(key, hit)
	return string.format("%s (id %s via %s at %.1f/%.1f, d=%s, age %.0fs)",
		key, tostring(hit.nodeID), tostring(hit.viaRing), hit.viaOx or 0, hit.viaOy or 0,
		hit.viaDistance and string.format("%.1fpx", hit.viaDistance) or "sole member",
		scanClock - hit.seenAt)
end

-- Two confirmed nodes closer together than a blip's hit area cannot both have been
-- seen: one blip answered for both. Node ids are not compared - a misattributed
-- tooltip can leave the pair carrying different ones - and the distance comes from
-- world coordinates, so this holds regardless of when each was confirmed.
local function logDoubles()
	for keyA, a in pairs(hits) do
		for keyB, b in pairs(hits) do
			if keyA < keyB then
				local dx, dy = a.wx - b.wx, a.wy - b.wy
				local yards = math.sqrt(dx * dx + dy * dy)
				local px = yards * pixelsPerYard
				-- one tooltip naming two nodes at one sample point is two real nodes
				-- sharing a spot, not one blip counted twice
				local samePoint = a.viaOx == b.viaOx and a.viaOy == b.viaOy
				if px <= DOUBLE_PX and not samePoint then
					logDistinct(diag.doubles, string.format(
						"[%.0fs] %.1fpx (%.0fyd) apart: %s and %s",
						scanClock, px, yards, describeHit(keyA, a), describeHit(keyB, b)),
						keyA .. keyB)
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
	wipe(claimed)
	buildClusters()

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

	-- Measured: a sample lands true where the minimap barely moved since the last one,
	-- and up to eight pixels off where it jumped far. Priority above decides which
	-- points a pass carries; the order they are visited in is then chosen for short
	-- hops - nearest next, greedily - which costs nothing and keeps every jump small.
	for index = 1, #pending - 1 do
		local current = pending[index]
		local best, bestDistance = index + 1, nil
		for candidate = index + 1, #pending do
			local dx = pending[candidate].ox - current.ox
			local dy = pending[candidate].oy - current.oy
			local distance = dx * dx + dy * dy
			if not bestDistance or distance < bestDistance then
				best, bestDistance = candidate, distance
			end
		end
		pending[index + 1], pending[best] = pending[best], pending[index + 1]
	end

	-- recorded before the pass runs, so the next tick does not queue the same cluster
	-- again while its samples are still being read
	for _, point in ipairs(pending) do
		for _, key in ipairs(clusters[point.payload.cluster].members) do
			local seen = probed[key]
			if seen then
				seen.at, seen.count = scanClock, seen.count + 1
			else
				probed[key] = { at = scanClock, count = 1 }
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
	local now = GetTime()
	local count = 0
	for key, hit in pairs(hits) do
		if not hit.test and (scanClock - hit.seenAt > ttl
			or now - hit.confirmedAt > STALE_SECONDS) then
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
	if sweeping then
		-- the pass belongs to a diagnostic, so confirmed nodes must outlive it
		return "running a diagnostic sweep", true
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
		logDoubles()

		-- Asked on the tick, not on an interval: a pass carries only the candidates
		-- something can have changed for, so a spot already read stays unasked and a
		-- new one is aimed at within a quarter second rather than at the next interval.
		if not reason and not Scanner:IsBusy() then
			queueScan()
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
	-- nothing has changed the zoom yet, so the scale has to be established once
	refreshIndoors()
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
		NodeRadarDB.debug, NodeRadarDB.sweep, NodeRadarDB.blip = nil, nil, nil
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
	if Scanner.hideableTextureCount < 3 then
		warn("this client exposes only " .. Scanner.hideableTextureCount
			.. " minimap textures - some markers stay visible during the scan")
	end
	return true
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("SKILL_LINES_CHANGED")
loader:RegisterEvent("MINIMAP_UPDATE_ZOOM")
loader:SetScript("OnEvent", function(_, event)
	if event == "SKILL_LINES_CHANGED" then
		if initialized then refreshSkills() end
		return
	elseif event == "MINIMAP_UPDATE_ZOOM" then
		-- fires on entering and leaving a cave, where the scale changes without the
		-- zoom level moving
		if initialized then refreshIndoors() end
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

	-- Both trees: hiding the minimap reaches its own children, but a marker anchored
	-- to the cluster beside it is left standing, and telling them apart is the whole
	-- point of asking.
	local children = {}
	local function list(frame, origin)
		for _, child in ipairs({ frame:GetChildren() }) do
			if child:IsShown() then
				local flags = ""
				if child.IsMouseEnabled and child:IsMouseEnabled() then
					flags = flags .. " mouse"
				end
				if child.IsIgnoringParentAlpha and child:IsIgnoringParentAlpha() then
					flags = flags .. " ignoresParentAlpha"
				end
				children[#children + 1] = origin .. ": "
					.. ((child.GetName and child:GetName()) or "unnamed") .. flags
			end
		end
	end

	list(Minimap, "minimap")
	if MinimapCluster then list(MinimapCluster, "cluster") end

	local report = {
		takenAt = date("%Y-%m-%d %H:%M:%S"),
		available = available,
		missing = missing,
		shownChildren = children,
	}
	NodeRadarDB.minimap = report
	local lines = { string.format("NodeRadar minimap probe %s", report.takenAt) }
	lines[#lines + 1] = "available: " .. table.concat(available, " ")
	lines[#lines + 1] = "missing: "
		.. (#missing > 0 and table.concat(missing, " ") or "none")
	lines[#lines + 1] = ""
	lines[#lines + 1] = string.format("visible child frames (%d):", #children)
	for _, entry in ipairs(children) do
		lines[#lines + 1] = "  " .. entry
	end
	NR.Dump:Show(table.concat(lines, "\n"), "NodeRadar - minimap probe")
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
	append(lines, "zone=%s radius=%.1f range=%s px/yd=%.3f rotate=%s %s zoom=%d",
		tostring(zoneID), mapRadius or 0, tostring(scanRange), pixelsPerYard or 0,
		tostring(rotateMinimap), indoors, Minimap:GetZoom())
	append(lines, "onHold=%s recheck=%.1fs newWindow=%ds pass=%ds burst=%d textures=%d "
		.. "updateBlips=%s settle=%d",
		pauseReason or "no", db.recheckSeconds, NEW_CANDIDATE_WINDOW, PASS_COOLDOWN, BURST,
		Scanner.hideableTextureCount, tostring(Scanner.canUpdateBlips), Scanner.settleFrames)
	append(lines, "spacing: cluster=%dpx match=%dpx probe=%dpx",
		CLUSTER_PX, MATCH_PX, PROBE[2][1])
	append(lines, "skill: mining=%s herbalism=%s",
		tostring(skillRank["Mining"]), tostring(skillRank["Herb Gathering"]))
	append(lines, "tracking: known=%s mining=%s herbalism=%s",
		tostring(trackingKnown), tostring(tracked["Mining"] or false),
		tostring(tracked["Herb Gathering"] or false))
	append(lines, "samples=%d tooltips=%d matched=%d probeRejected=%d",
		diag.samples, diag.tooltips, diag.matched, diag.probeRejected)
	append(lines, "rings: %s", countedList(diag.ringHits))
	append(lines, "tooltips taken by other frames: %s", countedList(diag.stolen))

	local visible = Scanner.visibleDuringScan
	if visible and #visible > 0 then
		append(lines, "")
		append(lines, "still visible during the last pass (%d):", #visible)
		for _, entry in ipairs(visible) do
			append(lines, "  %s", entry)
		end
	elseif visible then
		append(lines, "still visible during the last pass: no frame - anything left on "
			.. "screen is drawn by the client outside the frame tree")
	end

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
			"%s id=%d d=%.0fyd off=%.1f/%.1f probes=%d last=%s %s rings=%s",
			key, node.nodeID, math.sqrt(dx * dx + dy * dy), ox or 0, oy or 0,
			seen and seen.count or 0,
			seen and string.format("%.0fs ago", scanClock - seen.at) or "never",
			hits[key] and "CONFIRMED" or "missing", rings)
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
		append(lines, "clusters as of the last pass (member count, c = confirmed): %s",
			table.concat(sizes, " "))
	end

	appendList(lines, "drawn twice", diag.doubles.list)
	appendList(lines, "tooltips nothing could claim", diag.unclaimed.list)
	appendList(lines, "confirmations", diag.confirmations.list)
	appendList(lines, "distinct tooltips seen", diag.log.list)

	if type(NodeRadarDB.sweep) == "table" then
		for _, run in ipairs(NodeRadarDB.sweep) do
			append(lines, "")
			for _, line in ipairs(run) do
				append(lines, "%s", line)
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
		NodeRadarDB.debug, NodeRadarDB.sweep = nil, nil
		wipe(diag.ringHits)
		wipe(diag.stolen)
		for _, log in ipairs({ diag.log, diag.confirmations, diag.doubles, diag.unclaimed }) do
			wipe(log.list)
			wipe(log.seen)
		end
		diag.samples, diag.tooltips, diag.matched = 0, 0, 0
		out("diagnostics cleared")
		return
	elseif cmd == "minimap" then
		reportMinimap()
		return
	elseif cmd == "sweep" or cmd:match("^sweep%s+%d+$") then
		sweepBlips(tonumber(cmd:match("%d+")))
		return
	elseif cmd:match("^settle%s+%d+$") then
		local frames = tonumber(cmd:match("%d+"))
		Scanner:SetSettleFrames(frames)
		out(string.format("settling %d frame(s) between moving the minimap and reading "
			.. "it - a sweep now takes about %d seconds", frames,
			math.ceil(256 * (frames + 1) / 60)))
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
