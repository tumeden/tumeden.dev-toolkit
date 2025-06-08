-- // This is still work in progress.
-- /////////////////////////////////////////// Legion supported
function widget:GetInfo()
  return {
    name      = "RezBots - AGENT",
    desc      = "RezBots Resurrect, Collect resources, and heal injured units. alt+v to open UI",
    author    = "Tumeden",
    date      = "2025",
    version   = "v1.35",
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
local manuallyCommandedUnits = {}  -- Track units that have been manually commanded by player
local lastProgressCheck = {}  -- Track when units last made progress toward their targets
local lastStuckCheck = {}  -- Track when each unit was last checked for being stuck
local scriptIssuedCommands = {}  -- Track commands issued by the script itself
local pendingProcessUnits = {}  -- Queue for units that need processing to prevent race conditions
local processedManualCommands = {}  -- Track manual commands to prevent duplicate detection within same frame
local activeResurrections = {}  -- [featureID] = {unitID1, unitID2, ...} for features being resurrected
local interruptedResurrections = {}  -- [unitID] = {featureID, startFrame, attempts} for interrupted resurrections
local UNREACHABLE_EXPIRE_FRAMES = 3000  -- Number of frames to keep marking something as unreachable (e.g., ~2 min)
local maxUnitsPerFeature = 4  -- Maximum units allowed to target the same feature
local maxHealersPerUnit = 4  -- Maximum number of healers per unit
local healResurrectRadius = 1000 -- Set your desired heal/resurrect radius here  (default 1000)
local reclaimRadius = 1500 -- Set your desired reclaim radius here (any number works, 4000 is about half a large map)
local enemyAvoidanceRadius = 675  -- Adjust this value as needed -- Define a safe distance for enemy avoidance
local idleRegroupRadius = 3500 -- Radius to search for allied units when idle (default 3500)
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

-- Debug: Log command IDs on startup
local function logCommandIDs()
  if isLoggingEnabled then
    Spring.Echo("Command ID mappings:")
    Spring.Echo("  CMD.MOVE =", CMD.MOVE)
    Spring.Echo("  CMD.RESURRECT =", CMD.RESURRECT) 
    Spring.Echo("  CMD.RECLAIM =", CMD.RECLAIM)
    Spring.Echo("  CMD.REPAIR =", CMD.REPAIR)
    Spring.Echo("  CMD.STOP =", CMD.STOP)
  end
end

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

-- /////////////////////////////////////////// Script Command Wrapper
-- Use this instead of Spring.GiveOrderToUnit to track script-issued commands
local function giveScriptOrder(unitID, cmdID, cmdParams, cmdOpts)
  local currentFrame = Spring.GetGameFrame()
  
  -- Clean up old entries (older than 120 frames to match our detection window)
  for key, _ in pairs(scriptIssuedCommands) do
    local frameStr = key:match("_(%d+)$")
    if frameStr and (currentFrame - tonumber(frameStr)) > 120 then
      scriptIssuedCommands[key] = nil
    end
  end
  
  -- Store command before issuing it - use more inclusive tracking
  local cmdKey1 = unitID .. "_" .. cmdID .. "_" .. currentFrame
  local cmdKey2 = unitID .. "_" .. cmdID .. "_" .. (currentFrame + 1)  -- Next frame as well
  scriptIssuedCommands[cmdKey1] = true
  scriptIssuedCommands[cmdKey2] = true
  
  scvlog("SCRIPT CMD: Unit " .. unitID .. " cmd " .. cmdID .. " frame " .. currentFrame)
  scvlog("Tracking script command for unit", unitID, "cmd", cmdID, "at frame", currentFrame)
  
  -- Issue the actual command
  Spring.GiveOrderToUnit(unitID, cmdID, cmdParams, cmdOpts or {})
  return cmdKey1
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
    height = 640,
    backgroundColor = {0.1, 0.1, 0.1, 0.9},
    textColor = {1, 1, 1, 1},
    sectionHeaderColor = {0.8, 0.9, 1, 1},
    sectionBgColor = {0.15, 0.15, 0.18, 0.62}, -- middleground opacity
    checkboxColor = {0.3, 0.7, 0.3, 0.9},
    sliderColor = {0.3, 0.7, 0.3, 0.9},
    sliderKnobColor = {0.4, 0.8, 0.4, 1.0},
    sliderKnobSize = 12,
    padding = 24,
    spacing = 35,
    sectionSpacing = 44,
    sectionHeaderSize = 16,
    sectionGap = 8 -- new: vertical gap between sections
}

-- Movable UI state
local uiPosX = 0.5 -- normalized (0 = left, 1 = right)
local uiPosY = 0.7 -- normalized (0 = bottom, 1 = top)
local isDraggingUI = false
local dragOffsetX, dragOffsetY = 0, 0

-- Track which slider is being dragged
local activeDragSlider = nil
local activeDragName = nil

-- Commander names table (dynamically built in widget:Initialize)
local commanderNames = {}

local checkboxes = {
    excludeBuildings = { state = false, label = "Exclude buildings from Resurrection" },
    healing = { state = false, label = "Healing" },
    collecting = { state = false, label = "Resource Collection" },
    resurrecting = { state = false, label = "Resurrect" },
    healCloaked = { state = false, label = "Heal Cloaked Units" },
    excludeCommanders = { state = true, label = "Exclude Commanders from Collection" } -- New toggle, default enabled
}

local sliders = {}

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
    
    -- Initialize sliders with loaded values
    sliders.healResurrectRadius = { value = healResurrectRadius, min = 0, max = 2000, label = "Heal/Resurrect Radius" }
    sliders.reclaimRadius = { value = reclaimRadius, min = 0, max = 5000, label = "Resource Collection Radius" }
    sliders.enemyAvoidanceRadius = { value = enemyAvoidanceRadius, min = 0, max = 2000, label = "Maintain Safe Distance" }
    
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
        -- Dynamically build commanderNames table
        commanderNames.armcom = true
        commanderNames.corcom = true
        if legRezbotDefID then
            commanderNames.legcom = true
        else
            commanderNames.legcom = nil
        end
    else
        Spring.Echo("UnitDefNames table not found")
        widgetHandler:RemoveWidget()
        return
    end
end

local uiHitboxes = {}

