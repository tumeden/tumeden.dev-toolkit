-- // This is still work in progress.
-- /////////////////////////////////////////// GetInfo Function
function widget:GetInfo()
  return {
    name      = "RezBots - AGENT",
    desc      = "RezBots Resurrect, Collect resources, and heal injured units. alt+v to open UI",
    author    = "Tumeden",
    date      = "2025",
    version   = "v1.27",
    license   = "GNU GPL, v2 or later",
    layer     = 0,
    enabled   = true
  }
end

local widgetVersion = widget:GetInfo().version



-- /////////////////////////////////////////// ---- /////////////////////////////////////////// ---- /////////////////////////////////////////// 
-- /////////////////////////////////////////// ---                Main Code                     ---- /////////////////////////////////////////// 
-- /////////////////////////////////////////// ----  Do not edit things past this line          ---- ///////////////////////////////////////////



-- /////////////////////////////////////////// Important things :))
local widgetEnabled = true
local isLoggingEnabled = false
local unitsMovingToSafety = {}
local resurrectingUnits = {}  -- table to keep track of units currently resurrecting
local unitsToCollect = {}  -- table to keep track of units and their collection state
local healingUnits = {}  -- table to keep track of healing units
local unitLastPosition = {} -- Track the last position of each unit
local targetedFeatures = {}  -- Table to keep track of targeted features
local healingTargets = {}  -- Track which units are being healed and by how many healers
local unreachableFeatures = {}  -- [featureID] = true for features we know are unreachable
local UNREACHABLE_EXPIRE_FRAMES = 3000  -- Number of frames to keep marking something as unreachable (e.g., ~2 min)
local maxUnitsPerFeature = 4  -- Maximum units allowed to target the same feature
local maxHealersPerUnit = 4  -- Maximum number of healers per unit
local healResurrectRadius = 1000 -- Set your desired heal/resurrect radius here  (default 1000)
local reclaimRadius = 1500 -- Set your desired reclaim radius here (any number works, 4000 is about half a large map)
local enemyAvoidanceRadius = 675  -- Adjust this value as needed -- Define a safe distance for enemy avoidance
local IDLE_TIMEOUT_FRAMES = 15 * 30 -- 30 seconds at 30fps; adjust as needed
local lastIdleFrame = {} -- Track when each unit became idle
local lastFleePosition = {} -- Track last flee position for each unit
local FLEE_REORDER_DISTANCE = 100 -- Minimum distance to issue new flee order

-- Engine call optimizations
-- =========================
local armRectrDefID
local corNecroDefID
local legRezbotDefID -- Added for Legion RezBot
local spGetUnitDefID = Spring.GetUnitDefID
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetUnitPosition = Spring.GetUnitPosition
local spGetFeaturesInCylinder = Spring.GetFeaturesInCylinder
local spGetFeatureDefID = Spring.GetFeatureDefID
local spGetMyTeamID = Spring.GetMyTeamID
local spGetFeaturePosition = Spring.GetFeaturePosition
local spGetGameFrame = Spring.GetGameFrame
local spGetGroundHeight = Spring.GetGroundHeight
local spGetUnitSeparation = Spring.GetUnitSeparation
local GetUnitIsCloaked = Spring.GetUnitIsCloaked -- Added for cloaked check

-- Command Definitions
local CMD_MOVE = CMD.MOVE
local CMD_RESURRECT = CMD.RESURRECT
local CMD_RECLAIM = CMD.RECLAIM

-- Mathematical and Table Functions
local sqrt = math.sqrt
local pow = math.pow
local mathMax = math.max
local mathMin = math.min
local mathAbs = math.abs
local mathPi = math.pi
local mathCos = math.cos
local mathSin = math.sin
local mathFloor = math.floor
local tblInsert = table.insert
local tblRemove = table.remove
local tblSort = table.sort
local strFormat = string.format
local strSub = string.sub

-- Utility functions
local isMyResbot = isMyResbot
local isBuilding = isBuilding
local findNearestEnemy = findNearestEnemy
local getFeatureResources = getFeatureResources

-- OpenGL functions
local glVertex = gl.Vertex
local glBeginEnd = gl.BeginEnd


-- /////////////////////////////////////////// scvlog Function
-- CTRL + L to enable Logging
-- This is for development purposes.
local function scvlog(...)
  if isLoggingEnabled then
      Spring.Echo(...)
  end
end
--


-- /////////////////////////////////////////// -- /////////////////////////////////////////// -- /////////////////////////////////////////// -- 
-- /////////////////////////////////////////// -- /////////////////////////////////////////// -- /////////////////////////////////////////// -- 
-- ////////////////////////////////////////- UI CODE -////////////////////////////////////// -- /////////////////////////////////////////// -- 
-- /////////////////////////////////////////// -- /////////////////////////////////////////// -- /////////////////////////////////////////// -- 
-- /////////////////////////////////////////// -- /////////////////////////////////////////// -- /////////////////////////////////////////// -- 



-- UI Variables and Constants
local showUI = false
local UI = {
    width = 340,
    height = 540,
    backgroundColor = {0.1, 0.1, 0.1, 0.9},
    textColor = {1, 1, 1, 1},
    sectionHeaderColor = {0.8, 0.9, 1, 1},
    sectionBgColor = {0.15, 0.15, 0.18, 0.7},
    checkboxColor = {0.3, 0.7, 0.3, 0.9},
    sliderColor = {0.3, 0.7, 0.3, 0.9},
    sliderKnobColor = {0.4, 0.8, 0.4, 1.0},
    sliderKnobSize = 12,
    padding = 24,
    spacing = 35,
    sectionSpacing = 44,
    sectionHeaderSize = 16
}

-- Movable UI state
local uiPosX = 0.5 -- normalized (0 = left, 1 = right)
local uiPosY = 0.7 -- normalized (0 = bottom, 1 = top)
local isDraggingUI = false
local dragOffsetX, dragOffsetY = 0, 0

-- Track which slider is being dragged
local activeDragSlider = nil
local activeDragName = nil

local checkboxes = {
    excludeBuildings = { state = false, label = "Exclude buildings from Resurrection" },
    healing = { state = false, label = "Healing" },
    collecting = { state = false, label = "Resource Collection" },
    resurrecting = { state = false, label = "Resurrect" },
    healCloaked = { state = false, label = "Heal Cloaked Units" } -- New toggle, now defaults to false
}

local sliders = {
    healResurrectRadius = { value = healResurrectRadius, min = 0, max = 2000, label = "Heal/Resurrect Radius" },
    reclaimRadius = { value = reclaimRadius, min = 0, max = 5000, label = "Resource Collection Radius" },
    enemyAvoidanceRadius = { value = enemyAvoidanceRadius, min = 0, max = 2000, label = "Maintain Safe Distance" }
}

-- Helper function to draw circular knob
local function drawCircle(x, y, radius, color)
    gl.Color(unpack(color))
    gl.BeginEnd(GL.TRIANGLE_FAN, function()
        gl.Vertex(x, y)
        for i = 0, 30 do
            local angle = (i / 30) * 2 * math.pi
            gl.Vertex(x + math.cos(angle) * radius, 
                     y + math.sin(angle) * radius)
        end
    end)
end

function widget:Initialize()
    if Spring.GetSpectatingState() then
        Spring.Echo("You are a spectator. Widget is disabled.")
        widgetHandler:RemoveWidget(self)
        return
    end

    -- Load persistent UI state
    healResurrectRadius = Spring.GetConfigInt("scv_healResurrectRadius", healResurrectRadius)
    reclaimRadius = Spring.GetConfigInt("scv_reclaimRadius", reclaimRadius)
    enemyAvoidanceRadius = Spring.GetConfigInt("scv_enemyAvoidanceRadius", enemyAvoidanceRadius)
    
    -- Load UI position (normalized)
    uiPosX = Spring.GetConfigFloat("scv_uiPosX", uiPosX)
    uiPosY = Spring.GetConfigFloat("scv_uiPosY", uiPosY)
    
    -- Update slider values
    sliders.healResurrectRadius.value = healResurrectRadius
    sliders.reclaimRadius.value = reclaimRadius
    sliders.enemyAvoidanceRadius.value = enemyAvoidanceRadius
    
    -- Load checkbox states
    for k, v in pairs(checkboxes) do
        v.state = Spring.GetConfigInt("scv_checkbox_"..k, v.state and 1 or 0) == 1
    end

    if UnitDefNames then
        if UnitDefNames.armrectr then armRectrDefID = UnitDefNames.armrectr.id end
        if UnitDefNames.cornecro then corNecroDefID = UnitDefNames.cornecro.id end
        if UnitDefNames.legrezbot then legRezbotDefID = UnitDefNames.legrezbot.id end

        if not (armRectrDefID or corNecroDefID or legRezbotDefID) then
            Spring.Echo("No supported RezBot UnitDefIDs could be determined")
            widgetHandler:RemoveWidget()
            return
        end
    else
        Spring.Echo("UnitDefNames table not found")
        widgetHandler:RemoveWidget()
        return
    end
