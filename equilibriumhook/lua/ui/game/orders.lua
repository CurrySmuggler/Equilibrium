-- *****************************************************************************
-- * File: lua/modules/ui/game/orders.lua
-- * Author: Chris Blackwell
-- * Summary: Unit orders UI
-- *
-- * Copyright � 2005 Gas Powered Games, Inc.  All rights reserved.
-- *****************************************************************************

local UIUtil = import('/lua/ui/uiutil.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Grid = import('/lua/maui/grid.lua').Grid
local Checkbox = import('/lua/maui/checkbox.lua').Checkbox
local GameCommon = import('/lua/ui/game/gamecommon.lua')
local Button = import('/lua/maui/button.lua').Button
local Tooltip = import('/lua/ui/game/tooltip.lua')
local TooltipInfo = import('/lua/ui/help/tooltips.lua')
local Prefs = import('/lua/user/prefs.lua')
local CM = import('/lua/ui/game/commandmode.lua')
local UIMain = import('/lua/ui/uimain.lua')
local Select = import('/lua/ui/game/selection.lua')



local function IsAutoRefuelMode(units)
    return UnitData[units[1]:GetEntityId()].AutoRefuel == true
end

local function DockOrderInit(control, unitList)
    if not control.autoModeIcon then
        control.autoModeIcon = Bitmap(control, UIUtil.UIFile('/game/orders/autocast_yellow.dds'))
        LayoutHelpers.AtCenterIn(control.autoModeIcon, control)
        control.autoModeIcon:DisableHitTest()
        control.autoModeIcon:SetAlpha(0)
        control.autoModeIcon.OnHide = function(self, hidden)
            if not hidden and control:IsDisabled() then
                return true
            end
        end
    end 

    if not control.mixedModeIcon then
        control.mixedModeIcon = Bitmap(control.autoModeIcon, UIUtil.UIFile('/game/orders-panel/question-mark_bmp.dds'))
        LayoutHelpers.AtRightTopIn(control.mixedModeIcon, control)
        control.mixedModeIcon:DisableHitTest()
        control.mixedModeIcon:SetAlpha(0)
        control.mixedModeIcon.OnHide = function(self, hidden)
            if not hidden and control:IsDisabled() then
                return true
            end
        end
    end

    control._isAutoFuelMode = IsAutoRefuelMode(unitList)

    control._curHelpText = control._data.helpText
    if control._isAutoFuelMode then
        control.autoModeIcon:SetAlpha(1)
    else
        control.autoModeIcon:SetAlpha(0)
    end

    -- needs to override this to prevent call to self:DisableHitTest()
    control.Disable = function(self)
        self._isDisabled = true
        self:OnDisable()
    end
end



-- used by orders that happen immediately and don't change the command mode (ie the stop button)
local function DockOrderBehavior(self, modifiers)
    if modifiers.Left then
        if modifiers.Shift then
            IssueDockCommand(false)
        else
            IssueDockCommand(true)
        end
        self:SetCheck(false)
    elseif modifiers.Right then
        self._curHelpText = self._data.helpText
        if self._isAutoFuelMode then
            self.autoModeIcon:SetAlpha(0)
            self._isAutoFuelMode = false
        else
            self.autoModeIcon:SetAlpha(1)
            self._isAutoFuelMode = true
        end

        if controls.mouseoverDisplay.text then
            controls.mouseoverDisplay.text:SetText(self._curHelpText)
        end
        local cb = { Func = 'AutoRefuel', Args = { auto = self._isAutoFuelMode == true } }
        SimCallback(cb, true)
    end
end


-- sets up an orderInfo for each order that comes in
-- preferredSlot is custom data that is used to determine what slot the order occupies
-- initialStateFunc is a function that gets called once the control is created and allows you to set the initial state of the button
--      the function should have this declaration: function(checkbox, unitList)
-- extraInfo is used for storing any extra information required in setting up the button
local defaultOrdersTable = {
    -- Common rules
    AttackMove = {                  helpText = "attack_move",   bitmapId = 'attack_move',           preferredSlot = 1,  behavior = AttackMoveBehavior, },
    RULEUCC_Move = {                helpText = "move",          bitmapId = 'move',                  preferredSlot = 2,  behavior = StandardOrderBehavior,},
    RULEUCC_Attack = {              helpText = "attack",        bitmapId = 'attack',                preferredSlot = 3,  behavior = StandardOrderBehavior, },
    RULEUCC_Patrol = {              helpText = "patrol",        bitmapId = 'patrol',                preferredSlot = 4,  behavior = StandardOrderBehavior, },
    RULEUCC_Stop = {                helpText = "stop",          bitmapId = 'stop',                  preferredSlot = 5,  behavior = StopOrderBehavior, },
    RULEUCC_Guard = {               helpText = "assist",        bitmapId = 'guard',                 preferredSlot = 6,  behavior = StandardOrderBehavior, },
    RULEUCC_RetaliateToggle = {     helpText = "mode",          bitmapId = 'stand-ground',          preferredSlot = 7,  behavior = RetaliateOrderBehavior, initialStateFunc = RetaliateInitFunction},
    -- Unit specific rules
    RULEUCC_Overcharge = {          helpText = "overcharge",    bitmapId = 'overcharge',            preferredSlot = 8,  behavior = OverchargeBehavior, initialStateFunc = OverchargeInit, onframe = OverchargeFrame},
    RULEUCC_SiloBuildTactical = {   helpText = "build_tactical",bitmapId = 'silo-build-tactical',   preferredSlot = 9,  behavior = BuildOrderBehavior, initialStateFunc = BuildInitFunction,},
    RULEUCC_SiloBuildNuke = {       helpText = "build_nuke",    bitmapId = 'silo-build-nuke',       preferredSlot = 9,  behavior = BuildOrderBehavior, initialStateFunc = BuildInitFunction,},
    RULEUCC_Script = {       helpText = "special_action",bitmapId = 'overcharge',                   preferredSlot = 8,  behavior = StandardOrderBehavior},
    RULEUCC_Transport = {           helpText = "transport",     bitmapId = 'unload',                preferredSlot = 9,  behavior = StandardOrderBehavior, },
    RULEUCC_Nuke = {                helpText = "fire_nuke",     bitmapId = 'launch-nuke',           preferredSlot = 10,  behavior = StandardOrderBehavior, ButtonTextFunc = NukeBtnText},
    RULEUCC_Tactical = {            helpText = "fire_tactical", bitmapId = 'launch-tactical',       preferredSlot = 10,  behavior = StandardOrderBehavior, ButtonTextFunc = TacticalBtnText},
    RULEUCC_Teleport = {            helpText = "teleport",      bitmapId = 'teleport',              preferredSlot = 10,  behavior = StandardOrderBehavior, },
    RULEUCC_Ferry = {               helpText = "ferry",         bitmapId = 'ferry',                 preferredSlot = 10,  behavior = StandardOrderBehavior, },
    RULEUCC_Sacrifice = {           helpText = "sacrifice",     bitmapId = 'sacrifice',             preferredSlot = 10,  behavior = StandardOrderBehavior,},
    RULEUCC_Dive = {                helpText = "dive",          bitmapId = 'dive',                  preferredSlot = 11, behavior = DiveOrderBehavior, initialStateFunc = DiveInitFunction,},   
    RULEUCC_Reclaim = {             helpText = "reclaim",       bitmapId = 'reclaim',               preferredSlot = 12, behavior = StandardOrderBehavior, },
    RULEUCC_Capture = {             helpText = "capture",       bitmapId = 'convert',               preferredSlot = 13, behavior = StandardOrderBehavior,},
    RULEUCC_Repair = {              helpText = "repair",        bitmapId = 'repair',                preferredSlot = 14, behavior = StandardOrderBehavior,},
    RULEUCC_Dock = {                helpText = "dock",          bitmapId = 'dock',                  preferredSlot = 14, behavior = DockOrderBehavior, initialStateFunc = DockOrderInit,},
    
    DroneL = {              helpText = "drone",        bitmapId = 'unload02',                preferredSlot = 13, behavior = DroneBehavior,initialStateFunc = DroneInit,},
    DroneR = {              helpText = "drone",        bitmapId = 'unload02',                preferredSlot = 13, behavior = DroneBehavior,initialStateFunc = DroneInit,},

    -- Unit toggle rules
    RULEUTC_ShieldToggle = {        helpText = "toggle_shield",     bitmapId = 'shield',                preferredSlot = 8,  behavior = ScriptButtonOrderBehavior,   initialStateFunc = ScriptButtonInitFunction, extraInfo = 0,},
    RULEUTC_WeaponToggle = {        helpText = "toggle_weapon",     bitmapId = 'toggle-weapon',         preferredSlot = 8,  behavior = ScriptButtonOrderBehavior,   initialStateFunc = ScriptButtonInitFunction, extraInfo = 1,},    
    RULEUTC_JammingToggle = {       helpText = "toggle_jamming",    bitmapId = 'jamming',               preferredSlot = 9,  behavior = ScriptButtonOrderBehavior,   initialStateFunc = ScriptButtonInitFunction, extraInfo = 2,},
    RULEUTC_IntelToggle = {         helpText = "toggle_intel",      bitmapId = 'intel',                 preferredSlot = 9,  behavior = ScriptButtonOrderBehavior,   initialStateFunc = ScriptButtonInitFunction, extraInfo = 3,},
    RULEUTC_ProductionToggle = {    helpText = "toggle_production", bitmapId = 'production',            preferredSlot = 10,  behavior = ScriptButtonOrderBehavior,   initialStateFunc = ScriptButtonInitFunction, extraInfo = 4,},
    RULEUTC_StealthToggle = {       helpText = "toggle_stealth",    bitmapId = 'stealth',               preferredSlot = 10,  behavior = ScriptButtonOrderBehavior,   initialStateFunc = ScriptButtonInitFunction, extraInfo = 5,},
    RULEUTC_GenericToggle = {       helpText = "toggle_generic",    bitmapId = 'production',            preferredSlot = 11, behavior = ScriptButtonOrderBehavior,   initialStateFunc = ScriptButtonInitFunction, extraInfo = 6,},
    RULEUTC_SpecialToggle = {       helpText = "toggle_special",    bitmapId = 'activate-weapon',       preferredSlot = 12, behavior = ScriptButtonOrderBehavior,   initialStateFunc = ScriptButtonInitFunction, extraInfo = 7,},
    RULEUTC_CloakToggle = {         helpText = "toggle_cloak",      bitmapId = 'intel-counter',         preferredSlot = 12, behavior = ScriptButtonOrderBehavior,   initialStateFunc = ScriptButtonInitFunction, extraInfo = 8,},
}

-- this is needed to be kept in this file apparently even though im quite sure we dont touch it. whatever.
-- called by gamemain when new orders are available, 
function SetAvailableOrders(availableOrders, availableToggles, newSelection)
    -- save new selection
    -- LOG('available orders: ', repr(availableOrders))
    currentSelection = newSelection
    -- clear existing orders
    orderCheckboxMap = {}
    controls.orderButtonGrid:DestroyAllItems(true)

    -- create our copy of orders table
    standardOrdersTable = table.deepcopy(defaultOrdersTable)
    
    -- look in blueprints for any icon or tooltip overrides
    -- note that if multiple overrides are found for the same order, then the default is used
    -- the syntax of the override in the blueprint is as follows (the overrides use same naming as in the default table above):
    -- In General table
    -- OrderOverrides = {
    --     RULEUTC_IntelToggle = {
    --         bitmapId = 'custom',
    --         helpText = 'toggle_custom',
    --     },
    --  },
    -- 
    local orderDiffs
    
    for index, unit in newSelection do
        local overrideTable = unit:GetBlueprint().General.OrderOverrides
        if overrideTable then
            for orderKey, override in overrideTable do
                if orderDiffs == nil then
                    orderDiffs = {}
                end
                if orderDiffs[orderKey] ~= nil and (orderDiffs[orderKey].bitmapId ~= override.bitmapId or orderDiffs[orderKey].helpText ~= override.helpText) then
                    -- found order diff already, so mark it false so it gets ignored when applying to table
                    orderDiffs[orderKey] = false
                else
                    orderDiffs[orderKey] = override
                end
            end
        end
    end
    
    -- apply overrides
    if orderDiffs ~= nil then
        for orderKey, override in orderDiffs do
            if override and override ~= false then
                if override.bitmapId then
                    standardOrdersTable[orderKey].bitmapId = override.bitmapId
                end
                if override.helpText then
                    standardOrdersTable[orderKey].helpText = override.helpText
                end
            end
        end
    end
    
    CreateCommonOrders(availableOrders)
    
    local numValidOrders = 0
    for i, v in availableOrders do
        if standardOrdersTable[v] then
            numValidOrders = numValidOrders + 1
        end
    end
    for i, v in availableToggles do
        if standardOrdersTable[v] then
            numValidOrders = numValidOrders + 1
        end
    end
    
    if numValidOrders <= 12 then
        CreateAltOrders(availableOrders, availableToggles, currentSelection)
    end
    
    controls.orderButtonGrid:EndBatch()
    if table.getn(currentSelection) == 0 and controls.bg.Mini then
        controls.bg.Mini(true)
    elseif controls.bg.Mini then
        controls.bg.Mini(false)
    end
end
