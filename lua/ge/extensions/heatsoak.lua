-- HeatSoak Endurance Mode: Game Engine extension
-- Runs for the whole session across vehicle resets and level changes.
-- READ-ONLY: Never alters vehicle damage or temperatures.

local M = {}
local PREFIX = "[heatsoak-endurance] "

local activePreset = 15 -- default preset (15, 35, 60 C)
local PRESETS = {15, 35, 60}

local runActive = false
local runStartTime = nil
local lastLogSec = -1
local currentLogFile = nil
local latestLogFile = nil
local currentLogPath = nil
local failedComponents = {}
local lastVehicleData = nil

local function out(msg)
  log("I", "heatsoak_endurance", PREFIX .. msg)
end

local function formatTime(seconds)
  if not seconds or seconds < 0 then seconds = 0 end
  local mins = math.floor(seconds / 60)
  local secs = seconds - (mins * 60)
  return string.format("%02d:%04.1f", mins, secs)
end

-- ==================== STEP 1: Ambient Presets ====================
function M.setAmbient(temp)
  local target = nil
  if type(temp) == "number" then
    target = temp
  elseif type(temp) == "string" then
    target = tonumber(temp)
  end

  -- If called without arguments or invalid, cycle presets: 15 -> 35 -> 60 -> 15
  if not target then
    if activePreset == 15 then target = 35
    elseif activePreset == 35 then target = 60
    else target = 15 end
  end

  activePreset = target

  -- Apply to BeamNG world environment
  if core_environment and type(core_environment.setTemperatureProfile) == "function" then
    core_environment.setTemperatureProfile({averageC = target, minC = target, maxC = target})
  end

  -- Notify player
  if type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
    pcall(guihooks.messageForSeatedPlayers, {
      txt = string.format("HeatSoak: Ambient temperature set to %d°C", target),
      context = {}
    }, 4, "vehicle.heatsoak.ambient")
  end

  -- Update UI app
  if type(guihooks) == "table" and type(guihooks.trigger) == "function" then
    guihooks.trigger("HeatSoakAmbientPreset", {preset = activePreset})
  end

  out(string.format("Ambient preset set to %d°C", target))
  return activePreset
end

function M.getAmbient()
  return activePreset
end

-- ==================== STEP 2: Run Logging ====================
local function ensureDir(path)
  if FS and type(FS.directoryExists) == "function" and not FS:directoryExists(path) then
    FS:directoryCreate(path, true)
  end
end

local function openLogFiles()
  ensureDir("heatsoak_runs")
  local timestamp = os.date("%Y%m%d_%H%M%S")
  currentLogPath = "heatsoak_runs/run_" .. timestamp .. ".log"

  currentLogFile = io.open(currentLogPath, "w")
  latestLogFile = io.open("heatsoak_run_latest.log", "w")

  local header = string.format(
    "# =========================================================================\n" ..
    "# HeatSoak Endurance Run Log\n" ..
    "# Started: %s | Ambient Preset: %d°C\n" ..
    "# Format: [TIME] speed=... rpm=... thr=... | TEMPS: clt=... oil=... rod=... egt=... turb=... comp=... iat=... ic=... bay=... gb=... diff=... | DAMAGE: ring=... gsk=... rod=... turb=... cat=... gb=... diff=...\n" ..
    "# =========================================================================\n",
    os.date("%Y-%m-%d %H:%M:%S"), activePreset
  )

  if currentLogFile then
    currentLogFile:write(header)
    currentLogFile:flush()
  end
  if latestLogFile then
    latestLogFile:write(header)
    latestLogFile:flush()
  end

  out("Run log started: " .. currentLogPath .. " and heatsoak_run_latest.log")
end

local function writeToLog(line)
  if currentLogFile then
    currentLogFile:write(line .. "\n")
    currentLogFile:flush()
  end
  if latestLogFile then
    latestLogFile:write(line .. "\n")
    latestLogFile:flush()
  end
end

function M.startRun()
  if runActive then return end
  runActive = true
  runStartTime = os.clock()
  lastLogSec = -1
  failedComponents = {}
  openLogFiles()
  out("Endurance run manually started!")
  if type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
    pcall(guihooks.messageForSeatedPlayers, {txt = "HeatSoak: Endurance run started! Logging active.", context = {}}, 3, "vehicle.heatsoak.run")
  end
  if type(guihooks) == "table" and type(guihooks.trigger) == "function" then
    guihooks.trigger("HeatSoakRunState", {active = true, startTime = runStartTime})
  end
end

function M.stopRun()
  if not runActive then return end
  runActive = false
  local elapsed = runStartTime and (os.clock() - runStartTime) or 0
  writeToLog(string.format("# Run ended at %s (Total time: %s)", os.date("%Y-%m-%d %H:%M:%S"), formatTime(elapsed)))
  if currentLogFile then
    currentLogFile:close()
    currentLogFile = nil
  end
  if latestLogFile then
    latestLogFile:close()
    latestLogFile = nil
  end
  out("Endurance run stopped. Log saved.")
  if type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
    pcall(guihooks.messageForSeatedPlayers, {txt = "HeatSoak: Endurance run stopped. Log file saved.", context = {}}, 4, "vehicle.heatsoak.run")
  end
  if type(guihooks) == "table" and type(guihooks.trigger) == "function" then
    guihooks.trigger("HeatSoakRunState", {active = false})
  end
