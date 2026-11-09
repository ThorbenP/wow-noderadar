local ADDON, NR = ...

if not NR.Map or not NR.Candidates or not NR.Scanner or not NR.Radar or not NR.Options
	or not NR.Dump or not NR.NODES or not NR.Filter then
	print("|cff33ff99NodeRadar|r |cffff4444a file did not load - check BugSack|r")
	return
end

local Map, Candidates, Scanner, Radar = NR.Map, NR.Candidates, NR.Scanner, NR.Radar
local isSecret = NR.IsSecret

NR.version = C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"

-- the slow tick: tracking, skill and the hold reason change far slower than a frame
local TICK = 0.25
-- A node no check confirmed for this long is gone. Nodes the checks cover count the time
-- from their last whole check, so combat or a busy cursor does not take them off the
-- radar; nodes out of reach or hidden by the filters count it from now.
local STALE_SECONDS = 60
-- standing on a node puts its icon under the player marker, where it says nothing
local MIN_DISTANCE = 5
-- several nodes found at once ring once
local SOUND_GAP = 1
-- Bumped whenever the shape or meaning of what /nr debug records changes, which
-- discards the stored snapshots: comparing readings across formats misleads.
local DIAG_FORMAT = 5
local DIAG_KEPT = 6
-- events kept for /nr debug, across reloads, so a problem that came and went is still
-- on record
local LOG_KEPT = 500

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
local build = select(2, GetBuildInfo())
local shipped = NR.NODES[locale] or NR.NODES.enUS
NR.localNodes = shipped
local learned
local icons = {}

local hits, entries = {}, {}
local nextHitID = 0
local playerEast, playerNorth, playerInstance
local viewRadius
local sinceTick = TICK
local pauseReason
local running, initialized = false, false
-- the first presence cycle finds what was already there, which is no news
local baselineTaken = false
local lastSoundAt = -math.huge
local reportedError
local shownCount = 0
local tracked = {}
local skillRank = {}
-- tooltips made invisible because they show a reading, with the alpha to give back
local mutedTooltips = {}

local function out(msg)
	print("|cff33ff99NodeRadar|r " .. msg)
end

local function warn(msg)
	out("|cffffaa00" .. msg .. "|r")
end

local EMPTY = {}

