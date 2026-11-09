local ADDON, NR = ...

-- Spawn points from GatherMate2, when it is installed: its own database (what the player
-- gathered or imported) and GatherMate2_Data's raw tables, which NodeRadar loads itself
-- so the newest data counts without an import. They tell the scanner where a node can
-- appear, so it looks there first instead of searching.

local Candidates = {}
NR.Candidates = Candidates

local KINDS = { Mining = "ore", ["Herb Gathering"] = "herb" }
local DATA_TABLES = { Mining = "GatherMateData2MineDB", ["Herb Gathering"] = "GatherMateData2HerbDB" }
local DATA_ADDON = "GatherMate2_Data"
-- side of the square buckets candidates are filed in, in yards
local BUCKET = 100
-- two sources naming the same spawn within this many yards are one candidate
local SAME_SPOT = 3

local GatherMate
local builtFor
local buckets = {}
-- zones whose spawn points proved not to match this world
local distrusted = {}
Candidates.count = 0
Candidates.zones = 0

local function bucketKey(east, north)
	return math.floor(east / BUCKET) .. ":" .. math.floor(north / BUCKET)
end

local function decode(coord)
	return math.floor(coord / 1000000) / 10000, math.floor(coord % 1000000 / 100) / 10000
end

function Candidates:Init()
	local ace = LibStub and LibStub("AceAddon-3.0", true)
	GatherMate = ace and ace:GetAddon("GatherMate2", true)
	if not GatherMate or type(GatherMate.gmdbs) ~= "table" then
		NR.Log("GatherMate2 not usable - addon loaded=%s, AceAddon=%s, addon object=%s, "
			.. "databases=%s", tostring(C_AddOns.IsAddOnLoaded("GatherMate2")),
			tostring(ace ~= nil), tostring(GatherMate ~= nil),
			GatherMate and type(GatherMate.gmdbs) or "n/a")
		GatherMate = nil
		return
	end
	local why
	if not C_AddOns.IsAddOnLoaded(DATA_ADDON) then
		if C_AddOns.GetAddOnEnableState(DATA_ADDON, UnitName("player")) > 0 then
			local _, reason = C_AddOns.LoadAddOn(DATA_ADDON)
			why = reason
		else
			why = "not installed or disabled"
		end
	end
	self.dataLoaded = C_AddOns.IsAddOnLoaded(DATA_ADDON)
	NR.Log("GatherMate2 loaded; %s %s", DATA_ADDON, self.dataLoaded and "loaded"
		or "not loaded: " .. tostring(why))
end

function Candidates:Available()
	return GatherMate ~= nil
end

local function add(east, north, kind, name, zone)
	local key = bucketKey(east, north)
	local bucket = buckets[key]
	if not bucket then
		bucket = {}
		buckets[key] = bucket
	end
	for _, candidate in ipairs(bucket) do
		if candidate.kind == kind and math.abs(candidate.east - east) <= SAME_SPOT
			and math.abs(candidate.north - north) <= SAME_SPOT then
			return
		end
	end
	bucket[#bucket + 1] = { east = east, north = north, kind = kind, name = name, zone = zone,
		probedAt = -math.huge }
	Candidates.count = Candidates.count + 1
end

-- A zone's corners in world yards, or nil when it lies in another instance or this client
-- does not know it.
local function zoneFrame(zone, instanceID)
	local topInstance, topLeft = C_Map.GetWorldPosFromMapPos(zone, CreateVector2D(0, 0))
	local _, bottomRight = C_Map.GetWorldPosFromMapPos(zone, CreateVector2D(1, 1))
	if topInstance ~= instanceID or not topLeft or not bottomRight then return nil end
	-- the vectors carry UnitPosition's order: north first, then west
	local top, left = topLeft:GetXY()
	local bottom, right = bottomRight:GetXY()
	return top, left, bottom, right
end

-- the node's name as the minimap shows it, from GatherMate's id; nil when it has none
local names = {}
local function nameOf(dbType, nodeID)
	names[dbType] = names[dbType] or {}
	local name = names[dbType][nodeID]
	if name == nil then
		name = GatherMate:GetNameForNode(dbType, nodeID) or false
		names[dbType][nodeID] = name
	end
	return name or nil
