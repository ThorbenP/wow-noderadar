local ADDON, NR = ...

local Scanner = {}
NR.Scanner = Scanner

local BLANK = "Interface\\AddOns\\NodeRadar\\Blank.tga"
-- every blip shares one atlas texture; this is the modern layout, the pre-8.0 set
-- was Interface\Minimap\ObjectIcons and its cells do not line up with it
local BLIP_DEFAULT = "Interface\\Minimap\\ObjectIconsAtlas"
local ARROW_DEFAULT = "Interface\\Minimap\\MinimapArrow"
-- party and raid members are drawn from their own sheet, not the tracking atlas
local CLASS_BLIP_DEFAULT = "Interface\\Minimap\\PartyRaidBlips"

-- Everything the client draws on the minimap outside the frame hierarchy, so alpha
-- does not reach it and each needs its own texture swapped for a blank one. The
-- current value is read back where a getter exists rather than assumed: restoring a
-- guessed path would leave that arrow broken until the next reload. Where there is no
-- getter, only a default this addon is sure of makes the element eligible at all.
local MINIMAP_TEXTURES = {
	{ set = "SetBlipTexture", get = "GetBlipTexture", fallback = BLIP_DEFAULT },
	{ set = "SetPlayerTexture", get = "GetPlayerTexture", fallback = ARROW_DEFAULT },
	{ set = "SetClassBlipTexture", get = "GetClassBlipTexture", fallback = CLASS_BLIP_DEFAULT },
	{ set = "SetPOIArrowTexture", get = "GetPOIArrowTexture" },
	{ set = "SetStaticPOIArrowTexture", get = "GetStaticPOIArrowTexture" },
	{ set = "SetCorpsePOIArrowTexture", get = "GetCorpsePOIArrowTexture" },
}
-- how far down the minimap's frame tree pins are looked for
local CHILD_DEPTH = 4
-- fallback for clients without SetMouseClickEnabled
local MUTED_SCRIPTS = { "OnMouseDown", "OnMouseUp", "OnMouseWheel" }

-- Frames between moving the minimap and reading the tooltip, during which the position
-- is re-asserted. Waiting alone changes nothing, measured identical at 0, 2 and 10
-- frames; re-asserting helped in one reading out of two, which is not enough to pay
-- two frames for. One frame keeps the re-assert at half the cost.
local SETTLE_FRAMES = 1
Scanner.settleFrames = SETTLE_FRAMES

-- diagnostics: the settling time is the one number that separates "the client needs
-- time" from "the client needs an event", so it has to be changeable while playing
function Scanner:SetSettleFrames(frames)
	SETTLE_FRAMES = frames
	self.settleFrames = frames
end

local queue, cursor = {}, 1
local held
local settle = 0
-- the point waiting for its tooltip, kept as plain locals: one table per sample point
-- is one allocation per frame for the whole pass
local sampleX, sampleY, samplePayload, sampling
-- the handlers of the pass being run, so a caller reads its own samples and hears when
-- the pass ends - a dropped pass is silent otherwise
local onSample, onDone
local driver = CreateFrame("Frame")
driver:Hide()

Scanner.canSplitMouse = type(Minimap.SetMouseClickEnabled) == "function"
	and type(Minimap.SetMouseMotionEnabled) == "function"
Scanner.canHideBlips = type(Minimap.SetBlipTexture) == "function"
Scanner.pauseInCombat = false
Scanner.canHideArrow = type(Minimap.SetPlayerTexture) == "function"
Scanner.canHideClassBlips = type(Minimap.SetClassBlipTexture) == "function"