end

function widget:DrawScreen()
    if not showUI then return end
    
    local vsx, vsy = Spring.GetViewGeometry()
    local x = math.floor(uiPosX * vsx - UI.width / 2)
    local y = math.floor(uiPosY * vsy + UI.height / 2)
    
    -- Draw background
    gl.Color(UI.backgroundColor[1], UI.backgroundColor[2], UI.backgroundColor[3], UI.backgroundColor[4])
    gl.Rect(x, y - UI.height, x + UI.width, y)
    
    -- Draw title bar
    gl.Color(0.18, 0.18, 0.18, 1)
    gl.Rect(x, y - 30, x + UI.width, y)
    gl.Color(1, 1, 1, 1)
    gl.Text("RezBot Settings (" .. widgetVersion .. ")", x + UI.width/2 - 90, y - 30 + 8, 14, "o")
    
    local cy = y - 60
    local sectionPad = 16
    local sectionGap = 16
    local headerH = UI.sectionHeaderSize + 8
    local boxH = 16
    local sliderH = 26
    local spacing = UI.spacing
    local sectionW = UI.width - 32
    local sectionX = x + (UI.width - sectionW) / 2
    -- Section: Healing
    local healingControls = {"healing", "healCloaked"}
    local healingSlider = true
    local healingSectionHeight = headerH + #healingControls * spacing + (healingSlider and sliderH or 0) + sectionPad * 2
    local healingTop = cy + sectionPad
    local healingBot = cy - healingSectionHeight + sectionPad
    gl.Color(UI.sectionBgColor[1], UI.sectionBgColor[2], UI.sectionBgColor[3], 0.55)
    gl.Rect(sectionX, healingBot, sectionX + sectionW, healingTop)
    gl.Color(UI.sectionHeaderColor[1], UI.sectionHeaderColor[2], UI.sectionHeaderColor[3], UI.sectionHeaderColor[4])
    gl.Text("Healing", x + UI.width/2 - 40, cy - 2, UI.sectionHeaderSize, "o")
    cy = cy - headerH
    for _, name in ipairs(healingControls) do
        local box = checkboxes[name]
        local cx = x + UI.padding
        gl.Color(0.2, 0.2, 0.2, 0.8)
        gl.Rect(cx, cy, cx + boxH, cy + boxH)
        if box.state then
            gl.Color(0.3, 0.7, 0.3, 0.9)
            gl.Rect(cx + 2, cy + 2, cx + boxH - 2, cy + boxH - 2)
        end
        gl.Color(1, 1, 1, 1)
        gl.Text(box.label, cx + 24, cy + 2, 12)
        cy = cy - spacing
    end
    -- Healing slider
    local slider = sliders.healResurrectRadius
    local sliderX = x + UI.padding
    gl.Color(1, 1, 1, 1)
    gl.Text(slider.label, sliderX, cy + 20, 12)
    gl.Color(0.2, 0.2, 0.2, 0.8)
    gl.Rect(sliderX, cy, sliderX + 200, cy + 6)
    local fillWidth = 200 * (slider.value - slider.min) / (slider.max - slider.min)
    gl.Color(0.3, 0.7, 0.3, 0.9)
    gl.Rect(sliderX, cy, sliderX + fillWidth, cy + 6)
    local knobX = sliderX + fillWidth
    local knobY = cy + 3
    drawCircle(knobX + 1, knobY - 1, UI.sliderKnobSize/2 + 1, {0, 0, 0, 0.3})
    drawCircle(knobX, knobY, UI.sliderKnobSize/2, UI.sliderKnobColor)
    drawCircle(knobX - 2, knobY - 2, UI.sliderKnobSize/4, {1, 1, 1, 0.3})
    gl.Color(1, 1, 1, 1)
    gl.Text(string.format("%.0f", slider.value), sliderX + 210, cy - 2, 12)
    cy = cy - sliderH
    cy = cy - sectionPad
    cy = cy - sectionGap
    -- Section: Resurrection
    local resurrectionControls = {"resurrecting", "excludeBuildings"}
    local resurrectionSlider = false
    local resurrectionSectionHeight = headerH + #resurrectionControls * spacing + (resurrectionSlider and sliderH or 0) + sectionPad * 2
    local resurrectionTop = cy + sectionPad
    local resurrectionBot = cy - resurrectionSectionHeight + sectionPad
    gl.Color(UI.sectionBgColor[1], UI.sectionBgColor[2], UI.sectionBgColor[3], 0.55)
    gl.Rect(sectionX, resurrectionBot, sectionX + sectionW, resurrectionTop)
    gl.Color(UI.sectionHeaderColor[1], UI.sectionHeaderColor[2], UI.sectionHeaderColor[3], UI.sectionHeaderColor[4])
    gl.Text("Resurrection", x + UI.width/2 - 60, cy - 2, UI.sectionHeaderSize, "o")
    cy = cy - headerH
    for _, name in ipairs(resurrectionControls) do
        local box = checkboxes[name]
        local cx = x + UI.padding
        gl.Color(0.2, 0.2, 0.2, 0.8)
        gl.Rect(cx, cy, cx + boxH, cy + boxH)
        if box.state then
            gl.Color(0.3, 0.7, 0.3, 0.9)
            gl.Rect(cx + 2, cy + 2, cx + boxH - 2, cy + boxH - 2)
        end
        gl.Color(1, 1, 1, 1)
        gl.Text(box.label, cx + 24, cy + 2, 12)
        cy = cy - spacing
    end
    cy = cy - sectionPad
    cy = cy - sectionGap
    -- Section: Resource Collection
    local resourceControls = {"collecting"}
    local resourceSlider = true
    local resourceSectionHeight = headerH + #resourceControls * spacing + (resourceSlider and sliderH or 0) + sectionPad * 2
    local resourceTop = cy + sectionPad
    local resourceBot = cy - resourceSectionHeight + sectionPad
    gl.Color(UI.sectionBgColor[1], UI.sectionBgColor[2], UI.sectionBgColor[3], 0.55)
    gl.Rect(sectionX, resourceBot, sectionX + sectionW, resourceTop)
    gl.Color(UI.sectionHeaderColor[1], UI.sectionHeaderColor[2], UI.sectionHeaderColor[3], UI.sectionHeaderColor[4])
    gl.Text("Resource Collection", x + UI.width/2 - 90, cy - 2, UI.sectionHeaderSize, "o")
    cy = cy - headerH
    for _, name in ipairs(resourceControls) do
        local box = checkboxes[name]
        local cx = x + UI.padding
        gl.Color(0.2, 0.2, 0.2, 0.8)
        gl.Rect(cx, cy, cx + boxH, cy + boxH)
        if box.state then
            gl.Color(0.3, 0.7, 0.3, 0.9)
            gl.Rect(cx + 2, cy + 2, cx + boxH - 2, cy + boxH - 2)
        end
        gl.Color(1, 1, 1, 1)
        gl.Text(box.label, cx + 24, cy + 2, 12)
        cy = cy - spacing
    end
    -- Resource Collection slider
    slider = sliders.reclaimRadius
    sliderX = x + UI.padding
    gl.Color(1, 1, 1, 1)
    gl.Text(slider.label, sliderX, cy + 20, 12)
    gl.Color(0.2, 0.2, 0.2, 0.8)
    gl.Rect(sliderX, cy, sliderX + 200, cy + 6)
    fillWidth = 200 * (slider.value - slider.min) / (slider.max - slider.min)
    gl.Color(0.3, 0.7, 0.3, 0.9)
    gl.Rect(sliderX, cy, sliderX + fillWidth, cy + 6)
    knobX = sliderX + fillWidth
    knobY = cy + 3
    drawCircle(knobX + 1, knobY - 1, UI.sliderKnobSize/2 + 1, {0, 0, 0, 0.3})
    drawCircle(knobX, knobY, UI.sliderKnobSize/2, UI.sliderKnobColor)
    drawCircle(knobX - 2, knobY - 2, UI.sliderKnobSize/4, {1, 1, 1, 0.3})
    gl.Color(1, 1, 1, 1)
    gl.Text(string.format("%.0f", slider.value), sliderX + 210, cy - 2, 12)
    cy = cy - sliderH
    cy = cy - sectionPad
    cy = cy - sectionGap
    -- Section: Safety
    local safetyControls = {}
    local safetySlider = true
    local safetySectionHeight = headerH + #safetyControls * spacing + (safetySlider and sliderH or 0) + sectionPad * 2
    local safetyTop = cy + sectionPad
    local safetyBot = cy - safetySectionHeight + sectionPad
    gl.Color(UI.sectionBgColor[1], UI.sectionBgColor[2], UI.sectionBgColor[3], 0.55)
    gl.Rect(sectionX, safetyBot, sectionX + sectionW, safetyTop)
    gl.Color(UI.sectionHeaderColor[1], UI.sectionHeaderColor[2], UI.sectionHeaderColor[3], UI.sectionHeaderColor[4])
    gl.Text("Safety", x + UI.width/2 - 30, cy - 2, UI.sectionHeaderSize, "o")
    cy = cy - headerH
    cy = cy - sectionPad
    -- Safety slider
    slider = sliders.enemyAvoidanceRadius
    sliderX = x + UI.padding
    gl.Color(1, 1, 1, 1)
    gl.Text(slider.label, sliderX, cy + 20, 12)
    gl.Color(0.2, 0.2, 0.2, 0.8)
    gl.Rect(sliderX, cy, sliderX + 200, cy + 6)
    fillWidth = 200 * (slider.value - slider.min) / (slider.max - slider.min)
    gl.Color(0.3, 0.7, 0.3, 0.9)
    gl.Rect(sliderX, cy, sliderX + fillWidth, cy + 6)
    knobX = sliderX + fillWidth
    knobY = cy + 3
    drawCircle(knobX + 1, knobY - 1, UI.sliderKnobSize/2 + 1, {0, 0, 0, 0.3})
    drawCircle(knobX, knobY, UI.sliderKnobSize/2, UI.sliderKnobColor)
    drawCircle(knobX - 2, knobY - 2, UI.sliderKnobSize/4, {1, 1, 1, 0.3})
    gl.Color(1, 1, 1, 1)
    gl.Text(string.format("%.0f", slider.value), sliderX + 210, cy - 2, 12)
