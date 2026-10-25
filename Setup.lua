CastAheadSetup = {}

local OFFSET_MAX = 120

local function Clamp(v, limit)
    return math.max(-limit, math.min(limit, math.floor(v + 0.5)))
end

function CastAheadSetup.Snap(dx, dy, w, h)
    local halfW, halfH = w / 2, h / 2
    local sx = dx < -halfW and -1 or dx > halfW and 1 or 0
    local sy = dy > halfH and 1 or dy < -halfH and -1 or 0
    local side
    for name, spec in pairs(CastAheadAnchors) do
        if spec.dx == sx and spec.dy == sy then side = name end
    end

    local gap = CastAheadCore.BAR_GAP
    local out
    if sx ~= 0 then out = math.abs(dx) - halfW end
    if sy ~= 0 then
        local outY = math.abs(dy) - halfH
        out = out and math.min(out, outY) or outY
    end
    local offset = 0
    if out then
        offset = math.max(0, math.min(OFFSET_MAX, math.floor((out - gap) / 2 + 0.5) * 2))
    end

    local reach = out and (gap + offset) or 0
    local max = CastAheadConfig.NUDGE_MAX
    return side, offset, Clamp(dx - sx * (halfW + reach), max), Clamp(dy - sy * (halfH + reach), max)
end