end

local function addZones(source, dbType, kind, instanceID, frames)
	for zone, nodes in pairs(source) do
		if type(zone) == "number" and type(nodes) == "table" then
			local frame = frames[zone]
			if frame == nil then
				local top, left, bottom, right = zoneFrame(zone, instanceID)
				frame = top and { top, left, bottom, right } or false
				frames[zone] = frame
			end
			if frame then
				for coord, nodeID in pairs(nodes) do
					if type(coord) == "number" and type(nodeID) == "number" then
						local x, y = decode(coord)
						local north = frame[1] + (frame[3] - frame[1]) * y
						local west = frame[2] + (frame[4] - frame[2]) * x
						add(-west, north, kind, nameOf(dbType, nodeID), zone)
					end
				end
			end
		end
	end
end

-- Files every candidate of the player's instance in world yards. Built once per
-- instance: the conversion walks every zone, which is too slow to repeat per query.
function Candidates:Prepare(instanceID)
	if not GatherMate or instanceID == builtFor then return end
	builtFor = instanceID
	wipe(buckets)
	wipe(distrusted)
	self.count = 0
	local frames = {}
	for dbType, kind in pairs(KINDS) do
		-- GatherMate files zones across a base table and per-expansion storages behind a
		-- metatable; the tables themselves are read, so every zone is reached
		local own = GatherMate.gmdbs[dbType]
		if type(own) == "table" then
			local base = rawget(own, "__gm2_base_storage")
			addZones(base or own, dbType, kind, instanceID, frames)
			for _, storage in pairs(rawget(own, "__gm2_storage_map") or {}) do
				if type(storage) == "table" then addZones(storage, dbType, kind, instanceID, frames) end
			end
		end
		local data = _G[DATA_TABLES[dbType]]
		if type(data) == "table" then addZones(data, dbType, kind, instanceID, frames) end
	end
	local zones = 0
	for _, frame in pairs(frames) do
		if frame then zones = zones + 1 end
	end
	self.zones = zones
	-- a name NodeRadar does not know cannot be judged by the filters
	local unknown = {}
	for _, bucket in pairs(buckets) do
		for _, candidate in ipairs(bucket) do
			if candidate.name and not NR.localNodes[candidate.name] then
				unknown[candidate.name] = true
			end
		end
	end
	local list = {}
	for name in pairs(unknown) do list[#list + 1] = name end
	table.sort(list)
	NR.Log("spawn point names unknown to NodeRadar: %s", #list > 0 and table.concat(list, ", ")
		or "none")
end

function Candidates:Distrust(zone)
	distrusted[zone] = true
end

local function visitNear(east, north, radius, visit)
	local low, high = math.floor((east - radius) / BUCKET), math.floor((east + radius) / BUCKET)
	local bottom, top = math.floor((north - radius) / BUCKET), math.floor((north + radius) / BUCKET)
	local limit = radius * radius
	for column = low, high do
		for row = bottom, top do
			local bucket = buckets[column .. ":" .. row]
			if bucket then
				for _, candidate in ipairs(bucket) do
					local dx, dy = candidate.east - east, candidate.north - north
					if dx * dx + dy * dy <= limit then visit(candidate, dx, dy) end
				end
			end
		end
	end
end

-- Calls visit(candidate, dx, dy) for every trusted candidate within `radius` yards of
-- (east, north).
function Candidates:Near(east, north, radius, visit)
	visitNear(east, north, radius, function(candidate, dx, dy)
		if not distrusted[candidate.zone] then visit(candidate, dx, dy) end
	end)
end

-- whether a spawn point of a switched-off zone lies within `radius` yards
function Candidates:DistrustedNear(east, north, radius)
	if not next(distrusted) then return false end
	local found = false
	visitNear(east, north, radius, function(candidate)
		found = found or distrusted[candidate.zone] == true
	end)
	return found
end