end

function widget:MousePress(mx, my, button)
    if not showUI then return false end
    local vsx, vsy = Spring.GetViewGeometry()
    local x = math.floor(uiPosX * vsx - UI.width / 2)
    local y = math.floor(uiPosY * vsy + UI.height / 2)
    -- Check for title bar drag
    if mx >= x and mx <= x + UI.width and my >= y - 30 and my <= y then
        isDraggingUI = true
        dragOffsetX = mx - x
        dragOffsetY = my - y
        return true
    end
    -- Check for checkbox clicks
    local cy = y - 60
    local sectionPad = 16
    local sectionGap = 16
    local headerH = UI.sectionHeaderSize + 8
    local boxH = 16
    local sliderH = 26
    local spacing = UI.spacing
    -- Healing section
    cy = cy - headerH
    for _, name in ipairs({"healing", "healCloaked"}) do
        if mx >= x + UI.padding and mx <= x + UI.padding + boxH and
           my >= cy and my <= cy + boxH then
            checkboxes[name].state = not checkboxes[name].state
            Spring.SetConfigInt("scv_checkbox_"..name, checkboxes[name].state and 1 or 0)
            return true
        end
        cy = cy - spacing
    end
    -- Healing slider
    local healingSliderY = cy
    local healingSliderX = x + UI.padding
    local fillWidth = 200 * (sliders.healResurrectRadius.value - sliders.healResurrectRadius.min) / (sliders.healResurrectRadius.max - sliders.healResurrectRadius.min)
    local knobX = healingSliderX + fillWidth
    local knobY = healingSliderY + 3
    local knobHitSize = UI.sliderKnobSize + 4
    if (mx - knobX)^2 + (my - knobY)^2 <= (knobHitSize)^2 or
       (mx >= healingSliderX and mx <= healingSliderX + 200 and
        my >= healingSliderY - 4 and my <= healingSliderY + 10) then
        activeDragSlider = sliders.healResurrectRadius
        activeDragName = "healResurrectRadius"
        local ratio = (mx - healingSliderX) / 200
        ratio = math.max(0, math.min(1, ratio))
        sliders.healResurrectRadius.value = mathFloor(sliders.healResurrectRadius.min + (sliders.healResurrectRadius.max - sliders.healResurrectRadius.min) * ratio)
        healResurrectRadius = sliders.healResurrectRadius.value
        Spring.SetConfigInt("scv_healResurrectRadius", sliders.healResurrectRadius.value)
        return true
    end
    cy = cy - sliderH
    cy = cy - sectionPad
    cy = cy - sectionGap
    -- Resurrection section
    cy = cy - headerH
    for _, name in ipairs({"resurrecting", "excludeBuildings"}) do
        if mx >= x + UI.padding and mx <= x + UI.padding + boxH and
           my >= cy and my <= cy + boxH then
            checkboxes[name].state = not checkboxes[name].state
            Spring.SetConfigInt("scv_checkbox_"..name, checkboxes[name].state and 1 or 0)
            return true
        end
        cy = cy - spacing
    end
    cy = cy - sectionPad
    cy = cy - sectionGap
    -- Resource Collection section
    cy = cy - headerH
    if mx >= x + UI.padding and mx <= x + UI.padding + boxH and
       my >= cy and my <= cy + boxH then
        checkboxes.collecting.state = not checkboxes.collecting.state
        Spring.SetConfigInt("scv_checkbox_collecting", checkboxes.collecting.state and 1 or 0)
        return true
    end
    cy = cy - spacing
    -- Resource Collection slider
    local resourceSliderY = cy
    local resourceSliderX = x + UI.padding
    fillWidth = 200 * (sliders.reclaimRadius.value - sliders.reclaimRadius.min) / (sliders.reclaimRadius.max - sliders.reclaimRadius.min)
    knobX = resourceSliderX + fillWidth
    knobY = resourceSliderY + 3
    if (mx - knobX)^2 + (my - knobY)^2 <= (knobHitSize)^2 or
       (mx >= resourceSliderX and mx <= resourceSliderX + 200 and
        my >= resourceSliderY - 4 and my <= resourceSliderY + 10) then
        activeDragSlider = sliders.reclaimRadius
        activeDragName = "reclaimRadius"
        local ratio = (mx - resourceSliderX) / 200
        ratio = math.max(0, math.min(1, ratio))
        sliders.reclaimRadius.value = mathFloor(sliders.reclaimRadius.min + (sliders.reclaimRadius.max - sliders.reclaimRadius.min) * ratio)
        reclaimRadius = sliders.reclaimRadius.value
        Spring.SetConfigInt("scv_reclaimRadius", sliders.reclaimRadius.value)
        return true
    end
    cy = cy - sliderH
    cy = cy - sectionPad
    cy = cy - sectionGap
    -- Safety section
    cy = cy - headerH
    cy = cy - sectionPad
    -- Safety slider
    local safetySliderY = cy
    local safetySliderX = x + UI.padding
    fillWidth = 200 * (sliders.enemyAvoidanceRadius.value - sliders.enemyAvoidanceRadius.min) / (sliders.enemyAvoidanceRadius.max - sliders.enemyAvoidanceRadius.min)
    knobX = safetySliderX + fillWidth
    knobY = safetySliderY + 3
    if (mx - knobX)^2 + (my - knobY)^2 <= (knobHitSize)^2 or
       (mx >= safetySliderX and mx <= safetySliderX + 200 and
        my >= safetySliderY - 4 and my <= safetySliderY + 10) then
        activeDragSlider = sliders.enemyAvoidanceRadius
        activeDragName = "enemyAvoidanceRadius"
        local ratio = (mx - safetySliderX) / 200
        ratio = math.max(0, math.min(1, ratio))
        sliders.enemyAvoidanceRadius.value = mathFloor(sliders.enemyAvoidanceRadius.min + (sliders.enemyAvoidanceRadius.max - sliders.enemyAvoidanceRadius.min) * ratio)
        enemyAvoidanceRadius = sliders.enemyAvoidanceRadius.value
        Spring.SetConfigInt("scv_enemyAvoidanceRadius", sliders.enemyAvoidanceRadius.value)
        return true
    end
    return false
end

