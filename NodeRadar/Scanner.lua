local ADDON, NR = ...

local Scanner = {}
NR.Scanner = Scanner

-- Measured on Forever 1.60.1.70450: Minimap:UpdateMouseoverAtPoint takes a point in
-- GetCursorPosition's space and moves the minimap's mouseover there within the same
-- frame; with SetUsingSoftCursor(true) it counts wherever the real cursor is, and
-- C_TooltipInfo.GetMinimapMouseover() then names every blip under that point. A
-- whole-map sweep reads synchronously in a few milliseconds and never touches the
-- minimap's position, alpha or the player's own hover.

-- A gathering node's hit area is a square of fixed size on screen, whatever the
-- minimap's width or zoom: measured 25 units at scale 0.640 and 22.5 units at 0.704.
local NODE_PX = 16
-- The rest scale with it, as fractions of one node's square: the grid step never
-- passes over one, the slack absorbs the drift between the player's position and the
-- minimap within a frame, and an edge is walked in strides then halved three times.
local STEP_SHARE = 0.56
local NODE_SLACK_SHARE = 0.12
local CLAIM_SLACK_SHARE = 0.16
local STRIDE_SHARE = 0.16
local HALVINGS = 3
-- nodes measured out of one patch of touching cells before the rest is left alone
local PER_PATCH = 4

local function isSecret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end
NR.IsSecret = isSecret

Scanner.available = type(Minimap.UpdateMouseoverAtPoint) == "function"
	and type(Minimap.SetUsingSoftCursor) == "function"
	and C_TooltipInfo ~= nil and type(C_TooltipInfo.GetMinimapMouseover) == "function"

-- The client prefixes a node above or below the player with a height arrow texture
-- and colours quest lines; a node has to read the same name either way.
function Scanner.Plain(text)
	text = text:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|H.-|h(.-)|h", "%1")
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|n", " ")
	return strtrim(text)
end

local geometry
local reads = 0
-- this sweep's sizes in map units, from the minimap's scale
local node, step, nodeSlack, claimSlack, stride, reach

