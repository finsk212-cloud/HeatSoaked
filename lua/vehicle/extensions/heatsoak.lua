-- heatsoak: step 2. Thermal model on top of vanilla values. Never writes to vanilla state.
local M = {}

local PREFIX = "[heatsoak] "
local LOG_INTERVAL = 1
local KEY_PATTERNS = {"temp", "boost", "throttle", "rpm", "load", "fuel"}
local CONFIG_PATH = "lua/vehicle/extensions/heatsoak_config.json"
local KELVIN = 273.15

local timer = 0
local uiTimer = 0
local cfg = nil
local cachedVehicleParts = nil
local nodesReady = false
local gearboxDevice = nil
local gearboxEfficiency = nil
local converterDevice = nil
local diffDevices = {}
local PROBE_FIELDS = {"energyToCylinderWall", "energyToOil", "energyToExhaust", "oilLubricationCoef"}
local PROBE_SAMPLES = 150
local probe = {samples = 0, changed = {}, last = {}, done = false}
local rpmNoted = false
local thresholds = nil
local turboThreshold = nil
local lubWindow = nil
local gearPopTimer = 0
local gearboxBroken = false
local diffBroken = false
local seizedGearIndex = nil
local diffHitchTimer = 0
local diffHitchDuration = 0
local diffHitchActive = false
local ambientOverrideC = nil
local lastSimulatedOil = nil
local safeRevLimitEnabled = true
local tempRevLimiterActiveInEngine = false

-- node values for the UI step; same table for the extension's lifetime, nil where a node doesn't apply
M.state = {active = false}

local function out(msg)
  log("I", "heatsoak", PREFIX .. msg)
end

local function clamp01(x)
  return math.max(math.min(x, 1), 0)
end

local function clampTo(x, lo, hi)
  return math.max(math.min(x, hi), lo)
end