function widget:MouseRelease(mx, my, button)
    if isDraggingUI then
        isDraggingUI = false
        -- Save position
        Spring.SetConfigFloat("scv_uiPosX", uiPosX)
        Spring.SetConfigFloat("scv_uiPosY", uiPosY)
        return true
    end
    if activeDragSlider then
        activeDragSlider = nil
        activeDragName = nil
        return true
    end
    return false
end

function widget:MouseMove(mx, my, dx, dy, button)
    if not showUI then return end
    local vsx, vsy = Spring.GetViewGeometry()
    if isDraggingUI then
        uiPosX = math.max(0, math.min(1, (mx - dragOffsetX + UI.width / 2) / vsx))
        uiPosY = math.max(0, math.min(1, (my - dragOffsetY - UI.height / 2) / vsy))
    end
    -- Only process if we're dragging a slider
    if activeDragSlider then
        local x = math.floor(uiPosX * vsx - UI.width / 2)
        local ratio = (mx - (x + UI.padding)) / 200
        ratio = math.max(0, math.min(1, ratio))
        activeDragSlider.value = mathFloor(activeDragSlider.min + (activeDragSlider.max - activeDragSlider.min) * ratio)
        if activeDragName == "healResurrectRadius" then 
            healResurrectRadius = activeDragSlider.value
            Spring.SetConfigInt("scv_healResurrectRadius", activeDragSlider.value)
        elseif activeDragName == "reclaimRadius" then 
            reclaimRadius = activeDragSlider.value
            Spring.SetConfigInt("scv_reclaimRadius", activeDragSlider.value)
        elseif activeDragName == "enemyAvoidanceRadius" then 
            enemyAvoidanceRadius = activeDragSlider.value
            Spring.SetConfigInt("scv_enemyAvoidanceRadius", activeDragSlider.value)
        end
    end
end

function widget:KeyPress(key, mods, isRepeat)
    if key == 0x0076 and mods.alt then  -- Alt+V to toggle UI
        showUI = not showUI
        return true
    elseif key == 27 then  -- Escape to close UI
        showUI = false
        return true
    end
    return false
end



-- /////////////////////////////////////////// -- /////////////////////////////////////////// -- /////////////////////////////////////////// -- 
-- /////////////////////////////////////////// -- /////////////////////////////////////////// -- /////////////////////////////////////////// -- 
-- ////////////////////////////////////////- END UI CODE -////////////////////////////////////// -- /////////////////////////////////////////// -- 
-- /////////////////////////////////////////// -- /////////////////////////////////////////// -- /////////////////////////////////////////// -- 
-- /////////////////////////////////////////// -- /////////////////////////////////////////// -- /////////////////////////////////////////// -- 



-- ///////////////////////////////////////////  isMyResbot Function 
-- Updated isMyResbot function
  function isMyResbot(unitID, unitDefID)
    local myTeamID = Spring.GetMyTeamID()
    local unitTeamID = Spring.GetUnitTeam(unitID)

    -- Check if unit is a RezBot
    local isRezBot = unitTeamID == myTeamID and (
        (armRectrDefID and unitDefID == armRectrDefID) or
        (corNecroDefID and unitDefID == corNecroDefID) or
        (legRezbotDefID and unitDefID == legRezbotDefID)
    )
    
    -- Check if unit is valid and exists
    if not Spring.ValidUnitID(unitID) or Spring.GetUnitIsDead(unitID) then
        return false -- Invalid or dead units are not considered RezBots
    end

    -- Check if the unit is fully built
    local _, _, _, _, buildProgress = Spring.GetUnitHealth(unitID)
    if buildProgress < 1 then
        return false -- Units still being built are not considered RezBots
    end

    return isRezBot
end



-- A table to check if a unit definition name corresponds to a building
-- This was necessary because Dead units and dead buildings are all considered 'corpses,heaps'
-- There is no way to differentiate between a dead unit and dead building without referencing their name.
local buildingNames = {
  armamb = true,
  armamd = true,
  armanni = true,
  armbeamer = true,
  armbrtha = true,
  armcir = true,
  armclaw = true,
  armemp = true,
  armferret = true,
  armflak = true,
  armguard = true,
  armhlt = true,
  armjuno = true,
  armllt = true,
  armmercury = true,
  armpb = true,
  armrl = true,
  armshockwave = true,
  armsilo = true,
  armvulc = true,
  corbhmth = true,
  corbuzz = true,
  cordoom = true,
  corerad = true,
  corexp = true,
  corflak = true,
  corfmd = true,
  corhllt = true,
  corhlt = true,
  corint = true,
  corjuno = true,
  corllt = true,
  cormadsam = true,
  cormaw = true,
  cormexp = true,
  corpun = true,
  corrl = true,
  corscreamer = true,
  corsilo = true,
  cortoast = true,
  cortron = true,
  corvipe = true,
  armadvsol = true,
  armafus = true,
  armageo = true,
  armamex = true,
  armckfus = true,
  armestor = true,
  armfus = true,
  armgeo = true,
  armgmm = true,
  armmakr = true,
  armmex = true,
  armmmkr = true,
  armmoho = true,
  armmstor = true,
  armsolar = true,
  armwin = true,
  coradvsol = true,
  corafus = true,
  corageo = true,
  corestor = true,
  corfus = true,
  corgeo = true,
  cormakr = true,
  cormex = true,
  cormmkr = true,
  cormoho = true,
  cormstor = true,
  corsolar = true,
  corwin = true,
  armaap = true,
  armalab = true,
  armap = true,
  armavp = true,
  armhp = true,
  armlab = true,
  armshltx = true,
  armvp = true,
  coraap = true,
  coralab = true,
  corap = true,
  coravp = true,
  corgant = true,
  corhp = true,
  corlab = true,
  corvp = true,
  armarad = true,
  armasp = true,
  armdf = true,
  armdrag = true,
  armeyes = true,
  armfort = true,
  armgate = true,
  armjamt = true,
  armmine1 = true,
  armmine2 = true,
  armmine3 = true,
  armnanotc = true,
  armnanotct2 = true,
  armrad = true,
  armsd = true,
  armtarg = true,
  armveil = true,
  corarad = true,
  corasp = true,
  cordrag = true,
  coreyes = true,
  corfort = true,
  corgate = true,
  corjamt = true,
  cormine1 = true,
  cormine2 = true,
  cormine3 = true,
  cormine4 = true,
  cornanotc = true,
  cornanotct2 = true,
  corrad = true,
  corsd = true,
  corshroud = true,
  cortarg = true,
  armatl = true,
  armdl = true,
  armfflak = true,
  armfhlt = true,
  armfrock = true,
  armfrt = true,
  armgplat = true,
  armkraken = true,
  armptl = true,
  armtl = true,
  coratl = true,
  cordl = true,
  corenaa = true,
  corfdoom = true,
  corfhlt = true,
  corfrock = true,
  corfrt = true,
  corgplat = true,
  corptl = true,
  cortl = true,
  armfmkr = true,
  armtide = true,
  armuwadves = true,
  armuwadvms = true,
  armuwageo = true,
  armuwes = true,
  armuwfus = true,
  armuwgeo = true,
  armuwmex = true,
  armuwmme = true,
  armuwmmm = true,
  armuwms = true,
  corfmkr = true,
  cortide = true,
  coruwadves = true,
  coruwadvms = true,
  coruwageo = true,
  coruwes = true,
  coruwfus = true,
  coruwgeo = true,
  coruwmex = true,
  coruwmme = true,
  coruwmmm = true,
  coruwms = true,
  armamsub = true,
  armasy = true,
  armfhp = true,
  armplat = true,
  armshltxuw = true,
  armsy = true,
  coramsub = true,
  corasy = true,
  corfhp = true,
  corgantuw = true,
  corplat = true,
  corsy = true,
  armason = true,
  armfasp = true,
  armfatf = true,
  armfdrag = true,
  armfgate = true,
  armfmine3 = true,
  armfrad = true,
  armnanotcplat = true,
  armsonar = true,
  corason = true,
  corfasp = true,
  corfatf = true,
  corfdrag = true,
  corfgate = true,
  corfmine3 = true,
  corfrad = true,
  cornanotcplat = true,
  corsonar = true,
  -- Legion buildings (Defenses)
  legabm = true,
  legacluster = true,
  legapopupdef = true,
  legbastion = true,
  legbombard = true,
  legcluster = true,
  legdrag = true,
  legdtr = true,
  legflak = true,
  legforti = true,
  leggatet3 = true,
  leghive = true,
  leghlt = true,
  leglraa = true,
  leglrpc = true,
  leglupara = true,
  legmg = true,
  legperdition = true,
  legrhapsis = true,
  legrl = true,
  legsilo = true,
  legstarfall = true,
  -- Legion buildings (Economy)
  legadveconv = true,
  legadvestore = true,
  legadvsol = true,
  legafus = true,
  legageo = true,
  legamstor = true,
  legeconv = true,
  legestor = true,
  legfus = true,
  leggeo = true,
  legmex = true,
  legmext15 = true,
  legmoho = true,
  legmohobp = true,
  legmohobpct = true,
  legmohocon = true,
  legmohoconct = true,
  legmohoconin = true,
  legmstor = true,
  legrampart = true,
  legsolar = true,
  legwin = true,
  -- Legion buildings (Labs)
  legaap = true,
  legalab = true,
  legamphlab = true,
  legap = true,
  legavp = true,
  legfhp = true,
  leggant = true,
  leghp = true,
  legjim = true,
  leglab = true,
  legvp = true,
  -- Legion buildings (SeaDefenses)
  legctl = true,
  legfdrag = true,
  legfhive = true,
  legfmg = true,
  legfrl = true,
  legptl_deprecated = true,
  legtl = true,
  legtl_deprecated = true,
  -- Legion buildings (SeaUtility)
  legfrad = true,
  -- Legion buildings (Seaeconomy)
  legfeconv = true,
  legtide = true,
  leguwestore = true,
  leguwgeo = true,
  leguwmstore = true,
  -- Legion buildings (Utilities)
  legajam = true,
  legarad = true,
  legdeflector = true,
  legeyes = true,
  legjam = true,
  legjuno = true,
  legmine1 = true,
  legmine2 = true,
  legmine3 = true,
  legnanotc = true,
  legnanotcplat = true,
  legnanotc2 = true,
  legnanotc2plat = true,
  legrad = true,
  legsd = true,
  legtarg = true,
}

