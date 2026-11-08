local ADDON, NR = ...

-- What NodeRadar shows is kept true by one routine, run as a coroutine: every reading
-- it asks for costs a frame with the minimap under the cursor, so it is written as
-- straight code that yields until the reading is back. Nothing sweeps on a timer: a
-- presence check every PRESENCE_INTERVAL tells whether anything changed, and only a
-- change - or a spawn point coming into reach - buys more readings.

local Scanner = {}
NR.Scanner = Scanner

local Map, Candidates = NR.Map, NR.Candidates

-- A gathering node's hit area is a square of this many pixels on screen, whatever the
-- minimap's size or zoom.
local NODE_PX = 16
-- Shrunk to this many pixels the whole map fits under one hit square, so one reading
-- lists every node in reach, once per node. Measured: 20 px reads, 15 px reads nothing.
local PRESENCE_PX = 21
-- size for reading a single spot: large enough that a hit square is a few yards wide
local SPOT_PX = 128
-- A presence check takes the map from its place for two frames - the shrink needs a
-- frame to settle - so it runs rarely. Spawn points coming into reach are read the
-- moment they do, and a node the player gathers leaves the radar with the cast.
local PRESENCE_INTERVAL = 20
local IDLE_PRESENCE_INTERVAL = 60
-- however much asks for readings, a new burst starts at most this often
local BURST_GAP = 5
-- how often the routine looks for spawn points that came into reach; costs no reading
-- unless one did
local REACH_INTERVAL = 0.25
-- The search stops growing the map here; its last quadrant is then about 3 yards wide.
-- Off screen and invisible, a map wider than the screen costs nothing visible.
local SEARCH_MAX_PX = 1400
local QUADRANTS = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }
local QUADRANT_OVERLAP = 1.25
-- how far from the player, as a share of the reach, a reading point may lie
local MAP_EDGE_SHARE = 0.97
-- a spawn point read empty is read again after this long, unless something asks sooner
local RECHECK = 120
-- readings spent per cycle on single spots before the presence check comes round again
local SPOTS_PER_CYCLE = 6
-- a spawn point or a reading this close to a node already shown is that node, in yards
local SAME_NODE = 15
-- a node the search could not place is not searched for again for this long
local SEARCH_BACKOFF = 5
-- nodes of one name searched for in one presence burst; each search is about 20 readings
local SEARCHES_PER_CYCLE = 4
-- a spawn point read empty while the presence check misses a node is passed over this
-- long, so the search gets its turn
local SPAWN_RETRY = 15
-- Spawn data from another world - GatherMate2_Data is mined on Retail - shows in the
-- nodes the search finds: this many of them, none near a spawn point, and no node ever
-- found at one, switch the spawn points off until the instance changes. Empty spawn
-- points prove nothing; there are far more of them than nodes standing at a time.
local SPAWN_MISMATCHES = 3
-- part of a presence square's half width at its edge that counts neither in nor out
local EDGE_MARGIN = 0.1
-- readings of one point that may fail before the routine is told it did
local TRIES = 3

local world
local routine
local request
-- idle; prepared: resized off screen, goes under the cursor next frame; settle: under
-- the cursor for the frame the client needs to lay out the resized map; read: placed,
-- read next frame; gap: one frame for the world's own mouseover
local phase = "idle"
local resumeAt = 0
local searchFailedAt = {}
local reachLook = 0
-- set when the filters change: nodes they hid so far may now belong on the radar
local checkSoon = false
local lastReadingAt = -math.huge
-- per presence square, the difference last logged
local lastDifference = {}
-- invalid readings per reason since it was last logged, and when that was
local invalidPending, invalidLoggedAt = {}, {}
local INVALID_LOG_GAP = 10

local function log(...)
	if NR.Log then NR.Log(...) end
end

local function where(east, north)
	return string.format("%.0f/%.0f", east, north)
end