function widget:DrawScreen()
    if not showUI then return end
    uiHitboxes = {} -- reset hitboxes each frame
    local vsx, vsy = Spring.GetViewGeometry()
    -- Section layout constants
    local sectionPad = 4 -- reduced top padding above header
    local sectionGap = UI.sectionGap
    local headerH = 26 -- slimmer header background
    local boxH = 16
    local sliderH = 26
    local spacing = UI.spacing
    local sectionW = UI.width - 32
    -- Section definitions
    local sections = {
        {
            name = "Healing",
            mainToggle = "healing",
            options = {"healCloaked"},
            slider = sliders.healResurrectRadius,
        },
        {
            name = "Resurrection",
            mainToggle = "resurrecting",
            options = {"excludeBuildings"},
            slider = nil,
        },
        {
            name = "Resource Collection",
            mainToggle = "collecting",
            options = {"excludeCommanders"},
            slider = sliders.reclaimRadius,
        },
        {
            name = "Safety",
            mainToggle = nil,
            options = {},
            slider = sliders.enemyAvoidanceRadius,
        },
    }
    -- Calculate section heights dynamically
    local sectionHeights = {}
    for i, sec in ipairs(sections) do
        local optCount = #sec.options
        local hasSlider = sec.slider ~= nil
        local optionPad = 0
        if optCount > 0 then
            optionPad = 18
        elseif hasSlider then
            optionPad = 32
        else
            optionPad = 18
        end
        local sliderHgt = hasSlider and sliderH or 0
        sectionHeights[i] = headerH + sectionPad + optionPad + (optCount * spacing) + sliderHgt + sectionPad
        sections[i].optionPad = optionPad -- store for use in drawing
    end
    -- Calculate total height
    local totalHeight = 30 -- title bar
    for i, h in ipairs(sectionHeights) do
        totalHeight = totalHeight + h
        if i < #sectionHeights then totalHeight = totalHeight + sectionGap end
    end
    UI.height = totalHeight
    local x = math.floor(uiPosX * vsx - UI.width / 2)
    local y = math.floor(uiPosY * vsy + UI.height / 2)
    -- Draw main background
    gl.Color(UI.backgroundColor[1], UI.backgroundColor[2], UI.backgroundColor[3], UI.backgroundColor[4])
    gl.Rect(x, y - UI.height, x + UI.width, y)
    -- Draw title bar
    gl.Color(0.18, 0.18, 0.18, 1)
    gl.Rect(x, y - 30, x + UI.width, y)
    gl.Color(1, 1, 1, 1)
    gl.Text("RezBot Settings (" .. widgetVersion .. ")", x + UI.width/2 - 90, y - 30 + 8, 14, "o")
    -- Draw sections
    local cy = y - 30
    local sectionX = x + (UI.width - sectionW) / 2
    local borderColor = {0.4, 0.6, 0.9, 0.45}
    for i, sec in ipairs(sections) do
        local secH = sectionHeights[i]
        local secTop = cy
        local secBot = cy - secH
        -- Section background
        gl.Color(UI.sectionBgColor[1], UI.sectionBgColor[2], UI.sectionBgColor[3], UI.sectionBgColor[4])
        gl.Rect(sectionX, secBot, sectionX + sectionW, secTop)
        -- Border
        gl.Color(borderColor[1], borderColor[2], borderColor[3], borderColor[4])
        gl.LineWidth(1.5)
        gl.Rect(sectionX + 0.5, secBot + 0.5, sectionX + sectionW - 0.5, secTop - 0.5)
        gl.LineWidth(1)
        -- Header background
        local headerTop = secTop - sectionPad
        local headerBot = headerTop - headerH
        gl.Color(0.18, 0.22, 0.32, 0.82)
        gl.Rect(sectionX, headerBot, sectionX + sectionW, headerTop)
        -- Header text and main toggle (checkbox)
        local headerCenterY = (headerTop + headerBot) / 2
        local headerX = x + UI.width/2 -- center header text
        local checkX = x + UI.padding
        local checkY = headerCenterY - boxH/2
        if sec.mainToggle then
            gl.Color(0.2, 0.2, 0.2, 0.8)
            gl.Rect(checkX, checkY, checkX + boxH, checkY + boxH)
            if checkboxes[sec.mainToggle].state then
                gl.Color(0.3, 0.7, 0.3, 0.9)
                gl.Rect(checkX + 2, checkY + 2, checkX + boxH - 2, checkY + boxH - 2)
            end
            -- Store hitbox for main toggle
            table.insert(uiHitboxes, {type="checkbox", name=sec.mainToggle, x1=checkX, y1=checkY, x2=checkX+boxH, y2=checkY+boxH})
        end
        gl.Color(UI.sectionHeaderColor[1], UI.sectionHeaderColor[2], UI.sectionHeaderColor[3], UI.sectionHeaderColor[4])
        -- Center header text
        local headerText = sec.name
        local headerTextWidth = gl.GetTextWidth(headerText) * UI.sectionHeaderSize
        gl.Text(headerText, headerX - headerTextWidth/2, headerCenterY - UI.sectionHeaderSize/2 + 2, UI.sectionHeaderSize, "o")
        -- Section content
        local contentY = headerBot - sec.optionPad
        for _, name in ipairs(sec.options) do
            local box = checkboxes[name]
            local cx = x + UI.padding
            gl.Color(0.2, 0.2, 0.2, 0.8)
            gl.Rect(cx, contentY, cx + boxH, contentY + boxH)
            if box.state then
                gl.Color(0.3, 0.7, 0.3, 0.9)
                gl.Rect(cx + 2, contentY + 2, cx + boxH - 2, contentY + boxH - 2)
            end
            gl.Color(1, 1, 1, 1)
            gl.Text(box.label, cx + 24, contentY + 2, 12)
            -- Store hitbox for option checkbox
            table.insert(uiHitboxes, {type="checkbox", name=name, x1=cx, y1=contentY, x2=cx+boxH, y2=contentY+boxH})
            contentY = contentY - spacing
        end
        if sec.slider then
            local slider = sec.slider
            local sliderX = x + UI.padding
            gl.Color(1, 1, 1, 1)
            gl.Text(slider.label, sliderX, contentY + 20, 12)
            gl.Color(0.2, 0.2, 0.2, 0.8)
            gl.Rect(sliderX, contentY, sliderX + 200, contentY + 6)
            local fillWidth = 200 * (slider.value - slider.min) / (slider.max - slider.min)
            gl.Color(0.3, 0.7, 0.3, 0.9)
            gl.Rect(sliderX, contentY, sliderX + fillWidth, contentY + 6)
            local knobX = sliderX + fillWidth
            local knobY = contentY + 3
            drawCircle(knobX + 1, knobY - 1, UI.sliderKnobSize/2 + 1, {0, 0, 0, 0.3})
            drawCircle(knobX, knobY, UI.sliderKnobSize/2, UI.sliderKnobColor)
            drawCircle(knobX - 2, knobY - 2, UI.sliderKnobSize/4, {1, 1, 1, 0.3})
            gl.Color(1, 1, 1, 1)
            gl.Text(string.format("%.0f", slider.value), sliderX + 210, contentY - 2, 12)
            -- Store hitbox for slider knob and bar
            local knobHitSize = UI.sliderKnobSize + 4
            table.insert(uiHitboxes, {type="slider", name=slider.label, slider=slider, x1=sliderX, y1=contentY-4, x2=sliderX+200, y2=contentY+10, knobX=knobX, knobY=knobY, knobR=knobHitSize})
            contentY = contentY - sliderH
        end
        cy = secBot - sectionGap
    end
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
    -- Use dynamic hitboxes
    for _, hit in ipairs(uiHitboxes) do
        if hit.type == "checkbox" then
            if mx >= hit.x1 and mx <= hit.x2 and my >= hit.y1 and my <= hit.y2 then
                checkboxes[hit.name].state = not checkboxes[hit.name].state
                Spring.SetConfigInt("scv_checkbox_"..hit.name, checkboxes[hit.name].state and 1 or 0)
                return true
            end
        elseif hit.type == "slider" then
            -- Check knob first
            if (mx - hit.knobX)^2 + (my - hit.knobY)^2 <= (hit.knobR)^2 or
               (mx >= hit.x1 and mx <= hit.x2 and my >= hit.y1 and my <= hit.y2) then
                activeDragSlider = hit.slider
                activeDragName = hit.name
                local ratio = (mx - hit.x1) / 200
                ratio = math.max(0, math.min(1, ratio))
                hit.slider.value = mathFloor(hit.slider.min + (hit.slider.max - hit.slider.min) * ratio)
                if hit.slider == sliders.healResurrectRadius then
                    healResurrectRadius = hit.slider.value
                    Spring.SetConfigInt("scv_healResurrectRadius", hit.slider.value)
                elseif hit.slider == sliders.reclaimRadius then
                    reclaimRadius = hit.slider.value
                    Spring.SetConfigInt("scv_reclaimRadius", hit.slider.value)
                elseif hit.slider == sliders.enemyAvoidanceRadius then
                    enemyAvoidanceRadius = hit.slider.value
                    Spring.SetConfigInt("scv_enemyAvoidanceRadius", hit.slider.value)
                end
                return true
            end
        end
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
    elseif key == 0x006C and mods.alt then  -- Alt+L to toggle logging
        isLoggingEnabled = not isLoggingEnabled
        Spring.Echo("RezBots logging " .. (isLoggingEnabled and "enabled" or "disabled"))
        if isLoggingEnabled then
            logCommandIDs()
        end
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