-- Every name under a point. A secret answer means the client is withholding the
-- minimap right now, so it aborts the whole sweep rather than reading as empty.
local function namesAt(x, y)
	reads = reads + 1
	Minimap:UpdateMouseoverAtPoint((geometry.cx + x) * geometry.scale,
		(geometry.cy + y) * geometry.scale)
	local data = C_TooltipInfo.GetMinimapMouseover()
	if data == nil then return nil end
	if isSecret(data) or type(data) ~= "table" or isSecret(data.lines) then
		error("the minimap mouseover reads secret", 0)
	end
	if type(data.lines) ~= "table" then return nil end

	local names
	for _, line in ipairs(data.lines) do
		local text = type(line) == "table" and line.leftText or nil
		if isSecret(text) then error("a minimap mouseover line reads secret", 0) end
		if type(text) == "string" then
			for row in text:gmatch("[^\n]+") do
				local name = Scanner.Plain(row)
				if name ~= "" then
					names = names or {}
					names[#names + 1] = name
				end
			end
		end
	end
	return names
end

local function readsName(x, y, name)
	local names = namesAt(x, y)
	if not names then return false end
	for _, found in ipairs(names) do
		if found == name then return true end
	end
	return false
end

-- Distance from (x, y) along (dx, dy) to where the name stops, or nil when it never
-- stops within reach.
local function edge(x, y, dx, dy, name)
	local inside, outside = 0, nil
	for distance = stride, reach, stride do
		if not readsName(x + dx * distance, y + dy * distance, name) then
			outside = distance
			break
		end
		inside = distance
	end
	if not outside then return nil end
	for _ = 1, HALVINGS do
		local middle = (inside + outside) / 2
		if readsName(x + dx * middle, y + dy * middle, name) then
			inside = middle
		else
			outside = middle
		end
	end
	return (inside + outside) / 2
end

-- Centre of one axis of the square containing the seed. A span wider than one square
-- is two nodes overlapping; the seed belongs to the one whose edge is nearer.
local function axisCentre(seed, low, high)
	local span = low + high
	if span > node + nodeSlack then
		if low <= high then return seed - low + node / 2 end
		return seed + high - node / 2
	end
	return seed + (high - low) / 2
end

local function measure(seed, name)
	local right = edge(seed.x, seed.y, 1, 0, name)
	local left = right and edge(seed.x, seed.y, -1, 0, name)
	local up = left and edge(seed.x, seed.y, 0, 1, name)
	local down = up and edge(seed.x, seed.y, 0, -1, name)
	if not down then return nil end

	local x = axisCentre(seed.x, left, right)
	local y = axisCentre(seed.y, down, up)
	if not readsName(x, y, name) then return nil end
	return x, y
end

local function explains(found, cell)
	local half = node / 2 + claimSlack
	return math.abs(found.x - cell.x) <= half and math.abs(found.y - cell.y) <= half
end

-- Touching cells (eight neighbours) of one name form a patch.
local function patches(cells)
	local list, seen = {}, {}
	for key, cell in pairs(cells) do
		if not seen[key] then
			local members, stack = {}, { cell }
			seen[key] = true
			while #stack > 0 do
				local current = table.remove(stack)
				members[#members + 1] = current
				for dc = -1, 1 do
					for dr = -1, 1 do
						local neighbourKey = (current.col + dc) .. ":" .. (current.row + dr)
						local neighbour = cells[neighbourKey]
						if neighbour and not seen[neighbourKey] then
							seen[neighbourKey] = true
							stack[#stack + 1] = neighbour
						end
					end
				end
			end
			list[#list + 1] = members
		end
	end
	return list
end

-- Cells no node explains, and the one nearest their middle as the next seed.
local function unexplained(cells, nodes)
	local left = {}
	for _, cell in ipairs(cells) do
		local claimed = false
		for _, found in ipairs(nodes) do
			if explains(found, cell) then
				claimed = true
				break
			end
		end
		if not claimed then left[#left + 1] = cell end
	end
	return left
end

local function middleCell(cells)
	local sumX, sumY = 0, 0
	for _, cell in ipairs(cells) do
		sumX, sumY = sumX + cell.x, sumY + cell.y
	end
	local mx, my = sumX / #cells, sumY / #cells
	local best, bestDistance
	for index, cell in ipairs(cells) do
		local distance = (cell.x - mx) ^ 2 + (cell.y - my) ^ 2
		if not bestDistance or distance < bestDistance then
			best, bestDistance = index, distance
		end
	end
	return best
end

local function readGeometry()
	local left, bottom, width, height = Minimap:GetRect()
	local scale = Minimap:GetEffectiveScale()
	for _, value in ipairs({ left, bottom, width, height, scale }) do
		if type(value) ~= "number" or isSecret(value) then return nil end
	end
	if width <= 0 or height <= 0 then return nil end
	return { cx = left + width / 2, cy = bottom + height / 2, half = width / 2,
		scale = scale, square = GetMinimapShape and GetMinimapShape() == "SQUARE" }
end

-- Leaves the mouseover where the player's cursor is when it is on the minimap, so
-- their own hover tooltip carries on, and off the map otherwise.
local function putBack()
	local x, y = GetCursorPosition()
	local over = Minimap:IsMouseOver()
	if isSecret(x) or isSecret(y) or isSecret(over) or not over then
		x = (geometry.cx - geometry.half * 4) * geometry.scale
		y = (geometry.cy - geometry.half * 4) * geometry.scale
	end
	Minimap:UpdateMouseoverAtPoint(x, y)
end

local function sweep(isNode, known, result)
	local half = geometry.half
	local radius = (half + step / 2) ^ 2
	local cells = {}
	local row = 0
	for y = -half + step / 2, half, step do
		local col = 0
		for x = -half + step / 2, half, step do
			if geometry.square or x * x + y * y <= radius then
				local names = namesAt(x, y)
				for _, name in ipairs(names or {}) do
					result.names[name] = (result.names[name] or 0) + 1
					if isNode(name) then
						cells[name] = cells[name] or {}
						cells[name][col .. ":" .. row] = { x = x, y = y, col = col, row = row }
					end
				end
			end
			col = col + 1
		end
		row = row + 1
	end

	for name, byKey in pairs(cells) do
		local mine = {}
		for _, candidate in ipairs(known) do
			if candidate.name == name then mine[#mine + 1] = candidate end
		end

		for _, patch in ipairs(patches(byKey)) do
			for _, candidate in ipairs(mine) do
				if not result.present[candidate.ref] then
					for _, cell in ipairs(patch) do
						if explains(candidate, cell) then
							result.present[candidate.ref] = true
							break
						end
					end
				end
			end

			local measured = {}
			local left = unexplained(patch, mine)
			while #left > 0 and #measured < PER_PATCH do
				local seedIndex = middleCell(left)
				local x, y = measure(left[seedIndex], name)
				if x then
					local found = { name = name, x = x, y = y }
					measured[#measured + 1] = found
					result.found[#result.found + 1] = found
					mine[#mine + 1] = found
					left = unexplained(left, { found })
				else
					result.unmeasured = result.unmeasured + 1
					table.remove(left, seedIndex)
				end
			end
		end
	end
end

-- One look at the whole minimap. isNode(name) says which names are worth locating;
-- known holds nodes already located, as { name, x, y, ref } in map units from the
-- centre, and is only confirmed, never measured again. Returns { present = { [ref] =
-- true }, found = { { name, x, y } }, names = { [name] = cells }, reads, ms,
-- unmeasured, half } or nil and why. The soft cursor is switched off on every path.
function Scanner:Sweep(isNode, known)
	geometry = readGeometry()
	if not geometry then return nil, "the minimap's geometry is unreadable" end
	node = NODE_PX / geometry.scale
	step, nodeSlack = node * STEP_SHARE, node * NODE_SLACK_SHARE
	claimSlack, stride = node * CLAIM_SLACK_SHARE, node * STRIDE_SHARE
	-- two squares side by side; a name reading further than that is a chain of nodes
	reach = node * 2 + stride

	local result = { present = {}, found = {}, names = {}, unmeasured = 0,
		half = geometry.half }
	reads = 0
	local started = debugprofilestop()
	Minimap:SetUsingSoftCursor(true)
	local ok, err = pcall(sweep, isNode, known, result)
	pcall(putBack)
	Minimap:SetUsingSoftCursor(false)
	if not ok then return nil, tostring(err) end

	result.reads = reads
	result.ms = debugprofilestop() - started
	return result
end
