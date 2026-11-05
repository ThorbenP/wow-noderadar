local ADDON, NR = ...

if not NR.Scanner or not NR.Radar or not NR.Options or not NR.Dump or not NR.NODES
	or not NR.Filter then
	print("|cff33ff99NodeRadar|r |cffff4444a file did not load - check BugSack|r")
	return
end

local Scanner, Radar = NR.Scanner, NR.Radar
local isSecret = NR.IsSecret

NR.version = C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"

-- the slow tick: tracking, skill and the hold reason change far slower than a frame
local TICK = 0.25
local SWEEP_INTERVAL = 0.5
-- a node nothing has confirmed for this long is gone, whether or not anyone could look
local STALE_SECONDS = 30
-- standing on a node puts its icon under the player marker, where it says nothing
local MIN_DISTANCE = 5
-- Bumped whenever the shape or meaning of what /nr debug records changes, which
-- discards the stored snapshots: comparing readings across formats misleads.
local DIAG_FORMAT = 4
local DIAG_KEPT = 6

-- tracking spells by kind; the second of each pair is the same tracking on other clients
local TRACKING_SPELLS = { [2383] = "herb", [8387] = "herb", [2580] = "ore", [8388] = "ore" }
local TRACKING_ICON = { herb = 2383, ore = 2580 }
-- the gathering casts; their target is the node's name, as the minimap names it
local GATHER_CASTS = { [2366] = "herb", [2575] = "ore" }
local SKILL_LINES = { herb = 182, ore = 186 }
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local defaults = {
	radius = 120,
	iconSize = 20,
	nodeAlpha = 1,
	gridAlpha = 0.25,
	colorBySkill = true,
	showSparkle = true,
	showDistances = true,
	showGrid = false,
	showWindow = true,
	autoStart = false,
	hideInCombat = true,
	playSound = true,
	skillTooltip = true,
	hideTrivial = false,
	hideTooLow = false,
	-- item ids of the herbs and ores left off the radar
	hiddenItems = {},
	windowPoint = { "CENTER", "CENTER", 0, 220 },
}
NR.defaults = defaults

local db
local locale = GetLocale()
local shipped = NR.NODES[locale] or NR.NODES.enUS
NR.localNodes = shipped
local learned
local icons = {}

local hits, entries = {}, {}
local nextHitID = 0
local playerEast, playerNorth
local viewRadius
local lastSweepAt = -math.huge
local lastSweep, lastSweepError
local sinceTick = TICK
local pauseReason
local running, initialized = false, false
-- the first sweep after starting finds what was already there, which is no news
local baselineTaken = false
local shownCount = 0
local tracked = {}
local skillRank = {}
local diag = { sweeps = 0, failed = 0, reads = 0, ms = 0, worstMs = 0 }

local function out(msg)
	print("|cff33ff99NodeRadar|r " .. msg)
end

local function warn(msg)
	out("|cffffaa00" .. msg .. "|r")
end

local EMPTY = {}

-- { kind, skill, item } for a node name, from the shipped list or learned by gathering
local function nodeInfo(name)
	return shipped[name] or learned[name]
end

local function isNode(name)
	return nodeInfo(name) ~= nil
end

local function textureFor(name, kind, item)
	local key = name or item
	if icons[key] then return icons[key] end
	local texture = item and C_Item.GetItemIconByID(item)
		or C_Spell.GetSpellTexture(TRACKING_ICON[kind])
		or QUESTION_MARK
	icons[key] = texture
	return texture
end

local function readSkill(lineID)
	local info = C_SkillInfo.GetSkillLineInfoByID(lineID)
	if type(info) ~= "table" or isSecret(info) then return nil end
	local rank, modifier = info.rank, info.modifier
	if type(rank) ~= "number" or isSecret(rank) or isSecret(modifier) then return nil end
	return rank + (type(modifier) == "number" and modifier or 0)
end