-- /////////////////////////////////////////// Centralized Processing System
-- Queue units for processing to prevent race conditions
function queueUnitForProcessing(unitID, unitData)
  if unitData then
    pendingProcessUnits[unitID] = unitData
    scvlog("Queued unit", unitID, "for processing")
  end
end

-- Process all queued units atomically to prevent race conditions
function processQueuedUnits()
  if next(pendingProcessUnits) then
    local unitsToProcess = {}
    for unitID, unitData in pairs(pendingProcessUnits) do
      unitsToProcess[unitID] = unitData
    end
    pendingProcessUnits = {}  -- Clear the queue
    
    scvlog("Processing", table.getn(unitsToProcess) or 0, "queued units atomically")
    processUnits(unitsToProcess)
  end
end

-- /////////////////////////////////////////// processUnits Function (Updated)
-- 
-- 
-- 

function processUnits(units)
  for unitID, unitData in pairs(units) do
    local unitDefID = spGetUnitDefID(unitID)
    if isMyResbot(unitID, unitDefID) then

      -- 0) HIGHEST PRIORITY: Resume interrupted resurrections
      if interruptedResurrections[unitID] and unitData.taskStatus ~= "in_progress" then
        local interrupted = interruptedResurrections[unitID]
        if Spring.ValidFeatureID(interrupted.featureID) then
          local featureDef = FeatureDefs[Spring.GetFeatureDefID(interrupted.featureID)]
          if featureDef and featureDef.resurrectable then
            -- Check if feature is still available (not at unit limit)
            local currentTargets = targetedFeatures[interrupted.featureID] or 0
            if currentTargets < maxUnitsPerFeature then
              scvlog("Unit", unitID, "resuming interrupted resurrection of feature", interrupted.featureID, "(attempt", interrupted.attempts .. ")")
              
              -- Reserve the feature
              targetedFeatures[interrupted.featureID] = currentTargets + 1
              
              -- Track active resurrection
              activeResurrections[interrupted.featureID] = activeResurrections[interrupted.featureID] or {}
              table.insert(activeResurrections[interrupted.featureID], unitID)
              
              -- Clear the interruption and resume
              interruptedResurrections[unitID] = nil
              giveScriptOrder(unitID, CMD.RESURRECT, {interrupted.featureID + Game.maxUnits}, {})
              unitData.featureID = interrupted.featureID
              unitData.taskType = "resurrecting"
              unitData.taskStatus = "in_progress"
              resurrectingUnits[unitID] = true
              
              return  -- Skip to next unit
            else
              scvlog("Unit", unitID, "cannot resume resurrection - feature", interrupted.featureID, "at unit limit")
            end
          end
        end
        
        -- Feature no longer exists/resurrectable or at limit
        scvlog("Unit", unitID, "abandoning interrupted resurrection - feature no longer valid/available")
        interruptedResurrections[unitID] = nil
      end

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


