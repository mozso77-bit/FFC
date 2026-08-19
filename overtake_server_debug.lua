-- FFC F1 2026 OVERTAKE MODE (server script) V3 -- *** DEBUG / DIAGNOSTIC BUILD ***
-- Same spline-based arming as overtake_server.lua, plus:
--   * DEBUG_PHANTOM = true force-arms every detection in a Race so a SOLO driver can still exercise
--     arm -> app -> meter -> boost with no rivals. Set it FALSE for a real multi-car test.
--   * Logs, at every OUR detection crossing, the nearest car ahead: its index, the time gap (s), and
--     ITS speed (km/h) -- so a 2+ car test SHOWS a REMOTE car's splinePosition AND speedKmh both read.
--   * LAP_MIN defaults to 1 so the grant lands on the first flying lap.
--
-- REQUIRES A RACE SESSION (evalArm only arms when raceSessionType == Race).
--
--   [SCRIPT_5]
--   SCRIPT = "https://raw.githubusercontent.com/mozso77-bit/FFC/main/overtake_server_debug.lua"
--
--   [FFC_OVERTAKE]
--   WINDOW_S = 1.0
--   ACTIVE_ON_LAP = 1
--   OVERTAKE_KJ = 500
--

--------------------- CONFIG (defaults; host may override) --------------
local WINDOW_S      = 1.0
local LAP_MIN       = 1     -- DEBUG: enabled from lap 1
local OVERTAKE_KJ   = 500
local DEBUG_PHANTOM = false  -- true = force-arm in a Race (solo self-test); false = real gap-based behaviour
-------------------------------------------------------------------------

local sim   = ac.getSim()
local myIdx = ac.getCar(0).index

local sh = ac.connect({
  ac.StructItem.key('ffc_overtake_' .. ac.getCar(0).index),
  armed    = ac.StructItem.boolean(),
  deploy   = ac.StructItem.boolean(),
  boosting = ac.StructItem.boolean(),
  appBeat  = ac.StructItem.int32(),
}, false, ac.SharedNamespace.Shared)
sh.armed = false

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
  meta.serverReady = true
end
publishRules()

ac.onOnlineWelcome(function(_, config)
  WINDOW_S    = config:get('FFC_OVERTAKE', 'WINDOW_S', WINDOW_S)
  LAP_MIN     = config:get('FFC_OVERTAKE', 'ACTIVE_ON_LAP', LAP_MIN)
  OVERTAKE_KJ = config:get('FFC_OVERTAKE', 'OVERTAKE_KJ', OVERTAKE_KJ)
  publishRules()
end)

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
ac.log('FFC_Overtake DEBUG: track sections=' .. #dets
  .. ' cars=' .. sim.carsCount .. ' phantom=' .. tostring(DEBUG_PHANTOM))

local armedLocal = false

local function resetState()
  armedLocal = false
  sh.armed   = false
end
ac.onSessionStart(resetState)
ac.onCarJumped(0, function() armedLocal = false; sh.armed = false end)

local function evalArm()
  local arm     = false
  local isRace  = sim.raceSessionType == ac.SessionType.Race
  local me      = ac.getCar(myIdx)
  local mySpr   = me.splinePosition
  local mySpeed = me.speedKmh / 3.6                          -- m/s
  local L       = sim.trackLengthM
  local bestGap, bestSpeed, bestIdx                          -- nearest car AHEAD (spline gap)
  if isRace and mySpeed > 1.4 and L > 1 then
    for idx = 0, sim.carsCount - 1 do
      local o = ac.getCar(idx)
      if o and o.index ~= myIdx and o.isConnected and not o.isInPitlane and o.speedKmh > 5
         and o.splinePosition >= 0 then                      -- F1: skip invalid/unspawned spline (matches FFC_DRS)
        local gap = o.splinePosition - mySpr                 -- forward spline distance...
        if gap < 0 then gap = gap + 1.0 end                  -- ...wrapping at S/F
        if gap > 0 and gap < 0.5 and (not bestGap or gap < bestGap) then
          bestGap, bestSpeed, bestIdx = gap, o.speedKmh / 3.6, o.index
        end
      end
    end
  end
  local timeGap
  if bestGap then
    timeGap = (bestGap * L) / math.max((mySpeed + bestSpeed) / 2, 1)   -- distance / avg speed
    if timeGap > 0 and timeGap < WINDOW_S then arm = true end
  end
  if DEBUG_PHANTOM and isRace then arm = true end            -- solo self-test: force arm in a Race
  armedLocal = arm
  sh.armed   = arm
  ac.log('FFC_Overtake: evalArm cars=' .. sim.carsCount
    .. ' aheadCar=' .. (bestIdx or -1)
    .. ' gap=' .. (timeGap and string.format('%.2fs', timeGap) or 'none')
    .. ' otherKmh=' .. (bestSpeed and string.format('%.0f', bestSpeed * 3.6) or '-')
    .. ' race=' .. tostring(isRace) .. ' armed=' .. tostring(arm))
end

for _, det in ipairs(dets) do
  ac.onTrackPointCrossed(-1, det, function(carIndex)
    if carIndex == myIdx then evalArm() end
  end)
end

function script.update()
  if not armedLocal then return end
  if ac.getCar(0).isInPitlane then armedLocal = false; sh.armed = false end
end