-- Function to check if a unit or feature is a building or building wreckage
function isBuilding(id)
  -- First, check if it's a unit and a building based on unit definition name
  local unitDefID = spGetUnitDefID(id)
  if unitDefID then
      local unitDef = UnitDefs[unitDefID]
      if unitDef and buildingNames[unitDef.name] then
          return true
      end
  end

  -- If not a unit, check if it's a feature and a building wreckage
  local featureDefID = spGetFeatureDefID(id)
  if featureDefID then
      local featureDef = FeatureDefs[featureDefID]
      -- Check if the feature is reclaimable and has the 'fromunit' custom parameter
      if featureDef and featureDef.reclaimable and featureDef.customParams and featureDef.customParams.fromunit then
          -- Use the 'fromunit' parameter to check against the building names
          return buildingNames[featureDef.customParams.fromunit] == true
      end
  end

  return false -- Not a building or building wreckage
end




-- /////////////////////////////////////////// processUnits Function (Updated)
-- 
-- 
-- 

function processUnits(units)
  for unitID, unitData in pairs(units) do
    local unitDefID = spGetUnitDefID(unitID)
    if isMyResbot(unitID, unitDefID) then

      -- 1) Check for nearby damaged units (high-priority if <= 475 distance)
      --    If it finds a unit to heal, it sets "taskStatus = in_progress"
      if checkboxes.healing.state and unitData.taskStatus ~= "in_progress" then
        local nearestDamagedUnit, distance = findNearestDamagedFriendly(unitID, healResurrectRadius)
        if nearestDamagedUnit and distance <= 475 then
          performHealing(unitID, unitData)
        end
      end

      -- 2) Resurrecting Logic
      if checkboxes.resurrecting.state and unitData.taskStatus ~= "in_progress" then
        performResurrection(unitID, unitData)
      end

      -- 3) Collecting Logic
      if checkboxes.collecting.state and unitData.taskStatus ~= "in_progress" then
        performCollection(unitID, unitData)
      end

      -- 4) Healing Logic (e.g. no immediate damaged units found in step 1)
      if checkboxes.healing.state and unitData.taskStatus ~= "in_progress" then
        performHealing(unitID, unitData)
      end

      -- If any of the steps set unitData.taskStatus = "in_progress",
      -- we skip further steps for that unit (due to the checks above),
      -- but we continue on to the next unit in the loop.
    end
  end
end


-- ///////////////////////////////////////////  UnitCreated/Destroyed Function
function widget:UnitCreated(unitID, unitDefID, unitTeam)
  if isMyResbot(unitID, unitDefID) then  -- Use isMyResbot to check if the unit is a Resbot
    scvlog("Resbot created: UnitID = " .. unitID)
    unitsToCollect[unitID] = {
      featureCount = 0,
      lastReclaimedFrame = 0,
      taskStatus = "idle"  -- Set the task status to "idle" when the unit is created
    }
    processUnits({[unitID] = unitsToCollect[unitID]})
  end
end

function widget:UnitDestroyed(unitID, unitDefID, teamID)
  if unitsToCollect[unitID] then
      unitsToCollect[unitID] = nil
  end
end


-- ///////////////////////////////////////////  FeatureDestroyed Function
function widget:FeatureDestroyed(featureID, allyTeam)
  scvlog("Feature destroyed: FeatureID = " .. featureID)
  for unitID, data in pairs(unitsToCollect) do
    local unitDefID = spGetUnitDefID(unitID)
    if isMyResbot(unitID, unitDefID) then  -- Use isMyResbot to check if the unit is a Resbot
      if data.featureID == featureID then
        data.featureID = nil
        data.lastReclaimedFrame = Spring.GetGameFrame()
        data.taskStatus = "idle"  -- reset the unit to idle after unit destroyed.
        processUnits(unitsToCollect)
        break
      end
    end
  end
  targetedFeatures[featureID] = nil  -- Clear the target as the feature is destroyed
end




-- /////////////////////////////////////////// GameFrame Function
function widget:GameFrame(currentFrame)
  local stuckCheckInterval     = 1000
  local resourceCheckInterval  = 150   -- Interval to check and reassign tasks
  local actionInterval         = 30

  -- 1) Only run main actions every 'actionInterval' frames
  if (currentFrame % actionInterval == 0) then
    for unitID, unitData in pairs(unitsToCollect) do
      local unitDefID = Spring.GetUnitDefID(unitID)
      if isMyResbot(unitID, unitDefID) then
        if Spring.ValidUnitID(unitID) and not Spring.GetUnitIsDead(unitID) then
          ----------------------------------------------------------------------
          -- (A) Check for nearby enemies and possibly flee
          ----------------------------------------------------------------------
          local isFleeing = maintainSafeDistanceFromEnemy(unitID, unitData, enemyAvoidanceRadius)

          ----------------------------------------------------------------------
          -- (B) If not fleeing, handle tasks if idle or completed
          ----------------------------------------------------------------------
          if (not isFleeing) and 
             (unitData.taskStatus == "idle" or unitData.taskStatus == "completed") then
            processUnits({ [unitID] = unitData })
          end
        end
      end
    end
  end

  -- 2) Periodically check if units are stuck
  if (currentFrame % stuckCheckInterval == 0) then
    for unitID, _ in pairs(unitsToCollect) do
      local unitDefID = Spring.GetUnitDefID(unitID)
      if isMyResbot(unitID, unitDefID) then
        handleStuckUnits(unitID, UnitDefs[unitDefID])
      end
    end
  end

  -- 3) Periodically check resource needs & reassign tasks if necessary
  if (currentFrame % resourceCheckInterval == 0) then
    local resourceNeed = assessResourceNeeds()
    if resourceNeed ~= "full" then
      for unitID, unitData in pairs(unitsToCollect) do
        -- If the unit is idle or completed, see if there's something to do
        if (unitData.taskStatus == "idle") or (unitData.taskStatus == "completed") then
          processUnits({ [unitID] = unitData })
        end
      end
    end
  end

  -- 4) Once every 60 frames, remove unreachable entries older than UNREACHABLE_EXPIRE_FRAMES
  if (currentFrame % 60 == 0) then
    for featID, markedFrame in pairs(unreachableFeatures) do
      if (currentFrame - markedFrame) > UNREACHABLE_EXPIRE_FRAMES then
        unreachableFeatures[featID] = nil
        scvlog("FeatureID", featID, "is no longer marked unreachable")
      end
    end
  end

  -- 5) Check for units idle too long and send them to safety
  for unitID, unitData in pairs(unitsToCollect) do
    local unitDefID = spGetUnitDefID(unitID)
    if isMyResbot(unitID, unitDefID) then
      -- Only handle truly idle units
      if unitData.taskStatus == "idle" then
        -- Don't check if unit is already fleeing or returning
        if not unitsMovingToSafety[unitID] and unitData.taskStatus ~= "returning_to_friendly" then
          local last = lastIdleFrame[unitID] or currentFrame
          if currentFrame - last >= IDLE_TIMEOUT_FRAMES then
            local ux, uy, uz = Spring.GetUnitPosition(unitID)
            if ux and uz then -- Sanity check
              -- Find nearest valid combat unit
              local myTeamID = Spring.GetMyTeamID()
              local searchRadius = 2000 -- Large search radius for idle regroup
              local unitsInRadius = Spring.GetUnitsInCylinder(ux, uz, searchRadius)
              local minDistSq = math.huge
              local nearestCombatUnit = nil

              for _, otherUnitID in ipairs(unitsInRadius) do
                if otherUnitID ~= unitID then
                  local unitTeam = Spring.GetUnitTeam(otherUnitID)
                  if unitTeam == myTeamID then
                    local otherDefID = spGetUnitDefID(otherUnitID)
                    local otherDef = UnitDefs[otherDefID]
                    -- Must be a combat unit (has weapons, not resbot, not air, not constructor)
                    if otherDef and 
                       not isMyResbot(otherUnitID, otherDefID) and 
                       not otherDef.isAirUnit and 
                       not otherDef.canRepair and 
                       otherDef.weapons and #otherDef.weapons > 0 then
                      
                      local ox, oy, oz = Spring.GetUnitPosition(otherUnitID)
                      if ox and oz then
                        local distSq = (ux - ox)^2 + (uz - oz)^2
                        if distSq < minDistSq then
                          minDistSq = distSq
                          nearestCombatUnit = {x = ox, y = oy, z = oz}
                          scvlog("Found potential combat unit for idle regroup at distance: " .. math.sqrt(distSq))
                        end
                      end
                    end
                  end
                end
              end

              -- Only issue move order if we found a valid target and aren't too close
              if nearestCombatUnit and minDistSq > 500*500 then
                local safeX = nearestCombatUnit.x
                local safeZ = nearestCombatUnit.z
                local safeY = Spring.GetGroundHeight(safeX, safeZ)
                
                scvlog("Regrouping idle unit " .. unitID .. " to combat unit position")
                Spring.GiveOrderToUnit(unitID, CMD.MOVE, {safeX, safeY, safeZ}, {})
                unitData.taskStatus = "returning_to_friendly"
              end
            end
          end
          -- Only update the last idle frame if we're truly idle
          if unitData.taskStatus == "idle" then
            lastIdleFrame[unitID] = last
          end
        end
      else
        -- Reset idle timer for non-idle units
        lastIdleFrame[unitID] = currentFrame
      end
    end
  end