-- Appends one line to the event log with a wall clock and a tenth of a second.
function NR.Log(format, ...)
	if not db then return end
	local text = select("#", ...) > 0 and string.format(format, ...) or format
	local log = db.log
	-- the wall clock has whole seconds only; the session clock orders events within one
	log[#log + 1] = string.format("%s %.1f %s", date("%H:%M:%S"), GetTime(), text)
	while #log > LOG_KEPT do table.remove(log, 1) end
end
local log = NR.Log

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
local function wantedNode(kind, skill, item)
	if item and db.hiddenItems[item] then return false end
	local level = difficulty(kind, skill)
	if db.hideTooLow and level == "impossible" then return false end
	if db.hideTrivial and level == "trivial" then return false end
	return true
end

local function wanted(hit)
	return wantedNode(hit.kind, hit.skill, hit.item)
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

-- World position in yards, east and north, and the instance. Nil inside instances,
-- where the client withholds it, and whenever it answers a secret.
local function playerPosition()
	local north, west, _, instanceID = UnitPosition("player")
	if type(north) ~= "number" or isSecret(north) or isSecret(west) then return nil end
	return -west, north, not isSecret(instanceID) and instanceID or nil
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

-- Nodes taken off the radar lately: one found again at the same spot is the same node,
-- and is no news - a vein mined once is often still there for the next swing, and
-- nothing respawns that quickly.
local REMEMBER_SECONDS = 120
local SAME_SPOT = 15
local removed = {}

local function removeHit(key, reason)
	local hit = hits[key]
	if not hit then return end
	hits[key] = nil
	removed[#removed + 1] = { name = hit.name, east = hit.east, north = hit.north,
		appearedAt = hit.appearedAt, at = GetTime(), reason = reason }
end

-- the remembered node at this spot, taken out of the memory
local function recall(name, east, north)
	local now = GetTime()
	for index = #removed, 1, -1 do
		local entry = removed[index]
		if now - entry.at > REMEMBER_SECONDS then
			table.remove(removed, index)
		elseif entry.name == name and math.abs(entry.east - east) <= SAME_SPOT
			and math.abs(entry.north - north) <= SAME_SPOT then
			table.remove(removed, index)
			return entry
		end
	end
end

local function addHit(name, east, north, source)
	local info = nodeInfo(name)
	if not info then return end
	local earlier = recall(name, east, north)
	if earlier then
		log("again: %s at %.0f/%.0f (%s), off the radar for %.0f s after it was %s", name,
			east, north, source or "?", GetTime() - earlier.at, earlier.reason)
	elseif playerEast then
		local spawn
		if Candidates:Available() then
			Candidates:Near(east, north, 100, function(candidate, dx, dy)
				local distance = math.sqrt(dx * dx + dy * dy)
				if candidate.kind == info[1] and (not spawn or distance < spawn) then
					spawn = distance
				end
			end)
		end
		log("new: %s at %.0f/%.0f, %.0f yd away (%s), nearest spawn point %s", name, east,
			north, math.sqrt((east - playerEast) ^ 2 + (north - playerNorth) ^ 2),
			source or "?", spawn and string.format("%.1f yd", spawn) or "none within 100 yd")
	end
	nextHitID = nextHitID + 1
	local now = GetTime()
	local hit = { name = name, kind = info[1], skill = info[2], item = info[3],
		east = east, north = north, seenAt = now, appearedAt = earlier and earlier.appearedAt or now,
		texture = textureFor(name, info[1], info[3]) }
	hits["node" .. nextHitID] = hit
	if not earlier and baselineTaken and db.playSound and wanted(hit) and not skillTooLow(hit.kind, hit.skill)
		and now - lastSoundAt >= SOUND_GAP then
		lastSoundAt = now
		PlaySound(SOUNDKIT.MAP_PING, "Master")
	end
end

-- What the scanner may know and change of the world.
local context = {
	position = function()
		if playerEast and viewRadius then return playerEast, playerNorth, viewRadius end
	end,
	isNode = isNode,
	kindOf = function(name)
		local info = nodeInfo(name)
		return info and info[1]
	end,
	tracked = tracked,
	hits = hits,
	addHit = addHit,
	removeHit = removeHit,
	cycleDone = function() baselineTaken = true end,
	-- whether the filters let a node of this name onto the radar; unknown names may
	wanted = function(name)
		local info = nodeInfo(name)
		return not info or wantedNode(info[1], info[2], info[3])
	end,
}

-- Addons create and place their minimap buttons right after a loading screen, from the
-- map's size at that moment; the map stays in its place meanwhile.
local SETTLE_AFTER_LOADING = 5
local settledAt = 0

-- One source for why the minimap cannot be read, in the order that matters to the player.
local function holdReason()
	if not next(tracked) then return "no gathering tracking is active" end
	if not Map:IsAway() and not Minimap:IsVisible() then return "the minimap is hidden" end
	-- the gamepad's cursor is not the one the minimap is placed under
	if InputUtil.IsGamepadUIEnabled() then return "the gamepad cursor is in use" end
	-- readings are taken as offsets on a north-up map
	if C_CVar.GetCVar("rotateMinimap") == "1" then return "the minimap rotates" end
	if EditModeManagerFrame and EditModeManagerFrame:IsShown() then return "Edit Mode is open" end
	if GetTime() < settledAt then return "the interface is still loading" end
	if not playerEast then return "no position available here" end
	if not viewRadius then return "the minimap's range is unreadable" end
end

local function hiddenInCombat()
	return db.hideInCombat and UnitAffectingCombat("player")
end

-- Why the map may not go under the cursor this frame, or nil when it may. It never
-- interrupts the player: not while the cursor is on a frame or on something in the
-- world, not while it is dragged, aimed, or carrying something, and not while the camera
-- turns.
-- A frame's name for the log. Protected frames answer secret names, which must never
-- reach a string that is compared or stored.
local function frameName(frame)
	if frame == nil then return "none" end
	if isSecret(frame) then return "a protected frame" end
	local name = frame:GetDebugName()
	if isSecret(name) or type(name) ~= "string" then return "a protected frame" end
	return name
end

local function cursorBusy()
	if IsMouselooking() then return "the camera turns" end
	if IsMouseButtonDown() then return "a mouse button is held" end
	if SpellIsTargeting() then return "a spell is aimed" end
	if GetCursorInfo() then return "the cursor carries something" end
	local hovering = UnitExists("mouseover")
	if isSecret(hovering) or hovering then return "the cursor is on a unit" end
	local shown = GameTooltip:IsShown()
	if isSecret(shown) or shown and not mutedTooltips[GameTooltip] then
		return "a tooltip is shown (owner " .. frameName(GameTooltip:GetOwner()) .. ")"
	end
	local focus = GetMouseFoci()[1]
	if isSecret(focus) then return "the cursor is on a protected frame" end
	-- the map under the cursor is the reading's own doing; in its place it is the player's
	if focus == Minimap and not Map:IsAway() then return "the cursor is on the minimap" end
	if focus ~= nil and focus ~= Minimap and focus ~= WorldFrame then
		return "the cursor is on " .. frameName(focus)
	end
end

-- a pause of the readings is logged when it ends, if it lasted long enough to matter
local PAUSE_LOG_SECONDS = 2
-- A player steering with a mouse button lets go for a moment between two presses; a
-- burst starting in that moment blinks right after the press. Readings resume only once
-- the cursor has stayed free this long.
local RESUME_GRACE = 2
local busySince, busyWhy

local function cursorFree(now)
	local why = cursorBusy()
	if why ~= busyWhy then
		if busyWhy and now - busySince >= PAUSE_LOG_SECONDS then
			log("readings paused %.1f s: %s", now - busySince, busyWhy)
		end
		busySince, busyWhy = now, why
	end
	return why == nil and now - busySince >= RESUME_GRACE
end

local function readViewRadius()
	local radius = C_Minimap.GetViewRadius()
	if type(radius) ~= "number" or isSecret(radius) or radius <= 0 then return nil end
	return radius
end

-- The minimap is NodeRadar's while the radar is up and the map can be read; otherwise
-- it is the player's. Protected frames refuse in combat, so a change waits for the
-- next tick that allows it.
local refusedLogged = false
local function updateHold()
	local want = running and not hiddenInCombat() and not pauseReason
	if want and not Map:IsHeld() then
		if Map:Hold() then
			log("readings start, minimap %.0f px", Map:HomePixels())
			-- a pause still running from before is not this hold's
			busySince, busyWhy = -math.huge, nil
			Scanner:Start(context)
		elseif not refusedLogged then
			refusedLogged = true
			log("readings could not start")
		end
	elseif not want and Map:IsHeld() then
		if Map:Release() then
			Scanner:Stop()
			log("readings stop (%s)", not running and "radar stopped"
				or hiddenInCombat() and "combat" or pauseReason or "?")
		elseif not refusedLogged then
			refusedLogged = true
			log("the minimap could not be put back yet - protected in combat")
		end
	else
		refusedLogged = false
	end
end

-- Entries are a pool, not fresh tables: at 60 frames a second one table per shown
-- node is the addon's largest source of garbage. Radar:Render is told the count.
local function render(now)
	local facing = playerFacing()
	if not facing or not playerEast then return end

	local range = viewRadius or 0
	local count = 0
	for key, hit in pairs(hits) do
		local east, north = hit.east - playerEast, hit.north - playerNorth
		local distance = math.sqrt(east * east + north * north)
		local covered = distance <= range and wanted(hit)
		if (covered and Scanner.wholeCheckAt or now) - hit.seenAt > STALE_SECONDS then
			log("expired: %s, unconfirmed for %d s", hit.name, STALE_SECONDS)
			removeHit(key, "expired")
		else
			if covered and distance >= MIN_DISTANCE then
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

local preparedInstance
local lastFilters
local filterFlags = {}

-- Which known nodes the filters let through; a skill-up that changes none of them is no
-- reason for a check.
local function filterSignature()
	local count = 0
	for _, source in ipairs({ shipped, learned }) do
		for name in pairs(source) do
			count = count + 1
			filterFlags[count] = context.wanted(name) and "1" or "0"
		end
	end
	for index = #filterFlags, count + 1, -1 do filterFlags[index] = nil end
	return table.concat(filterFlags)
end

local function tick()
	refreshTracking()
	refreshSkills()
	viewRadius = readViewRadius()
	if viewRadius then Radar:SetRange(viewRadius) end
	if playerInstance and playerInstance ~= preparedInstance then
		preparedInstance = playerInstance
		local started = debugprofilestop()
		Candidates:Prepare(playerInstance)
		Scanner:TrustSpawns()
		if Candidates:Available() then
			log("spawn points for instance %s: %d in %d zones, %.0f ms", tostring(playerInstance),
				Candidates.count, Candidates.zones, debugprofilestop() - started)
		end
	end

	local reason = holdReason()
	if reason ~= pauseReason then
		log("hold reason: %s -> %s", pauseReason or "none", reason or "none")
	end
	if running and reason ~= pauseReason then
		if reason == "no gathering tracking is active" then
			warn("no gathering tracking is active - turn on Find Herbs or Find Minerals, "
				.. "otherwise the minimap shows no nodes")
		elseif pauseReason == "no gathering tracking is active" then
			out("gathering tracking is active again")
		end
	end
	pauseReason = reason
	local filters = filterSignature()
	if filters ~= lastFilters then
		if lastFilters then Scanner:CheckSoon() end
		lastFilters = filters
	end
	updateHold()

	if Scanner.lastError and Scanner.lastError ~= reportedError then
		reportedError = Scanner.lastError
		warn("scanning stopped after an error - /nr twice restarts it: " .. reportedError)
	end
end

local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(_, elapsed)
	local now = GetTime()
	playerEast, playerNorth, playerInstance = playerPosition()

	sinceTick = sinceTick + elapsed
	if sinceTick >= TICK then
		sinceTick = 0
		tick()
	end
	-- a release refused in combat keeps the driver going until it goes through
	if not running then
		if not Map:IsHeld() then driver:Hide() end
		return
	end

	if Map:IsHeld() then Scanner:Step(cursorFree(now)) end

	local hidden = hiddenInCombat()
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
	log("radar stopped")
	running = false
	updateHold()
	wipe(hits)
	shownCount = 0
	Radar:SetShown(false)
	NR.Options:Refresh()
end

function NR.Start()
	log("radar started, NodeRadar %s, client build %s", NR.version, tostring(build))
	running = true
	-- no reason yet, so the first tick reports whatever it finds - including a missing
	-- tracking ability, the one hold the user has to hear about
	pauseReason = nil
	sinceTick = TICK
	baselineTaken = false
	reportedError = nil
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
				local name = NR.Plain(row)
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

-- While the map is away from its place the player cannot see it, so a minimap mouseover
-- tooltip can only come from a reading: the client shows one for the frame a node sits
-- under the cursor. It is made invisible, and visible again as soon as the same tooltip
-- shows anything else or hides.
local function muteReadingTooltip(tooltip, data)
	local fromReading = Map:JustRead() and type(data) == "table" and not isSecret(data)
		and data.type == Enum.TooltipDataType.MinimapMouseover
	if fromReading and not mutedTooltips[tooltip] then
		mutedTooltips[tooltip] = tooltip:GetAlpha()
		tooltip:SetAlpha(0)
	elseif not fromReading and mutedTooltips[tooltip] then
		tooltip:SetAlpha(mutedTooltips[tooltip])
		mutedTooltips[tooltip] = nil
	end
end

local function unmuteTooltip(tooltip)
	if mutedTooltips[tooltip] then
		tooltip:SetAlpha(mutedTooltips[tooltip])
		mutedTooltips[tooltip] = nil
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
	db.log = type(db.log) == "table" and db.log or {}
	-- another addon shipped under the same folder name keeps its own shape in this table
	for name, info in pairs(learned) do
		if type(info) ~= "table" or (info[1] ~= "herb" and info[1] ~= "ore") then
			learned[name] = nil
		end
	end

	if not Map.available then
		out("|cffff4444this client cannot read the minimap's blips - NodeRadar needs "
			.. "WoW Forever|r")
		return false
	end

	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.MinimapMouseover,
		addSkillLines)
	TooltipDataProcessor.AddTooltipPostCall(TooltipDataProcessor.AllTypes, muteReadingTooltip)
	GameTooltip:HookScript("OnHide", unmuteTooltip)
	-- showing a tooltip can set its alpha again, after the data was processed
	GameTooltip:HookScript("OnShow", function(tooltip)
		if mutedTooltips[tooltip] then tooltip:SetAlpha(0) end
	end)
	Candidates:Init()
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
	local name = NR.Plain(target)
	if name == "" or nodeInfo(name) then return end
	learned[name] = { kind }
	log("learned node name %s (%s)", name, kind)
	out(string.format("learned a new %s node: %s", kind == "herb" and "herb" or "ore", name))
