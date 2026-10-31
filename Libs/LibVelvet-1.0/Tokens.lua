-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
local lib = LibStub("LibVelvet-1.0")
if not lib.loading then return end

lib.T = {
    bg = { 0.063, 0.075, 0.09, 0.99 },
    panel = { 0.082, 0.098, 0.125, 1 },
    border = { 0.18, 0.20, 0.235, 1 },
    control = { 0.275, 0.295, 0.337, 1 },
    divider = { 0.19, 0.21, 0.247, 1 },
    segfill = { 0.10, 0.118, 0.149, 1 },
    selected = { 0.196, 0.224, 0.282, 1 },
    navSelected = { 0.14, 0.16, 0.204, 1 },
    selLabel = { 0.97, 0.855, 0.50 },
    underline = { 0.91, 0.73, 0.275, 1 },
    title = { 0.92, 0.78, 0.40 },
    gold = { 1, 0.82, 0 },
    text = { 0.9, 0.9, 0.9 },
    muted = { 0.72, 0.74, 0.78 },
    hover = { 1, 1, 1, 0.04 },
    track = { 0.17, 0.19, 0.235, 1 },
    trackFill = { 0.59, 0.49, 0.27, 1 },
    thumb = { 0.83, 0.84, 0.87, 1 },
    well = { 0.078, 0.09, 0.114, 1 },
    wellOn = { 0.157, 0.141, 0.094, 1 },
    tick = { 0.94, 0.80, 0.39 },
}
lib.HEADER = lib.T.title
lib.FLAT = { bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 }
lib.GAP, lib.PAD = 8, 12