end




-- ///////////////////////////////////////////  findNearestDamagedFriendly Function
function findNearestDamagedFriendly(unitID, searchRadius)
  local myTeamID = spGetMyTeamID() -- Retrieve your team ID
  local x, y, z = spGetUnitPosition(unitID)
  local unitsInRadius = Spring.GetUnitsInCylinder(x, z, searchRadius)

  local minDistSq = searchRadius * searchRadius
  local nearestDamagedUnit = nil
  for _, otherUnitID in ipairs(unitsInRadius) do
    if otherUnitID ~= unitID then
      local unitDefID = spGetUnitDefID(otherUnitID)
      local unitDef = UnitDefs[unitDefID]

      if unitDef and not unitDef.isAirUnit then -- Check if the unit is not an air unit
        local unitTeam = Spring.GetUnitTeam(otherUnitID)
        if unitTeam == myTeamID then -- Check if the unit belongs to your team
          if (checkboxes.healCloaked.state or not (GetUnitIsCloaked and GetUnitIsCloaked(otherUnitID))) then
            local health, maxHealth, _, _, buildProgress = Spring.GetUnitHealth(otherUnitID)
            if health and maxHealth and health < maxHealth and buildProgress == 1 then
              local distSq = Spring.GetUnitSeparation(unitID, otherUnitID, true)
              if distSq < minDistSq then
                minDistSq = distSq
                nearestDamagedUnit = otherUnitID
              end
            end
          end
        end
      end
    end
  end

  return nearestDamagedUnit, math.sqrt(minDistSq)
end



-- ///////////////////////////////////////////  findNearestEnemy Function
function findNearestEnemy(unitID, searchRadius)
  local x, y, z = spGetUnitPosition(unitID)
  if not x or not z then return nil end  -- Validate unit position
  local unitsInRadius = Spring.GetUnitsInCylinder(x, z, searchRadius, Spring.ENEMY_UNITS)
  
  local minDistSq = searchRadius * searchRadius
  local nearestEnemy, isAirUnit = nil, false

  for _, enemyID in ipairs(unitsInRadius) do
    local enemyDefID = spGetUnitDefID(enemyID)
    local enemyDef = UnitDefs[enemyDefID]
    if enemyDef then
      local ex, ey, ez = spGetUnitPosition(enemyID)
      if ex and ez then
        local distSq = (x - ex)^2 + (z - ez)^2
        if distSq < minDistSq then
          minDistSq = distSq
          nearestEnemy = enemyID
          isAirUnit = enemyDef.isAirUnit
        end
      end
    end
  end

  return nearestEnemy, math.sqrt(minDistSq), isAirUnit
end



-- ///////////////////////////////////////////  maintainSafeDistanceFromEnemy Function
function maintainSafeDistanceFromEnemy(unitID, unitData, defaultAvoidanceRadius)
  local nearestEnemy, distance, isAirUnit = findNearestEnemy(unitID, defaultAvoidanceRadius)
  if nearestEnemy and distance < defaultAvoidanceRadius then
    -- We have a close enemy; force the unit to flee
    local ux, uy, uz = Spring.GetUnitPosition(unitID)
    local ex, ey, ez = Spring.GetUnitPosition(nearestEnemy)
    if not (ux and uz and ex and ez) then
      return false  -- sanity check if positions are invalid
    end

    -- Try to find the nearest combat unit to run toward
    local myTeamID = spGetMyTeamID()
    local searchRadius = defaultAvoidanceRadius * 2
    local unitsInRadius = Spring.GetUnitsInCylinder(ux, uz, searchRadius)
    local minDistSq = math.huge
    local nearestFriendly = nil

    for _, otherUnitID in ipairs(unitsInRadius) do
      if otherUnitID ~= unitID then
        local unitTeam = Spring.GetUnitTeam(otherUnitID)
        if unitTeam == myTeamID then
          local otherDefID = spGetUnitDefID(otherUnitID)
          local otherDef = UnitDefs[otherDefID]
          -- Only flee toward combat units
          if otherDef and 
             not isMyResbot(otherUnitID, otherDefID) and 
             not otherDef.isAirUnit and 
             not otherDef.canRepair and 
             otherDef.weapons and #otherDef.weapons > 0 then
            
            local ox, oy, oz = Spring.GetUnitPosition(otherUnitID)
            if ox and oz then
              local distSq = (ux - ox)^2 + (uz - oz)^2
              if distSq < minDistSq then
                minDistSq = distSq
                nearestFriendly = {x = ox, y = oy, z = oz}
              end
            end
          end
        end
      end
    end

    -- Calculate escape position
    local safeX, safeY, safeZ
    if nearestFriendly then
      -- Move toward combat unit while getting away from enemy
      local fx, fz = nearestFriendly.x, nearestFriendly.z  -- Direction from enemy to friendly
      local dirX, dirZ = fx - ex, fz - ez
      local mag = math.sqrt(dirX*dirX + dirZ*dirZ)
      if mag < 1e-6 then mag = 1 end
      -- Move beyond the friendly unit for safety
      safeX = fx + (dirX / mag * 100)  -- 100 is a small offset
      safeZ = fz + (dirZ / mag * 100)
      safeY = Spring.GetGroundHeight(safeX, safeZ)
    else
      -- No combat unit found, move directly away from enemy
      local dx, dz = (ux - ex), (uz - ez)
      local mag = math.sqrt(dx*dx + dz*dz)
      if mag < 1e-6 then mag = 1 end
      safeX = ux + (dx / mag * defaultAvoidanceRadius)
      safeZ = uz + (dz / mag * defaultAvoidanceRadius)
      safeY = Spring.GetGroundHeight(safeX, safeZ)
    end

    -- Check if we need to issue a new move order
    local lastPos = lastFleePosition[unitID]
    local needNewOrder = true
    
    if lastPos then
      local distToLastTarget = math.sqrt((safeX - lastPos.x)^2 + (safeZ - lastPos.z)^2)
      if distToLastTarget < FLEE_REORDER_DISTANCE then
        needNewOrder = false
      end
    end

    if needNewOrder then
      Spring.GiveOrderToUnit(unitID, CMD.MOVE, {safeX, safeY, safeZ}, {})
      lastFleePosition[unitID] = {x = safeX, y = safeY, z = safeZ}
    end

    unitsMovingToSafety[unitID] = true
    unitData.taskStatus = "fleeing"
    return true
  else
    -- No close enemy or safe enough distance
    if unitsMovingToSafety[unitID] then
      unitsMovingToSafety[unitID] = nil
      lastFleePosition[unitID] = nil  -- Clear the last position
      if unitData.taskStatus == "fleeing" then
        unitData.taskStatus = "idle"
      end
    end
    return false
  end