-- which of the drawn-on-top elements this client lets us blank and put back
local hideableTextures = {}
for _, texture in ipairs(MINIMAP_TEXTURES) do
	if type(Minimap[texture.set]) == "function"
		and (type(Minimap[texture.get]) == "function" or texture.fallback) then
		hideableTextures[#hideableTextures + 1] = texture
	end
end
Scanner.hideableTextureCount = #hideableTextures
Scanner.canUpdateBlips = type(Minimap.UpdateBlips) == "function"

-- The client resets the tooltip's alpha when it shows it, so hiding it once is not
-- enough; this fires at the moment of showing, before the frame is drawn.
GameTooltip:HookScript("OnShow", function(self)
	if held then self:SetAlpha(0) end
end)

-- swapping the texture alone leaves the already drawn blips on screen until the
-- client's next internal blip update, which shows up as a one-frame flash
local function refreshBlips()
	if Minimap.UpdateBlips then Minimap:UpdateBlips() end
end

-- GatherMate re-enables the mouse on its pins on every minimap update, so switching
-- it off for the duration of a pass does not hold. The tooltip's owner does: the
-- client owns a blip tooltip through the minimap, an addon pin owns its own.
local function ownerIsMinimap()
	local owner = GameTooltip:GetOwner()
	return owner == nil or owner == Minimap or owner == UIParent
end

-- a real tracking blip is drawn by the client on the minimap itself, so anything
-- whose tooltip belongs to a frame on top of it is an addon pin, not a node
local function focusIsMinimap()
	if GetMouseFoci then
		local foci = GetMouseFoci()
		return not foci or not foci[1] or foci[1] == Minimap
	end
	if GetMouseFocus then
		local focus = GetMouseFocus()
		return not focus or focus == Minimap
	end
	return true
end

-- the minimap tooltip lists everything under the cursor, so every line matters:
-- a node can sit below a vendor or another blip
-- names whatever is holding the tooltip instead of the minimap, so a pin covering the
-- spot being probed shows up as a count rather than as a sample that read empty
local function stolenBy()
	local owner = GameTooltip:GetOwner()
	if owner and owner ~= Minimap and owner ~= UIParent then
		return (owner.GetName and owner:GetName()) or "unnamed frame"
	end
	local focus = GetMouseFoci and GetMouseFoci() or nil
	focus = focus and focus[1] or (GetMouseFocus and GetMouseFocus())
	if focus and focus ~= Minimap then
		return (focus.GetName and focus:GetName()) or "unnamed frame"
	end
	return "unknown"
end

-- Returns the tooltip text, or nil plus the frame that took it: a tooltip owned by an
-- addon pin is not proof of a node, but it is not "nothing there" either.
local function tooltipText()
	if not GameTooltip:IsShown() then return nil end
	if not ownerIsMinimap() or not focusIsMinimap() then return nil, stolenBy() end

	local lines
	for index = 1, GameTooltip:NumLines() do
		local left = _G["GameTooltipTextLeft" .. index]
		local text = left and left:GetText()
		if text and text ~= "" then
			lines = lines and (lines .. "\n" .. text) or text
		end
	end
	return lines
end

-- The client resolves mouse focus once per frame, so the minimap has to be
-- dragged under the cursor one sample point at a time.
-- Addon pins are mouse-enabled child frames sitting exactly where a node is only
-- *expected*, so their tooltips would read as confirmed nodes and they leave the hit
-- test for the pass. A frame may also opt out of inherited alpha, which is how a pin
-- stays visible on a hidden minimap; clearing that covers pins from addons this one
-- has never heard of, which is the only way to stay ahead of what people install.
local function hideChildren(frame, depth)
	if depth > CHILD_DEPTH then return end

	local children = { frame:GetChildren() }
	for index = 1, #children do
		local child = children[index]
		if child and child:IsShown() then
			if child.IsMouseEnabled and child:IsMouseEnabled() then
				held.mouseChildren[#held.mouseChildren + 1] = child
				child:EnableMouse(false)
			end
			if child.IsIgnoringParentAlpha and child:IsIgnoringParentAlpha() then
				held.alphaChildren[#held.alphaChildren + 1] = child
				child:SetIgnoreParentAlpha(false)
			end
			hideChildren(child, depth + 1)
		end
	end

	-- textures and font strings carry the same opt-out
	local regions = { frame:GetRegions() }
	for index = 1, #regions do
		local region = regions[index]
		if region and region.IsIgnoringParentAlpha and region:IsIgnoringParentAlpha() then
			held.alphaChildren[#held.alphaChildren + 1] = region
			region:SetIgnoreParentAlpha(false)
		end
	end
end

local function hold()
	if held then return true end
	if Minimap:GetNumPoints() == 0 then return false end

	held = {
		anchor = { Minimap:GetPoint(1) },
		alpha = Minimap:GetAlpha(),
		strata = Minimap:GetFrameStrata(),
		tooltipAlpha = GameTooltip:GetAlpha(),
		scripts = {},
	}
	GameTooltip:SetAlpha(0)

	-- clicks would open the tracking menu or ping while the minimap sits under the
	-- cursor; hover has to survive because that is what produces blip tooltips
	if Scanner.canSplitMouse then
		Minimap:SetMouseClickEnabled(false)
		Minimap:SetMouseMotionEnabled(true)
	else
		for _, script in ipairs(MUTED_SCRIPTS) do
			held.scripts[script] = Minimap:GetScript(script)
			Minimap:SetScript(script, nil)
		end
	end

	held.mouseChildren, held.alphaChildren = {}, {}
	hideChildren(Minimap, 1)

	-- alpha hides the map image and everything under it in the frame tree; what the
	-- client draws on top has to be blanked one texture at a time
	Minimap:SetAlpha(0)
	Minimap:SetFrameStrata("TOOLTIP")
	held.textures = {}
	for _, texture in ipairs(hideableTextures) do
		local getter = Minimap[texture.get]
		held.textures[texture.set] = (getter and getter(Minimap)) or texture.fallback
		Minimap[texture.set](Minimap, BLANK)
	end
	refreshBlips()
	return true
end

local function release()
	if not held then return end

	Minimap:ClearAllPoints()
	Minimap:SetPoint(unpack(held.anchor))
	Minimap:SetAlpha(held.alpha)
	Minimap:SetFrameStrata(held.strata)

	if Scanner.canSplitMouse then
		Minimap:SetMouseClickEnabled(true)
		Minimap:SetMouseMotionEnabled(true)
	else
		for script, handler in pairs(held.scripts) do
			Minimap:SetScript(script, handler)
		end
	end

	for _, child in ipairs(held.mouseChildren) do
		child:EnableMouse(true)
	end
	for _, child in ipairs(held.alphaChildren) do
		child:SetIgnoreParentAlpha(true)
	end

	for setter, value in pairs(held.textures) do
		Minimap[setter](Minimap, value)
	end
	refreshBlips()

	local tooltipAlpha = held.tooltipAlpha
	held = nil
	GameTooltip:Hide()
	GameTooltip:SetAlpha(tooltipAlpha)
end

-- A held mouse button binds the client's mouse focus, and a bound focus is what makes
-- scanning impossible - not which button it is. Mouselook, entered by either button,
-- resolves no focus at all: measured, 22 samples produced 0 tooltips against a 24%
-- baseline. A button held on a frame keeps that frame focused however far the minimap
-- is dragged underneath. Both wait past a grace, because clicking a target or a node
-- is a button press as well.
local CLICK_GRACE = 0.25
local mouseSince

local function mouseBound()
	if IsMouselooking and IsMouselooking() then return "turning the camera" end
	if IsMouseButtonDown and IsMouseButtonDown() then return "a mouse button is held" end
end

-- Combat is a setting rather than a technical limit: scanning works in a fight, it
-- just takes the minimap and the mouse focus while it runs.
local function blocked()
	local bound = mouseBound()
	if bound then
		mouseSince = mouseSince or GetTime()
	else
		mouseSince = nil
	end

	if UnitIsDeadOrGhost("player") then
		return true, "dead"
	end
	if mouseSince and GetTime() - mouseSince > CLICK_GRACE then
		return true, bound
	end
	if Scanner.pauseInCombat and UnitAffectingCombat("player") then
		return true, "in combat"
	end
	if SpellIsTargeting() then
		return true, "a spell is waiting for a target"
	end
	if not Minimap:IsVisible() then
		return true, "the minimap is hidden"
	end
	return false
end

-- ends the pass and tells its owner whether every point was read
local function finish(completed)
	release()
	queue, cursor, sampling, settle = {}, 1, false, 0
	driver:Hide()

	local done = onDone
	onSample, onDone = nil, nil
	if done then done(completed) end
end

driver:SetScript("OnUpdate", function()
	local scale = Minimap:GetEffectiveScale()
	local cursorX, cursorY = GetCursorPosition()
	cursorX, cursorY = cursorX / scale, cursorY / scale

	if sampling then
		if settle > 0 then
			settle = settle - 1
			-- Re-assert the position rather than only waiting. Waiting alone changed
			-- nothing across 0, 2 and 10 frames, which says the client does not catch
			-- up on time; if it instead follows the minimap per assignment, repeating
			-- the same move is what lets the blips converge on it.
			Minimap:ClearAllPoints()
			Minimap:SetPoint("CENTER", UIParent, "BOTTOMLEFT", sampleX, sampleY)
			return
		end
		sampling = false
		local text, stolen = tooltipText()
		-- Where the minimap actually sits, not where it was told to go. Another addon
		-- can move it back in its own frame update, and then the sample describes a
		-- point nobody aimed at - which no amount of waiting would fix.
		local mapX, mapY = Minimap:GetCenter()
		Scanner.lastPlaceError = mapX and math.max(math.abs(mapX - sampleX),
			math.abs(mapY - sampleY)) or 0
		onSample(samplePayload, text, cursorX - (mapX or sampleX),
			cursorY - (mapY or sampleY), stolen)
		GameTooltip:Hide()
	end

	if cursor > #queue then
		finish(true)
		return
	end

	-- queued offsets go stale while the scan waits, so drop the pass and let the
	-- caller re-aim once scanning is possible again
	if blocked() or not hold() then
		finish(false)
		return
	end

	GameTooltip:SetAlpha(0)

	local point = queue[cursor]
	cursor = cursor + 1

	local x, y = cursorX - point.ox, cursorY - point.oy
	Minimap:ClearAllPoints()
	Minimap:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
	-- Measured: the client does not carry its blips along in the same frame the minimap
	-- moves, so the tooltip read next frame belongs to where they were before. Forcing
	-- the update here is what makes a sample describe the point it was aimed at.
	refreshBlips()
	sampleX, sampleY, samplePayload, sampling = x, y, point.payload, true
	settle = SETTLE_FRAMES
end)

-- diagnostics: which frame produced the tooltip that was just read
function Scanner:LastOwner()
	local owner = GameTooltip:GetOwner()
	if not owner then return "none" end
	if owner == Minimap then return "Minimap" end
	return owner:GetName() or "unnamed frame"
end

function Scanner:IsBusy()
	return driver:IsShown()
end

-- returns whether scanning is impossible right now, and why
function Scanner:IsBlocked()
	return blocked()
end

function Scanner:Restore()
	release()
	-- the safety net, used when a pass left nothing to restore from: only textures
	-- whose default is known can be put back at all
	for _, texture in ipairs(hideableTextures) do
		if texture.fallback then
			Minimap[texture.set](Minimap, texture.fallback)
		end
	end
	refreshBlips()
end

-- Each point carries an opaque payload handed straight back to sampler, so a caller
-- names its points however it likes. done(completed) fires once, on the pass ending
-- or being dropped.
function Scanner:Submit(points, sampler, done)
	if #points == 0 then return end
	queue, cursor, sampling, settle = points, 1, false, 0
	onSample, onDone = sampler, done
	driver:Show()
end

function Scanner:Abort()
	if not driver:IsShown() then return end
	finish(false)
end