-- ///////////////////////////////////////////  UnitCommand Function
-- Detects when a player manually commands a unit
function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag)
  -- Only track commands for our RezBots
  if isMyResbot(unitID, unitDefID) then
    -- Check if this command was issued by our script
    local currentFrame = Spring.GetGameFrame()
    local isScriptCommand = false
    
    -- Grace period for newly created units (ignore commands in first 5 seconds)
    local unitData = unitsToCollect[unitID]
    if unitData and unitData.createdFrame then
      local framesSinceCreation = currentFrame - unitData.createdFrame
      if framesSinceCreation < 150 then  -- 5 seconds at 30fps
        scvlog("Ignoring command for newly created unit", unitID, "- grace period active (", framesSinceCreation, "frames since creation)")
        return
      end
    end
    
    -- Prevent duplicate manual command detection within the same frame
    local manualKey = unitID .. "_" .. cmdID .. "_" .. currentFrame
    if processedManualCommands[manualKey] then
      scvlog("Duplicate manual command detected for unit", unitID, "cmd", cmdID, "frame", currentFrame, "- ignoring")
      return  -- Already processed this command in this frame
    end
    
    -- Check if this matches any recent script-issued command (more flexible range for delayed execution)
    for key, _ in pairs(scriptIssuedCommands) do
      local keyUnitID, keyCmdID, keyFrame = key:match("^(%d+)_(%d+)_(%d+)$")
      if keyUnitID and keyCmdID and keyFrame then
        if tonumber(keyUnitID) == unitID and 
           tonumber(keyCmdID) == cmdID and 
           math.abs(currentFrame - tonumber(keyFrame)) <= 90 then  -- Increased to 90 frames (3 seconds) for very delayed commands
          isScriptCommand = true
          scriptIssuedCommands[key] = nil  -- Clean up this specific key
          break
        end
      end
    end
    
    if not isScriptCommand then
      -- DEBUG: Show what we're looking for vs what we have
      scvlog("COMMAND DEBUG: Looking for", unitID .. "_" .. cmdID .. "_" .. currentFrame, "±90 frames")
      scvlog("COMMAND DEBUG: Available script commands:")
      for key, _ in pairs(scriptIssuedCommands) do
        local keyUnitID, keyCmdID, keyFrame = key:match("^(%d+)_(%d+)_(%d+)$")
        if keyUnitID and keyCmdID and keyFrame then
          local frameDiff = math.abs(currentFrame - tonumber(keyFrame))
          local unitMatch = tonumber(keyUnitID) == unitID
          local cmdMatch = tonumber(keyCmdID) == cmdID
          scvlog("  ", key, "- UnitMatch:", unitMatch, "CmdMatch:", cmdMatch, "FrameDiff:", frameDiff)
        end
      end
      
      -- Check if this is a RezBot that should be tracked but isn't
      local unitData = unitsToCollect[unitID]
      if not unitData and isMyResbot(unitID, unitDefID) then
        -- This is a RezBot that exists but wasn't properly registered
        scvlog("Auto-registering missing RezBot: Unit " .. unitID)
        unitsToCollect[unitID] = {
          featureCount = 0,
          lastReclaimedFrame = 0,
          taskStatus = "idle"
        }
        unitData = unitsToCollect[unitID]
        
        -- Don't flag this as manual - it's just an untracked unit getting commands
        scvlog("Unit", unitID, "was auto-registered, treating command as normal behavior")
      else
        -- This is a legitimate manual command
        Spring.Echo("=== MANUAL COMMAND DETECTED ===")
        Spring.Echo("Unit " .. unitID .. " cmd " .. cmdID .. " frame " .. currentFrame)
        Spring.Echo("Unit is RezBot: " .. tostring(isMyResbot(unitID, unitDefID)))
        if unitData then
          Spring.Echo("Unit task status: " .. (unitData.taskStatus or "nil"))
                  Spring.Echo("Unit feature target: " .. (unitData.featureID or "nil"))
      else
        Spring.Echo("Unit not in unitsToCollect table")
      end
      Spring.Echo("Available tracked commands:")
      for key, _ in pairs(scriptIssuedCommands) do
        Spring.Echo("  " .. key)
      end
      Spring.Echo("=== END DEBUG ===")
      
      -- Mark this command as processed to prevent duplicate detection
      processedManualCommands[manualKey] = true
      
      manuallyCommandedUnits[unitID] = true
      scvlog("Unit", unitID, "has been manually commanded by player (cmd", cmdID, "), disabling automated behavior")
      
      -- If the unit was doing automated tasks, clean up its state
      if unitData then
        unitData.taskStatus = "manual_override"
      end
      end
    else
      scvlog("Unit", unitID, "received script command (cmd", cmdID, "), continuing automation")
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
      taskStatus = "idle",  -- Set the task status to "idle" when the unit is created
      createdFrame = Spring.GetGameFrame()  -- Track creation frame for grace period
    }
    queueUnitForProcessing(unitID, unitsToCollect[unitID])
  end
  
  -- Process queued units immediately for newly created units
  processQueuedUnits()
end

-- Handle resurrected units (they trigger UnitFinished, not always UnitCreated)
function widget:UnitFinished(unitID, unitDefID, unitTeam)
  if isMyResbot(unitID, unitDefID) then
    local unitData = unitsToCollect[unitID]
    
    if not unitData then
      -- This unit wasn't registered in UnitCreated (likely resurrected)
      scvlog("Resbot finished (likely resurrected): UnitID = " .. unitID)
      unitsToCollect[unitID] = {
        featureCount = 0,
        lastReclaimedFrame = 0,
        taskStatus = "idle",
        createdFrame = Spring.GetGameFrame()  -- Track creation frame for grace period
      }
      queueUnitForProcessing(unitID, unitsToCollect[unitID])
      -- Process queued units immediately for resurrected units  
      processQueuedUnits()
    else
      -- Unit already exists (normal build process), just ensure proper state
      scvlog("Resbot finished normally: UnitID = " .. unitID)
      
      -- Clear any manual command flags from when it was dead
      if manuallyCommandedUnits[unitID] then
        manuallyCommandedUnits[unitID] = nil
        scvlog("Cleared manual command flag for finished unit", unitID)
      end
      
      -- Ensure it's in idle state and ready for tasks (avoid double processUnits call)
      if unitData.taskStatus ~= "idle" then
        scvlog("Resetting finished RezBot to idle: UnitID = " .. unitID)
        unitData.taskStatus = "idle"
        -- Don't call processUnits here - let the normal GameFrame logic handle it
      end
    end
  end
end

function widget:UnitDestroyed(unitID, unitDefID, teamID)
  -- Clean up if this was one of our RezBots
  if unitsToCollect[unitID] then
    unitsToCollect[unitID] = nil
    
    -- Clean up manual command tracking
    if manuallyCommandedUnits[unitID] then
        manuallyCommandedUnits[unitID] = nil
    end
    
    -- Clean up progress tracking
    if lastProgressCheck[unitID] then
        lastProgressCheck[unitID] = nil
    end
    
    -- Clean up stuck check tracking
    if lastStuckCheck[unitID] then
        lastStuckCheck[unitID] = nil
    end
    
    -- Clean up position tracking
    if unitLastPosition[unitID] then
        unitLastPosition[unitID] = nil
    end
    
    -- Clean up resurrection tracking
    if interruptedResurrections[unitID] then
        interruptedResurrections[unitID] = nil
    end
  end
  
  -- Clean up healing tracking if this unit was being healed (regardless of whether it was a RezBot)
  if healingTargets[unitID] then
    scvlog("Unit", unitID, "being healed has died, cleaning up healing assignments")
    
    -- Find all RezBots that were healing this unit and clear their assignments
    for rezbotID, targetID in pairs(healingUnits) do
      if targetID == unitID then
        healingUnits[rezbotID] = nil
        scvlog("Cleared healing assignment for RezBot", rezbotID, "due to target death")
        
        -- Set the RezBot back to idle so it can find new tasks
        local unitData = unitsToCollect[rezbotID]
        if unitData and unitData.taskStatus == "in_progress" and unitData.taskType == "healing" then
          unitData.taskStatus = "idle"
          scvlog("Set RezBot", rezbotID, "to idle after healing target died")
        end
      end
    end
    
    -- Clear the healing target counter
    healingTargets[unitID] = nil
  end
end