end

-- the node a gathering cast was sent at, until it succeeds or another cast is sent
local gatherTarget
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("PLAYER_LOGOUT")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("LOADING_SCREEN_DISABLED")
loader:RegisterEvent("PLAYER_REGEN_DISABLED")
loader:RegisterEvent("PLAYER_REGEN_ENABLED")
loader:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
loader:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
loader:SetScript("OnEvent", function(_, event, ...)
	if event == "UNIT_SPELLCAST_SENT" then
		local _, target, _, spellID = ...
		learnFromCast(target, spellID)
		gatherTarget = nil
		if initialized and type(target) == "string" and not isSecret(target)
			and not isSecret(spellID) and castKind(spellID) then
			gatherTarget = NR.Plain(target)
		end
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		local _, _, spellID = ...
		-- the node is gone with the cast; waiting for a presence check would leave it shown
		if gatherTarget and not isSecret(spellID) and castKind(spellID) then
			Scanner:Gathered(gatherTarget)
			gatherTarget = nil
		end
	elseif event == "PLAYER_LOGOUT" then
		Map:Release()
	elseif event == "PLAYER_ENTERING_WORLD" or event == "LOADING_SCREEN_DISABLED" then
		settledAt = GetTime() + SETTLE_AFTER_LOADING
	elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
		-- the minimap comes back the moment combat hides the radar, not a tick later
		if initialized then
			log(event == "PLAYER_REGEN_DISABLED" and "combat starts" or "combat ends")
			updateHold()
		end
	elseif initialize() and db.autoStart then
		NR.Start()
	end
end)

