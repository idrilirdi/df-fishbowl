-- fishbowl-unstick: free df-ai from modal viewscreens it cannot handle.
--
-- df-ai (0.47.05) logs "[ERROR] paused in unknown viewscreen <name>" and
-- freezes the fort forever when a screen it doesn't recognize appears.
-- Observed offenders on this install: viewscreen_meetingst (diplomat
-- conference) and viewscreen_game_cleanerst (post-load cleanup).
--
-- Scheduled from onMapLoad.init via `repeat` with graphical-frame units, so
-- it keeps running while the game is paused (which is exactly when it is
-- needed). A screen must be seen on two consecutive checks (~10s) before we
-- act, so brief legitimate appearances are left alone; then we escalate:
-- LEAVESCREEN -> SELECT -> hard dismiss. NOTE: this install is a dedicated
-- unattended screensaver — on a human-play install this would close your
-- diplomat meetings.

fishbowl_unstick = fishbowl_unstick or { last = nil, tries = 0 }
local state = fishbowl_unstick

local gui = require('gui')

local STUCK_CLASSES = {
    { class = df.viewscreen_meetingst, label = 'meetingst' },
    { class = df.viewscreen_game_cleanerst, label = 'game_cleanerst' },
}

local vs = dfhack.gui.getCurViewscreen(true)
if not vs then return end

local hit = nil
for _, entry in ipairs(STUCK_CLASSES) do
    if entry.class and entry.class:is_instance(vs) then
        hit = entry.label
        break
    end
end

if not hit then
    state.last = nil
    state.tries = 0
    return
end

if state.last ~= hit then
    -- first sighting: remember it, act only if still here next check
    state.last = hit
    state.tries = 0
    return
end

state.tries = state.tries + 1
if state.tries == 1 then
    print('fishbowl-unstick: ' .. hit .. ' stuck, sending LEAVESCREEN')
    gui.simulateInput(vs, 'LEAVESCREEN')
elseif state.tries == 2 then
    print('fishbowl-unstick: ' .. hit .. ' still stuck, sending SELECT')
    gui.simulateInput(vs, 'SELECT')
else
    print('fishbowl-unstick: ' .. hit .. ' immovable, dismissing screen')
    dfhack.screen.dismiss(vs)
    state.last = nil
    state.tries = 0
end