-- ///////////////////////////////////////////  FeatureDestroyed Function
function widget:FeatureDestroyed(featureID, allyTeam)
  -- Early exit: only process if this feature was actually targeted by our RezBots
  if not targetedFeatures[featureID] then
    return  -- Not a feature we care about, skip processing
  end
  
  scvlog("Feature destroyed: FeatureID = " .. featureID)
  
  -- Find ALL units that were targeting this specific feature
  local affectedUnits = {}
  for unitID, data in pairs(unitsToCollect) do
    local unitDefID = spGetUnitDefID(unitID)
    if isMyResbot(unitID, unitDefID) then  -- Use isMyResbot to check if the unit is a Resbot
      if data.featureID == featureID then
        -- Clear the destroyed feature assignment
        data.featureID = nil
        data.lastReclaimedFrame = Spring.GetGameFrame()
        data.taskStatus = "idle"  -- reset the unit to idle after feature destroyed
        affectedUnits[unitID] = data
        scvlog("Unit", unitID, "was targeting destroyed feature", featureID, "- marked for reprocessing")
      end
    end
  end
  
  -- Queue only the units that were actually affected by this feature destruction
  if next(affectedUnits) then
    scvlog("Queueing", table.getn(affectedUnits) or 0, "units affected by feature", featureID, "destruction")
    for unitID, data in pairs(affectedUnits) do
      queueUnitForProcessing(unitID, data)
    end
  else
    scvlog("No units were targeting destroyed feature", featureID)
  end
  targetedFeatures[featureID] = nil  -- Clear the target as the feature is destroyed
  
  -- Clean up active resurrection tracking
  if activeResurrections[featureID] then
    scvlog("Feature", featureID, "destroyed - clearing active resurrection tracking for", #activeResurrections[featureID], "units")
    activeResurrections[featureID] = nil
  end
  
  -- Clean up any interrupted resurrections for this feature  
  for unitID, interrupted in pairs(interruptedResurrections) do
    if interrupted.featureID == featureID then
      scvlog("Feature", featureID, "destroyed - clearing interrupted resurrection for unit", unitID)
      interruptedResurrections[unitID] = nil
    end
  end
  
  -- Process any queued units from feature destruction
  processQueuedUnits()
end




-- /////////////////////////////////////////// GameFrame Function
function widget:GameFrame(currentFrame)
  local stuckCheckInterval     = 300   -- Reduced from 1000 to 300 (10 seconds instead of 33)
  local resourceCheckInterval  = 150   -- Interval to check and reassign tasks
  local actionInterval         = 30

  -- 1) Only run main actions every 'actionInterval' frames
  if (currentFrame % actionInterval == 0) then
    for unitID, unitData in pairs(unitsToCollect) do
      local unitDefID = Spring.GetUnitDefID(unitID)
      if isMyResbot(unitID, unitDefID) then
        if Spring.ValidUnitID(unitID) and not Spring.GetUnitIsDead(unitID) then
          -- Skip all automated logic if unit has been manually commanded
          if not manuallyCommandedUnits[unitID] then
            ----------------------------------------------------------------------
            -- (A) Check for nearby enemies and possibly flee
            ----------------------------------------------------------------------
            local isFleeing = maintainSafeDistanceFromEnemy(unitID, unitData, enemyAvoidanceRadius)

            ----------------------------------------------------------------------
            -- (B) If not fleeing, handle tasks if idle or completed
            ----------------------------------------------------------------------
            if (not isFleeing) and 
               (unitData.taskStatus == "idle" or unitData.taskStatus == "completed") then
              queueUnitForProcessing(unitID, unitData)
            end
          else
            scvlog("Skipping automated logic for manually commanded unit", unitID)
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
        -- Only check for stuck units if they're not manually commanded
        if not manuallyCommandedUnits[unitID] then
          handleStuckUnits(unitID, UnitDefs[unitDefID])
        end
      end
    end
  end

  -- 3) Periodically check resource needs & reassign tasks if necessary
  if (currentFrame % resourceCheckInterval == 0) then
    local resourceNeed = assessResourceNeeds()
    if resourceNeed ~= "full" then
      for unitID, unitData in pairs(unitsToCollect) do
        local unitDefID = Spring.GetUnitDefID(unitID)
        if isMyResbot(unitID, unitDefID) then
          -- If the unit is idle or completed, see if there's something to do
          -- But only if not manually commanded
          if (unitData.taskStatus == "idle" or unitData.taskStatus == "completed") and 
             not manuallyCommandedUnits[unitID] then
            queueUnitForProcessing(unitID, unitData)
          end
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
    
    -- Clean up old manual command detection entries (older than 60 frames)
    for key, _ in pairs(processedManualCommands) do
      local frameStr = key:match("_(%d+)$")
      if frameStr and (currentFrame - tonumber(frameStr)) > 60 then
        processedManualCommands[key] = nil
      end
    end
  end

  -- 5) Check for units idle too long and send them to safety (only every 150 frames)
  if (currentFrame % 150 == 0) then
    for unitID, unitData in pairs(unitsToCollect) do
      local unitDefID = spGetUnitDefID(unitID)
      if isMyResbot(unitID, unitDefID) then
        -- Only handle truly idle units that haven't been manually commanded
        if unitData.taskStatus == "idle" and not manuallyCommandedUnits[unitID] then
          -- Initialize idle timer if not set
          if not lastIdleFrame[unitID] then
            lastIdleFrame[unitID] = currentFrame
          end
          
                    -- Don't check if unit is already fleeing or returning
          if not unitsMovingToSafety[unitID] and unitData.taskStatus ~= "returning_to_friendly" then
            local timeIdle = currentFrame - lastIdleFrame[unitID]
            if timeIdle >= IDLE_TIMEOUT_FRAMES then
              local ux, uy, uz = Spring.GetUnitPosition(unitID)
              if ux and uz then -- Sanity check
                -- Quick check: are there any combat units nearby? If so, skip expensive regroup logic
                local myTeamID = Spring.GetMyTeamID()
                local quickCheckRadius = math.max(300, enemyAvoidanceRadius / 2)  -- Half of safe distance, minimum 300 units
                local nearbyUnits = Spring.GetUnitsInCylinder(ux, uz, quickCheckRadius)
                local hasCombatNearby = false
                
                for _, otherUnitID in ipairs(nearbyUnits) do
                  if otherUnitID ~= unitID then
                    local unitTeam = Spring.GetUnitTeam(otherUnitID)
                    if unitTeam == myTeamID then
                      local otherDefID = spGetUnitDefID(otherUnitID)
                      local otherDef = UnitDefs[otherDefID]
                      if otherDef and 
                         not isMyResbot(otherUnitID, otherDefID) and 
                         not otherDef.isAirUnit and 
                         not otherDef.canRepair and 
                         otherDef.weapons and #otherDef.weapons > 0 then
                        hasCombatNearby = true
                        break
                      end
                    end
                  end
                end
                
                if hasCombatNearby then
                  scvlog("Unit " .. unitID .. " already has combat units nearby, skipping regroup")
                  lastIdleFrame[unitID] = currentFrame  -- Reset idle timer
                else
                  -- No combat units nearby, do full regroup search
                  scvlog("Unit " .. unitID .. " isolated, searching for regroup target")
                  local searchRadius = idleRegroupRadius -- Use configurable idle regroup radius
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
                    
                    scvlog("Regrouping isolated unit " .. unitID .. " to combat unit at distance " .. math.sqrt(minDistSq) .. " (idle for " .. timeIdle .. " frames)")
                    giveScriptOrder(unitID, CMD.MOVE, {safeX, safeY, safeZ}, {})
                    unitData.taskStatus = "returning_to_friendly"
                    lastIdleFrame[unitID] = nil  -- Clear idle timer since unit is now tasked
                  else
                    scvlog("Unit " .. unitID .. " found combat unit but too close (distance: " .. math.sqrt(minDistSq) .. ")")
                  end
                end
              end
            end
          -- Don't reset idle timer here - let it accumulate until unit gets a real task
        end
      else
        -- Reset idle timer for non-idle units
        lastIdleFrame[unitID] = currentFrame
      end
    end
  end
  end  -- End of idle regroup interval check
  
  -- RACE CONDITION FIX: Process all queued units atomically at the end of the frame
  processQueuedUnits()
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
    -- Validate that the enemy unit is actually alive and valid
    if Spring.ValidUnitID(enemyID) and not Spring.GetUnitIsDead(enemyID) then
      local enemyDefID = spGetUnitDefID(enemyID)
      local enemyDef = UnitDefs[enemyDefID]
      if enemyDef then
        -- Filter out critters and other non-threatening units
        local isThreat = false
        if enemyDef.weapons and #enemyDef.weapons > 0 then
          isThreat = true  -- Has weapons
        elseif enemyDef.canCapture or enemyDef.canReclaim then
          isThreat = true  -- Can capture/reclaim (constructor units)
        elseif enemyDef.buildOptions and #enemyDef.buildOptions > 0 then
          isThreat = true  -- Can build (factory/constructor)
        end
        
        -- Skip non-threatening units (critters, debris, etc.)
        if isThreat then
          local ex, ey, ez = spGetUnitPosition(enemyID)
          if ex and ez then
            local distSq = (x - ex)^2 + (z - ez)^2
            if distSq < minDistSq then
              minDistSq = distSq
              nearestEnemy = enemyID
              isAirUnit = enemyDef.isAirUnit
            end
          end
        else
          scvlog("Ignoring non-threatening unit:", enemyID, "name:", enemyDef.name)
        end
      end
    end
  end

  return nearestEnemy, math.sqrt(minDistSq), isAirUnit