end
  


-- ///////////////////////////////////////////  assessResourceNeeds Function
function assessResourceNeeds()
  local myTeamID = Spring.GetMyTeamID()
  local currentMetal,  storageMetal  = Spring.GetTeamResources(myTeamID, "metal")
  local currentEnergy, storageEnergy = Spring.GetTeamResources(myTeamID, "energy")

  -- Edge case: if storage is zero (extremely rare), just treat it as "no need"
  if (storageMetal <= 0) and (storageEnergy <= 0) then
      return false, false
  end

  local metalRatio  = currentMetal  / (storageMetal  > 0 and storageMetal  or 1)
  local energyRatio = currentEnergy / (storageEnergy > 0 and storageEnergy or 1)

  -- You like 75% as a cutoff:
  local needMetal  = (metalRatio  < 0.75)
  local needEnergy = (energyRatio < 0.75)

  -- Return two booleans: do we need metal? do we need energy?
  return needMetal, needEnergy
end




function getFeatureResources(featureID)
  local featureDefID = spGetFeatureDefID(featureID)
  local featureDef = FeatureDefs[featureDefID]
  return featureDef.metal, featureDef.energy
end



local mapX, mapZ = Game.mapSizeX, Game.mapSizeZ
local mapDiagonal = math.sqrt(mapX^2 + mapZ^2)

function getDynamicWeightDistance(mapDiagonal)
  local baseWeight = 1.2  -- Base weight for small maps
  local scalingFactor = 2.5  -- Determines how much the map size influences weightDistance
  local maxMapDiagonal = 12000  -- Example: Diagonal of a large map for reference

  -- Increase weightDistance for larger maps
  local weightDistance = baseWeight + scalingFactor * (mapDiagonal / maxMapDiagonal)
  return weightDistance
end

local dynamicWeightDistance = getDynamicWeightDistance(mapDiagonal)




-- /////////////////////////////////////////// findReclaimableFeature Function
function findReclaimableFeature(unitID, x, z, searchRadius, needMetal, needEnergy)
  local featuresInRadius = spGetFeaturesInCylinder(x, z, searchRadius)
  if not featuresInRadius then
      scvlog("No features found in the search radius for unit", unitID)
      return nil
  end

  local bestFeature = nil
  local bestScore   = math.huge

  for _, featureID in ipairs(featuresInRadius) do
      -------------------------------------------------------
      -- 1) Check if we already marked this feature unreachable
      -------------------------------------------------------
      if not unreachableFeatures[featureID] then
          local featureDefID = spGetFeatureDefID(featureID)
          if featureDefID then
              local fDef = FeatureDefs[featureDefID]
              if fDef and fDef.reclaimable then
                  local fx, _, fz = Spring.GetFeaturePosition(featureID)
                  local dist      = math.sqrt((x - fx)^2 + (z - fz)^2)
                  local fMetal    = fDef.metal  or 0
                  local fEnergy   = fDef.energy or 0

                  local effectiveMetal  = needMetal  and fMetal  or 0
                  local effectiveEnergy = needEnergy and fEnergy or 0

                  if (effectiveMetal + effectiveEnergy) > 0 then
                      local score = dist * dynamicWeightDistance
                      score       = score - (effectiveMetal + effectiveEnergy)

                      -- Also ensure we haven't exceeded maxUnitsPerFeature
                      local alreadyTargetedCount = targetedFeatures[featureID] or 0
                      if (score < bestScore) and (alreadyTargetedCount < maxUnitsPerFeature) then
                          bestScore   = score
                          bestFeature = featureID
                      end
                  end
              end
          end
      end
  end

  return bestFeature
end



-- ///////////////////////////////////////////  performHealing Function
-- Healing Function with Enhanced Logging
function performHealing(unitID, unitData)
  scvlog("Attempting to heal with unit:", unitID)
  
  local nearestDamagedUnit, distance = findNearestDamagedFriendly(unitID, healResurrectRadius)

  if nearestDamagedUnit and distance < healResurrectRadius then
      scvlog("Nearest damaged unit found for healing by unit", unitID, "is unit", nearestDamagedUnit, "at distance", distance)

      healingTargets[nearestDamagedUnit] = healingTargets[nearestDamagedUnit] or 0
      
      if healingTargets[nearestDamagedUnit] < maxHealersPerUnit and not healingUnits[unitID] then
          scvlog("Unit", unitID, "is healing unit", nearestDamagedUnit)
          Spring.GiveOrderToUnit(unitID, CMD.REPAIR, {nearestDamagedUnit}, {})
          healingUnits[unitID] = nearestDamagedUnit
          healingTargets[nearestDamagedUnit] = healingTargets[nearestDamagedUnit] + 1
          unitData.taskType = "healing"
          unitData.taskStatus = "in_progress"
      else
          scvlog("Healing target already has maximum healers or unit", unitID, "is already assigned to healing")
          unitData.taskStatus = "idle"
      end
  else
      scvlog("No damaged friendly unit found within range for unit", unitID)
      unitData.taskStatus = "idle"
  end
end




-- ///////////////////////////////////////////  performCollection Function
-- Collection Function with Enhanced Logging
function performCollection(unitID, unitData)
  scvlog("Attempting to collect with unit:", unitID)

  -- 1) Determine if we need metal or energy
  local needMetal, needEnergy = assessResourceNeeds()

  -- 2) If both are ≥75% full, skip reclaim
  if (not needMetal) and (not needEnergy) then
      scvlog("Both metal & energy ≥ 75%, skipping reclaim for unit", unitID)
      unitData.taskStatus = "idle"
      return false
  end

  -- 3) Find a feature that yields at least one needed resource
  local x, y, z = spGetUnitPosition(unitID)
  local featureID = findReclaimableFeature(unitID, x, z, reclaimRadius, needMetal, needEnergy)

  if featureID and Spring.ValidFeatureID(featureID) then
      scvlog("Unit", unitID, "is reclaiming feature", featureID)
      spGiveOrderToUnit(unitID, CMD.RECLAIM, {featureID + Game.maxUnits}, {})
      unitData.featureCount       = 1
      unitData.lastReclaimedFrame = Spring.GetGameFrame()
      targetedFeatures[featureID] = (targetedFeatures[featureID] or 0) + 1
      unitData.taskType           = "reclaiming"
      unitData.taskStatus         = "in_progress"
      return true
  else
      scvlog("No valid feature found (or needed) for collection by unit", unitID)
  end

  -- If nothing was found, set idle
  unitData.taskStatus = "idle"
  scvlog("Unit", unitID, "marked idle due to no relevant reclaim targets")
  return false
end