-- a profession the character lacks or a skill the client hides leaves no judgement
local function refreshSkills()
	for kind, lineID in pairs(SKILL_LINES) do
		skillRank[kind] = readSkill(lineID)
	end
end

-- Classic gathering: orange up to 25 points above the requirement, yellow to 50,
-- green to 100, grey beyond, where the node raises the skill no more.
local DIFFICULTY_COLORS = {
	impossible = { 1, 0.1, 0.1 }, hard = { 1, 0.5, 0.25 }, medium = { 1, 1, 0 },
	easy = { 0.25, 0.75, 0.25 }, trivial = { 0.5, 0.5, 0.5 },
}

local function difficulty(kind, required)
	local rank = skillRank[kind]
	if not required or not rank then return nil end
	local above = rank - required
	if above < 0 then return "impossible" end
	if above < 25 then return "hard" end
	if above < 50 then return "medium" end
	if above < 100 then return "easy" end
	return "trivial"
end

local function skillTooLow(kind, required)
	return difficulty(kind, required) == "impossible"
end

-- what the filters let onto the radar and into the alert
local function wanted(hit)
	if hit.item and db.hiddenItems[hit.item] then return false end
	local level = difficulty(hit.kind, hit.skill)
	if db.hideTooLow and level == "impossible" then return false end
	if db.hideTrivial and level == "trivial" then return false end
	return true
end

-- the client draws no blips for a gathering type it is not tracking
local function refreshTracking()
	wipe(tracked)
	for index = 1, C_Minimap.GetNumTrackingTypes() do
		local info = C_Minimap.GetTrackingInfo(index)
		local spellID = type(info) == "table" and info.spellID
		local kind = spellID and not isSecret(spellID) and TRACKING_SPELLS[spellID]
		if kind and info.active == true then tracked[kind] = true end
	end
end

-- World position in yards, east and north. Nil inside instances, where the client
-- withholds it, and whenever it answers a secret.
local function playerPosition()
	local north, west = UnitPosition("player")
	if type(north) ~= "number" or isSecret(north) or isSecret(west) then return nil end
	return -west, north
end

local function playerFacing()
	local facing = GetPlayerFacing()
	if type(facing) ~= "number" or isSecret(facing) then return nil end
	return facing
end

-- world offset east/north into the frame whose up is the player's facing
local function toFacing(east, north, facing)
	local s, c = math.sin(facing), math.cos(facing)
	return east * c + north * s, -east * s + north * c
end

local function newHit(name, info, east, north)
	nextHitID = nextHitID + 1
	local key = "node" .. nextHitID
	local kind, skill, item = info[1], info[2], info[3]
	local hit = { name = name, kind = kind, skill = skill, item = item,
		east = east, north = north, seenAt = GetTime(), appearedAt = GetTime(),
		texture = textureFor(name, kind, item) }
	hits[key] = hit
	return hit
end

local function sweepNow(now)
	local half = Minimap:GetWidth() / 2
	local unitsPerYard = half / viewRadius
	local known = {}
	for key, hit in pairs(hits) do
		local east, north = hit.east - playerEast, hit.north - playerNorth
		known[#known + 1] = { name = hit.name, ref = key,
			x = east * unitsPerYard, y = north * unitsPerYard }
	end

	lastSweepAt = now
	local result, err = Scanner:Sweep(isNode, known)
	diag.sweeps = diag.sweeps + 1
	if not result then
		diag.failed = diag.failed + 1
		if err ~= lastSweepError then warn("sweep failed: " .. err) end
		lastSweepError = err
		return
	end
	lastSweepError = nil
	lastSweep = result
	diag.reads = diag.reads + result.reads
	diag.ms = diag.ms + result.ms
	diag.worstMs = math.max(diag.worstMs, result.ms)

	for _, node in ipairs(known) do
		if result.present[node.ref] then
			hits[node.ref].seenAt = now
		else
			hits[node.ref] = nil
		end
	end

	local yardsPerUnit = viewRadius / result.half
	local alert = false
	for _, node in ipairs(result.found) do
		local east, north = node.x * yardsPerUnit, node.y * yardsPerUnit
		local hit = newHit(node.name, nodeInfo(node.name), playerEast + east,
			playerNorth + north)
		alert = alert or (wanted(hit) and not skillTooLow(hit.kind, hit.skill))
	end
	if alert and baselineTaken and db.playSound then
		PlaySound(SOUNDKIT.MAP_PING, "Master")
	end
	baselineTaken = true