end

-- Called from vehicle extension with read-only state snapshot
function M.onVehicleData(d)
  if type(d) ~= "table" then return end
  lastVehicleData = d

  -- Auto-start run on first throttle press (> 5%)
  if not runActive and (d.throttle or 0) > 0.05 then
    M.startRun()
  end

  if not runActive then return end

  local now = os.clock()
  local elapsed = now - runStartTime
  local currentSec = math.floor(elapsed)

  -- Check and record component failures immediately as they occur
  local checks = {
    {name = "ENGINE (connecting rod bearings melted)", failed = d.rodDamaged or (d.rodDamage and d.rodDamage >= 1.0)},
    {name = "ENGINE (head gasket blown)", failed = d.gasketDamaged or (d.gasketDamage and d.gasketDamage >= 1.0)},
    {name = "ENGINE (piston rings melted)", failed = d.ringDamaged or (d.ringDamage and d.ringDamage >= 1.0)},
    {name = "ENGINE (block / thermal seizure)", failed = d.engineBroken},
    {name = "TURBOCHARGER (bearing seizure / 100% damage)", failed = d.turboBroken or (d.turboDamage and d.turboDamage >= 1.0)},
    {name = "GEARBOX (cluster seizure / 100% damage)", failed = d.gearboxBroken or (d.gearboxDamage and d.gearboxDamage >= 1.0)},
    {name = "DIFFERENTIAL (pinion seizure / 100% damage)", failed = d.diffBroken or (d.diffDamage and d.diffDamage >= 1.0)}
  }

  for _, c in ipairs(checks) do
    if c.failed and not failedComponents[c.name] then
      failedComponents[c.name] = true
      local failLine = string.format(
        "[%s] *** FAILURE: %s *** | TEMPS: clt=%.1fC oil=%.1fC rod=%.1fC egt=%.0fC turb=%.0fC gb=%.0fC diff=%.0fC",
        formatTime(elapsed), c.name,
        d.coolant or 0, d.oil or 0, d.rodBearings or 0, d.egt or 0,
        d.turbineHousing or 0, d.gearboxOil or 0, d.diffOil or 0
      )
      writeToLog(failLine)
      out(failLine)
      if type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
        pcall(guihooks.messageForSeatedPlayers, {
          txt = string.format("FAILURE: %s at %s!", c.name, formatTime(elapsed)),
          context = {}
        }, 6, "vehicle.heatsoak.fail")
      end
    end
  end

  -- Write 1 Hz periodic telemetry log line
  if currentSec > lastLogSec then
    lastLogSec = currentSec
    local tireStr = (d.tires and d.tires ~= "") and (" | TIRES: " .. d.tires) or ""
    local logLine = string.format(
      "[%s] speed=%5.1fkm/h rpm=%4.0f thr=%3.0f%% | TEMPS: clt=%5.1fC oil=%5.1fC wall=%5.1fC blk=%5.1fC head=%5.1fC rod=%5.1fC egt=%4.0fC cat=%4.0fC turb=%4.0fC comp=%4.0fC iat=%4.0fC ic=%4.0fC bay=%4.0fC gb=%4.0fC diff=%4.0fC | DAMAGE: ring=%4.1f%% gsk=%4.1f%% rod=%4.1f%% turb=%4.1f%% cat=%4.1f%% gb=%4.1f%% diff=%4.1f%%",
      formatTime(elapsed),
      (d.speed or 0) * 3.6,
      d.rpm or 0,
      (d.throttle or 0) * 100,
      d.coolant or 0, d.oil or 0, d.wall or 0, d.block or 0, d.cylinderHead or 0, d.rodBearings or 0,
      d.egt or 0, d.catalyst or 0, d.turbineHousing or 0, d.compressorOut or 0, d.iat or 0, d.icCore or 0,
      d.engineBayAir or 0, d.gearboxOil or 0, d.diffOil or 0,
      (d.ringDamage or 0) * 100, (d.gasketDamage or 0) * 100, (d.rodDamage or 0) * 100,
      (d.turboDamage or 0) * 100, (d.catalystDamage or 0) * 100, (d.gearboxDamage or 0) * 100, (d.diffDamage or 0) * 100
    ) .. tireStr
    writeToLog(logLine)
  end
end

function M.onInit()
  setExtensionUnloadMode(M, "manual")
  rawset(_G, "heatsoak", M)
  rawset(_G, "extensions_heatsoak", M)
  out("HeatSoak Game Engine extension loaded (manual unload mode)")
end

function M.onClientStartMission()
  -- Apply active ambient preset on map load
  M.setAmbient(activePreset)
end

rawset(_G, "heatsoak", M)
rawset(_G, "extensions_heatsoak", M)

return M
