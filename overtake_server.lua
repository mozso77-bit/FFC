-- FFC F1 2026 OVERTAKE MODE (server script) v2 event-driven. Arms the local car
-- when, from LAP_MIN in a Race, it crosses a DRS DETECTION line within WINDOW_S
-- (crossing-timestamp gap) of the car ahead; 'armed' holds to the zone END. The app
-- reads 'armed', polls KERS, drives the boost. Cross-car logic lives HERE, never in
-- the car physics thread. Host via ACSM CSP Extra Options: [SCRIPT_1] SCRIPT=url.
-- Detail + realDRS.lua provenance: CLAUDE.md §C.

--------------------- CONFIG (defaults; host may override) --------------
local WINDOW_S    = 1.0   -- arm within this real time gap (s) at the detection line
local LAP_MIN     = 3     -- enabled from this lap (lapCount + 1 >= LAP_MIN)
local OVERTAKE_KJ = 500   -- per-lap budget (kJ) -- published to the app
-------------------------------------------------------------------------

local sim = ac.getSim()

-- Shared MAIN block: identical key + layout in car / app / server.
local sh = ac.connect({
  ac.StructItem.key('ffc_overtake_' .. ac.getCar(0).index),
  armed    = ac.StructItem.boolean(),   -- server->app: window open
  deploy   = ac.StructItem.boolean(),   -- app->car
  boosting = ac.StructItem.boolean(),   -- car->app
  appBeat  = ac.StructItem.int32(),     -- app->car heartbeat (layout parity; unused here)
}, false, ac.SharedNamespace.Shared)

-- META block (app+server only; car not connected): rules + presence for the announce.
local meta = ac.connect({
  ac.StructItem.key('ffc_overtake_meta_' .. ac.getCar(0).index),
  serverReady = ac.StructItem.boolean(),
  windowS     = ac.StructItem.float(),
  lapMin      = ac.StructItem.int32(),
  overtakeKJ  = ac.StructItem.int32(),
}, false, ac.SharedNamespace.Shared)

local function publishRules()
  meta.windowS     = WINDOW_S
  meta.lapMin      = LAP_MIN
  meta.overtakeKJ  = OVERTAKE_KJ
  meta.serverReady = true            -- set LAST so the app never reads half-published rules
end
publishRules()

-- Optional host tuning via server config [FFC_OVERTAKE] WINDOW_S / ACTIVE_ON_LAP /
-- OVERTAKE_KJ. Never fires offline, so the defaults above stand there.
ac.onOnlineWelcome(function(_, config)
  WINDOW_S    = config:get('FFC_OVERTAKE', 'WINDOW_S', WINDOW_S)
  LAP_MIN     = config:get('FFC_OVERTAKE', 'ACTIVE_ON_LAP', LAP_MIN)
  OVERTAKE_KJ = config:get('FFC_OVERTAKE', 'OVERTAKE_KJ', OVERTAKE_KJ)
  publishRules()
end)

-- Load the track's DRS zones. io.load + hand parser (ac.INIConfig has silently
-- no-op'd on some paths before).
local zones = {}
do
  local content
  pcall(function() content = io.load(ac.getTrackDataFilename('drs_zones.ini')) end)
  if content then
    local z
    for line in content:gmatch('[^\r\n]+') do
      line = line:match('^%s*(.-)%s*$')
      if line:match('^%[ZONE') then z = { det = 0, e = 0 }; zones[#zones + 1] = z
      elseif z then
        local k, v = line:match('^(%u+)%s*=%s*([%d%.]+)')
        if k == 'DETECTION' then z.det = tonumber(v) or 0
        elseif k == 'END' then z.e = tonumber(v) or 0 end
      end
    end
  end
end

-- L4: drop malformed zones (missing DETECTION/END parses to spline 0 = the S/F line).
do
  local valid = {}
  for _, z in ipairs(zones) do
    if z.det > 0 and z.e > 0 and z.det ~= z.e then valid[#valid + 1] = z end
  end
  zones = valid
end

local crossTime    = {}      -- [zone][car] = latest crossing time (ms); OTHER cars only
local armedZone    = nil
local armedEntered = false   -- M4 latch: car seen INSIDE the armed arc yet?
for zi = 1, #zones do crossTime[zi] = {} end

local function resetState()
  for zi = 1, #zones do crossTime[zi] = {} end
  armedZone    = nil
  armedEntered = false
  sh.armed     = false
end
ac.onSessionStart(resetState)

-- On our DETECTION crossing: armed iff another car crossed the same line within
-- WINDOW_S just ahead of us. Sets OR clears (self-correcting).
local function evalArm(zi, myTimeMs)
  local arm = false
  local me  = ac.getCar(0)
  if me ~= nil and (me.lapCount + 1) >= LAP_MIN and sim.raceSessionType == ac.SessionType.Race then
    for _, t in pairs(crossTime[zi]) do
      local d = myTimeMs - t                -- >= 0 => that car crossed at/ahead of us
      if d >= 0 and d < WINDOW_S * 1000 then arm = true; break end
    end
  end
  armedZone    = arm and zi or nil
  armedEntered = false
  sh.armed     = arm
end

-- Native crossing events for each zone's DETECTION + END lines.
for zi, z in ipairs(zones) do
  ac.onTrackPointCrossed(-1, z.det, function(carIndex, timeMs)
    if carIndex == 0 then evalArm(zi, timeMs)
    else crossTime[zi][carIndex] = timeMs end
  end)
  ac.onTrackPointCrossed(-1, z.e, function(carIndex, timeMs)
    if carIndex == 0 and armedZone == zi then armedZone = nil; sh.armed = false end
  end)
end

-- M4 safety: END is suppressed in pits / after a jump, so a pit/retire/teleport
-- mid-zone would strand armed=true. This gated update clears it once the car leaves
-- the arc. Entered-latch: getCar().splinePosition is graphics-rate and lags the
-- physics crossing (can read just before 'det' right after arming), so only allow the
-- clear AFTER the car has been seen inside the arc once. ~zero cost unless armed.
local function inArc(x, a, b)           -- wrap-aware "is x within forward arc [a,b]?"
  if b < a then b = b + 1; if x < a then x = x + 1 end end
  return x >= a and x <= b
end
function script.update()
  if armedZone == nil then return end
  local z  = zones[armedZone]
  local me = ac.getCar(0)
  if me == nil or z == nil then return end
  if inArc(me.splinePosition, z.det, z.e) then
    armedEntered = true
  elseif armedEntered then
    armedZone = nil; sh.armed = false
  end
end