end

-- One source for why nothing is being scanned, in the order that matters to the player.
local function holdReason()
	if not next(tracked) then return "no gathering tracking is active" end
	if not Minimap:IsVisible() then return "the minimap is hidden" end
	-- the sweep borrows the soft cursor, which is the gamepad's own
	if InputUtil.IsGamepadUIEnabled() then return "the gamepad cursor is in use" end
	-- a sweep reads offsets as north-up; Forever's options cannot turn rotation on
	if C_CVar.GetCVar("rotateMinimap") == "1" then return "the minimap rotates" end
	if not playerEast then return "no position available here" end
	if not viewRadius then return "the minimap's range is unreadable" end
end

-- Entries are a pool, not fresh tables: at 60 frames a second one table per shown
-- node is the addon's largest source of garbage. Radar:Render is told the count.
local function render(now)
	local facing = playerFacing()
	if not facing or not playerEast then return end

	local range = viewRadius or 0
	local count = 0
	for key, hit in pairs(hits) do
		if now - hit.seenAt > STALE_SECONDS then
			hits[key] = nil
		else
			local east, north = hit.east - playerEast, hit.north - playerNorth
			local distance = math.sqrt(east * east + north * north)
			if distance <= range and distance >= MIN_DISTANCE and wanted(hit) then
				local right, forward = toFacing(east, north, facing)
				count = count + 1
				local entry = entries[count]
				if not entry then
					entry = {}
					entries[count] = entry
				end
				entry.key, entry.rx, entry.ry = key, right / range, forward / range
				entry.distance, entry.texture = distance, hit.texture
				entry.appearedAt = hit.appearedAt
				-- the skill rises while the node sits on the radar
				entry.tooLow = skillTooLow(hit.kind, hit.skill)
			end
		end
	end
	shownCount = count
	Radar:Render(entries, count)
end

local function readViewRadius()
	local radius = C_Minimap.GetViewRadius()
	if type(radius) ~= "number" or isSecret(radius) or radius <= 0 then return nil end
	return radius
end

local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(_, elapsed)
	local now = GetTime()
	playerEast, playerNorth = playerPosition()

	sinceTick = sinceTick + elapsed
	if sinceTick >= TICK then
		sinceTick = 0
		refreshTracking()
		refreshSkills()
		viewRadius = readViewRadius()
		if viewRadius then Radar:SetRange(viewRadius) end

		local reason = holdReason()
		if reason ~= pauseReason then
			if reason == "no gathering tracking is active" then
				warn("no gathering tracking is active - turn on Find Herbs or Find Minerals, "
					.. "otherwise the minimap shows no nodes")
			elseif pauseReason == "no gathering tracking is active" then
				out("gathering tracking is active again")
			end
		end
		pauseReason = reason
	end

	if not pauseReason and now - lastSweepAt >= SWEEP_INTERVAL then
		sweepNow(now)
	end

	local hidden = db.hideInCombat and UnitAffectingCombat("player")
	Radar:SetShown(not hidden)
	if hidden then return end

	if not playerEast then
		if shownCount > 0 then
			shownCount = 0
			Radar:Render(EMPTY, 0)
		end
		return
	end
	render(now)
end)

function NR.Stop()
	running = false
	driver:Hide()
	wipe(hits)
	shownCount = 0
	Radar:SetShown(false)
	NR.Options:Refresh()
end