local stats = { readings = 0, invalid = 0, presence = 0, spots = 0, searches = 0,
	foundBySearch = 0, foundAtSpawn = 0, lost = 0, spawnReadings = 0, spawnHits = 0,
	searchedNearSpawn = 0, searchedFarFromSpawn = 0, invalidWhy = {} }
local spawnsDistrusted = false

local function spawnsUsable()
	return Candidates:Available() and not spawnsDistrusted
end

-- counts one reading at a spawn point and how many nodes it found
local function judgeSpawns(found)
	stats.spawnReadings = stats.spawnReadings + 1
	stats.spawnHits = stats.spawnHits + found
end

-- the distance from a searched node to the nearest spawn point of its kind, or nil
local function spawnDistance(kind, east, north)
	local best
	Candidates:Near(east, north, SAME_NODE * 4, function(candidate, dx, dy)
		local distance = math.sqrt(dx * dx + dy * dy)
		if candidate.kind == kind and (not best or distance < best) then best = distance end
	end)
	return best
end

local function judgeSearched(kind, east, north)
	if not Candidates:Available() or spawnsDistrusted then return end
	local distance = spawnDistance(kind, east, north)
	if distance and distance <= SAME_NODE then
		stats.searchedNearSpawn = stats.searchedNearSpawn + 1
	else
		stats.searchedFarFromSpawn = stats.searchedFarFromSpawn + 1
	end
	if stats.searchedFarFromSpawn >= SPAWN_MISMATCHES and stats.searchedNearSpawn == 0
		and stats.spawnHits == 0 then
		spawnsDistrusted = true
		log("spawn points switched off: %d nodes found by search, none near a spawn point - "
			.. "the data does not match this world", stats.searchedFarFromSpawn)
	end
end
Scanner.stats = stats
Scanner.lastPresence = {}

-- yards per map unit, and the half width of a hit square in yards, on a map `pixels`
-- across that shows `radius` yards each way
local function geometry(pixels, radius)
	local units = pixels / Minimap:GetEffectiveScale()
	local yardsPerUnit = radius / (units / 2)
	return yardsPerUnit, NODE_PX / 2 / Minimap:GetEffectiveScale() * yardsPerUnit
end

-- Inside the routine: one reading of the point (east, north) - the player when nil - on
-- a map `pixels` across. Returns the names and the world point actually read, or nil
-- when the reading did not count.
local function sample(pixels, east, north)
	return coroutine.yield("sample", pixels, east, north)
end

local function wait(seconds)
	coroutine.yield("wait", seconds)
end

local function count(names, wanted)
	local total = 0
	for _, name in ipairs(names) do
		if name == wanted then total = total + 1 end
	end
	return total
end

local function inSquare(point, east, north, half)
	return math.abs(point.east - east) <= half and math.abs(point.north - north) <= half
end

