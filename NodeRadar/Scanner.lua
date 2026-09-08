local ADDON, NR = ...

local Scanner = {}
NR.Scanner = Scanner

local BLANK = "Interface\\AddOns\\NodeRadar\\Blank.tga"
-- every blip shares one atlas texture; this is the modern layout, the pre-8.0 set
-- was Interface\Minimap\ObjectIcons and its cells do not line up with it
local BLIP_DEFAULT = "Interface\\Minimap\\ObjectIconsAtlas"
local ARROW_DEFAULT = "Interface\\Minimap\\MinimapArrow"
-- fallback for clients without SetMouseClickEnabled
local MUTED_SCRIPTS = { "OnMouseDown", "OnMouseUp", "OnMouseWheel" }

local queue, cursor = {}, 1
local pending, held
local driver = CreateFrame("Frame")
driver:Hide()

Scanner.canSplitMouse = type(Minimap.SetMouseClickEnabled) == "function"
	and type(Minimap.SetMouseMotionEnabled) == "function"
Scanner.canHideBlips = type(Minimap.SetBlipTexture) == "function"
Scanner.canHideArrow = type(Minimap.SetPlayerTexture) == "function"

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
local function tooltipText()
	if not GameTooltip:IsShown() then return nil end
	if not focusIsMinimap() then return nil end

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

	-- Addon pins (GatherMate, Questie) are mouse-enabled child frames sitting exactly
	-- where a node is only *expected*. Their tooltips would read as confirmed nodes,
	-- so they leave the hit test for the duration of the scan.
	-- the child list is fetched once: rebuilding it per iteration turns a minimap
	-- crowded with addon pins into a visible frame stall
	held.mouseChildren = {}
	local children = { Minimap:GetChildren() }
	for index = 1, #children do
		local child = children[index]
		if child and child.IsMouseEnabled and child:IsMouseEnabled() then
			held.mouseChildren[#held.mouseChildren + 1] = child
			child:EnableMouse(false)
		end
	end

	-- alpha hides the map image only; blips and the arrow render on top of it
	Minimap:SetAlpha(0)
	Minimap:SetFrameStrata("TOOLTIP")
	if Scanner.canHideBlips then Minimap:SetBlipTexture(BLANK) end
	if Scanner.canHideArrow then Minimap:SetPlayerTexture(BLANK) end
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

	if Scanner.canHideBlips then Minimap:SetBlipTexture(BLIP_DEFAULT) end
	if Scanner.canHideArrow then Minimap:SetPlayerTexture(ARROW_DEFAULT) end
	refreshBlips()

	local tooltipAlpha = held.tooltipAlpha
	held = nil
	GameTooltip:Hide()
	GameTooltip:SetAlpha(tooltipAlpha)
end

-- Measured: during mouselook the client resolves no mouse focus at all - 22 samples
-- produced 0 tooltips against a 24% baseline. Scanning is impossible while a button is
-- held, and the caller pauses hit expiry for exactly that reason.
-- Combat is a deliberate choice rather than a technical limit: taking the minimap and
-- the mouse focus away mid fight is worse than a stale radar.
local function blocked()
	return IsMouseButtonDown()
		or UnitAffectingCombat("player")
		or SpellIsTargeting()
		or not Minimap:IsVisible()
end

driver:SetScript("OnUpdate", function()
	if pending then
		if Scanner.onSample then
			local scale = Minimap:GetEffectiveScale()
			local cx, cy = GetCursorPosition()
			Scanner.onSample(pending.tag, tooltipText(), cx / scale - pending.x, cy / scale - pending.y,
				pending.ring)
		end
		GameTooltip:Hide()
		pending = nil
	end

	if cursor > #queue then
		release()
		driver:Hide()
		queue, cursor = {}, 1
		return
	end

	-- queued offsets go stale while the scan waits, so drop the pass and let the
	-- caller re-aim once scanning is possible again
	if blocked() or not hold() then
		release()
		queue, cursor, pending = {}, 1, nil
		driver:Hide()
		return
	end

	GameTooltip:SetAlpha(0)

	local point = queue[cursor]
	cursor = cursor + 1

	local scale = Minimap:GetEffectiveScale()
	local cx, cy = GetCursorPosition()
	local x, y = cx / scale - point.ox, cy / scale - point.oy
	Minimap:ClearAllPoints()
	Minimap:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
	pending = { x = x, y = y, tag = point.tag, ring = point.ring }
end)

function Scanner:IsBusy()
	return driver:IsShown()
end

function Scanner:IsBlocked()
	return blocked()
end

function Scanner:Restore()
	release()
	if Scanner.canHideBlips then Minimap:SetBlipTexture(BLIP_DEFAULT) end
	if Scanner.canHideArrow then Minimap:SetPlayerTexture(ARROW_DEFAULT) end
	refreshBlips()
end

function Scanner:Submit(points)
	if #points == 0 then return end
	queue, cursor, pending = points, 1, nil
	driver:Show()
end

function Scanner:Abort()
	queue, cursor, pending = {}, 1, nil
	release()
	driver:Hide()
end