function NR.Start()
	running = true
	-- no reason yet, so the first tick reports whatever it finds - including a missing
	-- tracking ability, the one hold the user has to hear about
	pauseReason = nil
	sinceTick = TICK
	lastSweepAt = -math.huge
	baselineTaken = false
	Radar:SetShown(true)
	driver:Show()
	NR.Options:Refresh()
end

function NR.IsRunning()
	return running
end

-- Hovering a node on the minimap shows what gathering it needs, coloured like the
-- node's own tooltip in the world. Several nodes under the cursor get a line each.
local function addSkillLines(tooltip, data)
	if not db.skillTooltip or isSecret(data) or type(data) ~= "table"
		or isSecret(data.lines) or type(data.lines) ~= "table" then
		return
	end
	local names, seen = {}, {}
	for _, line in ipairs(data.lines) do
		local text = type(line) == "table" and line.leftText or nil
		if isSecret(text) then return end
		if type(text) == "string" then
			for row in text:gmatch("[^\n]+") do
				local name = Scanner.Plain(row)
				local info = nodeInfo(name)
				if info and info[2] and not seen[name] then
					seen[name] = true
					names[#names + 1] = name
				end
			end
		end
	end

	refreshSkills()
	for _, name in ipairs(names) do
		local kind, required = nodeInfo(name)[1], nodeInfo(name)[2]
		-- nil for a profession the character lacks: no line, there is nothing to colour
		local skill = C_SkillInfo.GetSkillLineInfoByID(SKILL_LINES[kind])
		local skillName = type(skill) == "table" and skill.name
		if type(skillName) == "string" and not isSecret(skillName) then
			local text = ITEM_MIN_SKILL:format(skillName, required)
			if #names > 1 then text = name .. ": " .. text end
			local color = DIFFICULTY_COLORS[difficulty(kind, required) or "impossible"]
			tooltip:AddLine(text, color[1], color[2], color[3])
		end
	end
end

local function applyDefaults(target, source)
	for key, value in pairs(source) do
		if target[key] == nil then
			target[key] = type(value) == "table" and CopyTable(value) or value
		end
	end
end

local function initialize()
	if initialized then return true end

	NodeRadarDB = NodeRadarDB or {}
	-- Snapshots from an older format read as the current one but mean different
	-- things, so they are dropped rather than mixed into a fresh set of readings.
	if NodeRadarDB.debugFormat ~= DIAG_FORMAT then
		NodeRadarDB.debugFormat = DIAG_FORMAT
		NodeRadarDB.debug, NodeRadarDB.sweep, NodeRadarDB.blip, NodeRadarDB.minimap =
			nil, nil, nil, nil
	end
	applyDefaults(NodeRadarDB, defaults)
	db = NodeRadarDB
	db.learned = db.learned or {}
	db.learned[locale] = db.learned[locale] or {}
	learned = db.learned[locale]
	-- another addon shipped under the same folder name keeps its own shape in this table
	for name, info in pairs(learned) do
		if type(info) ~= "table" or (info[1] ~= "herb" and info[1] ~= "ore") then
			learned[name] = nil
		end
	end

	if not Scanner.available then
		out("|cffff4444this client cannot read the minimap's blips - NodeRadar needs "
			.. "WoW Forever|r")
		return false
	end

	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.MinimapMouseover,
		addSkillLines)
	Radar:Init(db)
	NR.Filter:Init(db)
	NR.Options:Init(db)
	initialized = true
	refreshSkills()
	out("ready. /nr starts and stops the radar")
	return true
end

-- What a gathering cast targets is the node's name exactly as the minimap shows it,
-- so a node the shipped list misses - a new variant, a locale gap - is learned the
-- first time the player gathers it.
local castKinds
local function castKind(spellID)
	if GATHER_CASTS[spellID] then return GATHER_CASTS[spellID] end
	if not castKinds then
		castKinds = {}
		for id, kind in pairs(GATHER_CASTS) do
			local name = C_Spell.GetSpellName(id)
			if name then castKinds[name] = kind end
		end
	end
	local name = C_Spell.GetSpellName(spellID)
	return name and castKinds[name]