local function getPoweredWheels()
  local list = {}
  local powered = (type(powertrain) == "table" and type(powertrain.getPoweredWheelNames) == "function") and powertrain.getPoweredWheelNames() or nil
  if type(wheels) == "table" then
    local source = wheels.wheelRotators or wheels.wheels or {}
    for _, w in pairs(source) do
      if type(w) == "table" and w.name and (not powered or powered[w.name]) then
        list[#list + 1] = w
      end
    end
  end
  return list
end

local function applyDrivetrainLock(dt, engine)
  dt = dt or 0
  if diffBroken or (gearboxBroken and gearboxDevice and gearboxDevice.gearIndex ~= 0) then
    local pw = getPoweredWheels()
    for _, w in ipairs(pw) do
      local maxBrake = math.max(w.brakeTorque or 0, w.parkingTorque or 0, 4500)
      w.desiredBrakingTorque = maxBrake
      if w.brakePressureDelay and type(w.brakePressureDelay.set) == "function" then
        w.brakePressureDelay:set(maxBrake)
      end
    end
    return
  end

  local s = M.state

  -- Intermittent tooth catch / hitch under load (>0.65 damage)
  local speed = (electrics.values and electrics.values.wheelspeed) or 0
  if (s.diffDamage or 0) > 0.65 and engine and (engine.engineLoad or 0) > 0.25 and speed > 1.0 and dt > 0 then
    diffHitchTimer = diffHitchTimer - dt
    if diffHitchTimer <= 0 and diffHitchDuration <= 0 then
      local hitchFactor = clamp01((s.diffDamage - 0.65) / 0.35)
      local minInterval = 6 - 5.0 * hitchFactor
      local maxInterval = 11 - 8.5 * hitchFactor
      diffHitchTimer = minInterval + math.random() * (maxInterval - minInterval)
      diffHitchDuration = 0.09 -- 90ms hard bite
      out(string.format("differential: momentary tooth hitch (%.0f%% damage)", s.diffDamage * 100))
    end
  end

  if diffHitchDuration > 0 and dt > 0 then
    diffHitchDuration = diffHitchDuration - dt
    diffHitchActive = true
    local hitchTorque = 1200 + 1800 * clamp01(((s.diffDamage or 0) - 0.65) / 0.35)
    local pw = getPoweredWheels()
    for _, w in ipairs(pw) do
      w.desiredBrakingTorque = math.max(w.desiredBrakingTorque or 0, hitchTorque)
      if w.brakePressureDelay and type(w.brakePressureDelay.set) == "function" then
        w.brakePressureDelay:set(w.desiredBrakingTorque)
      end
    end
  elseif diffHitchActive then
    diffHitchActive = false
    local pw = getPoweredWheels()
    for _, w in ipairs(pw) do
      w.desiredBrakingTorque = 0
      if w.brakePressureDelay and type(w.brakePressureDelay.set) == "function" then
        w.brakePressureDelay:set(0)
      end
    end
  end
end

local function releaseDrivetrainLock()
  diffHitchTimer = 0
  diffHitchDuration = 0
  diffHitchActive = false
  local pw = getPoweredWheels()
  for _, w in ipairs(pw) do
    w.desiredBrakingTorque = 0
    if w.brakePressureDelay and type(w.brakePressureDelay.set) == "function" then
      w.brakePressureDelay:set(0)
    end
  end
end

local function damagedLockedUpdateTorque(device, dt)
  dt = dt or 0.0005
  local inputAV = device.inputAV or 0
  local outputAVdiff = (device.outputAV1 or 0) - (device.outputAV2 or 0)
  local absOutputAVdiff = math.abs(outputAVdiff)

  local parentTorque = (device.parent and device.parentOutputTorqueName and device.parent[device.parentOutputTorqueName]) or 0
  local friction = ((device.friction or 0) * clampTo(inputAV, -1, 1) + (device.dynamicFriction or 0) * inputAV + (device.torqueLossCoef or 0) * parentTorque) * (device.wearFrictionCoef or 1) * (device.damageFrictionCoef or 1)
  local speedLimit = math.min((device.speedLimitCoef or 0.00000035) * absOutputAVdiff * absOutputAVdiff * absOutputAVdiff, 1)
  local inputTorque = (parentTorque - friction) * (1 - speedLimit) * (device.gearRatio or 1)

  local s = M.state
  local damage = (s and s.diffDamage) or 0.8
  local damageFrac = clamp01((damage - 0.50) / 0.50)

  -- Stiff locking spring: instant bite with zero compliance deadzone
  local lockSpring = 25000 + 35000 * damageFrac
  local lockTorqueLimit = 8000 + 10000 * damageFrac
  local maxDiffAngle = math.sqrt(lockTorqueLimit / lockSpring)
  local lockDamp = 0.12 * math.sqrt(lockSpring * 1.0)

  device.diffAngle = clampTo((device.diffAngle or 0) + outputAVdiff * dt, -maxDiffAngle, maxDiffAngle)
  local sgn = (device.diffAngle > 0 and 1) or (device.diffAngle < 0 and -1) or 0
  local absAngle = math.abs(device.diffAngle)

  -- Instant linear bite + quadratic lock to eliminate weak spring deadzone near 0 rad
  local springForce = (absAngle * 0.65 + absAngle * absAngle * 0.35) * lockSpring * sgn

  -- Chewed tooth chatter: oscillates cross-axle locking torque as gear teeth roll over each other in corners
  local chatter = 1.0
  if absOutputAVdiff > 0.15 then
    chatter = 1.0 + 0.45 * damageFrac * math.sin(device.diffAngle * 35)
  end

  local lockTorque = clampTo((springForce + lockDamp * outputAVdiff) * chatter, -lockTorqueLimit, lockTorqueLimit)

  device.inputTorque = inputTorque
  device.outputTorque1 = inputTorque * 0.5 - lockTorque
  device.outputTorque2 = inputTorque * 0.5 + lockTorque
end

local function setDiffSpoolLock(enable)
  if not diffDevices then return end
  local s = M.state
  local damage = (s and s.diffDamage) or 0
  for _, diffDev in ipairs(diffDevices) do
    -- Remove any UI mode shortcut button created by simplePowertrainControl
    if extensions.ui_simplePowertrainControl and type(extensions.ui_simplePowertrainControl.setButton) == "function" then
      pcall(extensions.ui_simplePowertrainControl.setButton, "powertrain_device_mode_shortcut_" .. diffDev.name, nil, nil, nil, nil, nil, true)
    end
    -- Clean up "locked" from availableModes so BeamNG never registers a mode toggle button
    if type(diffDev.availableModes) == "table" and diffDev.defaultMode and diffDev.defaultMode ~= "locked" then
      for i = #diffDev.availableModes, 1, -1 do
        if diffDev.availableModes[i] == "locked" then
          table.remove(diffDev.availableModes, i)
        end
      end
    end
    if diffDev.hsOriginalMode then
      diffDev.mode = diffDev.hsOriginalMode
      diffDev.hsOriginalMode = nil
    end

    if enable then
      if not diffDev.hsOriginalTorqueUpdate then
        diffDev.hsOriginalTorqueUpdate = diffDev.torqueUpdate
      end
      local damageFrac = clamp01((damage - 0.50) / 0.50)
      diffDev.lockTorque = math.max(diffDev.lockTorque or 0, 2000 + 4000 * damageFrac)
      diffDev.lockSpring = math.max(diffDev.lockSpring or 0, 2000 + 4000 * damageFrac)
      diffDev.torqueUpdate = damagedLockedUpdateTorque
    else
      if diffDev.hsOriginalTorqueUpdate then
        diffDev.torqueUpdate = diffDev.hsOriginalTorqueUpdate
        diffDev.hsOriginalTorqueUpdate = nil
      end
    end
  end
end

local function safeBreakDevice(device, alertMsg)
  if not device or device.isBroken then return end
  device.isBroken = true
  if type(device.onBreak) == "function" then
    pcall(device.onBreak, device)
  end
  if type(damageTracker) == "table" and type(damageTracker.setDamage) == "function" then
    pcall(damageTracker.setDamage, "powertrain", device.name, true)
  end
  if alertMsg and type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
    pcall(guihooks.messageForSeatedPlayers, {txt = alertMsg, context = {}}, 6, "vehicle.damage." .. (device.name or "powertrain"))
  end
end

local function safeRestoreDevice(device)
  if not device then return end
  device.isBroken = false
  if device.damageFrictionCoef then device.damageFrictionCoef = 1 end
  if device.damageLockTorqueCoef then device.damageLockTorqueCoef = 1 end
  if device.type == "differential" then
    if device.hsOriginalTorqueUpdate then
      device.torqueUpdate = device.hsOriginalTorqueUpdate
      device.hsOriginalTorqueUpdate = nil
    end
    if device.hsOriginalMode then
      device.mode = device.hsOriginalMode
      device.hsOriginalMode = nil
    end
    if type(device.availableModes) == "table" and device.defaultMode and device.defaultMode ~= "locked" then
      for i = #device.availableModes, 1, -1 do
        if device.availableModes[i] == "locked" then
          table.remove(device.availableModes, i)
        end
      end
    end
    if extensions.ui_simplePowertrainControl and type(extensions.ui_simplePowertrainControl.setButton) == "function" then
      pcall(extensions.ui_simplePowertrainControl.setButton, "powertrain_device_mode_shortcut_" .. device.name, nil, nil, nil, nil, nil, true)
    end
  end
  if type(device.setGearIndex) == "function" and device.gearIndex then
    pcall(device.setGearIndex, device, device.gearIndex)
  end
  if type(damageTracker) == "table" and type(damageTracker.setDamage) == "function" then
    pcall(damageTracker.setDamage, "powertrain", device.name, false)
  end
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

-- one line per field: numbers/booleans/strings with value, tables as key count, functions skipped
local function dumpFields(label, t)
  if type(t) ~= "table" then
    out(label .. " = " .. tostring(t) .. " (not a table)")
    return
  end
  for _, k in ipairs(sortedKeys(t)) do
    local v = t[k]
    local tv = type(v)
    if tv == "number" then
      out(string.format("%s.%s = %s", label, tostring(k), tostring(v)))
    elseif tv == "boolean" or tv == "string" then
      out(string.format("%s.%s = %s (%s)", label, tostring(k), tostring(v), tv))
    elseif tv == "table" then
      local n = 0
      for _ in pairs(v) do n = n + 1 end
      out(string.format("%s.%s = <table, %d keys>", label, tostring(k), n))
    end
  end
end

local function nameMatches(name)
  local lower = tostring(name):lower()
  for _, p in ipairs(KEY_PATTERNS) do
    if lower:find(p, 1, true) then return true end
  end
  return false
end

local function getEngine()
  return powertrain and powertrain.getDevice("mainEngine") or nil
end

function M.dump()
  out("===== dump begin =====")

  -- powertrain device list
  local devices = powertrain.getDevices()
  for _, name in ipairs(sortedKeys(devices)) do
    local d = devices[name]
    out(string.format("device '%s' type=%s", tostring(name), tostring(d.type)))
  end

  -- main engine
  local engine = getEngine()
  if engine then
    dumpFields("mainEngine", engine)
  else
    out("powertrain.getDevice('mainEngine') = nil")
  end

  -- forced induction: sub-modules of the engine device, not entries in the device list
  if engine then
    for _, key in ipairs({"turbocharger", "supercharger"}) do
      local fi = engine[key]
      if type(fi) == "table" and fi.isExisting then
        dumpFields("mainEngine." .. key, fi)
      else
        out("mainEngine." .. key .. " not present")
      end
    end
    -- thermals sub-module
    if type(engine.thermals) == "table" then
      dumpFields("mainEngine.thermals", engine.thermals)
    else
      out("mainEngine.thermals = nil")
    end
  end

  -- electrics.values filtered by name
  local matched = {}
  for k, v in pairs(electrics.values) do
    if nameMatches(k) then matched[#matched + 1] = k end
  end
  table.sort(matched)
  for _, k in ipairs(matched) do
    out(string.format("electrics.values.%s = %s", k, tostring(electrics.values[k])))
  end

  -- environment (obj:getEnvTemperature returns Kelvin)
  local okT, envT = pcall(function() return obj:getEnvTemperature() end)
  local okP, envP = pcall(function() return obj:getEnvPressure() end)
  out("obj:getEnvTemperature() = " .. (okT and (tostring(envT) .. " K") or "unavailable"))
  out("obj:getEnvPressure() = " .. (okP and (tostring(envP) .. " (unit unverified)") or "unavailable"))
  local okD, envD = pcall(function() return obj:getRelativeAirDensity() end)
  out("obj:getRelativeAirDensity() = " .. (okD and tostring(envD) or "unavailable"))

  out("===== dump end =====")
end

local function f(v, fmt)
  if type(v) ~= "number" then return "n/a" end
  -- LuaJIT's %f prints denormals as huge integers (1e-310 becomes 302642506592531929)
  if math.abs(v) < 1e-300 then v = 0 end
  return string.format(fmt or "%.1f", v)
end

local function deepMerge(base, over)
  local result = {}
  for k, v in pairs(base) do result[k] = v end
  for k, v in pairs(over) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deepMerge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

-- chosen part names of the spawned vehicle, used as override keys alongside the model name
local function collectPartNames(node, names)
  if type(node) ~= "table" then return names end
  if type(node.chosenPartName) == "string" and node.chosenPartName ~= "" then
    names[#names + 1] = node.chosenPartName
  end
  if type(node.children) == "table" then
    for _, child in pairs(node.children) do collectPartNames(child, names) end
  end
  return names
end

local function loadConfig()
  local raw = jsonReadFile(CONFIG_PATH)
  if type(raw) ~= "table" or type(raw.defaults) ~= "table" then
    log("E", "heatsoak", PREFIX .. "could not read " .. CONFIG_PATH .. "; thermal model disabled")
    return nil
  end

  local model = v and v.data and v.data.model
  local parts = collectPartNames(v and v.config and v.config.partsTree, {})
  table.sort(parts)
  cachedVehicleParts = parts
  local engineParts = {}
  for _, name in ipairs(parts) do
    if name:lower():find("engine", 1, true) then engineParts[#engineParts + 1] = name end
  end
  out(string.format("override keys: model=%s engine parts=%s", tostring(model), table.concat(engineParts, ",")))

  -- model override first, so a part-specific one wins over it
  local result = raw.defaults
  local engines = raw.engines or {}
  if model and engines[model] then
    result = deepMerge(result, engines[model])
    out("applied config override: " .. model)
  end
  for _, name in ipairs(parts) do
    if engines[name] then
      result = deepMerge(result, engines[name])
      out("applied config override: " .. name)
    end
  end
  return result
end

local function modelEnabled(engine)
  -- vanilla treats a missing flag as disabled too (combustionEngineThermals.lua:1644)
  return engine ~= nil and engine.thermalsEnabled and engine.thermals ~= nil and cfg ~= nil
end

local function sortedKeyNames(t)
  if type(t) ~= "table" then return tostring(t) end
  local names = {}
  for _, k in ipairs(sortedKeys(t)) do names[#names + 1] = tostring(k) end
  return table.concat(names, ",")
end

local function dumpKeyNames(engine)
  out("keys mainEngine.turbocharger: " .. sortedKeyNames(engine.turbocharger))
  local debugData = engine.thermals.debugData
  out("keys thermals.debugData: " .. sortedKeyNames(debugData))
  if type(debugData) == "table" then
    for _, k in ipairs(sortedKeys(debugData)) do
      if type(debugData[k]) == "table" then
        out("keys thermals.debugData." .. tostring(k) .. ": " .. sortedKeyNames(debugData[k]))
      end
    end
  end
end

-- devices are fixed for a spawned vehicle; absent ones leave their node nil
local function findDrivetrainDevices(s, ambient)
  local c = cfg.gearboxOil
  gearboxDevice = powertrain.getDevice("gearbox")
  gearboxEfficiency = gearboxDevice and c.efficiency[gearboxDevice.type] or nil
  if gearboxDevice and not gearboxEfficiency then
    out("no gearboxOil.efficiency for type " .. tostring(gearboxDevice.type) .. "; gearbox node skipped")
    gearboxDevice = nil
  end
  converterDevice = gearboxDevice and powertrain.getDevicesByType("torqueConverter")[1] or nil
  s.gearboxOil = gearboxDevice and ambient or nil

  diffDevices = powertrain.getDevicesByType("differential")
  s.diffOilByDevice = {}
  for _, d in ipairs(diffDevices) do s.diffOilByDevice[d.name] = ambient end
  s.diffOil = #diffDevices > 0 and ambient or nil
end

-- logs once whether the fields change while driving, and whether the debug stream was open at the time
local function probeThermalData(etd)
  if probe.done then return end
  probe.samples = probe.samples + 1
  for _, name in ipairs(PROBE_FIELDS) do
    if etd[name] ~= probe.last[name] then probe.changed[name] = (probe.changed[name] or 0) + 1 end
    probe.last[name] = etd[name]
  end
  if probe.samples < PROBE_SAMPLES then return end
  probe.done = true

  local parts = {}
  for _, name in ipairs(PROBE_FIELDS) do
    parts[#parts + 1] = string.format("%s changed %d/%d last=%s", name, probe.changed[name] or 0, probe.samples, tostring(etd[name]))
  end
  local streamOpen = streams and streams.willSend and streams.willSend("engineThermalData")
  local live = (probe.changed.energyToCylinderWall or 0) > 1 and (probe.changed.energyToOil or 0) > 1
  out(string.format("debugData live check: %s, streamOpen=%s: %s", live and "LIVE" or "NOT LIVE", tostring(streamOpen and true or false), table.concat(parts, "; ")))
end

local function stepOil(t, heatIn, c, bay, ambient, speed, dt)
  local heatOut = (c.gAirBase + c.gAirPerSpeed * speed) * (t - ambient) + c.gBay * (t - bay)
  return t + (heatIn - heatOut) / (c.mass * c.specificHeat) * dt
end

local function validLimit(x)
  return type(x) == "number" and x == x and x > 0
end

-- The block limit is a jbeam value that vanilla does not copy onto the engine device, and its merged jbeam copy is a
-- file-local in powertrain.lua. Vanilla builds that copy by merging the named section v.data[name] over the device
-- row in v.data.powertrain (powertrain.lua:494-495), so both are looked up here, the section first because it wins.
-- Returns the limit and "found", or nil with "unset" (the engine's jbeam was read and has no such key, so vanilla uses
-- its default) or "unreadable" (the engine's jbeam could not be found at all) plus a note.
local function jbeamBlockLimit(engine)
  local data = type(v) == "table" and v.data or nil
  if type(data) ~= "table" then return nil, "unreadable", "no v.data" end
  local name = engine.name
  local section = data[name]
  local row = nil
  if type(data.powertrain) == "table" then
    for _, entry in pairs(data.powertrain) do
      if type(entry) == "table" and entry.name == name then
        row = entry
        break
      end
    end
  end
  -- explicit checks, not ipairs over {section, row}: that would stop at a nil section and never look at the row
  if type(section) == "table" and validLimit(section.engineBlockTemperatureDamageThreshold) then
    return section.engineBlockTemperatureDamageThreshold, "found"
  end
  if type(row) == "table" and validLimit(row.engineBlockTemperatureDamageThreshold) then
    return row.engineBlockTemperatureDamageThreshold, "found"
  end
  if type(section) == "table" or row then return nil, "unset" end
  return nil, "unreadable", string.format("v.data.%s is %s and the powertrain has no '%s' row", tostring(name), type(section), tostring(name))
end

-- vanilla's own turbo condition, read only: integrity 0-1 (1 = undamaged) and the two damage coefficients it is made
-- from (damageFrictionCoef 1..20, damageExhaustPowerCoef 1..0.2, turbocharger.lua:136-146). nil when unavailable.
local function turboCondition(engine)
  local turbo = engine.turbocharger
  if type(turbo) ~= "table" or not turbo.isExisting or type(turbo.getPartCondition) ~= "function" then return nil end
  local ok, integrity, state = pcall(turbo.getPartCondition)
  if not ok or type(integrity) ~= "number" or integrity ~= integrity then return nil end
  local friction = type(state) == "table" and type(state.damageFrictionCoef) == "number" and state.damageFrictionCoef or nil
  local exhaust = type(state) == "table" and type(state.damageExhaustPowerCoef) == "number" and state.damageExhaustPowerCoef or nil
  return integrity, friction, exhaust
end

-- Vanilla turbo heat damage (turbocharger.lua:200-206) compares turboTemp = exhaust + coolant + oil against the jbeam
-- key damageThresholdTemperature of the turbocharger section (default 1000, turbocharger.lua:441). The engine's own
-- jbeam names that section in its 'turbocharger' key (combustionEngine.lua:2111-2114), merged like the block limit above.
local function jbeamTurboThreshold(engine)
  local data = type(v) == "table" and v.data or nil
  if type(data) ~= "table" then return nil, "unreadable", "no v.data" end
  local name = engine.name
  local sectionName = type(data[name]) == "table" and data[name].turbocharger or nil
  if type(sectionName) ~= "string" and type(data.powertrain) == "table" then
    for _, entry in pairs(data.powertrain) do
      if type(entry) == "table" and entry.name == name and type(entry.turbocharger) == "string" then
        sectionName = entry.turbocharger
        break
      end
    end
  end
  if type(sectionName) ~= "string" then
    return nil, "unreadable", string.format("engine '%s' names no turbocharger section in its jbeam", tostring(name))
  end
  local turboData = data[sectionName]
  if type(turboData) ~= "table" then
    return nil, "unreadable", string.format("v.data.%s is %s", sectionName, type(turboData))
  end
  if validLimit(turboData.damageThresholdTemperature) then return turboData.damageThresholdTemperature, "found", sectionName end
  return nil, "unset", sectionName
end

local function readTurboThreshold(engine)
  local value, state, note = jbeamTurboThreshold(engine)
  local default = cfg.turboDamage.vanillaThresholdDefault
  if value then
    turboThreshold = value
    out(string.format("turbo damage threshold: %g C (jbeam damageThresholdTemperature in '%s'), compared with exhaust + coolant + oil", value, note))
  elseif state == "unset" then
    turboThreshold = default
    out(string.format("turbo damage threshold: %g C (damageThresholdTemperature not set in '%s', using vanilla default), compared with exhaust + coolant + oil", default, note))
  else
    turboThreshold = nil
    out("turbo damage threshold: lookup failed: " .. tostring(note))
  end
end

-- Per-engine damage limits are copied from the jbeam onto the engine device. When a jbeam omits one, vanilla falls
-- back to its own default (combustionEngineThermals.lua:1785-1789), so the config carries those same defaults.
local function readDamageThresholds(engine)
  local defaults = cfg.damage.defaults
  local sources = {}
  local function pick(key, deviceField, default)
    local v = engine[deviceField]
    if type(v) == "number" and v == v and v > 0 then
      sources[key] = "device"
      return v
    end
    sources[key] = "default"
    return default
  end
  thresholds = {
    wall = pick("wall", "cylinderWallTemperatureDamageThreshold", defaults.wallTemperature),
    ring = pick("ring", "pistonRingDamageThreshold", defaults.pistonRing),
    gasket = pick("gasket", "headGasketDamageThreshold", defaults.headGasket),
    rod = pick("rod", "connectingRodDamageThreshold", defaults.connectingRod)
  }

  -- block limit: the jbeam if it can be read, then a per-model override from the config, then vanilla's default
  local jbeamLimit, jbeamState, lookupNote = jbeamBlockLimit(engine)
  if jbeamLimit then
    thresholds.block, sources.block = jbeamLimit, "jbeam"
  elseif validLimit(cfg.damage.blockTemperatureOverride) then
    thresholds.block, sources.block = cfg.damage.blockTemperatureOverride, "override"
  else
    thresholds.block, sources.block = defaults.blockTemperature, "default"
  end
  local reason = ""
  if jbeamState == "unset" then
    reason = sources.block == "override"
      and string.format(" | not set in jbeam, using override %g", thresholds.block)
      or string.format(" | not set in jbeam, using vanilla default %g", thresholds.block)
  elseif jbeamState == "unreadable" then
    reason = " | jbeam lookup failed: " .. tostring(lookupNote)
  end
  out(string.format("block limit: %g (%s)%s", thresholds.block, sources.block, reason))

  -- the oil trigger is a fixed constant in vanilla and no jbeam sets it, so it has no source to look up
  out(string.format("damage thresholds: wall=%g(%s) block=%g(%s) ring=%g(%s) gasket=%g(%s) rod=%g(%s) oil=%g(constant)",
    thresholds.wall, sources.wall, thresholds.block, sources.block, thresholds.ring, sources.ring,
    thresholds.gasket, sources.gasket, thresholds.rod, sources.rod, defaults.oilTemperature))
end

-- vanilla accumulates joules of engine work while a temperature is over its limit, capped at the threshold
local function damagePercent(accumulated, threshold)
  if type(accumulated) ~= "number" or accumulated ~= accumulated or not threshold then return nil end
  return clamp01(accumulated / threshold) * 100
end

local function positiveOrNil(v)
  if type(v) == "number" and v > 0 then return v end
  return nil
end

local function flag(v)
  if type(v) ~= "boolean" then return "n/a" end
  return v and "true" or "false"
end

-- vanilla's engine damage flags that don't live on thermals; getDamage is a plain read that returns false when unset
local function trackedFlag(name)
  if type(damageTracker) ~= "table" or type(damageTracker.getDamage) ~= "function" then return "n/a" end
  return flag(damageTracker.getDamage("engine", name) and true or false)
end

-- electrics.values.rpm decays to denormals once the engine has stopped. Nothing else in the model reads it.
local function sanitizeRpm(raw, engine)
  local stopped = engine.isDisabled or engine.isStalled or (engine.ignitionCoef or 1) < 1
  local magnitude = type(raw) == "number" and math.abs(raw) or 0
  local invalid = type(raw) ~= "number" or raw ~= raw or magnitude > cfg.rpmMax or (magnitude > 0 and magnitude < 1e-300)
  if invalid and not rpmNoted then
    rpmNoted = true
    out(string.format("rpm sanitized: raw=%s stopped=%s", type(raw) == "number" and string.format("%.17g", raw) or tostring(raw), tostring(stopped and true or false)))
  end
  if stopped or invalid then return 0 end
  return raw
end

-- Ground model surface friction heat partition and loose surface dissipation:
-- Defines what fraction of friction scrub energy turns into rubber heat
local SURFACE_HEAT_FACTOR = {
  [9]  = 0.00, -- WATER
  [10] = 0.45, -- ASPHALT (dry pavement: 45% into rubber, 55% into pavement)
  [11] = 0.15, -- ASPHALT_WET
  [12] = 0.05, -- SLIPPERY
  [13] = 0.40, -- ROCK
  [14] = 0.22, -- DIRT_DUSTY
  [15] = 0.25, -- DIRT
  [16] = 0.10, -- SAND (loose particles displace; low rubber friction)
  [17] = 0.15, -- SANDY_ROAD
  [18] = 0.05, -- MUD (slurry lubricant cooling)
  [19] = 0.20, -- GRAVEL
  [20] = 0.06, -- GRASS (moist sod/vegetation shears; rubber does not grind)
  [21] = 0.00, -- ICE
  [22] = 0.00, -- SNOW
  [29] = 0.45, -- RUMBLE_STRIP
  [30] = 0.45, -- COBBLESTONE
  [31] = 0.06, -- FOLIAGE_THIN
  [32] = 0.40, -- SPIKE_STRIP
}

local originalNodeFriction = {}

local function restoreTireFriction()
  if not originalNodeFriction then return end
  for nodeId, orig in pairs(originalNodeFriction) do
    if obj and type(obj.setNodeFrictionSlidingCoefs) == "function" and orig then
      obj:setNodeFrictionSlidingCoefs(nodeId, orig.friction, orig.sliding)
    end
  end
  originalNodeFriction = {}
end

local function triggerTireBlowout(wd, t, reason)
  if not t or t.blown or not wd or wd.isTireDeflated or wd.isBroken then return end
  t.blown = true
  t.blowoutReason = reason

  if type(beamstate) == "table" and type(beamstate.deflateTire) == "function" and wd.wheelID then
    pcall(beamstate.deflateTire, wd.wheelID)
  elseif obj and wd.pressureGroup and type(v) == "table" and type(v.data) == "table" and type(v.data.pressureGroups) == "table" and v.data.pressureGroups[wd.pressureGroup] then
    pcall(obj.deflatePressureGroup, obj, v.data.pressureGroups[wd.pressureGroup])
  end

  if type(damageTracker) == "table" and type(damageTracker.setDamage) == "function" then
    pcall(damageTracker.setDamage, "wheels", "tire" .. (wd.name or ""), true)
  end

  local alertMsg = string.format("%s tire blowout! (%s)", wd.name or "Wheel", reason or "overheat")
  if type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
    pcall(guihooks.messageForSeatedPlayers, {txt = alertMsg, context = {}}, 6, "vehicle.damage.deflated." .. (wd.name or ""))
  end

  log("W", "heatsoak", string.format("Tire blowout on %s! Reason: %s, treadT=%.1fC, wear=%.1f%%, psi=%.1f",
    tostring(wd.name), tostring(reason), t.treadT or 0, t.wearPercent or 0, t.pressurePsi or 0))
end

local function detectWheelCompound(wdName, parts)
  parts = parts or cachedVehicleParts or {}
  local lowerName = wdName and string.lower(wdName) or ""
  local isFront = lowerName:sub(1,1) == "f" or lowerName:find("_f", 1, true) or lowerName:find("front", 1, true) or lowerName:find("fl", 1, true) or lowerName:find("fr", 1, true)
  local isRear  = lowerName:sub(1,1) == "r" or lowerName:find("_r", 1, true) or lowerName:find("rear", 1, true) or lowerName:find("rl", 1, true) or lowerName:find("rr", 1, true)

  for _, part in ipairs(parts) do
    local p = string.lower(part)
    if p:find("tire", 1, true) then
      local matchesAxle = (isFront and (p:find("_f_", 1, true) or p:find("front", 1, true)))
                       or (isRear and (p:find("_r_", 1, true) or p:find("rear", 1, true)))
      if matchesAxle then
        if p:find("drag", 1, true) then return "drag"
        elseif p:find("race", 1, true) or p:find("slick", 1, true) then return "race"
        elseif p:find("sport", 1, true) or p:find("semi_slick", 1, true) then return "sport"
        elseif p:find("rally", 1, true) then return "rally"
        elseif p:find("offroad", 1, true) or p:find("allterrain", 1, true) or p:find("mud", 1, true) then return "offroad"
        elseif p:find("standard", 1, true) or p:find("biasply", 1, true) then return "standard"
        end
      end
    end
  end

  for _, part in ipairs(parts) do
    local p = string.lower(part)
    if p:find("tire", 1, true) then
      if p:find("drag", 1, true) then return "drag"
      elseif p:find("race", 1, true) or p:find("slick", 1, true) then return "race"
      elseif p:find("sport", 1, true) or p:find("semi_slick", 1, true) then return "sport"
      elseif p:find("rally", 1, true) then return "rally"
      elseif p:find("offroad", 1, true) or p:find("allterrain", 1, true) or p:find("mud", 1, true) then return "offroad"
      end
    end
  end

  return "standard"
end

local function calculateTireGrip(t, tc, presPa, basePresPa)
  local comp = (tc.compounds and tc.compounds[t.compound]) or tc
  local tMin = comp.optimumTempMin or tc.optimumTempMin or 75
  local tMax = comp.optimumTempMax or tc.optimumTempMax or 100
  local tWarn = comp.warnTemp or tc.warnTemp or 115
  local tCrit = comp.criticalTemp or tc.criticalTemp or 135
  local coldMin = comp.coldGripMin or tc.coldGripMin or 0.85
  local overheatGrip = comp.overheatGrip or tc.overheatGrip or 0.80
  local blisterGrip = comp.blisterGrip or tc.blisterGrip or 0.65

  local trd = t.treadT or 20
  local mTemp = 1.0

  if trd < tMin then
    local coldFrac = math.max((trd - 15) / math.max(tMin - 15, 1), 0)
    coldFrac = math.min(coldFrac, 1.0)
    mTemp = coldMin + (1.0 - coldMin) * (coldFrac ^ 0.8)
  elseif trd <= tMax then
    mTemp = 1.0
  elseif trd <= tWarn then
    local warmFrac = (trd - tMax) / math.max(tWarn - tMax, 1)
    mTemp = 1.0 - (1.0 - 0.90) * warmFrac
  elseif trd <= tCrit then
    local hotFrac = (trd - tWarn) / math.max(tCrit - tWarn, 1)
    mTemp = 0.90 - (0.90 - overheatGrip) * hotFrac
  else
    local critFrac = math.min((trd - tCrit) / 25, 1.0)
    mTemp = overheatGrip - (overheatGrip - blisterGrip) * critFrac
  end

  -- Tread Wear Penalty
  local wear = math.min(math.max(t.wearPercent or 0, 0), 100)
  local maxWearLoss = comp.maxWearGripLoss or tc.maxWearGripLoss or 0.25
  local mWear = 1.0 - maxWearLoss * ((wear / 100) ^ 1.5)

  -- Pressure Penalty
  local presRatio = math.max((presPa or basePresPa) / math.max(basePresPa, 1), 0.2)
  local mPres = 1.0
  if presRatio > 1.25 then
    mPres = math.max(1.0 - (presRatio - 1.25) * 0.15, 0.90)
  elseif presRatio < 0.85 then
    mPres = math.max(1.0 - (0.85 - presRatio) * 0.25, 0.85)
  end

  local totalGrip = math.max(math.min(mTemp * mWear * mPres, 1.05), 0.45)
  return totalGrip, mTemp, mWear, mPres
end

local function updateTires(s, dt, ambient, speed)
  local tc = cfg.tires
  if not tc then return end
  if type(wheels) ~= "table" or type(wheels.wheels) ~= "table" then return end

  s.tireData = s.tireData or {}

  for _, wd in pairs(wheels.wheels) do
    if type(wd) == "table" and wd.name then
      local basePresPa = wd.startingPressure or 206842
      local t = s.tireData[wd.name]
      if not t then
        local compound = detectWheelCompound(wd.name, cachedVehicleParts)
        t = {
          name = wd.name,
          compound = compound,
          wheelID = wd.wheelID,
          treadT = ambient,
          carcassT = ambient,
          airT = ambient,
          pressurePsi = math.max((basePresPa * 0.000145038) - 14.696, 0),
          wearPercent = 0,
          vanillaAvg = ambient,
          vanillaCore = ambient,
          slipEnergy = 0,
          slipSpeed = 0,
          slipPowerEst = 0,
          downForce = 0
        }
        s.tireData[wd.name] = t
      end

      local comp = (tc.compounds and tc.compounds[t.compound]) or {}
      local surfaceThickness = comp.surfaceThickness or tc.surfaceThickness or 0.0015
      local treadThickness = comp.treadThickness or tc.treadThickness or 0.009
      local heatGainMult = comp.heatGainMult or 1.0
      local abrasionMult = comp.abrasionCapacityMult or 1.0

      -- 1. Real physical dimensions from JBeam geometry
      local radius = wd.radius or 0.33
      local width = wd.tireWidth or 0.225
      local circumference = 2 * math.pi * radius
      local treadArea = circumference * width
      local areaScale = math.max(treadArea / 0.45, 0.5)
      local rubberDensity = tc.rubberDensity or 1150

      -- Surface flash skin (quick thermal response to slip and braking)
      local treadMass = math.max(treadArea * surfaceThickness * rubberDensity, 0.7)
      -- Bulk carcass mass (belts, plies, sidewalls: ~8-10 kg)
      local carcassThickness = math.max(treadThickness - surfaceThickness, 0.004) + 0.010
      local carcassMass = math.max(treadArea * carcassThickness * rubberDensity, 6.0)
      local cavityAirMass = math.max((wd.tireVolume or (treadArea * 0.10)) * 1.225 * 2.8, 0.12)
      -- Usable tread rubber slab for total abrasive wear capacity
      local fullTreadMass = math.max(treadArea * treadThickness * rubberDensity, 2.5)

      local treadC = treadMass * (tc.treadSpecificHeat or 1800)
      local carcassC = carcassMass * (tc.carcassSpecificHeat or 1600)
      local airC = cavityAirMass * (tc.cavityAirSpecificHeat or 1005)

      local wheelSpeed = math.abs(wd.angularVelocity or 0) * radius
      local slipEnergy = wd.slipEnergy or 0
      local downForce = math.max(wd.downForceRaw or wd.downForce or 0, 0)
      local brakeCore = wd.brakeCoreTemperature or ambient

      -- Slip speed and power comparison for logging / unit verification
      local sLong = wd.lastSlip or 0
      local sLat = wd.lastSideSlip or 0
      local slipSpeed = math.sqrt(sLong * sLong + sLat * sLat)
      local frictionForceEst = downForce * 1.0
      local slipPowerEst = slipSpeed * frictionForceEst

      -- 2. Surface material partition and ground contact
      local mat1 = wd.contactMaterialID1
      local mat2 = wd.contactMaterialID2
      local hasContact = (mat1 and mat1 >= 0) or (mat2 and mat2 >= 0)
      local isOnGround = downForce > 50 and hasContact

      local surfFactor = 0
      if hasContact then
        local f1 = mat1 and SURFACE_HEAT_FACTOR[mat1]
        local f2 = mat2 and SURFACE_HEAT_FACTOR[mat2]
        surfFactor = f1 or f2 or (tc.asphaltFrictionPartition or 0.45)
        if f1 and f2 then surfFactor = math.min(f1, f2) end

        -- Loose ground displacement / sinkage (sand, mud, deep soil) carries heat away in flying debris
        local depth = wd.contactDepth or 0
        if depth > 0.02 then
          surfFactor = surfFactor * math.max(0.15, 1 - (depth - 0.02) * 10)
        end
      end

      -- Water immersion quench
      local inWater = obj and type(obj.inWater) == "function" and wd.node1 and obj:inWater(wd.node1)
      if inWater then surfFactor = 0 end

      -- 3. Heat inputs
      -- Contact patch micro-slip shear power during braking (even without screeching skids)
      local brakeInput = (electrics.values and electrics.values.brake) or 0
      local brakingTorque = math.abs(wd.brakingTorque or 0)
      local isBraking = isOnGround and (brakeInput > 0.02 or brakingTorque > 15)

      local brakeShearPower = 0
      if isBraking and speed > 1.0 then
        local brakeForce = brakingTorque / math.max(radius, 0.05)
        local maxFrictionForce = downForce * (comp.frictionCoef or 1.0)
        local retardingForce = math.min(brakeForce > 0 and brakeForce or (brakeInput * downForce), maxFrictionForce)

        local absSlipLong = math.abs(sLong)
        local speedDiff = math.max(speed - wheelSpeed, 0)
        local microSlipV = math.min(math.max(absSlipLong, speedDiff), speed)
        if microSlipV > 0.05 then
          brakeShearPower = retardingForce * microSlipV
        end
      end

      -- Total friction power combines BeamNG solver slip energy and contact patch braking micro-slip
      local totalFrictionPower = math.max(slipEnergy, brakeShearPower)
      local qSlip = totalFrictionPower * surfFactor * heatGainMult

      -- Underinflation hysteretic flexing: lower pressure causes larger sidewall deflection and higher flex heating
      local presPa = basePresPa
      if wd.pressureGroup and type(v) == "table" and type(v.data) == "table" and type(v.data.pressureGroups) == "table" and v.data.pressureGroups[wd.pressureGroup] then
        if obj and type(obj.getGroupPressure) == "function" then
          presPa = obj:getGroupPressure(v.data.pressureGroups[wd.pressureGroup]) or presPa
        end
      end
      local presRatio = math.max(presPa / basePresPa, 0.35)
      local flexFactor = (1 / presRatio) ^ 1.25
      local qFlex = 0
      if isOnGround then
        qFlex = (tc.flexingCoeff or 0.0060) * downForce * wheelSpeed * flexFactor
      end

      -- Carcass: heat conduction from brake rotor through wheel hub
      local qBrake = (tc.conductionBrakeToWheel or 0.20) * math.max(brakeCore - t.carcassT, 0)

      -- 4. Heat transfers
      -- Effective turbulent air velocity combines car forward airspeed and tire rotational spin
      local vAirTurbulent = math.sqrt(speed * speed + wheelSpeed * wheelSpeed * 0.7)
      local qAirTread = ((tc.convectionAirBase or 14.0) + (tc.convectionAirPerSpeed or 1.8) * vAirTurbulent) * areaScale * (t.treadT - ambient)
      local qAirCarcass = ((tc.convectionAirBase or 14.0) * 0.4 + (tc.convectionAirPerSpeed or 1.8) * 0.4 * speed) * areaScale * (t.carcassT - ambient)

      -- Road surface conduction (isolated if airborne)
      local roadTemp = ambient + (ambient > 25 and (ambient - 20) * 0.40 or 0)
      local qRoad = 0
      if isOnGround then
        qRoad = (tc.conductionRoadBase or 28.0) * areaScale * (t.treadT - roadTemp)
      end

      -- Tread to Carcass conduction
      local qTread2Carcass = (tc.conductionTreadToCarcass or 22.0) * areaScale * (t.treadT - t.carcassT)
      -- Water cooling quench if submerged
      local qWater = inWater and (450 * areaScale * (t.treadT - ambient)) or 0
      -- Carcass to Cavity Air conduction
      local qCarcass2Air = (tc.conductionCarcassToAir or 8.0) * areaScale * (t.carcassT - t.airT)

      -- 5. Integration per dt
      t.treadT = t.treadT + (qSlip - qAirTread - qRoad - qTread2Carcass - qWater) * dt / treadC
      t.carcassT = t.carcassT + (qTread2Carcass + qFlex + qBrake - qAirCarcass - qCarcass2Air) * dt / carcassC
      t.airT = t.airT + qCarcass2Air * dt / airC

      -- 6. Gay-Lussac Ideal Gas Law: P_hot_abs = P_cold_abs * (T_air_K / T_ambient_K)
      local ambientK = ambient + 273.15
      local airK = t.airT + 273.15
      local coldPresAbsPsi = (basePresPa * 0.000145038)
      local hotPresAbsPsi = coldPresAbsPsi * (airK / ambientK)
      t.pressurePsi = math.max(hotPresAbsPsi - 14.696, 0)

      -- 7. Cumulative physical tread wear tracking (scales with tire heat, road surface heat, and ambient heat)
      t.wearPercent = t.wearPercent or 0
      local optMax = comp.optimumTempMax or tc.optimumTempMax or 100

      -- Factor A: Tire heat (tread surface softening + bulk carcass thermal softening)
      local mTire = 1.0
      if t.treadT > optMax then
        local overheatDeg = t.treadT - optMax
        mTire = 1.0 + math.min((overheatDeg / 25.0) ^ 2 * 3.5, 6.0)
      elseif t.treadT < (optMax - 40.0) then
        local coldDeg = (optMax - 40.0) - t.treadT
        mTire = 1.0 + math.min((coldDeg / 30.0) * 0.35, 0.50)
      end
      if t.carcassT > 75.0 then
        local carcassSoftening = math.min((t.carcassT - 75.0) / 45.0, 1.0) * 0.50
        mTire = mTire * (1.0 + carcassSoftening)
      end

      -- Factor B: Road Surface heat (hot asphalt accelerates shear and abrasive degradation)
      local mSurface = 1.0
      if roadTemp > 25.0 then
        mSurface = 1.0 + math.min((roadTemp - 25.0) / 40.0, 1.5) * 0.45
      end

      -- Factor C: Ambient heat (high ambient temperature accelerates polymer breakdown)
      local mAmbient = 1.0
      if ambient > 20.0 then
        mAmbient = 1.0 + math.min((ambient - 20.0) / 30.0, 1.5) * 0.35
      end

      local totalWearMult = mTire * mSurface * mAmbient
      local wearJoule = qSlip * dt * totalWearMult
      local totalAbrasiveCapacity = (tc.abrasionCapacityPerKg or 32000000) * fullTreadMass * abrasionMult
      t.wearPercent = math.min(t.wearPercent + (wearJoule / totalAbrasiveCapacity) * 100, 100)

      -- Read vanilla internal temperatures for verification (K to C)
      local vAvg = ambient
      local vCore = ambient
      if obj and type(obj.getWheelAvgTemperature) == "function" and wd.wheelID then
        local rawAvg = obj:getWheelAvgTemperature(wd.wheelID)
        if rawAvg and rawAvg > 0 then vAvg = rawAvg - 273.15 end
      end
      if obj and type(obj.getWheelCoreTemperature) == "function" and wd.wheelID then
        local rawCore = obj:getWheelCoreTemperature(wd.wheelID)
        if rawCore and rawCore > 0 then vCore = rawCore - 273.15 end
      end

      t.vanillaAvg = vAvg
      t.vanillaCore = vCore
      t.slipEnergy = slipEnergy
      t.slipSpeed = slipSpeed
      t.slipPowerEst = slipPowerEst
      t.downForce = downForce
      t.brakeCore = brakeCore
      t.coldPsi = math.max((basePresPa * 0.000145038) - 14.696, 0)
      t.sLat = sLat

      -- 8. Stage 2: Grip Window, Pressure Physics, and Blowouts
      local totalGrip, mTemp, mWear, mPres = calculateTireGrip(t, tc, presPa, basePresPa)
      t.gripMult = totalGrip
      t.mTemp = mTemp
      t.mWear = mWear
      t.mPres = mPres

      local isBlownOrDeflated = t.blown or wd.isTireDeflated or wd.isBroken

      -- Apply live node friction if enabled and tire is intact
      if tc.enableGripEffects ~= false and not isBlownOrDeflated then
        local treadNodes = wd.treadNodes or (v and v.data and v.data.wheels and v.data.wheels[wd.wheelID] and v.data.wheels[wd.wheelID].treadNodes)
        if treadNodes and (not t.appliedGrip or math.abs(t.appliedGrip - totalGrip) >= 0.005) then
          t.appliedGrip = totalGrip
          for _, nodeId in pairs(treadNodes) do
            local orig = originalNodeFriction[nodeId]
            if not orig then
              local node = v and v.data and v.data.nodes and v.data.nodes[nodeId]
              if node then
                orig = {
                  friction = node.frictionCoef or 1.0,
                  sliding = node.slidingFrictionCoef or node.frictionCoef or 1.0
                }
                originalNodeFriction[nodeId] = orig
              end
            end
            if orig and obj and type(obj.setNodeFrictionSlidingCoefs) == "function" then
              obj:setNodeFrictionSlidingCoefs(nodeId, orig.friction * totalGrip, orig.sliding * totalGrip)
            end
          end
        end
      end

      -- Apply live pneumatic cavity pressure to physics solver
      if tc.enablePressurePhysics ~= false and not isBlownOrDeflated then
        if wd.pressureGroup and type(v) == "table" and type(v.data) == "table" and type(v.data.pressureGroups) == "table" and v.data.pressureGroups[wd.pressureGroup] then
          local pGroup = v.data.pressureGroups[wd.pressureGroup]
          if obj and type(obj.setGroupPressure) == "function" then
            local hotPresAbsPa = hotPresAbsPsi * 6894.757
            local clampedPa = math.max(math.min(hotPresAbsPa, 517106), 103421)
            obj:setGroupPressure(pGroup, clampedPa)
          end
        end
      end

      -- Blowout failure checks
      if tc.enableBlowout ~= false and not isBlownOrDeflated then
        local bTempThresh = comp.criticalTemp or tc.blowoutTempThreshold or 140.0
        local bWearThresh = tc.blowoutWearThreshold or 100.0
        local bMaxPsi = tc.maxBurstPressurePsi or 65.0

        -- A. Thermal delamination
        -- Real belt delamination requires internal ply bond failure, which only occurs
        -- when the deep bulk carcass is boiling hot (carcassT >= 95C) AND tread is scorching (> 155C).
        -- Drifting with cold or warm tires (carcass < 95C) simply smokes and wears the tread surface,
        -- and will NOT trigger sudden premature blowouts.
        local delamTreadThresh = comp.blowoutTempThreshold or tc.blowoutTempThreshold or 155.0
        local delamCarcassThresh = 95.0

        if t.treadT >= delamTreadThresh and t.carcassT >= delamCarcassThresh then
          local treadDelta = (t.treadT - delamTreadThresh) / 25.0
          local carcassDelta = (t.carcassT - delamCarcassThresh) / 20.0
          local speedFactor = 0.4 + 0.6 * math.min(wheelSpeed / 25.0, 2.0)
          local loadFactor = 0.4 + 0.6 * math.min(downForce / 4000.0, 2.0)
          local stressRate = treadDelta * carcassDelta * speedFactor * loadFactor * 0.25
          t.thermalStress = (t.thermalStress or 0) + stressRate * dt
          if t.thermalStress >= 5.0 or (t.carcassT >= 135.0 and t.treadT >= 190.0) then
            triggerTireBlowout(wd, t, "thermal delamination")
          end
        else
          t.thermalStress = math.max((t.thermalStress or 0) - 0.50 * dt, 0)
        end

        -- B. Excessive tread wear / cord exposure
        if not t.blown and t.wearPercent >= bWearThresh then
          local cordRate = (0.15 + 0.85 * math.min(wheelSpeed / 20, 2.0)) * (0.3 + 0.7 * math.min(downForce / 4000, 2.0))
          t.cordStress = (t.cordStress or 0) + cordRate * dt
          if t.cordStress >= 8.0 then
            triggerTireBlowout(wd, t, "cord wear puncture")
          end
        else
          t.cordStress = 0
        end

        -- C. Overpressure rupture
        if not t.blown and t.pressurePsi >= bMaxPsi then
          triggerTireBlowout(wd, t, "overpressure rupture")
        end
      end
    end
  end
end

local function updateNodes(dt, engine)
  local s = M.state
  local ev = electrics.values
  local th = engine.thermals
  local ambient = ambientOverrideC or (obj:getEnvTemperature() - KELVIN)
  local rpm = sanitizeRpm(ev.rpm, engine)
  s.rpm = rpm
  local throttle = ev.throttle or 0
  local speed = ev.airspeed or 0
  local hasTurbo = type(engine.turbocharger) == "table" and engine.turbocharger.isExisting
  local hasSupercharger = type(engine.supercharger) == "table" and engine.supercharger.isExisting

  if not nodesReady then
    -- Cold Spawn Override: Force all engine thermals and fluids to ambient temperature
    if th then
      th.engineBlockTemperature = ambient
      th.cylinderWallTemperature = ambient
      th.oilTemperature = ambient
      th.coolantTemperature = ambient
      th.exhaustTemperature = ambient
    end
    lastSimulatedOil = ambient
    s.egt = ambient
    s.turbineHousing = hasTurbo and ambient or nil
    s.compressorHousing = hasTurbo and ambient or nil
    s.superchargerHousing = hasSupercharger and ambient or nil
    s.manifoldHousing = ambient
    s.icCore = (hasTurbo or hasSupercharger) and ambient or nil
    s.engineBayAir = ambient
    findDrivetrainDevices(s, ambient)
    readDamageThresholds(engine)
    if hasTurbo then readTurboThreshold(engine) else turboThreshold = nil end
    s.cylinderHead = ambient
    s.rodBearings = ambient
    s.catalyst = engine.requiredEnergyType == "gasoline" and ambient or nil
    s.catalystDamage = s.catalyst and 0 or nil
    s.dCatHeat = s.catalyst and 0 or nil
    s.dCatContam = s.catalyst and 0 or nil
    s.catalystLoss = s.catalyst and 0 or nil
    s.gearboxDamage = gearboxDevice and 0 or nil
    s.diffDamage = (#diffDevices > 0) and 0 or nil
    -- the damage model restarts from zero with every vehicle reset, which is what sets nodesReady back to false
    lubWindow = nil
    s.turboPrevIntegrity = nil
    s.turboOurDamage = hasTurbo and 0 or nil
    s.turboDamage = hasTurbo and 0 or nil
    s.tireData = nil
    nodesReady = true
  end

  -- Initial spawn cold lock (ensure ambient temp before engine start)
  if timer < 0.25 and rpm == 0 and th and th.coolantTemperature and th.coolantTemperature > ambient + 5 then
    th.engineBlockTemperature = ambient
    th.cylinderWallTemperature = ambient
    th.oilTemperature = ambient
    th.coolantTemperature = ambient
    th.exhaustTemperature = ambient
    s.cylinderHead = ambient
    s.rodBearings = ambient
    lastSimulatedOil = ambient
  end

  -- energy fields below are per update and would be counted repeatedly while nothing is simulated
  if dt <= 0 then return end

  local running = rpm >= cfg.engineOffRpm
  local powerFrac = clamp01((engine.engineLoad or 0) * rpm / engine.maxRPM)

  -- egt
  local c = cfg.egt
  local egtTarget = ambient + c.base + c.k * powerFrac ^ c.exponent
  local egtTau = c.tau
  if not running then
    egtTarget = ambient
    egtTau = c.engineOffTau
  elseif throttle <= 0 and rpm > c.fuelCutRpm then
    egtTarget = c.fuelCutTemp
  end
  s.egt = s.egt + (egtTarget - s.egt) * (1 - math.exp(-dt / egtTau))

  -- engineBayAir
  c = cfg.engineBayAir
  local bay = s.engineBayAir
  -- a missing block temperature means no heat flow from the block, not a crash
  local blockTemperature = type(th.engineBlockTemperature) == "number" and th.engineBlockTemperature or bay
  local bayIn = c.gBlock * (blockTemperature - bay) + c.gExhaust * (th.exhaustTemperature - bay)
  local bayOut = (c.gAmbientBase + c.gAmbientPerSpeed * speed) * (bay - ambient)
  s.engineBayAir = bay + (bayIn - bayOut) / (c.mass * c.specificHeat) * dt

  -- turbineHousing: the link scales with exhaust flow and is gone once the engine stops
  if hasTurbo then
    c = cfg.turbineHousing
    local t = s.turbineHousing
    local link = running and (c.linkBase + c.linkPerPower * powerFrac) or 0
    local air = c.airBase + (running and c.airRunning or 0) + c.airPerSpeed * speed
    local tK, bayK = t + KELVIN, bay + KELVIN
    local radiated = c.radiation * (tK ^ 4 - bayK ^ 4)
    local heatIn = link * (s.egt - t)
    local heatOut = air * (t - bay) + radiated
    s.turbineHousing = t + (heatIn - heatOut) / (c.mass * c.specificHeat) * dt
  end

  -- compressorOut: isentropic estimate, absolute temperature. Vacuum doesn't cool the charge.
  local t2 = ambient
  if hasTurbo then
    c = cfg.compressor
    local pr = math.max((c.baroKpa + (ev.boost or 0) * c.kpaPerPsi) / c.baroKpa, 1)
    t2 = (ambient + KELVIN) * (1 + (pr ^ c.exponent - 1) / c.efficiency) - KELVIN
    s.compressorOut = t2
    -- compressorHousing: aluminum volute thermal mass (~2.5 kg).
    -- Builds heat slowly from charge air, conduction from CHRA/turbine, and engine bay air.
    s.compressorHousing = s.compressorHousing or ambient
    local compMass = 2.5
    local compSpecificHeat = 900
    local compC = compMass * compSpecificHeat
    local boostFlow = math.max(ev.boost or 0, 0) / (cfg.intercooler and cfg.intercooler.boostRefPsi or 12.5)
    local qAir = (15.0 + 35.0 * clamp01(boostFlow)) * (t2 - s.compressorHousing)
    local qConduction = 8.0 * ((s.turbineHousing or ambient) - s.compressorHousing)
    local qCooling = (16.0 + 1.6 * (speed or 0)) * (s.compressorHousing - (s.engineBayAir or ambient))
    s.compressorHousing = s.compressorHousing + (qAir + qConduction - qCooling) / compC * dt
  else
    s.compressorOut = nil
    s.compressorHousing = nil
  end

  -- superchargerHousing: aluminum blower casting (~6.0 kg)
  if hasSupercharger then
    local scBoost = math.max(ev.boost or 0, 0)
    local prSC = math.max((101.325 + scBoost * 6.89476) / 101.325, 1)
    local scT2 = (ambient + KELVIN) * (1 + (prSC ^ 0.286 - 1) / 0.65) - KELVIN
    s.superchargerOut = scT2
    s.superchargerHousing = s.superchargerHousing or ambient
    local scC = 6.0 * 900
    local qSCInternal = (14.0 + 35.0 * clamp01(powerFrac)) * (scT2 - s.superchargerHousing) + 20.0 * powerFrac
    local qSCConduction = 12.0 * ((s.cylinderHead or ambient) - s.superchargerHousing)
    local qSCCooling = (16.0 + 1.8 * (speed or 0)) * (s.superchargerHousing - (s.engineBayAir or ambient))
    s.superchargerHousing = s.superchargerHousing + (qSCInternal + qSCConduction - qSCCooling) / scC * dt
    if not hasTurbo then
      t2 = scT2
    end
  else
    s.superchargerOut = nil
    s.superchargerHousing = nil
  end

  -- icCore and iat; forced induction with intercooler
  if hasTurbo or hasSupercharger then
    c = cfg.intercooler
    local coreCooling = c.eStandstill + (c.eAtRefSpeed - c.eStandstill) * clamp01(speed / c.refSpeed)
    local core = s.icCore or ambient
    local boostFlow = math.max(ev.boost or 0, 0) / c.boostRefPsi
    local coreIn = c.gCharge * boostFlow * (t2 - core) + c.gBay * (bay - core)
    local coreOut = c.gAirAtRefSpeed * coreCooling / c.eAtRefSpeed * (core - ambient)
    s.icCore = core + (coreIn - coreOut) / (c.mass * c.specificHeat) * dt

    local chargeEff = c.epsIdle + (c.epsFull - c.epsIdle) * clamp01(boostFlow)
    s.iat = t2 - chargeEff * (t2 - s.icCore)
  else
    s.icCore = nil
    s.iat = ambient
  end

  -- manifoldHousing: ~3.5kg aluminum intake manifold casting bolted directly to cylinder head
  s.manifoldHousing = s.manifoldHousing or ambient
  local manifoldC = 3.5 * 900
  local headT = s.cylinderHead or (th and th.coolantTemperature) or ambient
  local qManHead = 16.0 * (headT - s.manifoldHousing) -- strong metal conduction from cylinder head
  local qManBay = (10.0 + 1.4 * (speed or 0)) * (s.manifoldHousing - (s.engineBayAir or ambient)) -- engine bay air convection
  local qManAir = (6.0 + 16.0 * clamp01(throttle)) * (s.iat - s.manifoldHousing) -- internal airflow heat exchange
  s.manifoldHousing = s.manifoldHousing + (qManHead - qManBay + qManAir) / manifoldC * dt

  -- gearboxOil: gear losses, plus converter slip (pump power minus turbine power) when there is a converter
  if gearboxDevice then
    local d = gearboxDevice
    local heat = (1 - gearboxEfficiency) * math.abs((d.outputTorque1 or 0) * (d.outputAV1 or 0))
    if converterDevice then
      local tc = converterDevice
      heat = heat + math.abs((tc.torqueDiff or 0) * (tc.inputAV or 0) - (tc.outputTorque1 or 0) * (tc.outputAV1 or 0))
    end
    s.gearboxOil = stepOil(s.gearboxOil, heat, cfg.gearboxOil, bay, ambient, speed, dt)

    -- Step F: gearbox overheating damage
    local gd = cfg.drivetrainDamage and cfg.drivetrainDamage.gearbox
    if gd and s.gearboxOil then
      -- Gears and bearings only wear from degraded oil when rotating
      local gbRotating = (math.abs(d.inputAV or 0) > 5.0) or (math.abs(d.outputAV1 or 0) > 0.5)
      if gbRotating then
        local heatFactor = clampTo((s.gearboxOil - gd.startTemp) / (gd.fullRateTemp - gd.startTemp), 0, 1)
        local rate = heatFactor / gd.perSecondDivisor
        s.gearboxDamage = clamp01((s.gearboxDamage or 0) + rate * dt)
      end

      -- catastrophic seizure at 100% destruction
      if s.gearboxDamage >= 1.0 and not gearboxBroken then
        gearboxBroken = true
        seizedGearIndex = d.gearIndex or 1
        applyDrivetrainLock(dt, engine)
        if type(damageTracker) == "table" and type(damageTracker.setDamage) == "function" then
          pcall(damageTracker.setDamage, "powertrain", d.name, true)
        end
        if type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
          pcall(guihooks.messageForSeatedPlayers, {txt = "Transmission seized: gear cluster welded from extreme heat! Engine stalled, wheels locked!", context = {}}, 6, "vehicle.damage.gearbox")
        end
        out("gearbox: seized solid and destroyed from 100% heat damage")
      end

      if gearboxBroken then
        applyDrivetrainLock(dt, engine)
        if seizedGearIndex and type(controller) == "table" and type(controller.getController) == "function" then
          local vc = controller.getController("vehicleController")
          if vc and vc.shiftToGearIndex and d.gearIndex ~= seizedGearIndex then
            pcall(vc.shiftToGearIndex, vc, seizedGearIndex)
          end
        end
        if d.gearIndex and d.gearIndex ~= 0 and engine then
          if engine.isStalled ~= nil then engine.isStalled = true end
          if type(engine.cutIgnition) == "function" then engine:cutIgnition(0.5) end
        end
      else
        local targetFriction = 1 + (gd.maxFrictionCoef - 1) * s.gearboxDamage
        -- torque stutter under load when damaged
        if s.gearboxDamage > 0.25 and (engine.engineLoad or 0) > 0.35 then
          local simTime = type(obj.getSimulationTime) == "function" and obj:getSimulationTime() or 0
          local stutter = 1 + 0.35 * s.gearboxDamage * math.sin(simTime * 35)
          targetFriction = targetFriction * stutter
        end
        if d.damageFrictionCoef then d.damageFrictionCoef = targetFriction end
        if d.damageLockTorqueCoef then d.damageLockTorqueCoef = math.max(0.2, 1 - 0.8 * s.gearboxDamage) end

        -- synchro wear on manual gearboxes
        if d.synchroWear and d.gearIndex and d.gearIndex > 0 and s.gearboxDamage > 0.1 then
          local g = d.gearIndex
          if d.synchroWear[g] then
            d.synchroWear[g] = clamp01(d.synchroWear[g] + s.gearboxDamage * (gd.synchroWearRate or 0.005) * dt)
          end
        end

        -- gear pop-out into neutral under heavy load
        if s.gearboxDamage > 0.40 and d.gearIndex and d.gearIndex ~= 0 and (engine.engineLoad or 0) > 0.5 then
          gearPopTimer = gearPopTimer - dt
          if gearPopTimer <= 0 then
            gearPopTimer = 1.0
            local popChance = clamp01((s.gearboxDamage - 0.40) / 0.60) * 0.12
            if math.random() < popChance then
              if d.setGearIndex then
                d:setGearIndex(0)
              elseif type(controller) == "table" and type(controller.getController) == "function" then
                local vc = controller.getController("vehicleController")
                if vc and vc.shiftToGearIndex then vc:shiftToGearIndex(0) end
              end
              guihooks.messageForSeatedPlayers({txt = "Transmission pop-out: gear kicked into neutral from heat damage!", context = {}}, 4, "vehicle.damage.gearbox")
              out("gearbox: popped out of gear into neutral from severe overheating")
            end
          end
        end
      end
    end
  end

  -- diffOil: one node per differential; the reported value is the hottest
  c = cfg.diffOil
  local hottest = nil
  for _, d in ipairs(diffDevices) do
    local power = (d.outputTorque1 or 0) * (d.outputAV1 or 0) + (d.outputTorque2 or 0) * (d.outputAV2 or 0)
    local t = stepOil(s.diffOilByDevice[d.name], (1 - c.efficiency) * math.abs(power), c, bay, ambient, speed, dt)
    s.diffOilByDevice[d.name] = t
    if not hottest or t > hottest then hottest = t end
  end
  s.diffOil = hottest

  -- Step F: differential overheating damage (driven by the hottest differential)
  local dd = cfg.drivetrainDamage and cfg.drivetrainDamage.differential
  if dd and s.diffOil and #diffDevices > 0 then
    -- Differential only wears from degraded oil when gears/axles are rotating
    local diffRotating = false
    for _, d in ipairs(diffDevices) do
      if math.abs(d.outputAV1 or 0) > 0.5 or math.abs(d.outputAV2 or 0) > 0.5 then
        diffRotating = true
        break
      end
    end

    if diffRotating then
      local heatFactor = clampTo((s.diffOil - dd.startTemp) / (dd.fullRateTemp - dd.startTemp), 0, 1)
      local rate = heatFactor / dd.perSecondDivisor
      s.diffDamage = clamp01((s.diffDamage or 0) + rate * dt)
    end

    -- catastrophic pinion seizure at 100% destruction
    if s.diffDamage >= 1.0 and not diffBroken then
      diffBroken = true
      setDiffSpoolLock(false)
      applyDrivetrainLock(dt, engine)
      for _, diffDev in ipairs(diffDevices) do
        if diffDev.damageFrictionCoef then diffDev.damageFrictionCoef = 1.0 end
        if type(damageTracker) == "table" and type(damageTracker.setDamage) == "function" then
          pcall(damageTracker.setDamage, "powertrain", diffDev.name, true)
        end
      end
      if type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
        pcall(guihooks.messageForSeatedPlayers, {txt = "Differential seized: pinion bearing welded, drive wheels locked!", context = {}}, 6, "vehicle.damage.diff")
      end
      out("differential: seized solid and broke from 100% heat damage")
    end

    if diffBroken then
      applyDrivetrainLock(dt, engine)
      for _, diffDev in ipairs(diffDevices) do
        if diffDev.damageFrictionCoef then diffDev.damageFrictionCoef = 1.0 end
      end
    else
      if s.diffDamage >= 0.50 then
        setDiffSpoolLock(true)
      else
        setDiffSpoolLock(false)
      end

      local targetFriction = 1 + (dd.maxFrictionCoef - 1) * s.diffDamage
      local simTime = type(obj.getSimulationTime) == "function" and obj:getSimulationTime() or 0

      for _, diffDev in ipairs(diffDevices) do
        local fCoef = targetFriction
        -- cornering binding / chatter: when turning with wheel speed differential
        if s.diffDamage > 0.35 then
          local avDiff = math.abs((diffDev.outputAV1 or 0) - (diffDev.outputAV2 or 0))
          if avDiff > 1.5 then
            local chatter = 1 + 0.6 * s.diffDamage * math.abs(math.sin(simTime * 22))
            fCoef = fCoef * chatter
          end
        end
        if diffDev.damageFrictionCoef then diffDev.damageFrictionCoef = fCoef end
      end
    end
  end

  -- Tire thermodynamics: simulated per wheel (any wheel count)
  updateTires(s, dt, ambient, speed)

  -- combustion and friction energy per update from vanilla, read the way vanilla's own integrator uses it
  local etd = th.debugData and th.debugData.engineThermalData or {}
  if running then probeThermalData(etd) end

  -- cylinderHead: no coolant loop, or no wall temperature to conduct from, means no head node
  if th.coolantTemperature and type(th.cylinderWallTemperature) == "number" then
    c = cfg.cylinderHead
    local t = s.cylinderHead or th.coolantTemperature
    local conducted = c.gWall * (th.cylinderWallTemperature - t) + c.gCoolant * (th.coolantTemperature - t)
    s.cylinderHead = t + (c.combustionFraction * (etd.energyToCylinderWall or 0) + conducted * dt) / (c.mass * c.specificHeat)
  else
    s.cylinderHead = nil
  end

  -- Oil warmup pacing: Oil has higher thermal mass in sump and warms up realistically slower than coolant
  local curOil = th.oilTemperature
  if curOil and lastSimulatedOil then
    if running and curOil < 80 and curOil > lastSimulatedOil then
      local warmupRate = (cfg.coldEngine and cfg.coldEngine.oilWarmupRate) or 0.55
      local dOil = curOil - lastSimulatedOil
      th.oilTemperature = lastSimulatedOil + dOil * warmupRate
      curOil = th.oilTemperature
    end
  end
  lastSimulatedOil = curOil

  -- rodBearings: friction energy already follows rpm; lost lubrication multiplies it
  c = cfg.rodBearings
  local starve = c.starvationGain * (1 - (etd.oilLubricationCoef or 1))
  local bearingHeat = c.frictionFraction * (etd.energyToOil or 0) * (engine.engineLoad or 0) * (1 + starve)
  local rod = s.rodBearings
  s.rodBearings = rod + (bearingHeat + c.gOil * (th.oilTemperature - rod) * dt) / (c.mass * c.specificHeat)

  -- catalyst: follows egt through exhaust flow, gone once the engine stops. Unburnt-fuel heating is not modelled.
  if s.catalyst then
    c = cfg.catalyst
    local cat = s.catalyst
    local link = running and (c.linkBase + c.linkPerPower * powerFrac) or 0
    local air = c.gAirBase + c.gAirPerSpeed * speed
    s.catalyst = cat + (link * (s.egt - cat) - air * (cat - ambient)) / (c.mass * c.specificHeat) * dt

    local cd = cfg.catalystDamage
    if cd then
      local heatFactor = clampTo((s.catalyst - cd.startTemp) / (cd.fullRateTemp - cd.startTemp), 0, cd.maxFactor or 1)
      s.dCatHeat = heatFactor / cd.perSecondDivisor

      local contamCount = 0
      if cd.contamination and cd.contamination.enabled and running then
        if th.pistonRingsDamaged then contamCount = contamCount + 1 end
        if th.headGasketBlown then contamCount = contamCount + 1 end
      end
      s.dCatContam = (cd.contamination and cd.contamination.perSecondDivisor) and (contamCount / cd.contamination.perSecondDivisor) or 0

      s.catalystDamage = clamp01((s.catalystDamage or 0) + (s.dCatHeat + s.dCatContam) * dt)
    end
  else
    s.catalystDamage, s.dCatHeat, s.dCatContam = nil, nil, nil
  end

  -- Cold Engine Abuse: Revving hard or high load while oil is cold (< 65C)
  local tOil = th.oilTemperature or ambient
  local safeOil = (cfg.coldEngine and cfg.coldEngine.safeOilTemp) or 65
  local isDiesel = isDieselEngine(engine)
  local safeRpm = getSafeRpm(engine)
  local maxRpm = cfg.rpmMax or (type(engine.maxRPM) == "number" and engine.maxRPM > 0 and engine.maxRPM) or (isDiesel and 4600 or 7000)

  if running and tOil < safeOil then
    local coldFactor = clamp01((safeOil - tOil) / math.max(safeOil - ambient, 15))
    local highLoadRpm = math.floor(safeRpm * 0.74)
    if rpm > safeRpm or (throttle > 0.60 and rpm > highLoadRpm) then
      local rpmExcess = clamp01((rpm - safeRpm) / math.max(maxRpm - safeRpm, 1000))
      local loadExcess = clamp01(math.max(throttle, engine.engineLoad or 0))

      -- Cold abuse stress (0.0 to 1.0)
      local coldStress = coldFactor * (rpmExcess ^ 1.2) * (0.35 + 0.65 * loadExcess)
      if coldStress > 0.01 then
        local workRate = math.max((engine.lastOutputTorque or 0) * (rpm * 0.10472), 35000)
        local abuseJoules = workRate * coldStress * dt

        -- 1. Connecting Rod Bearings (Primary: ~70% cold abuse damage -> rod knock / spun bearing)
        if thresholds.rod then
          local rodAdd = abuseJoules * 1.4
          th.oilOverheatDamage = math.min((th.oilOverheatDamage or 0) + rodAdd, thresholds.rod)
          if th.oilOverheatDamage >= thresholds.rod and not th.connectingRodBearingsDamaged then
            th.connectingRodBearingsDamaged = true
            if damageTracker and type(damageTracker.setDamage) == "function" then
              damageTracker.setDamage("engine", "rodBearingsDamaged", true)
            end
            if guihooks and type(guihooks.message) == "function" then
              guihooks.message({txt = "vehicle.damage.rodBearings", context = {}}, 5, "damage")
            end
          end
        end

        -- 2. Piston Rings & Cylinder Wall (Secondary: ~30% cold abuse damage -> bore scoring & smoke)
        if thresholds.ring then
          local ringAdd = abuseJoules * 0.6
          th.cylinderWallOverheatDamage = math.min((th.cylinderWallOverheatDamage or 0) + ringAdd, thresholds.ring)
          if th.cylinderWallOverheatDamage >= thresholds.ring and not th.pistonRingsDamaged then
            th.pistonRingsDamaged = true
            if damageTracker and type(damageTracker.setDamage) == "function" then
              damageTracker.setDamage("engine", "pistonRingsDamaged", true)
            end
            if guihooks and type(guihooks.message) == "function" then
              guihooks.message({txt = "vehicle.damage.pistonRings", context = {}}, 5, "damage")
            end
          end
        end

        -- 3. Turbocharger bearing wear under cold oil
        if hasTurbo and s.turboOurDamage ~= nil then
          s.turboOurDamage = math.min(s.turboOurDamage + coldStress * 0.025 * dt, 1.0)
        end
      end
    end
  end

  -- vanilla damage: read only. Each accumulator has its own trigger in vanilla: wall temperature for the piston
  -- rings, block temperature for the head gasket, oil temperature for the rod bearings.
  s.block = type(th.engineBlockTemperature) == "number" and th.engineBlockTemperature or nil
  s.wall = type(th.cylinderWallTemperature) == "number" and th.cylinderWallTemperature or nil
  s.wallWarn = thresholds.wall - cfg.damage.wallWarnMargin
  s.wallCritical = thresholds.wall
  s.blockWarn = thresholds.block - cfg.damage.blockWarnMargin
  s.blockCritical = thresholds.block
  s.ringDamage = damagePercent(th.cylinderWallOverheatDamage, thresholds.ring)
  s.gasketDamage = damagePercent(th.engineBlockOverheatDamage, thresholds.gasket)
  s.rodDamage = damagePercent(th.oilOverheatDamage, thresholds.rod)

  -- turbo damage 0-1. A tracking model only: nothing is written back to the game, so it changes no boost and no vanilla
  -- damage. Three sources, each a per-second rate from heatsoak_config.json (turboDamage).
  if hasTurbo then
    local d = cfg.turboDamage
    local turbine = s.turbineHousing

    -- 1. heat under boost: the housing above heat.warn, scaled by how much of the turbo's boost range is in use
    local boostMax = ev.turboBoostMax
    local boostFrac = (type(boostMax) == "number" and boostMax > 0) and clamp01((ev.turboBoost or 0) / boostMax) or 0
    -- switched off by default (heat.enabled): vanilla already damages the turbo from heat through its own integrity,
    -- which turboDamage combines below, so counting heat here as well would count it twice
    if d.heat.enabled then
      local heatFactor = clampTo((turbine - d.heat.warn) / (d.heat.crit - d.heat.warn), 0, d.heat.maxFactor)
      s.dHeat = heatFactor * boostFrac / d.heat.perSecondDivisor
    else
      s.dHeat = 0
    end

    -- 2. hot shutdown: the engine has stopped (sanitized rpm is 0) while the housing is still hot
    local cokeFactor = (rpm == 0) and clampTo((turbine - d.coking.temperature) / d.coking.range, 0, d.coking.maxFactor) or 0
    s.dCoke = cokeFactor / d.coking.perSecondDivisor

    -- 3. oil: hot oil, plus any loss of lubrication
    -- lubrication dips shorter than oil.lubricationHoldSeconds are ignored: the value used is the highest one seen in that
    -- trailing window, so a dip only counts once it has lasted the whole window (a sliding-window maximum). The window
    -- starts out holding 1, so a dip right after spawn is held back the same way.
    local rawLubrication = type(etd.oilLubricationCoef) == "number" and clamp01(etd.oilLubricationCoef) or 1
    local hold = d.oil.lubricationHoldSeconds or 0
    local lubrication = rawLubrication
    if hold > 0 then
      local w = lubWindow
      if not w then
        w = {times = {0}, values = {1}, head = 1, tail = 1, clock = 0}
        lubWindow = w
      end
      w.clock = w.clock + dt
      -- values at or below the new one can never be the maximum again
      while w.tail >= w.head and w.values[w.tail] <= rawLubrication do
        w.values[w.tail], w.times[w.tail] = nil, nil
        w.tail = w.tail - 1
      end
      w.tail = w.tail + 1
      w.values[w.tail], w.times[w.tail] = rawLubrication, w.clock
      while w.head < w.tail and w.times[w.head] < w.clock - hold do
        w.values[w.head], w.times[w.head] = nil, nil
        w.head = w.head + 1
      end
      lubrication = w.values[w.head]
    end
    s.oilLubricationUsed = lubrication
    local oilTemperature = type(th.oilTemperature) == "number" and th.oilTemperature or 0
    local oilFactor = clampTo((oilTemperature - d.oil.warn) / d.oil.range, 0, d.oil.maxFactor)
    s.dOil = oilFactor / d.oil.perSecondDivisor + (1 - lubrication) / d.oil.lubricationDivisor

    s.turboOurDamage = clamp01((s.turboOurDamage or 0) + (s.dHeat + s.dCoke + s.dOil) * dt)

    -- combined with vanilla's turbo integrity as independent hazards: undamaged only if both are. Without a readable
    -- integrity only our own damage counts.
    local integrity, friction, exhaust = turboCondition(engine)
    s.turboIntegrity, s.turboFrictionCoef, s.turboExhaustPowerCoef = integrity, friction, exhaust
    -- Vanilla integrity only ever falls, except when the part is repaired or reset. A rise without a reset is a repair:
    -- our own damage and the boost cut start over too (a reset does the same through onReset).
    if integrity and s.turboPrevIntegrity and integrity > s.turboPrevIntegrity + cfg.turboBoostCut.repairIntegrityRise then
      out(string.format("turbo repaired (integrity %.3f -> %.3f): own damage and boost cut cleared", s.turboPrevIntegrity, integrity))
      s.turboOurDamage = 0
      lubWindow = nil
      s.turboRepaired = true
    end
    s.turboPrevIntegrity = integrity
    s.turboDamage = clamp01(1 - (1 - s.turboOurDamage) * clamp01(integrity or 1))
    -- vanilla's turbo heat input (turbocharger.lua:200)
    s.turboTemp = (th.exhaustTemperature or 0) + (th.coolantTemperature or 0) + (th.oilTemperature or 0)
  else
    s.turboDamage, s.turboOurDamage, s.dHeat, s.dCoke, s.dOil = nil, nil, nil, nil, nil
    s.turboIntegrity, s.turboFrictionCoef, s.turboExhaustPowerCoef, s.turboTemp = nil, nil, nil, nil
    s.turboPrevIntegrity = nil
  end
end

local function sendToUI(dt, engine)
  uiTimer = uiTimer + dt
  if uiTimer < 1 / cfg.ui.updateHz then return end
  uiTimer = 0
  if not playerInfo.firstPlayerSeated then return end

  local s = M.state

  local tireList = {}
  local tireSummaryParts = {}
  if s.tireData then
    for name, t in pairs(s.tireData) do
      local comp = (cfg.tires and cfg.tires.compounds and cfg.tires.compounds[t.compound]) or {}
      local trd = t.treadT or 20
      local sLat = math.abs(t.sLat or 0)
      local innerT = trd + 2.5 + math.min(sLat * 0.4, 4.0)
      local midT = trd
      local outerT = trd - 1.5 + math.min(sLat * 1.2, 8.0)

      table.insert(tireList, {
        name = name,
        compound = t.compound or "standard",
        compoundName = comp.name or "Standard",
        treadT = t.treadT,
        carcassT = t.carcassT,
        airT = t.airT,
        innerT = innerT,
        midT = midT,
        outerT = outerT,
        pressurePsi = t.pressurePsi,
        coldPsi = t.coldPsi or 30.0,
        brakeTemp = t.brakeCore or 20.0,
        wearPercent = t.wearPercent or 0,
        gripPercent = math.floor((t.gripMult or 1.0) * 100 + 0.5),
        blown = not not t.blown
      })
      table.insert(tireSummaryParts, string.format("%s[%s]:trd=%.1fC,car=%.1fC,air=%.1fC,psi=%.1f,grp=%.0f%%,wear=%.1f%%,vAvg=%.1fC,vCore=%.1fC,slipE=%.0f,slipP=%.0f",
        name, t.compound or "std", t.treadT or 0, t.carcassT or 0, t.airT or 0, t.pressurePsi or 0, (t.gripMult or 1.0) * 100, t.wearPercent or 0, t.vanillaAvg or 0, t.vanillaCore or 0, t.slipEnergy or 0, t.slipPowerEst or 0
      ))
    end
    table.sort(tireList, function(a, b) return tostring(a.name) < tostring(b.name) end)
    table.sort(tireSummaryParts)
  end
  local tireSummary = table.concat(tireSummaryParts, " | ")
  local amb = ambientOverrideC or (obj and type(obj.getEnvTemperature) == "function" and (obj:getEnvTemperature() - KELVIN)) or 20
  local roadTemp = amb + (amb > 25 and (amb - 20) * 0.40 or 0)

  local hasTurboDev = type(engine.turbocharger) == "table" and engine.turbocharger.isExisting
  local hasSuperchargerDev = type(engine.supercharger) == "table" and engine.supercharger.isExisting

  local isDiesel = isDieselEngine(engine)
  local safeRpm = getSafeRpm(engine)

  guihooks.trigger("HeatSoakData", {
    safeRevLimit = safeRevLimitEnabled,
    isWarm = ((th and th.oilTemperature or 20) >= 65),
    isDiesel = isDiesel,
    safeRpm = safeRpm,
    ambient = amb,
    surface = roadTemp,
    coolant = engine.thermals.coolantTemperature,
    oil = engine.thermals.oilTemperature,
    egt = s.egt,
    turbineHousing = s.turbineHousing,
    compressorOut = s.compressorOut,
    compressorHousing = s.compressorHousing,
    superchargerHousing = s.superchargerHousing,
    superchargerOut = s.superchargerOut,
    manifoldHousing = s.manifoldHousing,
    hasTurbo = hasTurboDev,
    hasSupercharger = hasSuperchargerDev,
    iat = s.iat,
    icCore = s.icCore,
    engineBayAir = s.engineBayAir,
    gearboxOil = s.gearboxOil,
    diffOil = s.diffOil,
    cylinderHead = s.cylinderHead,
    rodBearings = s.rodBearings,
    catalyst = s.catalyst,
    wall = s.wall,
    block = (th and th.engineBlockTemperature) or s.block,
    ringDamage = positiveOrNil(s.ringDamage),
    gasketDamage = positiveOrNil(s.gasketDamage),
    rodDamage = positiveOrNil(s.rodDamage),
    turboDamage = positiveOrNil(s.turboDamage and s.turboDamage * 100),
    boostCut = positiveOrNil(s.turboLoss and s.turboLoss * 100),
    catalystDamage = positiveOrNil(s.catalystDamage and s.catalystDamage * 100),
    gearboxDamage = positiveOrNil(s.gearboxDamage and s.gearboxDamage * 100),
    diffDamage = positiveOrNil(s.diffDamage and s.diffDamage * 100),
    ambient60 = (ambientOverrideC == 60),
    limits = {
      wall = {warn = s.wallWarn, critical = s.wallCritical},
      block = {warn = s.blockWarn, critical = s.blockCritical}
    },
    ui = cfg.ui,
    tires = tireList
  })

  if obj and type(obj.queueGameEngineLua) == "function" then
    local ev = electrics.values or {}
    local throttle = ev.throttle or 0
    local speed = ev.airspeed or 0
    local rpm = sanitizeRpm(ev.rpm, engine)
    local th = engine and engine.thermals
    local geCmd = string.format(
      "if not heatsoak then extensions.load('heatsoak') end; if heatsoak and heatsoak.onVehicleData then heatsoak.onVehicleData({throttle=%.3f, speed=%.2f, rpm=%.0f, coolant=%.1f, oil=%.1f, wall=%.1f, block=%.1f, cylinderHead=%.1f, rodBearings=%.1f, egt=%.0f, catalyst=%.0f, turbineHousing=%.0f, compressorOut=%.0f, iat=%.0f, icCore=%.0f, engineBayAir=%.0f, gearboxOil=%.0f, diffOil=%.0f, ringDamage=%.4f, gasketDamage=%.4f, rodDamage=%.4f, turboDamage=%.4f, catalystDamage=%.4f, gearboxDamage=%.4f, diffDamage=%.4f, rodDamaged=%s, gasketDamaged=%s, ringDamaged=%s, engineBroken=%s, turboBroken=%s, gearboxBroken=%s, diffBroken=%s, tires=[[%s]]}) end",
      throttle, speed, rpm,
      (th and th.coolantTemperature) or 0,
      (th and th.oilTemperature) or 0,
      s.wall or 0, s.block or 0, s.cylinderHead or 0, s.rodBearings or 0,
      s.egt or 0, s.catalyst or 0, s.turbineHousing or 0, s.compressorOut or 0,
      s.iat or 0, s.icCore or 0, s.engineBayAir or 0, s.gearboxOil or 0, s.diffOil or 0,
      s.ringDamage or 0, s.gasketDamage or 0, s.rodDamage or 0,
      s.turboDamage or 0, s.catalystDamage or 0, s.gearboxDamage or 0, s.diffDamage or 0,
      tostring(th and th.connectingRodBearingsDamaged == true),
      tostring(th and th.headGasketBlown == true),
      tostring(th and th.pistonRingsDamaged == true),
      tostring(engine and engine.isStalled == true and not engine.starterEngaged),
      tostring(engine and engine.turbocharger and engine.turbocharger.isBroken == true),
      tostring(gearboxBroken == true),
      tostring(diffBroken == true),
      tireSummary
    )
    obj:queueGameEngineLua(geCmd)
  end
end

-- ===== manual turbo boost test and automatic boost cut =====
-- The only places this mod writes to the game, and both only ever call the turbo's setWastegateOffset: the manual
-- heatsoak.testTurbo from the console, and the automatic boost cut from turboDamage (further below).
local turboTest = {active = false}
M.state.turboTest = turboTest

-- state of the automatic cut. All amounts are psi taken off the wastegate offset; 0 means "at baseline".
--   ref      highest turboBoost seen since spawn/reset
--   want     loss fraction the damage asks for (0-1)
--   smooth   low-passed want * ref
--   applied  the cut last written to the game
--   dirty    true while the game's offset is not known to be at baseline because of us
local boostCut = {}
local function resetBoostCutState()
  boostCut.ref, boostCut.want, boostCut.smooth, boostCut.applied = 0, 0, 0, 0
  boostCut.baseline, boostCut.baselineTimer = nil, 0
  boostCut.startLogged, boostCut.halfLogged, boostCut.pausedNoted, boostCut.failed = false, false, false, false
  boostCut.settle = math.huge                                        -- seconds since the applied cut last changed
end
resetBoostCutState()
boostCut.dirty = false
M.state.boostCut = boostCut
local TURBO_TEST_SNAPSHOT_TIMES = {2, 5}

local function turboSnapshot(engine)
  local ev = electrics.values
  local turbo = engine.turbocharger
  local integrity, condition
  if type(turbo.getPartCondition) == "function" then
    local ok, i, st = pcall(turbo.getPartCondition)
    if ok then integrity, condition = i, st end
  end
  return {
    boost = ev.boost,
    torque = engine.lastOutputTorque,
    forcedInductionCoef = engine.forcedInductionCoef,
    throttle = ev.throttle,
    rpm = engine.outputRPM,
    gear = ev.gearIndex,
    turboRpm = type(turbo.turboAV) == "number" and turbo.turboAV * 9.5492965855 or nil,
    integrity = integrity,
    frictionCoef = type(condition) == "table" and condition.damageFrictionCoef or nil,
    exhaustPowerCoef = type(condition) == "table" and condition.damageExhaustPowerCoef or nil
  }
end

local function logTurboSnapshot(label, snap)
  out(string.format("turbo test %s: boost=%s psi torque=%s Nm forcedInductionCoef=%s throttle=%s rpm=%s gear=%s turboRpm=%s integrity=%s frictionCoef=%s exhaustPowerCoef=%s",
    label, f(snap.boost, "%.1f"), f(snap.torque, "%.0f"), f(snap.forcedInductionCoef, "%.4f"), f(snap.throttle, "%.2f"),
    f(snap.rpm, "%.0f"), tostring(snap.gear), f(snap.turboRpm, "%.0f"), f(snap.integrity, "%.2f"),
    f(snap.frictionCoef, "%.2f"), f(snap.exhaustPowerCoef, "%.2f")))
end

-- Vanilla's only caller of setWastegateOffset is the driveModes controller (driveModes.lua:42-49), and the offset is a
-- file-local of the turbo module, so it can't be read back. The normal value is therefore the active drive mode's
-- turbocharger setting, or 0 when the car has no drive modes (the turbo module starts at 0).
local function baselineWastegateOffset(engine)
  local ctrl = nil
  if type(controller) == "table" then
    if type(controller.getControllersByType) == "function" then
      local list = controller.getControllersByType("driveModes")
      ctrl = type(list) == "table" and list[1] or nil
    end
    if not ctrl and type(controller.getController) == "function" then
      ctrl = controller.getController("driveModes")
    end
  end
  if type(ctrl) ~= "table" or type(ctrl.getCurrentDriveModeKey) ~= "function" or type(ctrl.getDriveModeData) ~= "function" then
    return 0, "no drive modes"
  end
  local key = ctrl.getCurrentDriveModeKey()
  local mode = key and ctrl.getDriveModeData(key) or nil
  if type(mode) == "table" and type(mode.settings) == "table" then
    for _, setting in pairs(mode.settings) do
      if type(setting) == "table" and setting.type == "turbocharger" and setting.name == engine.name and type(setting.wastegateOffset) == "number" then
        return setting.wastegateOffset, "drive mode '" .. tostring(key) .. "'"
      end
    end
  end
  return 0, "drive mode '" .. tostring(key) .. "' sets no turbocharger offset"
end

-- factor: 1 = normal, 0.5 = half boost, 0 = none. refPsi is optional: the boost the factor is relative to.
function M.testTurbo(factor, refPsi)
  local engine = getEngine()
  local turbo = engine and engine.turbocharger
  if type(turbo) ~= "table" or not turbo.isExisting or type(turbo.setWastegateOffset) ~= "function" then
    out("testTurbo: no turbocharger on this vehicle (superchargers are not supported)")
    return false
  end
  if type(factor) ~= "number" or factor ~= factor then
    out("testTurbo: usage heatsoak.testTurbo(factor [, referencePsi]), factor 1 = normal, 0.5 = half boost, 0 = none")
    return false
  end
  factor = math.max(math.min(factor, 1), 0)

  local baseline, baselineSource = baselineWastegateOffset(engine)
  local offset, reference, referenceSource = baseline, nil, nil
  if factor < 1 then
    -- the turbo module's target boost isn't readable, so the reduction is relative to boost actually seen
    if type(refPsi) == "number" and refPsi > 0 then
      reference, referenceSource = refPsi, "argument"
    elseif (electrics.values.boost or 0) > 1 then
      reference, referenceSource = electrics.values.boost, "live boost"
    elseif (turboTest.peakBoost or 0) > 1 then
      reference, referenceSource = turboTest.peakBoost, "peak boost seen since load"
    else
      out("testTurbo: no boost reference. Call it under boost, after a pull, or pass the boost in psi: heatsoak.testTurbo(0.5, 12)")
      return false
    end
    offset = baseline - (1 - factor) * reference
  end

  local before = turboSnapshot(engine)
  logTurboSnapshot("before", before)
  local ok, err = pcall(turbo.setWastegateOffset, offset)
  if not ok then
    out("testTurbo: setWastegateOffset failed: " .. tostring(err))
    return false
  end

  -- the test now owns the offset: the automatic cut is paused while it is active, and starts again from baseline after testTurbo(1)
  boostCut.applied = 0
  boostCut.settle = 0
  boostCut.dirty = factor < 1
  turboTest.active = factor < 1
  turboTest.factor = factor
  turboTest.offsetPsi = offset
  turboTest.baselinePsi = baseline
  turboTest.referencePsi = reference
  turboTest.before = before
  turboTest.after = {}
  turboTest.pending = {}
  for _, t in ipairs(TURBO_TEST_SNAPSHOT_TIMES) do turboTest.pending[#turboTest.pending + 1] = {at = t} end
  turboTest.elapsed = 0

  if factor < 1 then
    out(string.format("testTurbo: factor %.2f -> wastegate offset %.2f psi (baseline %.2f from %s, reference %.1f psi from %s). heatsoak.testTurbo(1) restores it",
      factor, offset, baseline, baselineSource, reference, referenceSource))
  else
    out(string.format("testTurbo: restored wastegate offset to %.2f psi (%s)", baseline, baselineSource))
  end
  return true
end

local function updateTurboTest(dt, engine)
  local ev = electrics.values
  if (ev.boost or 0) > (turboTest.peakBoost or 0) then turboTest.peakBoost = ev.boost end
  if not turboTest.pending or #turboTest.pending == 0 or not engine then return end
  turboTest.elapsed = turboTest.elapsed + dt
  local nextSnap = turboTest.pending[1]
  if turboTest.elapsed >= nextSnap.at then
    table.remove(turboTest.pending, 1)
    local snap = turboSnapshot(engine)
    turboTest.after[#turboTest.after + 1] = snap
    logTurboSnapshot(string.format("after +%gs", nextSnap.at), snap)
    if #turboTest.pending == 0 and turboTest.active then
      out("testTurbo: reduction is still applied. heatsoak.testTurbo(1) restores normal boost")
    end
  end
end

-- loss fraction for a combined turboDmg: piecewise linear through cfg.turboBoostCut.points ({damage, loss} pairs),
-- 0 below the first point and the last loss above the last point
local function lossFromDamage(damage)
  local points = cfg.turboBoostCut.points
  if damage <= points[1][1] then return points[1][2] end
  for i = 2, #points do
    local a, b = points[i - 1], points[i]
    if damage <= b[1] then return a[2] + (b[2] - a[2]) * (damage - a[1]) / (b[1] - a[1]) end
  end
  return points[#points][2]
end

local function writeWastegateOffset(engine, offset)
  local turbo = engine and engine.turbocharger
  if type(turbo) ~= "table" or type(turbo.setWastegateOffset) ~= "function" then return false, "no setWastegateOffset" end
  local ok, err = pcall(turbo.setWastegateOffset, offset)
  if not ok then return false, tostring(err) end
  boostCut.offset = offset
  return true
end

-- puts the wastegate offset back to the baseline if this mod (the cut or a test) may have moved it
local function restoreBaseline(engine, why)
  if not boostCut.dirty and not turboTest.active then return end
  local ok, baseline = pcall(baselineWastegateOffset, engine)
  if not ok or type(baseline) ~= "number" then baseline = 0 end
  local written, err = writeWastegateOffset(engine, baseline)
  if written then
    out(string.format("boost cut: wastegate offset restored to baseline %.2f psi (%s)", baseline, why))
  else
    out(string.format("boost cut: could not restore the wastegate offset (%s): %s", why, err))
  end
  boostCut.dirty = false
  turboTest.active = false
end

local function updateBoostCut(dt, engine)
  local s = M.state
  if s.turboDamage == nil then s.turboLoss, s.turboOffset, s.turboLossWanted, s.turboRefBoost = nil, nil, nil, nil return end
  if dt <= 0 or not nodesReady then return end
  local c = cfg.turboBoostCut
  local ev = electrics.values

  if s.turboRepaired then
    s.turboRepaired = nil
    restoreBaseline(engine, "turbo repaired")
    resetBoostCutState()
  end

  -- reference = the highest (live boost + the cut currently applied) seen: the boost the turbo reaches is already reduced by
  -- the cut, so adding it back tracks what the turbo could do uncut. The cut counted is the one in effect before this
  -- update's own write. While testTurbo has the offset the applied cut is 0, so a test only ever lowers the sum.
  -- The boost lags a change of the offset, and a sum taken in that gap overstates the uncut boost for good (the reference
  -- never falls), so the reference is only updated once the applied cut has stood still for referenceSettleSeconds.
  boostCut.settle = boostCut.settle + dt
  local boostNow = type(ev.turboBoost) == "number" and ev.turboBoost or ev.boost
  if type(boostNow) == "number" and boostNow == boostNow and boostCut.settle >= c.referenceSettleSeconds then
    local uncut = boostNow + boostCut.applied
    if uncut > boostCut.ref then boostCut.ref = uncut end
  end
  boostCut.want = lossFromDamage(s.turboDamage)
  boostCut.smooth = boostCut.smooth + (boostCut.want * boostCut.ref - boostCut.smooth) * (1 - math.exp(-dt / c.smoothSeconds))

  -- the drive mode can change the baseline at any time, and its own setWastegateOffset then replaces the cut
  boostCut.baselineTimer = boostCut.baselineTimer - dt
  local baselineChanged = false
  if boostCut.baseline == nil or boostCut.baselineTimer <= 0 then
    boostCut.baselineTimer = c.baselineCheckSeconds
    local ok, b = pcall(baselineWastegateOffset, engine)
    if ok and type(b) == "number" then
      baselineChanged = boostCut.baseline ~= nil and b ~= boostCut.baseline
      boostCut.baseline = b
    end
  end
  local baseline = boostCut.baseline or 0

  if turboTest.active then
    -- heatsoak.testTurbo owns the offset until testTurbo(1)
    if not boostCut.pausedNoted then
      boostCut.pausedNoted = true
      out("boost cut: paused while heatsoak.testTurbo is active (heatsoak.testTurbo(1) ends the test)")
    end
    s.turboOffset = turboTest.offsetPsi
    boostCut.smooth = 0                                              -- the cut starts again from baseline, smoothed, when the test ends
    boostCut.settle = 0
  else
    if boostCut.pausedNoted then
      boostCut.pausedNoted = false
      out("boost cut: resumed")
    end
    if not boostCut.failed then
      local applied = boostCut.applied
      local write = nil
      if boostCut.want == 0 and applied > 0 and boostCut.smooth < c.minStepPsi then
        write = 0                                                    -- cut gone: back to exactly baseline
      elseif math.abs(boostCut.smooth - applied) > c.minStepPsi then
        write = boostCut.smooth
      elseif baselineChanged and applied > 0 then
        write = applied
      end
      if write then
        local ok, err = writeWastegateOffset(engine, baseline - write)
        if ok then
          boostCut.applied = write
          boostCut.settle = 0
          boostCut.dirty = write > 0
        else
          boostCut.failed = true
          out("boost cut: setWastegateOffset failed, automatic cut stopped until the next reset: " .. tostring(err))
        end
      end
    end
    s.turboOffset = baseline - boostCut.applied
  end

  local fraction = boostCut.ref > 0 and clamp01(boostCut.applied / boostCut.ref) or 0
  s.turboLoss, s.turboLossWanted, s.turboRefBoost = fraction, boostCut.want, boostCut.ref
  if fraction > 0 and not boostCut.startLogged then
    boostCut.startLogged = true
    out(string.format("boost cut started: turboDmg=%.3f loss=%.1f%% cut=%.2f psi of reference %.1f psi, wastegate offset %.2f psi (baseline %.2f)",
      s.turboDamage, fraction * 100, boostCut.applied, boostCut.ref, s.turboOffset, baseline))
  end
  if fraction >= 0.5 and not boostCut.halfLogged then
    boostCut.halfLogged = true
    out(string.format("boost cut reached 50%%: turboDmg=%.3f loss=%.1f%% cut=%.2f psi of reference %.1f psi, wastegate offset %.2f psi (baseline %.2f)",
      s.turboDamage, fraction * 100, boostCut.applied, boostCut.ref, s.turboOffset, baseline))
  end
end

-- manual testing: sets our own damage so that the combined turboDmg equals x. Vanilla's integrity can't be changed from
-- here, so x below what vanilla damage alone gives ends up at that floor. setTurboDamage(0) clears our damage.
function M.setTurboDamage(x)
  local engine = getEngine()
  local s = M.state
  if not engine or type(engine.turbocharger) ~= "table" or not engine.turbocharger.isExisting then
    out("setTurboDamage: no turbocharger on this vehicle")
    return false
  end
  if type(x) ~= "number" or x ~= x or x < 0 or x > 1 then
    out("setTurboDamage: usage heatsoak.setTurboDamage(x), x from 0 to 1, 0 clears our damage")
    return false
  end
  if not nodesReady or s.turboOurDamage == nil then
    out("setTurboDamage: the model has not started yet, try again in a moment")
    return false
  end
  local integrity = turboCondition(engine)
  integrity = clamp01(integrity or 1)
  local ours
  if x == 0 then
    ours = 0
  elseif integrity <= 0 then
    ours = 0
  else
    ours = clamp01(1 - (1 - x) / integrity)
  end
  s.turboOurDamage = ours
  s.turboDamage = clamp01(1 - (1 - ours) * integrity)
  local note = ""
  if x == 0 and integrity < 1 then
    note = string.format(" (vanilla integrity %.3f still counts, so turboDmg is %.3f)", integrity, s.turboDamage)
  elseif x > 0 and math.abs(s.turboDamage - x) > 1e-6 then
    note = string.format(" (vanilla damage alone is already %.3f, so turboDmg cannot go lower)", 1 - integrity)
  end
  out(string.format("setTurboDamage(%g): own damage %.4f, vanilla integrity %.3f -> turboDmg %.4f%s", x, ours, integrity, s.turboDamage, note))
  return true
end

-- ===== manual engine power loss test (research for a catalyst failure) =====
-- Cuts engine torque with the engine's own outputTorqueState multiplier, the field vanilla itself scales for a blown head
-- gasket and damaged piston rings (combustionEngineThermals.lua:295,303) and for valve damage (combustionEngine.lua:524).
-- It multiplies the final torque in updateTorque (line 752), and the game's engine reset sets it back to 1 (line 1371).
local powerLoss = {factor = 1, fraction = 0, active = false, pending = {}, elapsed = 0}
M.state.powerLoss = powerLoss
local POWER_TEST_MAX_FRACTION = 0.95   -- leaves the engine alive: a factor of 0 is "disabled", and the idle governor still needs some torque
local POWER_TEST_SNAPSHOT_TIMES = {1, 3, 6}

-- automatic catalyst cut state
local catCut = {
  smooth = 0,
  applied = 0,
  appliedFactor = 1,
  pausedNoted = false,
  startLogged = false
}
M.state.catCut = catCut

local function resetCatCutState()
  catCut.smooth = 0
  catCut.applied = 0
  catCut.appliedFactor = 1
  catCut.pausedNoted = false
  catCut.startLogged = false
end

-- loss fraction for catalyst damage: 0 below 0.10, linear to max 0.50 at 1.00 damage
local function lossFromCatDamage(damage)
  if not damage then return 0 end
  local points = (cfg and cfg.catalystLoss and cfg.catalystLoss.points) or {{0.1, 0}, {1.0, 0.5}}
  if damage <= points[1][1] then return points[1][2] end
  for i = 2, #points do
    local a, b = points[i - 1], points[i]
    if damage <= b[1] then
      local v = a[2] + (b[2] - a[2]) * (damage - a[1]) / (b[1] - a[1])
      return math.max(0, math.min(v, 0.50))
    end
  end
  return math.min(points[#points][2], 0.50)
end

local function powerSnapshot(engine)
  local ev = electrics.values
  local torque = type(engine.lastOutputTorque) == "number" and engine.lastOutputTorque or nil
  local av = type(engine.outputAV1) == "number" and engine.outputAV1 or nil
  return {
    rpm = av and av * 9.5492965855 or nil,
    idleRpm = type(engine.idleAV) == "number" and engine.idleAV * 9.5492965855 or nil,
    throttle = ev.throttle,
    load = engine.engineLoad,
    torque = torque,
    powerKw = (torque and av) and torque * av / 1000 or nil,
    boost = ev.turboBoost or ev.boost,
    state = engine.outputTorqueState,
    stalled = engine.isStalled
  }
end

local function logPowerSnapshot(label, snap)
  out(string.format("power test %s: rpm=%s idle=%s throttle=%s load=%s torque=%s Nm power=%s kW boost=%s psi outputTorqueState=%s stalled=%s",
    label, f(snap.rpm, "%.0f"), f(snap.idleRpm, "%.0f"), f(snap.throttle, "%.2f"), f(snap.load, "%.2f"), f(snap.torque, "%.0f"),
    f(snap.powerKw, "%.1f"), f(snap.boost, "%.1f"), f(snap.state, "%.4f"), tostring(snap.stalled)))
end

-- Sets our share of outputTorqueState to `factor` (1 = none). Other things that scale the same field (vanilla damage) multiply
-- with it, so the field is changed by the ratio new/old rather than overwritten. A value above 1 after dividing can only mean the
-- game reset the field behind our back, and then our share is simply gone.
local function setPowerFactor(engine, factor)
  local state = engine.outputTorqueState
  local base = state / powerLoss.factor
  if base > 1.000001 then base = 1 end
  engine.outputTorqueState = base * factor
  powerLoss.factor = factor
end

function M.testPowerLoss(fraction)
  local engine = getEngine()
  if not engine or type(engine.outputTorqueState) ~= "number" then
    out("testPowerLoss: this vehicle has no combustion engine with an outputTorqueState")
    return false
  end
  if type(fraction) ~= "number" or fraction ~= fraction or fraction < 0 or fraction > 1 then
    out("testPowerLoss: usage heatsoak.testPowerLoss(fraction), 0.3 = 30% less power, 0 restores")
    return false
  end
  if engine.outputTorqueState <= 0 and fraction > 0 then
    out("testPowerLoss: the engine's output torque is already 0 (disabled or locked up), not changing it")
    return false
  end
  local clamped = math.min(fraction, POWER_TEST_MAX_FRACTION)

  -- if automatic catalyst cut was active, restore its share so testPowerLoss operates from clean vanilla torque
  if catCut.appliedFactor ~= 1 then
    local state = engine.outputTorqueState
    local base = state / catCut.appliedFactor
    if base > 1.000001 then base = 1 end
    engine.outputTorqueState = base
    catCut.appliedFactor = 1
    catCut.applied = 0
    catCut.smooth = 0
  end

  local before = powerSnapshot(engine)
  logPowerSnapshot("before", before)
  local old, oldState = powerLoss.factor, engine.outputTorqueState
  setPowerFactor(engine, 1 - clamped)
  powerLoss.fraction, powerLoss.active = clamped, clamped > 0
  powerLoss.before, powerLoss.after = before, {}
  powerLoss.elapsed = 0
  powerLoss.pending = {}
  for _, t in ipairs(POWER_TEST_SNAPSHOT_TIMES) do powerLoss.pending[#powerLoss.pending + 1] = {at = t} end

  if clamped > 0 then
    out(string.format("testPowerLoss: %.0f%%%s -> outputTorqueState %.4f (was %.4f, our share %.3f -> %.3f). heatsoak.testPowerLoss(0) restores it",
      clamped * 100, clamped < fraction and string.format(" (capped from %.0f%%)", fraction * 100) or "", engine.outputTorqueState,
      oldState, old, 1 - clamped))
  else
    out(string.format("testPowerLoss: restored, our share %.3f -> 1, outputTorqueState %.4f (was %.4f)", old, engine.outputTorqueState, oldState))
  end
  return true
end

local function updatePowerTest(dt, engine)
  if not engine or #powerLoss.pending == 0 then return end
  powerLoss.elapsed = powerLoss.elapsed + dt
  local nextSnap = powerLoss.pending[1]
  if powerLoss.elapsed >= nextSnap.at then
    table.remove(powerLoss.pending, 1)
    local snap = powerSnapshot(engine)
    powerLoss.after[#powerLoss.after + 1] = snap
    logPowerSnapshot(string.format("after +%gs", nextSnap.at), snap)
    if #powerLoss.pending == 0 and powerLoss.active then
      out("testPowerLoss: the cut is still applied. heatsoak.testPowerLoss(0) restores normal power")
    end
  end
end

local function updateCatalystCut(dt, engine)
  local s = M.state
  if s.catalystDamage == nil then
    s.catalystLoss = nil
    return
  end
  if dt <= 0 or not nodesReady or not engine or type(engine.outputTorqueState) ~= "number" then return end

  if powerLoss.active then
    if not catCut.pausedNoted then
      catCut.pausedNoted = true
      out("catalyst cut: paused while heatsoak.testPowerLoss is active (heatsoak.testPowerLoss(0) ends the test)")
    end
    catCut.smooth = 0
    s.catalystLoss = 0
    return
  else
    if catCut.pausedNoted then
      catCut.pausedNoted = false
      out("catalyst cut: resumed")
    end
  end

  local want = lossFromCatDamage(s.catalystDamage)
  local smoothTau = (cfg and cfg.catalystLoss and cfg.catalystLoss.smoothSeconds) or 2
  catCut.smooth = catCut.smooth + (want - catCut.smooth) * (1 - math.exp(-dt / smoothTau))

  local targetLoss = catCut.smooth
  if want == 0 and targetLoss < 0.001 then
    targetLoss = 0
    catCut.smooth = 0
  end
  targetLoss = math.max(0, math.min(targetLoss, 0.50))

  local targetFactor = 1 - targetLoss
  if math.abs(targetFactor - catCut.appliedFactor) > 0.0005 or (targetLoss == 0 and catCut.appliedFactor ~= 1) then
    local state = engine.outputTorqueState
    if state > 0 then
      local base = state / catCut.appliedFactor
      if base > 1.000001 then base = 1 end
      engine.outputTorqueState = base * targetFactor
      catCut.appliedFactor = targetFactor
      catCut.applied = targetLoss
    end
  end

  s.catalystLoss = catCut.applied

  if s.catalystLoss > 0 and not catCut.startLogged then
    catCut.startLogged = true
    out(string.format("catalyst cut started: catalystDmg=%.3f loss=%.1f%%, outputTorqueState=%.4f",
      s.catalystDamage, s.catalystLoss * 100, engine.outputTorqueState or 0))
  end
end

function M.setCatalystDamage(x)
  local engine = getEngine()
  local s = M.state
  if not engine or engine.requiredEnergyType ~= "gasoline" then
    out("setCatalystDamage: no catalyst on this vehicle (only gasoline engines have a catalyst)")
    return false
  end
  if type(x) ~= "number" or x ~= x or x < 0 or x > 1 then
    out("setCatalystDamage: usage heatsoak.setCatalystDamage(x), x from 0 to 1, 0 clears catalyst damage")
    return false
  end
  if not nodesReady or s.catalyst == nil then
    out("setCatalystDamage: the model has not started yet, try again in a moment")
    return false
  end
  s.catalystDamage = x
  out(string.format("setCatalystDamage(%g): catalyst damage set to %.4f", x, s.catalystDamage))
  return true
end

function M.setGearboxDamage(x)
  local s = M.state
  if not gearboxDevice then
    out("setGearboxDamage: no tracked gearbox on this vehicle")
    return false
  end
  if type(x) ~= "number" or x ~= x or x < 0 or x > 1 then
    out("setGearboxDamage: usage heatsoak.setGearboxDamage(x), x from 0 to 1, 0 clears damage")
    return false
  end
  s.gearboxDamage = x
  local gd = cfg.drivetrainDamage and cfg.drivetrainDamage.gearbox
  if x >= 1.0 then
    gearboxBroken = true
    seizedGearIndex = gearboxDevice.gearIndex or 1
    applyDrivetrainLock(0, getEngine())
    local engine = getEngine()
    if engine and gearboxDevice.gearIndex and gearboxDevice.gearIndex ~= 0 then
      if engine.isStalled ~= nil then engine.isStalled = true end
      if type(engine.cutIgnition) == "function" then engine:cutIgnition(0.5) end
    end
    if type(damageTracker) == "table" and type(damageTracker.setDamage) == "function" then
      pcall(damageTracker.setDamage, "powertrain", gearboxDevice.name, true)
    end
    if type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
      pcall(guihooks.messageForSeatedPlayers, {txt = "Transmission seized: gear cluster welded from extreme heat! Engine stalled, wheels locked!", context = {}}, 6, "vehicle.damage.gearbox")
    end
    out("setGearboxDamage(1): gearbox seized solid (engine stalled, wheels locked)")
  else
    if gearboxBroken then
      gearboxBroken = false
      seizedGearIndex = nil
      releaseDrivetrainLock()
      safeRestoreDevice(gearboxDevice)
    end
    local targetFriction = 1 + ((gd and gd.maxFrictionCoef or 2.5) - 1) * x
    if gearboxDevice.damageFrictionCoef then gearboxDevice.damageFrictionCoef = targetFriction end
    if gearboxDevice.damageLockTorqueCoef then gearboxDevice.damageLockTorqueCoef = math.max(0.2, 1 - 0.8 * x) end
    out(string.format("setGearboxDamage(%g): gearbox damage set to %.4f (friction %.1fx)", x, x, targetFriction))
  end
  return true
end

function M.setDiffDamage(x)
  local s = M.state
  if not diffDevices or #diffDevices == 0 then
    out("setDiffDamage: no tracked differential on this vehicle")
    return false
  end
  if type(x) ~= "number" or x ~= x or x < 0 or x > 1 then
    out("setDiffDamage: usage heatsoak.setDiffDamage(x), x from 0 to 1, 0 clears damage")
    return false
  end
  s.diffDamage = x
  local dd = cfg.drivetrainDamage and cfg.drivetrainDamage.differential
  if x >= 1.0 then
    diffBroken = true
    setDiffSpoolLock(false)
    applyDrivetrainLock(0, getEngine())
    for _, d in ipairs(diffDevices) do
      if d.damageFrictionCoef then d.damageFrictionCoef = 1.0 end
      if type(damageTracker) == "table" and type(damageTracker.setDamage) == "function" then
        pcall(damageTracker.setDamage, "powertrain", d.name, true)
      end
    end
    if type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
      pcall(guihooks.messageForSeatedPlayers, {txt = "Differential seized: pinion bearing welded, drive wheels locked!", context = {}}, 6, "vehicle.damage.diff")
    end
    out("setDiffDamage(1): differential seized and marked broken (wheels locked)")
  else
    if diffBroken then
      diffBroken = false
      releaseDrivetrainLock()
      for _, d in ipairs(diffDevices) do
        safeRestoreDevice(d)
      end
    end
    if x >= 0.50 then
      setDiffSpoolLock(true)
    else
      setDiffSpoolLock(false)
    end
    local targetFriction = 1 + ((dd and dd.maxFrictionCoef or 1.5) - 1) * x
    for _, d in ipairs(diffDevices) do
      if d.damageFrictionCoef then d.damageFrictionCoef = targetFriction end
    end
    out(string.format("setDiffDamage(%g): differential damage set to %.4f (friction %.1fx%s)",
      x, x, targetFriction, x >= 0.50 and ", spool locked" or ""))
  end
  return true
end

function M.setAmbient(temp)
  if obj and type(obj.queueGameEngineLua) == "function" then
    local arg = temp and tostring(temp) or ""
    obj:queueGameEngineLua(string.format("if not heatsoak then extensions.load('heatsoak') end; if heatsoak and heatsoak.setAmbient then heatsoak.setAmbient(%s) end", arg))
  end
end

function M.startRun()
  if obj and type(obj.queueGameEngineLua) == "function" then
    obj:queueGameEngineLua("if not heatsoak then extensions.load('heatsoak') end; if heatsoak and heatsoak.startRun then heatsoak.startRun() end")
  end
end

function M.stopRun()
  if obj and type(obj.queueGameEngineLua) == "function" then
    obj:queueGameEngineLua("if not heatsoak then extensions.load('heatsoak') end; if heatsoak and heatsoak.stopRun then heatsoak.stopRun() end")
  end
end

function M.toggleAmbient60()
  if ambientOverrideC == 60 then
    ambientOverrideC = nil
    if obj and type(obj.queueGameEngineLua) == "function" then
      obj:queueGameEngineLua("if core_environment then core_environment.resetTemperatureProfile() end")
    end
    if type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
      pcall(guihooks.messageForSeatedPlayers, {txt = "HeatSoak: Ambient temperature reset to map default", context = {}}, 3, "vehicle.heatsoak.ambient")
    end
    out("ambient temperature reset to map default")
  else
    ambientOverrideC = 60
    if obj and type(obj.queueGameEngineLua) == "function" then
      obj:queueGameEngineLua("if core_environment then core_environment.setTemperatureProfile({averageC = 60, minC = 60, maxC = 60}) end")
    end
    if type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
      pcall(guihooks.messageForSeatedPlayers, {txt = "HeatSoak: Ambient temperature set to 60°C (High Heat)", context = {}}, 3, "vehicle.heatsoak.ambient")
    end
    out("ambient temperature set to 60°C")
  end
  return ambientOverrideC ~= nil
end

function M.setAmbient60(enabled)
  if enabled then
    ambientOverrideC = 60
    if obj and type(obj.queueGameEngineLua) == "function" then
      obj:queueGameEngineLua("if core_environment then core_environment.setTemperatureProfile({averageC = 60, minC = 60, maxC = 60}) end")
    end
    if type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
      pcall(guihooks.messageForSeatedPlayers, {txt = "HeatSoak: Ambient temperature set to 60°C (High Heat)", context = {}}, 3, "vehicle.heatsoak.ambient")
    end
    out("ambient temperature set to 60°C")
  else
    ambientOverrideC = nil
    if obj and type(obj.queueGameEngineLua) == "function" then
      obj:queueGameEngineLua("if core_environment then core_environment.resetTemperatureProfile() end")
    end
    if type(guihooks) == "table" and type(guihooks.messageForSeatedPlayers) == "function" then
      pcall(guihooks.messageForSeatedPlayers, {txt = "HeatSoak: Ambient temperature reset to map default", context = {}}, 3, "vehicle.heatsoak.ambient")
    end
    out("ambient temperature reset to map default")
  end
  return ambientOverrideC ~= nil
end

function M.blowoutTire(wheelName)
  wheelName = wheelName and string.upper(wheelName)
  local s = M.state
  if not s.tireData or type(wheels) ~= "table" or type(wheels.wheels) ~= "table" then return false end
  for _, wd in pairs(wheels.wheels) do
    if not wheelName or wd.name == wheelName or string.upper(wd.name) == wheelName then
      local t = s.tireData[wd.name]
      if t and not t.blown then
        triggerTireBlowout(wd, t, "manual test")
        return true
      end
    end
  end
  return false
end

function M.setTireWear(wearPercent, wheelName)
  wearPercent = tonumber(wearPercent) or 100
  wheelName = wheelName and string.upper(wheelName)
  local s = M.state
  if not s.tireData then return false end
  for name, t in pairs(s.tireData) do
    if not wheelName or name == wheelName or string.upper(name) == wheelName then
      t.wearPercent = math.min(math.max(wearPercent, 0), 100)
    end
  end
  return true
end

function M.setTireTemp(tempC, wheelName)
  tempC = tonumber(tempC) or 120
  wheelName = wheelName and string.upper(wheelName)
  local s = M.state
  if not s.tireData then return false end
  for name, t in pairs(s.tireData) do
    if not wheelName or name == wheelName or string.upper(name) == wheelName then
      t.treadT = tempC
      t.carcassT = tempC * 0.8
    end
  end
  return true
end

function M.setTireCompound(compoundName, wheelName)
  compoundName = compoundName and string.lower(compoundName) or "race"
  wheelName = wheelName and string.upper(wheelName)
  local s = M.state
  if not s.tireData then return false end
  for name, t in pairs(s.tireData) do
    if not wheelName or name == wheelName or string.upper(name) == wheelName then
      t.compound = compoundName
      out(string.format("Tire %s compound set to: %s", tostring(name), tostring(compoundName)))
    end
  end
  return true
end


local autoDisabledDueToWarm = false
local hookedShiftLogic = false
local upshiftCooldown = 0

local function isDieselEngine(engine)
  if not engine then return false end
  if engine.requiredEnergyType == "diesel" or engine.energyType == "diesel" then
    return true
  end
  local name = tostring(engine.name or ""):lower()
  if name:find("diesel") then return true end
  if type(engine.storage) == "table" then
    for _, s in pairs(engine.storage) do
      if type(s) == "table" and s.energyType == "diesel" then
        return true
      end
    end
  end
  if engine.maxRPM and engine.maxRPM <= 4600 and (engine.idleRPM and engine.idleRPM <= 750) then
    return true
  end
  return false
end

local function getSafeRpm(engine)
  if isDieselEngine(engine) then
    return (cfg and cfg.coldEngine and cfg.coldEngine.safeRpmDiesel) or 2500
  end
  return (cfg and cfg.coldEngine and cfg.coldEngine.safeRpm) or 3500
end

local function hookShiftLogic()
  if hookedShiftLogic then return end
  local vc = controller and controller.getController("vehicleController")
  if not vc then
    log("W", "heatsoak", "[DEBUG] hookShiftLogic: vc is NIL")
    return
  end

  local sharedFuncs = nil
  local shiftBehaviorTable = nil
  for _, func in ipairs({vc.reset, vc.init}) do
    if type(func) == "function" and type(debug) == "table" and type(debug.getupvalue) == "function" then
      local i = 1
      while true do
        local name, val = debug.getupvalue(func, i)
        if not name then break end
        log("I", "heatsoak", string.format("[DEBUG] upvalue %d: %s (%s)", i, tostring(name), type(val)))
        if name == "sharedFunctions" and type(val) == "table" then
          sharedFuncs = val
        elseif name == "shiftBehavior" and type(val) == "table" then
          shiftBehaviorTable = val
        end
        i = i + 1
      end
    end
    if sharedFuncs then break end
  end

  log("I", "heatsoak", string.format("[DEBUG] sharedFuncs found: %s, shiftBehavior found: %s", tostring(sharedFuncs ~= nil), tostring(shiftBehaviorTable ~= nil)))

  if sharedFuncs and type(sharedFuncs.selectShiftPoints) == "function" then
    local origSelect = sharedFuncs.selectShiftPoints
    sharedFuncs.selectShiftPoints = function(gearIndex)
      origSelect(gearIndex)
      if safeRevLimitEnabled then
        local engine = getEngine()
        local safeRpm = getSafeRpm(engine)
        local safeShiftUpAV = (safeRpm - 250) * (math.pi / 30)
        local safeShiftDownAV = (safeRpm - 1200) * (math.pi / 30)
        if shiftBehaviorTable and shiftBehaviorTable.shiftUpAV then
          if shiftBehaviorTable.shiftUpAV > safeShiftUpAV then
            shiftBehaviorTable.shiftUpAV = safeShiftUpAV
          end
          if shiftBehaviorTable.shiftDownAV > safeShiftDownAV then
            shiftBehaviorTable.shiftDownAV = math.min(shiftBehaviorTable.shiftDownAV, safeShiftDownAV)
          end
        end
      end
    end
    hookedShiftLogic = true
    log("I", "heatsoak", "[DEBUG] hookShiftLogic SUCCEEDED! Shift points hooked.")
  end
end

local function applySafeRevLimiter(engine, dt)
  if not engine then return end
  hookShiftLogic()

  local th = engine.thermals
  local tOil = (th and th.oilTemperature) or 20
  local isWarm = (tOil >= 65)
  local isDiesel = isDieselEngine(engine)
  local safeRpm = getSafeRpm(engine)
  local vc = controller and controller.getController("vehicleController")

  -- Auto-disable ONCE when warm-up transition completes
  if isWarm and not autoDisabledDueToWarm then
    autoDisabledDueToWarm = true
    if safeRevLimitEnabled then
      safeRevLimitEnabled = false
      if tempRevLimiterActiveInEngine and type(engine.resetTempRevLimiter) == "function" then
        engine:resetTempRevLimiter()
        tempRevLimiterActiveInEngine = false
      end
      if electrics.values and electrics.values.throttleOverride then
        electrics.values.throttleOverride = nil
      end
      if vc and type(vc.setAggressionOverride) == "function" then
        vc.setAggressionOverride(nil)
      end
      if guihooks and type(guihooks.message) == "function" then
        guihooks.message({txt = "Engine reached operating temp (65C): Safe rev limit auto-disabled.", context = {}}, 4, "info")
      end
    end
  end

  if upshiftCooldown > 0 then
    upshiftCooldown = upshiftCooldown - dt
  end

  if safeRevLimitEnabled then
    -- 1. Clamp vehicleController aggression to 0 so native shift logic chooses low economy shift points
    if vc and type(vc.setAggressionOverride) == "function" then
      vc.setAggressionOverride(0.0)
    end

    -- 2. Keep the temp rev limiter in combustionEngine as an absolute ceiling
    local targetAV = safeRpm * (math.pi / 30)
    if type(engine.setTempRevLimiter) == "function" then
      engine:setTempRevLimiter(targetAV, targetAV * 0.05)
      tempRevLimiterActiveInEngine = true
    end

    -- 3. Smooth soft-throttle taper: eliminate harsh bounce/jumping at the limit!
    local currentRpm = (engine.outputAV1 or 0) * 9.549296596425384
    local taperWindow = 280
    local taperStart = safeRpm - taperWindow -- 3220 for gas, 2220 for diesel

    if currentRpm > taperStart then
      local excess = math.min(math.max((currentRpm - taperStart) / taperWindow, 0), 1)
      -- Smooth cosine roll-off down to 0.10 holding power
      local throttleMult = 0.5 * (1 + math.cos(excess * math.pi))
      local maxAllowedThrottle = 0.10 + (throttleMult * 0.90)

      local userThrottle = (electrics.values and electrics.values.throttle) or 0
      if userThrottle > maxAllowedThrottle then
        electrics.values.throttleOverride = maxAllowedThrottle
      end
    else
      if electrics.values and electrics.values.throttleOverride then
        electrics.values.throttleOverride = nil
      end
    end

    -- 4. Active Upshift Trigger: if transmission hasn't shifted and RPM is near the safe cap
    local gearbox = powertrain and powertrain.getDevice("gearbox")
    if gearbox and gearbox.gearIndex and gearbox.gearIndex >= 1 and gearbox.maxGearIndex and gearbox.gearIndex < gearbox.maxGearIndex then
      local userThrottle = (electrics.values and electrics.values.throttle) or 0
      local isShifting = gearbox.isShifting
      local shiftTriggerRpm = safeRpm - 200 -- 3300 gas, 2300 diesel
      if currentRpm >= shiftTriggerRpm and userThrottle > 0.15 and not isShifting and upshiftCooldown <= 0 then
        local nextGear = gearbox.gearIndex + 1
        if type(gearbox.setGearIndex) == "function" then
          gearbox:setGearIndex(nextGear, 0.25)
          upshiftCooldown = 0.8
        elseif vc and type(vc.shiftUpOnDown) == "function" then
          vc.shiftUpOnDown()
          upshiftCooldown = 0.8
        end
      end
    end
  else
    -- Safe rev limit is OFF
    if tempRevLimiterActiveInEngine and type(engine.resetTempRevLimiter) == "function" then
      engine:resetTempRevLimiter()
      tempRevLimiterActiveInEngine = false
    end
    if electrics.values and electrics.values.throttleOverride then
      electrics.values.throttleOverride = nil
    end
    if vc and type(vc.setAggressionOverride) == "function" then
      vc.setAggressionOverride(nil)
    end
  end
end

function M.toggleSafeRevLimit()
  safeRevLimitEnabled = not safeRevLimitEnabled
  local engine = getEngine()
  local vc = controller and controller.getController("vehicleController")

  if not safeRevLimitEnabled then
    if engine and type(engine.resetTempRevLimiter) == "function" then
      engine:resetTempRevLimiter()
      tempRevLimiterActiveInEngine = false
    end
    if electrics.values and electrics.values.throttleOverride then
      electrics.values.throttleOverride = nil
    end
    if vc and type(vc.setAggressionOverride) == "function" then
      vc.setAggressionOverride(nil)
    end
  else
    if engine and type(engine.setTempRevLimiter) == "function" then
      local safeRpm = getSafeRpm(engine)
      local targetAV = safeRpm * (math.pi / 30)
      engine:setTempRevLimiter(targetAV, targetAV * 0.05)
      tempRevLimiterActiveInEngine = true
    end
  end

  -- Broadcast immediate update to UI
  local th = engine and engine.thermals
  local tOil = (th and th.oilTemperature) or 20
  local isDiesel = isDieselEngine(engine)
  local safeRpm = getSafeRpm(engine)

  guihooks.trigger("HeatSoakData", {
    safeRevLimit = safeRevLimitEnabled,
    isWarm = (tOil >= 65),
    isDiesel = isDiesel,
    safeRpm = safeRpm
  })
end

function M.updateGFX(dt)
  local engine = getEngine()
  updateTurboTest(dt, engine)
  updatePowerTest(dt, engine)
  local enabled = modelEnabled(engine)
  M.state.active = enabled and true or false
  if not enabled then return end

  applySafeRevLimiter(engine, dt)
  updateNodes(dt, engine)
  applyDrivetrainLock(dt, engine)
  updateBoostCut(dt, engine)
  updateCatalystCut(dt, engine)
  sendToUI(dt, engine)

  timer = timer + dt
  if timer < LOG_INTERVAL then return end
  timer = 0

  local ev = electrics.values
  local th = engine.thermals
  local s = M.state
  local hasFI = (type(engine.turbocharger) == "table" and engine.turbocharger.isExisting)
    or (type(engine.supercharger) == "table" and engine.supercharger.isExisting)
  local boost = hasFI and (f(ev.boost) .. "psi") or "n/a"

  local etd = th.debugData and th.debugData.engineThermalData or {}
  out(string.format("rpm=%s thr=%s load=%s boost=%s coolant=%s oil=%s exh=%s amb=%s spd=%s egt=%s tur=%s cmp=%s ic=%s iat=%s bay=%s gearbox=%s diff=%s head=%s rod=%s cat=%s energyToCylinderWall=%s energyToOil=%s energyToExhaust=%s oilLubricationCoef=%s wall=%s wallDamage=%s pistonRingsDamaged=%s headGasketBlown=%s rodBearingsDamaged=%s oilMass=%s oilLeakRateOverall=%s block=%s coolantMass=%s coolantLeakRateHeadGasket=%s coolantLeakRateOverall=%s miniumSafeOilMass=%s oilLevelCritical=%s turboDmg=%s turboOurDmg=%s dHeat=%s dCoke=%s dOil=%s turboIntegrity=%s turboFrictionCoef=%s turboExhaustPowerCoef=%s torque=%s turboTemp=%s turboThreshold=%s turboLoss=%s turboLossWanted=%s turboOffset=%s turboRefBoost=%s catalystDmg=%s catalystLoss=%s dCatHeat=%s dCatContam=%s gearboxDmg=%s diffDmg=%s",
    f(s.rpm, "%.0f"), f(ev.throttle, "%.2f"), f(engine.engineLoad, "%.2f"), boost,
    f(th.coolantTemperature), f(th.oilTemperature), f(th.exhaustTemperature),
    f(obj:getEnvTemperature() - KELVIN), f((ev.wheelspeed or 0) * 3.6, "%.0f") .. "kph",
    f(s.egt, "%.0f"), f(s.turbineHousing, "%.0f"), f(s.compressorOut, "%.0f"), f(s.icCore, "%.0f"), f(s.iat, "%.0f"), f(s.engineBayAir, "%.0f"),
    f(s.gearboxOil, "%.0f"), f(s.diffOil, "%.0f"),
    f(s.cylinderHead, "%.0f"), f(s.rodBearings, "%.0f"), f(s.catalyst, "%.0f"),
    f(etd.energyToCylinderWall, "%.1f"), f(etd.energyToOil, "%.1f"), f(etd.energyToExhaust, "%.1f"), f(etd.oilLubricationCoef, "%.3f"),
    f(th.cylinderWallTemperature, "%.1f"), f(th.cylinderWallOverheatDamage, "%.0f"), flag(th.pistonRingsDamaged),
    flag(th.headGasketBlown), flag(th.connectingRodBearingsDamaged), f(etd.oilMass, "%.2f"), f(etd.oilLeakRateOverall, "%.5f"),
    f(th.engineBlockTemperature, "%.1f"), f(etd.coolantMass, "%.2f"), f(etd.coolantLeakRateHeadGasket, "%.5f"),
    f(etd.coolantLeakRateOverall, "%.5f"), f(etd.miniumSafeOilMass, "%.2f"), trackedFlag("oilLevelCritical"),
    f(s.turboDamage, "%.4f"), f(s.turboOurDamage, "%.4f"), f(s.dHeat, "%.5f"), f(s.dCoke, "%.5f"), f(s.dOil, "%.5f"),
    f(s.turboIntegrity, "%.3f"), f(s.turboFrictionCoef, "%.3f"), f(s.turboExhaustPowerCoef, "%.3f"),
    f(engine.lastOutputTorque, "%.0f"), f(s.turboTemp, "%.0f"), f(turboThreshold, "%.0f"),
    f(s.turboLoss, "%.3f"), f(s.turboLossWanted, "%.3f"), f(s.turboOffset, "%.2f"), f(s.turboRefBoost, "%.1f"),
    f(s.catalystDamage, "%.4f"), f(s.catalystLoss, "%.3f"), f(s.dCatHeat, "%.5f"), f(s.dCatContam, "%.5f"),
    f(s.gearboxDamage, "%.4f"), f(s.diffDamage, "%.4f")))
end

-- nodes are seeded on the next update: ambient isn't final yet at load (logged 15C at load, 25C seconds later)
function M.onReset()
  nodesReady = false
  timer = 0
  lastSimulatedOil = nil
  safeRevLimitEnabled = true
  autoDisabledDueToWarm = false
  upshiftCooldown = 0
  hookedShiftLogic = false
  if electrics.values and electrics.values.throttleOverride then
    electrics.values.throttleOverride = nil
  end
  local vc = controller and controller.getController("vehicleController")
  if vc and type(vc.setAggressionOverride) == "function" then
    vc.setAggressionOverride(nil)
  end
  local engine = getEngine()
  if tempRevLimiterActiveInEngine and engine and type(engine.resetTempRevLimiter) == "function" then
    engine:resetTempRevLimiter()
  end
  tempRevLimiterActiveInEngine = false
  -- the turbo module's own reset does not touch its wastegate offset, so a cut or a test would survive the reset
  if engine and cfg then
    restoreBaseline(engine, "vehicle reset")
  end
  resetBoostCutState()
  resetCatCutState()
  -- the engine's own reset puts outputTorqueState back to 1, which takes a power-loss test with it
  if powerLoss.active then
    out(string.format("power test: ended by the vehicle reset (our share was %.3f)", powerLoss.factor))
  end
  powerLoss.factor, powerLoss.fraction, powerLoss.active, powerLoss.pending = 1, 0, false, {}
  gearPopTimer = 0
  gearboxBroken = false
  diffBroken = false
  seizedGearIndex = nil
  setDiffSpoolLock(false)
  releaseDrivetrainLock()
  safeRestoreDevice(gearboxDevice)
  for _, d in ipairs(diffDevices) do
    safeRestoreDevice(d)
  end
  if type(wheels) == "table" and type(wheels.wheels) == "table" then
    for _, w in pairs(wheels.wheels) do
      w.frictionTorque = 0
    end
  end
  local s = M.state
  s.turboDamage, s.turboOurDamage = s.turboDamage and 0 or nil, s.turboOurDamage and 0 or nil
  s.turboLoss = s.turboLoss and 0 or nil
  s.catalystDamage = s.catalyst and 0 or nil
  s.catalystLoss = s.catalyst and 0 or nil
  s.dCatHeat = s.catalyst and 0 or nil
  s.dCatContam = s.catalyst and 0 or nil
  s.gearboxDamage = gearboxDevice and 0 or nil
  s.diffDamage = (#diffDevices > 0) and 0 or nil
  if gearboxDevice then
    if gearboxDevice.damageFrictionCoef then gearboxDevice.damageFrictionCoef = 1 end
    if gearboxDevice.damageLockTorqueCoef then gearboxDevice.damageLockTorqueCoef = 1 end
  end
  for _, d in ipairs(diffDevices) do
    if d.damageFrictionCoef then d.damageFrictionCoef = 1 end
  end
  restoreTireFriction()
  s.tireData = nil
end

function M.onExtensionLoaded()
  cfg = loadConfig()
  local engine = getEngine()
  if not modelEnabled(engine) then return end
  out("loaded; call heatsoak.dump() in the vehicle console for a full dump")
  if obj and type(obj.queueGameEngineLua) == "function" then
    obj:queueGameEngineLua("if not heatsoak then extensions.load('heatsoak') end")
  end
  M.dump()
  dumpKeyNames(engine)
end

return M