-- the shown nodes matching `test`, as a list: the routine yields while walking it, and a
-- table must not be walked across a yield while others change it
local function shown(test)
	local list = {}
	for key, hit in pairs(world.hits) do
		if test(hit) then list[#list + 1] = key end
	end
	return list
end

local function nearestHit(name, east, north)
	local best, bestDistance
	for key, hit in pairs(world.hits) do
		if hit.name == name then
			local distance = math.max(math.abs(hit.east - east), math.abs(hit.north - north))
			if distance <= SAME_NODE and (not bestDistance or distance < bestDistance) then
				best, bestDistance = key, distance
			end
		end
	end
	return best
end

local function nearAnyHit(kind, east, north)
	for _, hit in pairs(world.hits) do
		if hit.kind == kind and math.abs(hit.east - east) <= SAME_NODE
			and math.abs(hit.north - north) <= SAME_NODE then
			return true
		end
	end
	return false
end

local function readSpot(east, north)
	local names = sample(SPOT_PX, east, north)
	if names then stats.spots = stats.spots + 1 end
	return names
end

-- Confirms or adds every node a spot reading names. Returns how many were new.
local function settleSpot(names, east, north, now, source)
	local added = 0
	for _, name in ipairs(names) do
		if world.isNode(name) then
			local key = nearestHit(name, east, north)
			if key then
				world.hits[key].seenAt = now
			else
				world.addHit(name, east, north, source)
				added = added + 1
			end
		end
	end
	return added
end

-- Reads a shown node's spot: confirmed when its name is there, removed when it is not.
local function recheck(key, now)
	local hit = world.hits[key]
	if not hit then return end
	local names = readSpot(hit.east, hit.north)
	if not names or not world.hits[key] then return end
	if count(names, hit.name) > 0 then
		hit.seenAt = now
	else
		log("gone: %s at %s - its spot reads [%s]", hit.name, where(hit.east, hit.north),
			table.concat(names, ", "))
		world.removeHit(key, "gone")
		stats.lost = stats.lost + 1
	end
end

-- Quadtree search for one node of `name` inside the square of half width `half` around
-- (east, north) that no shown node accounts for. Each quadrant is read with a hit square
-- its size and a quarter more - the map grows to make it so - and the shown nodes inside
-- are subtracted: a quadrant with a count left over holds a missing node.
local function search(name, east, north, half)
	stats.searches = stats.searches + 1
	local readings = 0
	local function fail(why)
		log("search for %s failed after %d readings: %s", name, readings, why)
	end
	while true do
		local _, _, radius = world.position()
		if not radius then return fail("no position") end
		local quarter = half / 2
		-- each quadrant is read a little wider than it is, so a node on a border - as
		-- one beside the player is, where the centre square's quadrants meet - lies
		-- well inside at least one of them
		local reach = quarter * QUADRANT_OVERLAP
		-- the hit square's half width is NODE_PX * radius / pixels yards
		local pixels = NODE_PX * radius / reach
		if pixels > SEARCH_MAX_PX then break end
		local playerEast, playerNorth = world.position()
		local edge = radius * MAP_EDGE_SHARE
		local chosenEast, chosenNorth
		for _, corner in ipairs(QUADRANTS) do
			-- a widened quadrant can reach past the map's edge, where a reading falls off the
			-- map; no node lies beyond the reach, so it is pulled back inside
			local quadrantEast = math.max(playerEast - edge, math.min(playerEast + edge,
				east + corner[1] * quarter))
			local quadrantNorth = math.max(playerNorth - edge, math.min(playerNorth + edge,
				north + corner[2] * quarter))
			local names, readEast, readNorth = sample(pixels, quadrantEast, quadrantNorth)
			readings = readings + 1
			if not names then return fail("a reading did not count") end
			local accounted = 0
			for _, hit in pairs(world.hits) do
				if hit.name == name and inSquare(hit, readEast, readNorth, reach) then
					accounted = accounted + 1
				end
			end
			if count(names, name) > accounted then
				chosenEast, chosenNorth = quadrantEast, quadrantNorth
				break
			end
		end
		if not chosenEast then
			return fail(string.format("no quadrant of %s +-%.0f holds it", where(east, north), half))
		end
		east, north, half = chosenEast, chosenNorth, reach
	end

	local names = readSpot(east, north)
	readings = readings + 1
	if not names or count(names, name) == 0 then
		return fail("the spot at " .. where(east, north) .. " does not read it")
	end
	log("search placed %s at %s in %d readings", name, where(east, north), readings)
	return east, north
end

-- A spawn point of the same kind near a searched position is where the node really is.
local function snap(kind, east, north)
	if not spawnsUsable() then return east, north end
	local best, bestDistance
	Candidates:Near(east, north, SAME_NODE, function(candidate, dx, dy)
		local distance = dx * dx + dy * dy
		if candidate.kind == kind and (not bestDistance or distance < bestDistance) then
			best, bestDistance = candidate, distance
		end
	end)
	if best then return best.east, best.north end
	return east, north
end

-- A name the presence square counts more often than nodes are shown: its spawn points
-- inside the square first, then a search.
local function findMissing(name, number, squareEast, squareNorth, half, now)
	-- the radar would not show it; finding where it stands costs readings for nothing
	if not world.wanted(name) then return end
	local kind = world.kindOf(name)
	local spent = 0
	if spawnsUsable() then
		local open = {}
		Candidates:Near(squareEast, squareNorth, half * 1.5, function(candidate, dx, dy)
			if candidate.kind == kind and math.abs(dx) <= half and math.abs(dy) <= half
				and now - candidate.probedAt >= SPAWN_RETRY
				and not nearAnyHit(kind, candidate.east, candidate.north) then
				candidate.distance = dx * dx + dy * dy
				open[#open + 1] = candidate
			end
		end)
		table.sort(open, function(a, b)
			if a.probedAt ~= b.probedAt then return a.probedAt < b.probedAt end
			return a.distance < b.distance
		end)
		for _, candidate in ipairs(open) do
			if number <= 0 or spent >= SPOTS_PER_CYCLE then break end
			local names = readSpot(candidate.east, candidate.north)
			spent = spent + 1
			if names then
				candidate.probedAt = now
				local added = 0
				if count(names, name) > 0 then
					added = settleSpot(names, candidate.east, candidate.north, now, "spawn point")
					stats.foundAtSpawn = stats.foundAtSpawn + added
					number = number - added
				end
				judgeSpawns(added)
			end
		end
	end

	-- the spawn points are spent for now; each search finds one node they miss, and the
	-- presence check comes round too rarely to leave the rest for later
	if now - (searchFailedAt[name] or -math.huge) <= SEARCH_BACKOFF then return end
	for _ = 1, math.min(number, SEARCHES_PER_CYCLE) do
		local east, north = search(name, squareEast, squareNorth, half)
		if not east then
			searchFailedAt[name] = now
			return
		end
		judgeSearched(kind, east, north)
		east, north = snap(kind, east, north)
		if nearestHit(name, east, north) then return end
		world.addHit(name, east, north, "search")
		stats.foundBySearch = stats.foundBySearch + 1
	end
end

-- One presence reading of the square of half width `half` centred `dx`, `dy` yards from
-- the player, set against the nodes shown inside it. `rechecked` collects the shown nodes
-- already read again during this check, as the squares overlap.
local function window(now, label, dx, dy, half, rechecked)
	local east, north = world.position()
	if not east then return end
	local names, readEast, readNorth = sample(PRESENCE_PX, east + dx, north + dy)
	if not names then return end
	stats.presence = stats.presence + 1
	local inner, outer = half * (1 - EDGE_MARGIN), half * (1 + EDGE_MARGIN)

	local seen = {}
	for _, name in ipairs(names) do
		if world.isNode(name) then seen[name] = (seen[name] or 0) + 1 end
	end
	if label == "centre" then Scanner.lastPresence = seen end

	local shownInner, shownOuter = {}, {}
	for _, hit in pairs(world.hits) do
		if inSquare(hit, readEast, readNorth, outer) then
			shownOuter[hit.name] = (shownOuter[hit.name] or 0) + 1
			if inSquare(hit, readEast, readNorth, inner) then
				shownInner[hit.name] = (shownInner[hit.name] or 0) + 1
			end
		end
	end

	local gone = {}
	for name, total in pairs(shownInner) do
		if (seen[name] or 0) < total then gone[name] = true end
	end
	for _, hit in pairs(world.hits) do
		if not gone[hit.name] and inSquare(hit, readEast, readNorth, inner) then
			hit.seenAt = now
		end
	end

	-- a difference is logged when it changes, not on every check it persists
	local differences = {}
	for name, total in pairs(seen) do
		if total ~= (shownOuter[name] or 0) then
			differences[#differences + 1] = string.format("%s seen %d shown %d", name, total,
				shownOuter[name] or 0)
		end
	end
	for name, total in pairs(shownInner) do
		if not seen[name] then differences[#differences + 1] = name .. " seen 0 shown " .. total end
	end
	table.sort(differences)
	local summary = table.concat(differences, "; ")
	if summary ~= lastDifference[label] then
		lastDifference[label] = summary
		log("presence %s: %s", label, summary ~= "" and summary or "matches the radar")
	end

	for name in pairs(gone) do
		-- a node the filters hide is left to expire rather than read again
		for _, key in ipairs(shown(function(hit)
			return hit.name == name and world.wanted(name)
				and inSquare(hit, readEast, readNorth, inner)
		end)) do
			if not rechecked[key] then
				rechecked[key] = true
				recheck(key, now)
			end
		end
	end
	for name, total in pairs(seen) do
		local missing = total - (shownOuter[name] or 0)
		if missing > 0 then findMissing(name, missing, readEast, readNorth, half, now) end
	end
end

-- The presence check: one square on the player and one pushed to each side, as far as
-- the map reaches. Together they cover the whole reach - its corners lie beyond the
-- radius - while every reading stays on the map.
local function presence(now)
	local _, _, radius = world.position()
	if not radius then return end
	local _, half = geometry(PRESENCE_PX, radius)
	local side = radius - half
	local rechecked = {}
	window(now, "centre", 0, 0, half, rechecked)
	window(now, "east", side, 0, half, rechecked)
	window(now, "west", -side, 0, half, rechecked)
	window(now, "north", 0, side, half, rechecked)
	window(now, "south", 0, -side, half, rechecked)
end

-- Whether a spawn point came into reach, or was last checked long ago. The presence check
-- that follows covers the whole reach, so each is marked as looked at; a node it shows
-- that nobody knows of is looked for at its spawn points first.
-- Also returns whether any spawn point in reach could hold a node the radar would show.
local function reach(now)
	local east, north, radius = world.position()
	if not east or not spawnsUsable() then return false, true end
	local due, wanted = false, false
	-- in reach now but not at the previous look, however long the routine waited between
	reachLook = reachLook + 1
	Candidates:Near(east, north, radius * 0.97, function(candidate)
		local entered = candidate.reachLook ~= reachLook - 1
		candidate.reachLook = reachLook
		if not world.tracked[candidate.kind] then return end
		-- a node the filters hide is not worth a reading
		if candidate.name and not world.wanted(candidate.name) then return end
		wanted = true
		if not entered and now - (candidate.checkedAt or -math.huge) < RECHECK then return end
		-- checked by the presence check that follows, not read at its spot
		candidate.checkedAt = now
		due = true
	end)
	return due, wanted
end

local function track()
	local lastPresenceAt = -math.huge
	while true do
		-- a burst ends when the routine waits; the next one keeps its distance
		local rest = BURST_GAP - (GetTime() - lastReadingAt)
		if rest > 0 then wait(rest) end
		local due, wanted = reach(GetTime())
		-- with no spawn point in reach that could hold a shown node, nodes are unlikely;
		-- the check then only guards against spots GatherMate does not know
		local interval = wanted and PRESENCE_INTERVAL or IDLE_PRESENCE_INTERVAL
		if due or checkSoon or GetTime() >= lastPresenceAt + interval then
			checkSoon = false
			presence(GetTime())
			lastPresenceAt = GetTime()
			world.cycleDone()
		end
		wait(REACH_INTERVAL)
	end
end

-- The player gathered `name`: the nearest shown node of that name within reach of the
-- cast leaves the radar at once rather than at the next presence check.
local GATHER_REACH = 15
function Scanner:Gathered(name)
	if not world then return end
	local east, north = world.position()
	if not east then return end
	local key = nearestHit(name, east, north)
	local hit = key and world.hits[key]
	if hit and math.abs(hit.east - east) <= GATHER_REACH and math.abs(hit.north - north) <= GATHER_REACH then
		log("gathered: %s at %s", name, where(hit.east, hit.north))
		world.removeHit(key, "gathered")
	end
end

-- context: position() -> east, north, radius; isNode(name); kindOf(name); tracked, the
-- kinds the minimap shows; hits; addHit(name, east, north, source); removeHit(key,
-- reason); cycleDone(); wanted(name), whether the filters let such a node onto the radar
function Scanner:Start(context)
	world = context
	routine = coroutine.create(track)
	request, phase, resumeAt = nil, "idle", 0
	self.lastError = nil
	lastDifference = {}
	log("scanner started")
end

function Scanner:CheckSoon()
	checkSoon = true
end

-- spawn points get a fresh chance in another instance
function Scanner:TrustSpawns()
	spawnsDistrusted = false
	stats.spawnReadings, stats.spawnHits = 0, 0
	stats.searchedNearSpawn, stats.searchedFarFromSpawn = 0, 0
end

function Scanner:SpawnsDistrusted()
	return spawnsDistrusted
end

function Scanner:Stop()
	routine, request, phase = nil, nil, "idle"
end

function Scanner:IsRunning()
	return routine ~= nil
end

local function resume(...)
	local ok, kind, a, b, c = coroutine.resume(routine, ...)
	if not ok then
		routine, request = nil, nil
		Scanner.lastError = tostring(kind)
		log("scanner error: %s", Scanner.lastError)
		return
	end
	if kind == "wait" then
		request, resumeAt = nil, GetTime() + a
	else
		request = { pixels = a, east = b, north = c, tries = 0 }
	end
end

local function place()
	local east, north, radius = world.position()
	if not east then return false end
	local yardsPerUnit = geometry(request.pixels, radius)
	local ox = request.east and (request.east - east) / yardsPerUnit or 0
	local oy = request.north and (request.north - north) / yardsPerUnit or 0
	Map:Place(ox, oy)
	return true
end

-- Between two readings of a burst the map stays away, parked off the cursor: one short
-- absence from its place instead of a flicker, and no resize to settle again. After the
-- last reading it goes home.
local function collect()
	local names, why = Map:Read()
	local east, north, radius = world.position()
	local ox, oy = Map:CursorOffset()
	phase = "gap"
	stats.readings = stats.readings + 1
	lastReadingAt = GetTime()
	if names and east then
		local yardsPerUnit = geometry(request.pixels, radius)
		resume(names, east + ox * yardsPerUnit, north + oy * yardsPerUnit)
		Map:Park(request ~= nil)
		return
	end
	Map:Park(true)
	why = why or "no position"
	stats.invalid = stats.invalid + 1
	stats.invalidWhy[why] = (stats.invalidWhy[why] or 0) + 1
	invalidPending[why] = (invalidPending[why] or 0) + 1
	local now = GetTime()
	if now - (invalidLoggedAt[why] or -math.huge) >= INVALID_LOG_GAP then
		log("reading did not count (%dx since last logged): %s", invalidPending[why], why)
		invalidPending[why], invalidLoggedAt[why] = 0, now
	end
	request.tries = request.tries + 1
	if request.tries >= TRIES then
		resume(nil)
		Map:Park(request ~= nil)
	end
end

-- Called every frame while the map is held. `free` says whether the cursor may take the
-- map now; a reading already placed is collected either way.
function Scanner:Step(free)
	if not routine then return end
	if phase == "read" then return collect() end
	if phase == "gap" then
		phase = "idle"
		return
	end
	if phase == "prepared" then
		if free and place() then
			phase = "settle"
		else
			Map:Park(false)
			phase = "idle"
		end
		return
	end
	-- After a resize the client lays the blips out anew only once the map is drawn on
	-- screen, so the first frame under the cursor reads nothing and is let pass. The map
	-- already sits there; a cursor busy now only costs this one reading.
	if phase == "settle" then
		phase = "read"
		return
	end
	-- a burst the cursor interrupts must not keep the map from its place
	if not free and Map:IsAway() then Map:Park(false) end

	if not request then
		if GetTime() < resumeAt then return end
		resume()
		if not request then return end
	end
	if not free then return end
	if Map:Ready(request.pixels) then
		if place() then phase = "read" end
	else
		Map:Prepare(request.pixels)
		phase = "prepared"
	end
end