end



-- ///////////////////////////////////////////  maintainSafeDistanceFromEnemy Function
function maintainSafeDistanceFromEnemy(unitID, unitData, defaultAvoidanceRadius)
  local nearestEnemy, distance, isAirUnit = findNearestEnemy(unitID, defaultAvoidanceRadius)
  
  -- Debug logging to track enemy detection
  if nearestEnemy then
    -- Debug: Check what this "enemy" actually is
    local enemyDefID = Spring.GetUnitDefID(nearestEnemy)
    local enemyDef = UnitDefs[enemyDefID]
    local enemyTeam = Spring.GetUnitTeam(nearestEnemy)
    local myTeam = Spring.GetMyTeamID()
    local isAlly = Spring.AreTeamsAllied(myTeam, enemyTeam)
    scvlog("Unit", unitID, "detected enemy", nearestEnemy, "at distance", distance, "avoidance radius", defaultAvoidanceRadius)
    scvlog("ENEMY DEBUG: Unit " .. nearestEnemy .. " DefID: " .. (enemyDefID or "nil") .. " Name: " .. (enemyDef and enemyDef.name or "unknown") .. " Team: " .. (enemyTeam or "nil") .. " MyTeam: " .. myTeam .. " Allied: " .. tostring(isAlly) .. " Dead: " .. tostring(Spring.GetUnitIsDead(nearestEnemy)))
  end
  
  if nearestEnemy and distance < defaultAvoidanceRadius then
    -- Check if unit is currently resurrecting - save progress before fleeing
    if unitData.taskType == "resurrecting" and unitData.featureID then
      local featureID = unitData.featureID
      local currentFrame = Spring.GetGameFrame()
      
      -- Check if we already have an interrupted resurrection record
      local interrupted = interruptedResurrections[unitID]
      if interrupted and interrupted.featureID == featureID then
        -- Increment attempts for the same feature
        interrupted.attempts = interrupted.attempts + 1
        interrupted.startFrame = currentFrame
        scvlog("Unit", unitID, "interrupting resurrection again - feature", featureID, "attempt", interrupted.attempts)
      else
        -- New interruption
        interruptedResurrections[unitID] = {
          featureID = featureID,
          startFrame = currentFrame,
          attempts = 1
        }
        scvlog("Unit", unitID, "interrupting resurrection - feature", featureID, "first attempt")
      end
      
      -- Check attempt limit with temporary unreachable marking
      if interrupted and interrupted.attempts >= 5 then
        scvlog("Unit", unitID, "reached 5 resurrection attempts for feature", featureID, "- marking temporarily unreachable")
        -- Mark as temporarily unreachable using existing system
        unreachableFeatures[featureID] = currentFrame
        interruptedResurrections[unitID] = nil  -- Clear the interruption record
      end
      
      -- Clean up active resurrection tracking
      if activeResurrections[featureID] then
        for i = #activeResurrections[featureID], 1, -1 do
          if activeResurrections[featureID][i] == unitID then
            table.remove(activeResurrections[featureID], i)
            break
          end
        end
        if #activeResurrections[featureID] == 0 then
          activeResurrections[featureID] = nil
        end
      end
    end
    
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
      scvlog("Unit", unitID, "FLEEING from enemy", nearestEnemy, "to position", safeX, safeZ)
      giveScriptOrder(unitID, CMD.MOVE, {safeX, safeY, safeZ}, {})
      lastFleePosition[unitID] = {x = safeX, y = safeY, z = safeZ}
    else
      scvlog("Unit", unitID, "already fleeing, not issuing new order")
    end

    unitsMovingToSafety[unitID] = true
    unitData.taskStatus = "fleeing"
    scvlog("Unit", unitID, "taskStatus set to fleeing")
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
  local bestScore = math.huge
  local maxFeaturesToConsider = 25  -- Maximum number of features to consider
  local nearestFeatures = {}

  -- First pass: collect distances and initial filtering
  for _, featureID in ipairs(featuresInRadius) do
      -------------------------------------------------------
      -- 1) Check if we already marked this feature unreachable
      -------------------------------------------------------
      if not unreachableFeatures[featureID] then
          -------------------------------------------------------
          -- 2) Check if this feature is being actively resurrected
          -------------------------------------------------------
          if activeResurrections[featureID] then
              scvlog("Skipping feature", featureID, "- being resurrected by", #activeResurrections[featureID], "units")
          else
          local featureDefID = spGetFeatureDefID(featureID)
          if featureDefID then
              local fDef = FeatureDefs[featureDefID]
              if fDef and fDef.reclaimable then
                  -- Commander exclusion logic (no goto)
                  local isCommanderWreck = checkboxes.excludeCommanders.state and fDef.customParams and fDef.customParams.fromunit and commanderNames[fDef.customParams.fromunit]
                  if not isCommanderWreck then
                      local fx, _, fz = Spring.GetFeaturePosition(featureID)
                      local distSq = (x - fx)^2 + (z - fz)^2
                      local fMetal = fDef.metal or 0
                      local fEnergy = fDef.energy or 0
                      local effectiveMetal = needMetal and fMetal or 0
                      local effectiveEnergy = needEnergy and fEnergy or 0

                      if (effectiveMetal + effectiveEnergy) > 0 then
                          -- Store feature data if it has resources we need
                          if #nearestFeatures < maxFeaturesToConsider then
                              table.insert(nearestFeatures, {
                                  id = featureID,
                                  distSq = distSq,
                                  metal = effectiveMetal,
                                  energy = effectiveEnergy
                              })
                          else
                              -- Replace the worst scoring feature if this one is better
                              local worstIdx, worstScore = 1, -math.huge
                              for i, feat in ipairs(nearestFeatures) do
                                  local score = feat.distSq * dynamicWeightDistance - (feat.metal + feat.energy)
                                  if score > worstScore then
                                      worstIdx = i
                                      worstScore = score
                                  end
                              end
                              
                              local newScore = distSq * dynamicWeightDistance - (effectiveMetal + effectiveEnergy)
                              if newScore < worstScore then
                                  nearestFeatures[worstIdx] = {
                                      id = featureID,
                                      distSq = distSq,
                                      metal = effectiveMetal,
                                      energy = effectiveEnergy
                                  }
                              end
                          end
                      end
                  else
                      scvlog("Skipping commander wreck for featureID", featureID)
                  end
              end
          end
          end  -- End of active resurrection check
      end
  end

  -- Second pass: find the best feature among the nearest ones and IMMEDIATELY reserve it
  for _, feat in ipairs(nearestFeatures) do
      local alreadyTargetedCount = targetedFeatures[feat.id] or 0
      if alreadyTargetedCount < maxUnitsPerFeature then
          local score = feat.distSq * dynamicWeightDistance - (feat.metal + feat.energy)
          if score < bestScore then
              bestScore = score
              bestFeature = feat.id
          end
      end
  end

  -- RACE CONDITION FIX: Reserve the slot immediately before returning
  if bestFeature then
      targetedFeatures[bestFeature] = (targetedFeatures[bestFeature] or 0) + 1
      scvlog("RESERVED: Feature", bestFeature, "now reserved by unit", unitID, "- count:", targetedFeatures[bestFeature])
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
          giveScriptOrder(unitID, CMD.REPAIR, {nearestDamagedUnit}, {})
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
      -- Feature was already reserved in findReclaimableFeature - no need to increment again
      local currentCount = targetedFeatures[featureID] or 0
      scvlog("Unit", unitID, "is reclaiming feature", featureID, "- already reserved, count:", currentCount)
      
      giveScriptOrder(unitID, CMD.RECLAIM, {featureID + Game.maxUnits}, {})
      unitData.featureCount       = 1
      unitData.lastReclaimedFrame = Spring.GetGameFrame()
      unitData.featureID          = featureID  -- Store the target feature ID
      -- targetedFeatures[featureID] increment removed - already done in findReclaimableFeature
      
      -- Debug: Check count after assignment (should be same as currentCount)
      local finalCount = targetedFeatures[featureID]
      scvlog("Feature", featureID, "final assignment count:", finalCount, "(limit:", maxUnitsPerFeature, ")")
      if finalCount > maxUnitsPerFeature then
          Spring.Echo("WARNING: Feature " .. featureID .. " exceeded limit! Has " .. finalCount .. " units (max " .. maxUnitsPerFeature .. ")")
      end
      
      unitData.taskType           = "reclaiming"
      unitData.taskStatus         = "in_progress"
      return true
  else
      -- CLEANUP: If findReclaimableFeature reserved a slot but the feature is now invalid, clean up the reservation
      if featureID then
          scvlog("Feature", featureID, "was reserved but is now invalid, cleaning up reservation")
          targetedFeatures[featureID] = (targetedFeatures[featureID] or 0) - 1
          if targetedFeatures[featureID] <= 0 then
              targetedFeatures[featureID] = nil
          end
      end
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
                      -- RACE CONDITION FIX: Reserve the slot immediately
                      targetedFeatures[featureID] = (targetedFeatures[featureID] or 0) + 1
                      local currentCount = targetedFeatures[featureID]
                      scvlog("Unit", unitID, "is resurrecting feature", featureID, "- reserved, count:", currentCount)
                      
                      -- Track active resurrection
                      activeResurrections[featureID] = activeResurrections[featureID] or {}
                      table.insert(activeResurrections[featureID], unitID)
                      
                      giveScriptOrder(unitID, CMD.RESURRECT, {featureID + Game.maxUnits}, {})
                      unitData.featureID = featureID  -- Store the target feature ID
                      unitData.taskType = "resurrecting"
                      unitData.taskStatus = "in_progress"
                      resurrectingUnits[unitID] = true
                      
                      -- Debug: Check final count
                      local finalCount = targetedFeatures[featureID]
                      scvlog("Feature", featureID, "final resurrection count:", finalCount, "(limit:", maxUnitsPerFeature, ")")
                      if finalCount > maxUnitsPerFeature then
                          Spring.Echo("WARNING: Feature " .. featureID .. " exceeded resurrection limit! Has " .. finalCount .. " units (max " .. maxUnitsPerFeature .. ")")
                      end
                      
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

  -- Clear manual command flag when unit becomes idle
  if manuallyCommandedUnits[unitID] then
    manuallyCommandedUnits[unitID] = nil
    scvlog("Unit", unitID, "is now idle, re-enabling automated behavior")
  end

  -- Immediately reassign a new task for the unit
  if (unitDef.canReclaim and checkboxes.collecting.state) or
     (unitDef.canResurrect and checkboxes.resurrecting.state) or
     (unitDef.canRepair and checkboxes.healing.state) then
    scvlog("Re-queueing UnitID for tasks:", unitID)
    queueUnitForProcessing(unitID, unitData)
  end

  -- Clear any lingering target associations ONLY if the unit is truly going idle
  -- Don't clean up if the unit was just assigned a task (taskStatus = "in_progress")
  if unitData.featureID and unitData.taskStatus ~= "in_progress" then
    scvlog("Handling targeted feature for UnitID:", unitID, "featureID:", unitData.featureID)
    targetedFeatures[unitData.featureID] = (targetedFeatures[unitData.featureID] or 0) - 1
    if targetedFeatures[unitData.featureID] <= 0 then
      targetedFeatures[unitData.featureID] = nil
    end
    unitData.featureID = nil
  elseif unitData.featureID and unitData.taskStatus == "in_progress" then
    scvlog("Unit", unitID, "has active assignment to feature", unitData.featureID, "- not cleaning up")
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
    
    -- Clean up active resurrection tracking
    if unitData.featureID and activeResurrections[unitData.featureID] then
      for i = #activeResurrections[unitData.featureID], 1, -1 do
        if activeResurrections[unitData.featureID][i] == unitID then
          table.remove(activeResurrections[unitData.featureID], i)
          scvlog("Removed unit", unitID, "from active resurrection tracking for feature", unitData.featureID)
          break
        end
      end
      if #activeResurrections[unitData.featureID] == 0 then
        activeResurrections[unitData.featureID] = nil
        scvlog("No more units resurrecting feature", unitData.featureID, "- clearing active tracking")
      end
    end
  end
  
  -- Process any queued units from UnitIdle
  processQueuedUnits()
end





-- ///////////////////////////////////////////  isUnitStuck Function
local checkInterval = 150  -- Reduced from 500 to 150 frames (5 seconds instead of 16)

function isUnitStuck(unitID)
  local currentFrame = Spring.GetGameFrame()
  if lastStuckCheck[unitID] and (currentFrame - lastStuckCheck[unitID]) < checkInterval then
    scvlog("Skipping stuck check for unit due to cooldown: UnitID = " .. unitID)
    return false  -- Skip check if within the cooldown period
  end

  lastStuckCheck[unitID] = currentFrame

  local minMoveDistance = 0.8  -- Further reduced for even more sensitive detection
  local x, y, z = spGetUnitPosition(unitID)
  local lastPos = unitLastPosition[unitID] or {x = x, y = y, z = z}
  local distanceMoved = math.sqrt((lastPos.x - x)^2 + (lastPos.z - z)^2)
  local stuck = distanceMoved < minMoveDistance
  
  -- Additional check: if unit is actively trying to reclaim/resurrect but hasn't moved much
  local unitData = unitsToCollect[unitID]
  if unitData and unitData.taskStatus == "in_progress" then
      -- Check if unit has current commands (trying to do something but can't reach it)
      local commands = Spring.GetUnitCommands(unitID, 1)
      if commands and #commands > 0 then
          local cmd = commands[1]
          -- If unit has reclaim or resurrect command but is stuck, it's likely an unreachable target
          if cmd.id == CMD.RECLAIM or cmd.id == CMD.RESURRECT then
              -- Track progress toward target
              local targetDistance = nil
              if cmd.params and #cmd.params >= 3 then
                  local tx, tz = cmd.params[1], cmd.params[3]
                  targetDistance = math.sqrt((x - tx)^2 + (z - tz)^2)
              end
              
              local progressData = lastProgressCheck[unitID]
              if not progressData then
                  lastProgressCheck[unitID] = {
                      lastDistance = targetDistance or 9999,
                      lastFrame = currentFrame,
                      stuckFrames = 0
                  }
              else
                  -- Check if we're making progress toward target
                  local madeProgress = false
                  if targetDistance and progressData.lastDistance then
                      madeProgress = (progressData.lastDistance - targetDistance) > 0.5
                  end
                  
                  if madeProgress or distanceMoved > 1.0 then
                      -- Reset stuck counter if making progress
                      progressData.stuckFrames = 0
                      progressData.lastDistance = targetDistance
                      progressData.lastFrame = currentFrame
                  else
                      -- Increment stuck counter
                      progressData.stuckFrames = progressData.stuckFrames + (currentFrame - progressData.lastFrame)
                      progressData.lastFrame = currentFrame
                      
                      -- If stuck for more than 3 seconds (90 frames), consider it unreachable
                      if progressData.stuckFrames > 90 then
                          scvlog("Unit", unitID, "hasn't made progress for", progressData.stuckFrames, "frames - unreachable target")
                          unitLastPosition[unitID] = {x = x, y = y, z = z}
                          lastProgressCheck[unitID] = nil  -- Reset
                          return true
                      end
                  end
              end
          end
      else
          -- No commands, reset progress tracking
          lastProgressCheck[unitID] = nil
      end
  else
      -- Not in progress, reset progress tracking
      lastProgressCheck[unitID] = nil
  end
  
  unitLastPosition[unitID] = {x = x, y = y, z = z}

  if stuck then
    scvlog("Unit is stuck: UnitID = " .. unitID, "distance moved:", distanceMoved)
  else
    scvlog("Unit is not stuck: UnitID = " .. unitID, "distance moved:", distanceMoved)
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
              
              -- If we don't have featureID stored, try to find it from nearby features
              if not featureID then
                  local ux, uy, uz = Spring.GetUnitPosition(unitID)
                  if ux and uz then
                      -- Look for features within a small radius that this unit might be trying to reach
                      local nearbyFeatures = Spring.GetFeaturesInCylinder(ux, uz, 100)
                      for _, nearbyFeatureID in ipairs(nearbyFeatures) do
                          -- Check if this feature is targeted and has resources/is resurrectable
                          if targetedFeatures[nearbyFeatureID] then
                              local featureDefID = spGetFeatureDefID(nearbyFeatureID)
                              if featureDefID then
                                  local fDef = FeatureDefs[featureDefID]
                                  if fDef and (fDef.reclaimable or fDef.resurrectable) then
                                      featureID = nearbyFeatureID
                                      scvlog("Found likely stuck target: featureID", featureID)
                                      break
                                  end
                              end
                          end
                      end
                  end
              end

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
              else
                  scvlog("Could not identify stuck target for unit", unitID)
              end
          end

          -- 2) Force the stuck unit to STOP
          giveScriptOrder(unitID, CMD.STOP, {}, {})

          -- 3) Reset the unit's data to idle
          unitsToCollect[unitID] = {
              featureCount       = 0,
              lastReclaimedFrame = 0,
              taskStatus         = "idle",
              featureID          = nil
          }

          -- Queue the unit for processing to pick a new task
          queueUnitForProcessing(unitID, unitsToCollect[unitID])
          -- Process queued units immediately for stuck units
          processQueuedUnits()

      else
          scvlog("Unit is not stuck: UnitID = " .. unitID)
      end
  else
      scvlog("Unit is not a Resbot or UnitDef is not valid: UnitID = " .. unitID)
  end
end


