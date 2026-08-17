-- FFC F1 2026 OVERTAKE MODE (server script) V3 -- last-detection eligibility.
-- At EVERY DRS DETECTION line it sets 'armed' = a car is within WINDOW_S ahead of us.
-- 'armed' HOLDS until the next detection, at S/F it equals the LAST detection's result. The app
-- reads it at S/F to grant that lap's deploy-ANYWHERE budget (host-tunable).
--
-- Host via ACSM CSP Extra Options:
--
--   [SCRIPT_5]
--   SCRIPT = "https://raw.githubusercontent.com/mozso77-bit/FFC/main/overtake_server.lua"
--
--   [FFC_OVERTAKE]
--   WINDOW_S = 1.0
--   ACTIVE_ON_LAP = 2
--   OVERTAKE_KJ = 500
--

--------------------- CONFIG (defaults; host may override) --------------
local WINDOW_S    = 1.0   -- arm within this real time gap (s) to the car ahead at the detection line
local LAP_MIN     = 2     -- enabled from this lap (lapCount + 1 >= LAP_MIN)
local OVERTAKE_KJ = 300   -- per-lap budget (kJ) -- published to the app
-------------------------------------------------------------------------

local sim   = ac.getSim()
local myIdx = ac.getCar(0).index          -- local player index (0); used to skip self + as gap main car

-- Shared MAIN block: identical key + layout in car / app / server.
local sh = ac.connect({
  ac.StructItem.key('ffc_overtake_' .. ac.getCar(0).index),
  armed    = ac.StructItem.boolean(),   -- server->app: within WINDOW_S of the car ahead at the last detection
  deploy   = ac.StructItem.boolean(),   -- app->car
  boosting = ac.StructItem.boolean(),   -- car->app
  appBeat  = ac.StructItem.int32(),     -- app->car heartbeat (layout parity; unused here)
}, false, ac.SharedNamespace.Shared)
sh.armed = false            -- clear a stale arm latched by a previous script load (symmetry with car/app)

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

-- Optional host tuning via server config [FFC_OVERTAKE] WINDOW_S / ACTIVE_ON_LAP / OVERTAKE_KJ.
ac.onOnlineWelcome(function(_, config)
  WINDOW_S    = config:get('FFC_OVERTAKE', 'WINDOW_S', WINDOW_S)
  LAP_MIN     = config:get('FFC_OVERTAKE', 'ACTIVE_ON_LAP', LAP_MIN)
  OVERTAKE_KJ = config:get('FFC_OVERTAKE', 'OVERTAKE_KJ', OVERTAKE_KJ)
  publishRules()
end)

-- ---- load the track's DRS DETECTION lines (only the detection SPLINE positions matter) ----
local dets = {}
do
  local content
  pcall(function() content = io.load(ac.getTrackDataFilename('drs_zones.ini')) end)
  if content then
    for line in content:gmatch('[^\r\n]+') do
      local v = line:match('^%s*DETECTION%s*=%s*([%d%.]+)')
      local d = v and tonumber(v)
      if d and d > 0 then dets[#dets + 1] = d end
    end
  end
end
ac.log('FFC_Overtake server: track sections=' .. #dets)

local armedLocal = false     -- mirror of sh.armed, gates the pit-clear update cheaply

local function resetState()
  armedLocal = false
  sh.armed   = false
end
ac.onSessionStart(resetState)
ac.onCarJumped(0, function() armedLocal = false; sh.armed = false end)

-- At OUR detection crossing: armed = the closest car physically AHEAD on track is within WINDOW_S
local function evalArm()
  local arm = false
  if sim.raceSessionType == ac.SessionType.Race then
    local me      = ac.getCar(myIdx)
    local mySpr   = me.splinePosition
    local mySpeed = me.speedKmh / 3.6                        -- m/s
    local L       = sim.trackLengthM
    if mySpeed > 1.4 and L > 1 then                          -- need real speed (>~5 km/h) + track length
      local bestGap, bestSpeed
      for idx = 0, sim.carsCount - 1 do
        local o = ac.getCar(idx)
        if o and o.index ~= myIdx and o.isConnected and not o.isInPitlane and o.speedKmh > 5 then
          local gap = o.splinePosition - mySpr               -- forward spline distance...
          if gap < 0 then gap = gap + 1.0 end                -- ...wrapping at S/F
          if gap > 0 and gap < 0.5 and (not bestGap or gap < bestGap) then
            bestGap, bestSpeed = gap, o.speedKmh / 3.6       -- nearest car ahead in the front half-lap
          end
        end
      end
      if bestGap then
        local timeGap = (bestGap * L) / math.max((mySpeed + bestSpeed) / 2, 1)   -- distance / avg speed
        if timeGap > 0 and timeGap < WINDOW_S then arm = true end
      end
    end
  end
  armedLocal = arm
  sh.armed   = arm
end

-- Only OUR crossing (carIndex 0 = local player) triggers the check; that IS the detection point.
for _, det in ipairs(dets) do
  ac.onTrackPointCrossed(-1, det, function(carIndex)
    if carIndex == myIdx then evalArm() end
  end)
end

-- Pit-clear: 'armed' holds between detections; clear it on pit entry so a pre-pit arm can't grant
-- at S/F. Gated on the local mirror -> ~one branch/frame unless actually armed.
function script.update()
  if not armedLocal then return end
  if ac.getCar(0).isInPitlane then armedLocal = false; sh.armed = false end
end