-- The snapshot is built as text, which is what both consumers want: the window hands
-- it to the clipboard, and the saved copy is read as text too.
local function append(lines, format, ...)
	lines[#lines + 1] = select("#", ...) > 0 and string.format(format, ...) or format
end

local function tally(source)
	local parts = {}
	for key, value in pairs(source) do parts[#parts + 1] = key .. "=" .. tostring(value) end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function snapshotLines()
	local lines = {}
	local version = GetBuildInfo()
	append(lines, "NodeRadar %s snapshot %s, client %s.%s %s", NR.version,
		date("%Y-%m-%d %H:%M:%S"), tostring(version), tostring(build), locale)
	append(lines, "onHold=%s held=%s scanning=%s viewRadius=%s mapPixels=%.1f",
		pauseReason or "no", tostring(Map:IsHeld()),
		tostring(Scanner:IsRunning()), tostring(viewRadius), Map:HomePixels())
	append(lines, "position=%s instance=%s facing=%s",
		playerEast and string.format("%.1f/%.1f", playerEast, playerNorth) or "none",
		tostring(playerInstance), tostring(playerFacing()))
	append(lines, "skill: herbalism=%s mining=%s; tracking: herb=%s ore=%s",
		tostring(skillRank.herb), tostring(skillRank.ore),
		tostring(tracked.herb or false), tostring(tracked.ore or false))
	local stats = Scanner.stats
	append(lines, "readings=%d invalid=%d presence=%d spots=%d searches=%d "
		.. "foundAtSpawn=%d foundBySearch=%d lost=%d lastError=%s", stats.readings,
		stats.invalid, stats.presence, stats.spots, stats.searches, stats.foundAtSpawn,
		stats.foundBySearch, stats.lost, tostring(Scanner.lastError))
	append(lines, "spawn point readings=%d nodes found there=%d searched nodes near/far "
		.. "from a spawn point=%d/%d switched off=%s", stats.spawnReadings, stats.spawnHits,
		stats.searchedNearSpawn, stats.searchedFarFromSpawn, tostring(Scanner:SpawnsDistrusted()))
	append(lines, "invalid readings: %s", tally(stats.invalidWhy))
	append(lines, "readings now: %s", busyWhy and string.format("paused %.1f s, %s",
		GetTime() - busySince, busyWhy) or "allowed")
	append(lines, "last presence: %s", tally(Scanner.lastPresence))
	append(lines, "GatherMate2=%s data=%s zones=%d spawnPoints=%d",
		tostring(Candidates:Available()), tostring(Candidates.dataLoaded or false),
		Candidates.zones, Candidates.count)

	local learnedNames = {}
	for name, info in pairs(learned) do
		learnedNames[#learnedNames + 1] = name .. "=" .. info[1]
	end
	table.sort(learnedNames)
	append(lines, "learned: %s", #learnedNames > 0 and table.concat(learnedNames, ", ")
		or "none")

	local shown = {}
	for key, hit in pairs(hits) do
		if playerEast then
			local east, north = hit.east - playerEast, hit.north - playerNorth
			local spawn
			if Candidates:Available() then
				Candidates:Near(hit.east, hit.north, 50, function(candidate, dx, dy)
					local distance = math.sqrt(dx * dx + dy * dy)
					if candidate.kind == hit.kind and (not spawn or distance < spawn) then
						spawn = distance
					end
				end)
			end
			shown[#shown + 1] = string.format("  %s %s d=%.0fyd age=%.0fs seen=%.0fs ago "
				.. "spawnPoint=%s", key, hit.name, math.sqrt(east * east + north * north),
				GetTime() - hit.appearedAt, GetTime() - hit.seenAt,
				spawn and string.format("%.1fyd", spawn) or "none")
		end
	end
	table.sort(shown)
	append(lines, "")
	append(lines, "known nodes (%d):", #shown)
	for _, line in ipairs(shown) do append(lines, "%s", line) end

	append(lines, "")
	append(lines, "event log (%d, oldest first, kept across reloads):", #db.log)
	for _, line in ipairs(db.log) do append(lines, "%s", line) end
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
		local stats = Scanner.stats
		for key, value in pairs(stats) do
			stats[key] = type(value) == "table" and {} or 0
		end
		wipe(db.log)
		out("diagnostics and event log cleared")
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
