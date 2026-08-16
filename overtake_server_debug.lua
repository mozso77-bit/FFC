-- FFC F1 2026 OVERTAKE MODE (server script) v3 -- *** DEBUG / SELF-TEST BUILD ***
-- Identical to overtake_server.lua EXCEPT:
--   * DEBUG_PHANTOM seeds a fake car 0.5 s AHEAD at EVERY detection, so a SOLO driver
--     arms every lap -- exercises onTrackPointCrossed -> evalArm -> sh.armed -> app grant
--     -> deploy -> boost end-to-end with no other drivers online.
--   * LAP_MIN defaults to 1 so the grant lands on the first flying lap (less driving).
-- REQUIRES A RACE SESSION: evalArm only arms when raceSessionType == Race (a solo
-- Practice/Qualy will never arm, phantom or not). Turn on the app's DEBUG_MODE = 1 to
-- watch serverSignal / overtakePolling / overtakeMode car flip.
-- FOR PRODUCTION use overtake_server.lua (real proximity, LAP_MIN 3). Host this separately.
--
-- Host via ACSM CSP Extra Options (example):
--
-- [SCRIPT_5]
-- SCRIPT = "https://raw.githubusercontent.com/mozso77-bit/FFC/main/overtake_server_debug.lua"
--
-- [FFC_OVERTAKE]
-- WINDOW_S = 1.0
-- ACTIVE_ON_LAP = 1
-- OVERTAKE_KJ = 500
--

--------------------- CONFIG (defaults; host may override) --------------
local WINDOW_S      = 1.0   -- arm within this real time gap (s) at the detection line
local LAP_MIN       = 1     -- DEBUG: enabled from lap 1 (production default is 3)
local OVERTAKE_KJ   = 300   -- per-lap budget (kJ) -- published to the app
local DEBUG_PHANTOM = true  -- DEBUG: seed a fake car 0.5 s ahead at each detection (solo self-test); false = real behaviour
-------------------------------------------------------------------------

local sim = ac.getSim()

-- Shared MAIN block: identical key + layout in car / app / server.
local sh = ac.connect({
  ac.StructItem.key('ffc_overtake_' .. ac.getCar(0).index),
  armed    = ac.StructItem.boolean(),   -- server->app: within 1 s at the last detection
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

-- Optional host tuning via server config [FFC_OVERTAKE] WINDOW_S / ACTIVE_ON_LAP /
-- OVERTAKE_KJ. Never fires offline, so the defaults above stand there.
ac.onOnlineWelcome(function(_, config)
  WINDOW_S    = config:get('FFC_OVERTAKE', 'WINDOW_S', WINDOW_S)
  LAP_MIN     = config:get('FFC_OVERTAKE', 'ACTIVE_ON_LAP', LAP_MIN)
  OVERTAKE_KJ = config:get('FFC_OVERTAKE', 'OVERTAKE_KJ', OVERTAKE_KJ)
  publishRules()
end)

-- ---- load the track's DRS DETECTION lines (only detection points matter now) ----
-- io.load + hand parser (ac.INIConfig has silently no-op'd on some paths before).
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
ac.log('FFC_Overtake: track sections=' .. #dets
  .. ' me.index=' .. ac.getCar(0).index
  .. ' me.sessionID=' .. (car and car.sessionID or -1)
  .. ' phantom=' .. tostring(DEBUG_PHANTOM))

-- crossing timestamps (ms) per detection per car
local crossTime  = {}
local armedLocal = false     -- mirror of sh.armed, gates the pit-clear update cheaply
for i = 1, #dets do crossTime[i] = {} end

local function resetState()
  for i = 1, #dets do crossTime[i] = {} end
  armedLocal = false
  sh.armed   = false
end
ac.onSessionStart(resetState)

-- A local jump (race restart -> grid, teleport, reset) lands OFF-pit, so the pit-clear
-- update won't fire -- clear the arm here too so a stale value can't grant next lap.
-- (Only the local arm; other cars' crossing timestamps stay valid.)
ac.onCarJumped(0, function() armedLocal = false; sh.armed = false end)

-- On OUR crossing of a detection: armed = within WINDOW_S of a car ahead at that line.
-- 'armed' HOLDS that value until the next detection overwrites it, so at S/F it equals
-- the last detection's result (end of the last corner). The app reads it there and
-- applies the lap gate + pit check. No END events / zone arc / M4 -- deployment is
-- anywhere-on-the-lap, so there is no in-zone arm to get stuck.
local function evalArm(i, myTimeMs)
  if DEBUG_PHANTOM then crossTime[i].phantom = myTimeMs - 500 end   -- DEBUG: fake car crossed 0.5 s before us -> d=500ms < 1000 -> arms
  local arm = false
  if sim.raceSessionType == ac.SessionType.Race then
    for _, t in pairs(crossTime[i]) do
      local d = myTimeMs - t                -- >= 0 => that car crossed at/ahead of us
      if d >= 0 and d < WINDOW_S * 1000 then arm = true; break end
    end
  end
  armedLocal = arm
  sh.armed   = arm
  ac.log('FFC_Overtake: evalArm section#' .. i
    .. ' race=' .. tostring(sim.raceSessionType == ac.SessionType.Race)
    .. ' armed=' .. tostring(arm))
end

-- DIAGNOSTIC: log EVERY crossing (all cars) with the crosser index + our identity in both spaces.
-- Arming still uses `== 0` (same as production) so this build reproduces production behaviour while
-- the log tells us whether `== 0` is right or should be `car.sessionID`.
for i, det in ipairs(dets) do
  ac.onTrackPointCrossed(-1, det, function(carIndex, timeMs)
    ac.log('FFC_Overtake: cross section#' .. i .. ' crosser=' .. carIndex
      .. ' (me.sessionID=' .. (car and car.sessionID or -1)
      .. ', me.index=' .. ac.getCar(0).index .. ')')
    if carIndex == 0 then evalArm(i, timeMs)
    else crossTime[i][carIndex] = timeMs end
  end)
end

-- Pit-clear: 'armed' holds between detections, and detection crossings are auto-skipped
-- in the pitlane -- so a driver who pits would keep a pre-pit arm and could commit a grant
-- at S/F on stale proximity. Clear it on pit entry; a fresh detection re-arms after pit
-- exit (so the out-lap forfeits, but the lap after is honoured if re-earned). Gated on the
-- local mirror -> ~one branch/frame unless actually armed.
function script.update()
  if not armedLocal then return end
  if ac.getCar(0).isInPitlane then armedLocal = false; sh.armed = false end
end
