-- FFC F1 2026 OVERTAKE MODE (server script) v3 -- last-detection eligibility.
-- At EVERY DRS DETECTION line it sets 'armed' = within WINDOW_S of the car ahead
-- (crossing-timestamp gap). 'armed' HOLDS until the next detection, at S/F it equals
-- the LAST detection's result. The app reads it at S/F to grant that lap's deploy-ANYWHERE
-- budget (OVERTAKE_KJ if eligible, else 0; host-tunable).
--
-- Host via ACSM CSP Extra Options:
--
-- [SCRIPT_1]
-- SCRIPT = "https://raw.githubusercontent.com/mozso77-bit/FFC/main/overtake_server.lua"
--
-- [FFC_OVERTAKE]
-- WINDOW_S = 1.0
-- ACTIVE_ON_LAP = 2
-- OVERTAKE_KJ = 300
--

--------------------- CONFIG (defaults; host may override) --------------
local WINDOW_S    = 1.0   -- arm within this real time gap (s) at the detection line
local LAP_MIN     = 2     -- enabled from this lap (lapCount + 1 >= LAP_MIN)
local OVERTAKE_KJ = 500   -- per-lap budget (kJ) -- published to the app
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
      if d and d > 0 then dets[#dets + 1] = d end          -- skip missing/degenerate (-> 0)
    end
  end
end

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
  local arm = false
  if sim.raceSessionType == ac.SessionType.Race then
    for _, t in pairs(crossTime[i]) do
      local d = myTimeMs - t                -- >= 0 => that car crossed at/ahead of us
      if d >= 0 and d < WINDOW_S * 1000 then arm = true; break end
    end
  end
  armedLocal = arm
  sh.armed   = arm
end

for i, det in ipairs(dets) do
  ac.onTrackPointCrossed(-1, det, function(carIndex, timeMs)
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