-- ///////////////////////////////////////////  performResurrection Function
-- Resurrection Function with Maximum Units Per Feature Check
function performResurrection(unitID, unitData)
  scvlog("Attempting to resurrect with unit:", unitID)
  local resurrectableFeatures = resurrectNearbyDeadUnits(unitID, healResurrectRadius)

  scvlog("Found " .. #resurrectableFeatures .. " resurrectable features for unit:", unitID)

  if #resurrectableFeatures > 0 then
      for i, featureID in ipairs(resurrectableFeatures) do
          local wreckageDefID = Spring.GetFeatureDefID(featureID)
          local feature = FeatureDefs[wreckageDefID]

          if not (checkboxes.excludeBuildings.state and isBuilding(featureID)) then
              if feature.customParams["category"] == "corpses" then
                  if Spring.ValidFeatureID(featureID) and (not targetedFeatures[featureID] or targetedFeatures[featureID] < maxUnitsPerFeature) then
                      scvlog("Unit", unitID, "is resurrecting feature", featureID)
                      spGiveOrderToUnit(unitID, CMD.RESURRECT, {featureID + Game.maxUnits}, {})
                      unitData.taskType = "resurrecting"
                      unitData.taskStatus = "in_progress"
                      resurrectingUnits[unitID] = true
                      
                      targetedFeatures[featureID] = (targetedFeatures[featureID] or 0) + 1
                      return  -- Exit after issuing the first valid order
                  else
                      scvlog("Feature", featureID, "is already targeted by maximum units or not valid")
                  end
              else
                  scvlog("Feature", featureID, "is not a corpse, skipping")
              end
          else
              scvlog("Feature", featureID, "is a building or building wreckage, excluded from resurrection")
          end
      end
  else
      scvlog("No resurrectable features found for unit:", unitID)
  end

  -- No features to resurrect, mark as idle to reassign
  scvlog("No resurrection tasks available, setting unit", unitID, "to idle")
  unitData.taskStatus = "idle"
end



-- /////////////////////////////////////////// resurrectNearbyDeadUnits Function
local maxFeaturesToConsider = 25 -- Maximum number of features to consider

-- Function to resurrect nearby dead units, excluding buildings if specified
function resurrectNearbyDeadUnits(unitID, healResurrectRadius)
  local x, y, z = spGetUnitPosition(unitID)
  if not x or not z then return {} end

  local allFeatures = Spring.GetFeaturesInCylinder(x, z, healResurrectRadius)
  local nearestFeatures = {}

  for _, featureID in ipairs(allFeatures) do
      local featureDefID = spGetFeatureDefID(featureID)
      local featureDef = FeatureDefs[featureDefID]

      -- Check if the feature is a building and if it should be excluded
      if featureDef and featureDef.reclaimable and featureDef.resurrectable and 
         (not checkboxes.excludeBuildings.state or not isBuilding(featureID)) then
          local fx, fy, fz = spGetFeaturePosition(featureID)
          local distanceSq = (x - fx)^2 + (z - fz)^2

          if #nearestFeatures < maxFeaturesToConsider then
              nearestFeatures[#nearestFeatures + 1] = {id = featureID, distanceSq = distanceSq}
          else
              -- Replace the farthest feature if the current one is nearer
              local farthestIndex, farthestDistanceSq = 1, nearestFeatures[1].distanceSq
              for i, featureData in ipairs(nearestFeatures) do
                  if featureData.distanceSq > farthestDistanceSq then
                      farthestIndex, farthestDistanceSq = i, featureData.distanceSq
                  end
              end
              if distanceSq < farthestDistanceSq then
                  nearestFeatures[farthestIndex] = {id = featureID, distanceSq = distanceSq}
              end
          end
      end
  end

  -- Sort the nearest features by distance
  table.sort(nearestFeatures, function(a, b) return a.distanceSq < b.distanceSq end)

  -- Extract feature IDs from the table
  local featureIDs = {}
  for _, featureData in ipairs(nearestFeatures) do
      table.insert(featureIDs, featureData.id)
  end

  return featureIDs
end



-- ///////////////////////////////////////////  UnitIdle Function
function widget:UnitIdle(unitID)
  scvlog("UnitIdle called for UnitID:", unitID)

  local unitDefID = spGetUnitDefID(unitID)
  if not unitDefID then
    scvlog("Invalid unitDefID for UnitID:", unitID)
    return
  end

  local unitDef = UnitDefs[unitDefID]
  if not unitDef then
    scvlog("Invalid unitDef for UnitID:", unitID)
    return
  end

  if not isMyResbot(unitID, unitDefID) then
    return
  end

  scvlog("UnitIdle called for Resbot UnitID:", unitID)

  local unitData = unitsToCollect[unitID]
  if not unitData then
    scvlog("Initializing unitData for new UnitID:", unitID)
    unitData = {
      featureCount = 0,
      lastReclaimedFrame = 0,
      taskStatus = "idle",
      featureID = nil
    }
    unitsToCollect[unitID] = unitData
  else
    unitData.taskStatus = "idle"
    scvlog("Setting taskStatus to idle for UnitID:", unitID)
  end

  -- Immediately reassign a new task for the unit
  if (unitDef.canReclaim and checkboxes.collecting.state) or
     (unitDef.canResurrect and checkboxes.resurrecting.state) or
     (unitDef.canRepair and checkboxes.healing.state) then
    scvlog("Re-queueing UnitID for tasks:", unitID)
    processUnits({[unitID] = unitData})
  end

  -- Clear any lingering target associations
  if unitData.featureID then
    scvlog("Handling targeted feature for UnitID:", unitID)
    targetedFeatures[unitData.featureID] = (targetedFeatures[unitData.featureID] or 0) - 1
    if targetedFeatures[unitData.featureID] <= 0 then
      targetedFeatures[unitData.featureID] = nil
    end
    unitData.featureID = nil
  end

  if healingUnits[unitID] then
    scvlog("Handling healing unit for UnitID:", unitID)
    local healedUnitID = healingUnits[unitID]
    healingTargets[healedUnitID] = (healingTargets[healedUnitID] or 0) - 1
    if healingTargets[healedUnitID] <= 0 then
      healingTargets[healedUnitID] = nil
    end
    healingUnits[unitID] = nil
  end

  if resurrectingUnits[unitID] then
    scvlog("Clearing resurrecting unit for UnitID:", unitID)
    resurrectingUnits[unitID] = nil
  end
end





-- ///////////////////////////////////////////  isUnitStuck Function
local lastStuckCheck = {}
local checkInterval = 500  -- Number of game frames to wait between checks

function isUnitStuck(unitID)
  local currentFrame = Spring.GetGameFrame()
  if lastStuckCheck[unitID] and (currentFrame - lastStuckCheck[unitID]) < checkInterval then
    scvlog("Skipping stuck check for unit due to cooldown: UnitID = " .. unitID)
    return false  -- Skip check if within the cooldown period
  end

  lastStuckCheck[unitID] = currentFrame

  local minMoveDistance = 2  -- Define the minimum move distance, adjust as needed
  local x, y, z = spGetUnitPosition(unitID)
  local lastPos = unitLastPosition[unitID] or {x = x, y = y, z = z}
  local stuck = (math.abs(lastPos.x - x)^2 + math.abs(lastPos.z - z)^2) < minMoveDistance^2
  unitLastPosition[unitID] = {x = x, y = y, z = z}

  if stuck then
    scvlog("Unit is stuck: UnitID = " .. unitID)
  else
    scvlog("Unit is not stuck: UnitID = " .. unitID)
  end

  return stuck
end




-- ///////////////////////////////////////////  handleStuckUnits Function
function handleStuckUnits(unitID, unitDef)
  if not unitDef then
      local unitDefID = spGetUnitDefID(unitID)
      unitDef = UnitDefs[unitDefID]
  end

  if isMyResbot(unitID, spGetUnitDefID(unitID)) then
      if isUnitStuck(unitID) then
          scvlog("Unit is stuck. Reassigning task: UnitID = " .. unitID)
          
          -- 1) If this unit has a current feature target, mark it unreachable
          local unitData = unitsToCollect[unitID]
          if unitData and unitData.taskStatus == "in_progress" then
              local featureID = unitData.featureID

              -- Or if you track the feature differently (resurrect vs. reclaim),
              -- you may also look in resurrectingUnits or targetedFeatures.
              
              if featureID then
                unreachableFeatures[featureID] = Spring.GetGameFrame()  -- store the frame we decided it's unreachable
                scvlog("Marking featureID", featureID, "as unreachable at frame", unreachableFeatures[featureID])
                  
                  -- Remove from targetedFeatures so no one else tries it
                  if targetedFeatures[featureID] then
                      targetedFeatures[featureID] = targetedFeatures[featureID] - 1
                      if targetedFeatures[featureID] <= 0 then
                          targetedFeatures[featureID] = nil
                      end
                  end
              end
          end

          -- 2) Force the stuck unit to STOP
          Spring.GiveOrderToUnit(unitID, CMD.STOP, {}, {})

          -- 3) Reset the unit's data to idle
          unitsToCollect[unitID] = {
              featureCount       = 0,
              lastReclaimedFrame = 0,
              taskStatus         = "idle",
              featureID          = nil
          }

          -- Re-run processUnits on that single unit to pick a new task
          processUnits({[unitID] = unitsToCollect[unitID]})

      else
          scvlog("Unit is not stuck: UnitID = " .. unitID)
      end
  else
      scvlog("Unit is not a Resbot or UnitDef is not valid: UnitID = " .. unitID)
  end
end

