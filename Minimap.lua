-- Minimap button via LibDBIcon.
--
-- A hand-rolled button was tried first and was wrong: it positioned itself on
-- the minimap directly, which fights every addon that collects minimap buttons
-- into a bar. LibDBIcon is what those collectors expect to find, and it also
-- keeps the icon's position for us.

local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
local LDBIcon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)
if not (LDB and LDBIcon) then return end

local broker = LDB:NewDataObject("CastAhead", {
    type = "launcher",
    -- An eye: the addon's whole job is seeing what a mob is about to cast. The
    -- button draws about twenty pixels across, masked to a circle, among a row
    -- of other addons' buttons, so what matters is a silhouette nobody else
    -- there is using - not detail. The warrior armour-break icon this replaces
    -- meant nothing and read as a brown smudge at that size.
    icon = "Interface\\Icons\\Spell_Holy_MindVision",
    OnClick = function(_, button)
        if button == "RightButton" and CastAheadCore and CastAheadCore.Debug then
            CastAheadCore.Debug()
        else
            CastAhead_Toggle()
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("CastAhead")
        tooltip:AddLine("Left click: browse tracked casts", 0.8, 0.8, 0.8)
        tooltip:AddLine("Right click: print status to chat", 0.6, 0.6, 0.6)
    end,
})

-- Registration has to wait for saved variables: LibDBIcon stores the icon's
-- position in the table it is handed.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.minimap = CastAheadDB.minimap or {}
    -- The old hand-written button saved an angle under its own key; drop it so
    -- it cannot fight the library for the icon's position.
    CastAheadDB.minimapAngle = nil
    if not LDBIcon:IsRegistered("CastAhead") then
        LDBIcon:Register("CastAhead", broker, CastAheadDB.minimap)
    end
end)