end

local function learnFromCast(target, spellID)
	if not initialized or type(target) ~= "string" or isSecret(target)
		or isSecret(spellID) then
		return
	end
	local kind = castKind(spellID)
	if not kind then return end
	local name = Scanner.Plain(target)
	if name == "" or nodeInfo(name) then return end
	learned[name] = { kind }
	out(string.format("learned a new %s node: %s", kind == "herb" and "herb" or "ore", name))
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
loader:SetScript("OnEvent", function(_, event, ...)
	if event == "UNIT_SPELLCAST_SENT" then
		local _, target, _, spellID = ...
		learnFromCast(target, spellID)
		return
	end
	if initialize() and db.autoStart then NR.Start() end
end)

-- The snapshot is built as text, which is what both consumers want: the window hands
-- it to the clipboard, and the saved copy is read as text too.
local function append(lines, format, ...)
	lines[#lines + 1] = select("#", ...) > 0 and string.format(format, ...) or format
end

local function snapshotLines()
	local lines = {}
	local version, build = GetBuildInfo()
	append(lines, "NodeRadar %s snapshot %s, client %s.%s %s", NR.version,
		date("%Y-%m-%d %H:%M:%S"), tostring(version), tostring(build), locale)
	append(lines, "onHold=%s viewRadius=%s mapWidth=%.1f scale=%.3f shape=%s",
		pauseReason or "no", tostring(viewRadius), Minimap:GetWidth(),
		Minimap:GetEffectiveScale(), GetMinimapShape and GetMinimapShape() or "ROUND")
	append(lines, "position=%s facing=%s",
		playerEast and string.format("%.1f/%.1f", playerEast, playerNorth) or "none",
		tostring(playerFacing()))
	append(lines, "skill: herbalism=%s mining=%s; tracking: herb=%s ore=%s",
		tostring(skillRank.herb), tostring(skillRank.ore),
		tostring(tracked.herb or false), tostring(tracked.ore or false))
	local succeeded = math.max(diag.sweeps - diag.failed, 1)
	append(lines, "sweeps=%d failed=%d avgReads=%.0f avgMs=%.1f worstMs=%.1f lastError=%s",
		diag.sweeps, diag.failed, diag.reads / succeeded, diag.ms / succeeded, diag.worstMs,
		tostring(lastSweepError))

	local learnedNames = {}
	for name, info in pairs(learned) do
		learnedNames[#learnedNames + 1] = name .. "=" .. info[1]
	end
	table.sort(learnedNames)
	append(lines, "learned: %s", #learnedNames > 0 and table.concat(learnedNames, ", ")
		or "none")

	if lastSweep then
		append(lines, "")
		append(lines, "last sweep: %d reads, %.1f ms, %d new, %d unmeasured",
			lastSweep.reads, lastSweep.ms, #lastSweep.found, lastSweep.unmeasured)
		local seen = {}
		for name, cells in pairs(lastSweep.names) do
			seen[#seen + 1] = string.format("  %s %s (%d cells)",
				isNode(name) and "NODE " or "other", name, cells)
		end
		table.sort(seen)
		for _, line in ipairs(seen) do append(lines, "%s", line) end
	end


	local shown = {}
	for key, hit in pairs(hits) do
		if playerEast then
			local east, north = hit.east - playerEast, hit.north - playerNorth
			shown[#shown + 1] = string.format("  %s %s d=%.0fyd age=%.0fs",
				key, hit.name, math.sqrt(east * east + north * north),
				GetTime() - hit.appearedAt)
		end
	end
	table.sort(shown)
	append(lines, "")
	append(lines, "on the radar (%d):", #shown)
	for _, line in ipairs(shown) do append(lines, "%s", line) end
	return lines
end

local function writeDiagnostics()
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
		NodeRadarDB.debug = nil
		diag.sweeps, diag.failed, diag.reads, diag.ms, diag.worstMs = 0, 0, 0, 0, 0
		out("diagnostics cleared")
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
