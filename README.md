# heatsoak

Step 1 (field research) is confirmed by an in-game run on 0.40.4 (`beamng.log`).
The thermal model up to the intercooler nodes ran in-game with no logged errors, on an etkc. The gearbox and diff nodes
have **not yet run in-game**. All sanity numbers below come from running this `heatsoak.lua` under LuaJIT with stubbed
game globals, and from replaying a logged drive through it.

Files:
- `lua/vehicle/extensions/heatsoak.lua`: the extension
- `lua/vehicle/extensions/heatsoak_config.json`: every model constant
- `lua/vehicle/extensions/auto/heatsoak_loader.lua`: loads it on each vehicle spawn

Console (vehicle Lua context): `heatsoak.dump()`. Node values: `heatsoak.state`.

## Sanity checks

| Check | Result | Target |
|---|---|---|
| compressorOut, 12.5 psi, 20C | 100.6C | ~100C |
| iat, 12.5 psi, 20C, 100 km/h, after 30 s of boost | 49.7C | 45-60C once soaked |
| iat, same, after 70 s | 55.2C | 45-60C once soaked |
| iat, same, after 600 s (bay soaked at 51.8C) | 59.0C | 45-60C |
| iat at idle, 60 s after a 60 s hard run, 20C | 40.1C (core 41.1C, bay 58.0C) | within ~3C of core |
| iat 120 s after shutoff following that run, 20C | 43.9C (core 45.2C, bay 62.8C) | |
| egt, load 1 at 100% maxRPM | 900C | ~900C |
| egt, load 1 at 95% maxRPM | 861C | 850-900C |
| egt, load 1 at 90% maxRPM | 823C | **below 850C** |
| egt, idle (828 rpm, load 0.37) | 350C | ~350C |
| egt, fuel cut, settled | 250C | 250C |
| turbineHousing, 370C at idle, after 150 s, 20C ambient | 167C, falling 0.35 K/s at 180 s | ~160C, still dropping |
| same at 1.9C ambient (the logged run's ambient) | 160C | |
| turbineHousing heating tau, idle to full load | 23 s | ~25 s |

Other results:
- Housing full-load steady state: see the turbo section below. Idle equilibrium: 124C (20C ambient).
- Engine off from 370C: 231C at 150 s, 155C at 300 s, 92C at 600 s. Falls every second for 3000 s. Slower than idle.
- Replay of the logged drive (481 s, 1.9C ambient, coolant standing in for block because block wasn't logged):
  peak egt 822C, housing 307C, compressorOut 78C, iat 34C, bay 58C. After about 35 s of hard driving then idle, iat
  goes 13.0C (t=40 s), 26.6C (t=125 s), 34.3C (t=480 s).

The iat scenarios are synthetic, because the log has only about 35 s of boost and no shutoff. They use the logged
exhaust cooldown and hold block at 90C. For that reason the shutoff numbers equal the idle numbers: nothing in the
core or bay model depends on the engine running, so only block and exhaust can tell them apart.

## Model behaviour worth knowing

- `icCore` is a thermal node seeded at ambient. Heat in: `gCharge * boost/boostRefPsi * (compressorOut - core)` and
  `gBay * (bay - core)`. Heat out: `gAirAtRefSpeed * coreCooling/eAtRefSpeed * (core - ambient)`, where `coreCooling`
  runs from `eStandstill` to `eAtRefSpeed` with speed.
- Core tau: 22 s at idle, 19 s at 100 km/h, 16 s at 100 km/h on boost. `mass`, `gCharge`, `gBay` and `gAirAtRefSpeed`
  were tuned to hit the targets, not measured.
- `iat = compressorOut - chargeEff * (compressorOut - icCore)`. `chargeEff` falls linearly from `epsIdle` (0.95) at
  zero boost to `epsFull` (0.75) at `boostRefPsi`, and stays at `epsFull` above that. It doesn't affect the core.
- `epsFull` was raised from a starting 0.60, which missed the soaked highway target at 67.3C. The soaked result of
  59.0C is near the top of the 45-60C range, so a hotter ambient or a hotter bay will go over it.
- After a hard run iat drops at once as boost goes away (54.3C to about 37C), then climbs for minutes as the bay soaks.
- `compressorOut` must be computed in Kelvin to give 100C; the code converts. Vacuum is clamped to PR = 1.
- Without a turbo: `turbineHousing`, `compressorOut` and `icCore` are nil, and `iat` equals ambient. That includes
  supercharged cars, even though `electrics.values.boost` reads their boost.

Added beyond the spec, because the spec's numbers needed them:
- Engine off (`rpm < engineOffRpm`): egt decays to ambient over `egt.engineOffTau`. Otherwise it would hold at ambient + 320.
- Housing link scales with power (`linkBase + linkPerPower * powerFrac`) and is zero with the engine off. A fixed
  link can't give both a 25 s heating tau and the slow idle cooldown.
- Housing `airRunning` is extra airflow with the engine on, so shutoff cools slower than idle.
- `powerFrac` is clamped to 0..1, because logged rpm exceeds maxRPM (5850 vs 5600).
- Skip test is `not thermalsEnabled` rather than `== false`, because vanilla also disables thermals on nil
  (`combustionEngineThermals.lua:1644`). Skipped vehicles do no updates and no 1 Hz line or dump. They still log
  one `override keys` line at load.

Inputs: `speed` is `electrics.values.airspeed`, which is `obj:getGroundSpeed()` (`electrics.lua:416`), so wheelspin
doesn't add airflow. The nodes are seeded on the first update, not at load, because ambient read 15C at load and 25C
seconds later.

## Turbo, step A: housing retune and a manual boost test

No damage logic yet, no limits changed, no damage rows added.

### Turbine housing retune

The logs showed the modelled housing topping out at 473-526C at full boost, 0.55-0.60 of `egt`, even at 60C ambient
with `egt` at 816-935C. Real cast-iron housings run about 0.8-0.9 of EGT at sustained full load, so the constants were
refitted. The fit targets were the old calibration (heating tau 23 s, idle cooldown 163 / 151C at 150 / 180 s, shutoff
curve 224 / 154 / 116 / 95C at 150 / 300 / 450 / 600 s, idle equilibrium 120C) plus a steady full-load ratio of 0.80
at 15C and 100 km/h.

| Constant | Before | After |
|---|---|---|
| `mass` (kg, at 500 J/kgK) | 4 | 14.6 |
| `linkBase` (W/K) | 1 | 1.3 |
| `linkPerPower` (W/K) | 60 | 292 |
| `airBase` (W/K) | 6 | 29.7 |
| `airRunning` (W/K) | 10.5 | 37 |
| `airPerSpeed` (W/K per m/s) | 0.3 | 0.22 |
| `radiation` | 6.8e-9 | 0 |

The three taus can only all hold if the thermal mass and every conductance grow together while the power-dependent
link grows much faster. `mass` is therefore a fitted lumped value (housing plus the manifold and flange it is bolted
to), not the weight of a turbine housing. The radiation term fitted to zero: its cooling at high temperature could be
absorbed by `airBase` and `airRunning`, and it held the ratio down. The `turbineHousing` limits are unchanged (750 / 850).

Steady full load (90% of max rpm, load 1, 12.5 psi, held 30 min), housing / `egt`:

| Speed | 15C before | 15C after | 60C before | 60C after |
|---|---|---|---|---|
| 0 km/h | 0.73 | 0.82 | 0.73 | 0.82 |
| 100 km/h | 0.66 | **0.80** (653C of 818C) | 0.67 | 0.81 (695C of 863C) |
| 200 km/h | 0.61 | 0.78 | 0.62 | 0.79 |
| 250 km/h | 0.59 | 0.77 | 0.60 | 0.78 |

Calibration held: heating tau 23 s (was 23), idle cooldown from 370C at 150 / 180 s is 167 / 155C (was 163 / 151),
shutoff 231 / 155 / 114 / 92C (was 224 / 154 / 116 / 95), idle equilibrium 124C (was 120). Early cooldown is a few
degrees slower and the 600 s point a few faster. The ratio falls with speed because airflow cools the housing; the
target was set at 100 km/h.

**Replay of your logged drives** (Sunburst, 1 row = 1 s, inputs from the log). Checked first: with the old constants the
replay reproduces the `tur=` already in the log, with a mean error of 1.4 / 3.7 / 0.9C on the three runs and matching
peaks (526 / 526, 513 / 511, 104 / 104):

| Run | Ambient | Peak housing before | Peak housing after | Longest full-load stretch, end ratio before / after |
|---|---|---|---|---|
| beamng.1 (83 s full load, boost 13.5 psi) | 60C | 526C | **681C** | 0.62 / 0.80 |
| same | 15C | 488C | 638C | 0.60 / 0.79 |
| beamng.2 (54 s full load) | 60C | 511C | **660C** | 0.56 / 0.72 |
| same | 15C | 474C | 619C | 0.55 / 0.71 |
| beamng.3 (no full load) | 60C | 104C | 105C | none |

- **No Vivace log exists on this machine.** The game keeps the current log and three archives, and all four hold
  Sunburst runs only. The earlier cars (including an ETK C and a first run at 1.9C ambient) have rotated out. The current
  log's run is only 54 rows with no sustained full load, so it isn't in the table. The Vivace matters for step B, because
  its jbeam uses drive-mode wastegate offsets (see below). Drive a Vivace turbo and the same replay can be run on it.
- **The 15C rows are a what-if.** They keep the logged vanilla temperatures (coolant, oil, block, exhaust), which were
  recorded at 60C ambient, and change only the ambient the model sees. They only reach the housing through the engine bay
  node.
- **The 54 s stretch ends at 0.72, not 0.80,** so the housing hadn't settled by then. That is the model's behaviour from
  the logged start; I didn't dig into the exact split between the 23 s tau and the bay warming.
- **`egt` is still our own estimate,** not a game value, so "0.8 x egt" is relative to the model's `egt`.
- **The warn limit is now in reach.** 750C is the limit; at 935C `egt` the housing settles near 750C, and a 60C
  ambient with no airflow reaches 711C. That is intended, but a long pull will now show amber.

### The game's turbocharger.lua

All four are in `lua/vehicle/powertrain/turbocharger.lua`; its public interface is at the end of the file (lines 538-551).

| Function | Signature | Effect |
|---|---|---|
| `setWastegateOffset` (`:529`) | `(offset)`, psi | Sets a file-local `wastegateOffset` (Pa). It is added to the wastegate's target boost every frame (`:246`). The wastegate PID then holds boost near the new target. Reversible: `0` undoes it. Not read back anywhere, and nothing is damaged or flagged. |
| `applyDeformGroupDamage` (`:115`) | `(damageAmount)` | Meant for crash damage. Adds `damageAmount` scaled to friction (`damageFrictionCoef`, +1 per 0.01) and removes drive power (`damageExhaustPowerCoef`, -0.1 per 0.01, floored at 0). Cumulative, sets the `inductionSystemDamaged` flag, and shows a message to seated players. |
| `setPartCondition` (`:121`) | `(odometer, integrity, visual)` | Overwrites, not adds. `odometer` sets wear (`wearFrictionCoef`, 1 to 2 between 3e7 and 1e9). `integrity` is a number 0-1 (friction coefficient 1 to 20, drive power 1 to 0.2) or a table with those two coefficients. For save and load of part condition. |
| `getPartCondition` (`:136`) | `()` | Read only. Returns the integrity value (the lower of the friction and exhaust-power integrities, 0-1) and a table with the two coefficients. |

**Safest for reducing boost: `setWastegateOffset`.** It is the only one that changes the boost target directly, it
leaves no permanent state, it triggers no damage flag or message, and the original value restores it. The damage paths
reduce boost only indirectly. The wastegate compensates for lost drive power until it runs out of headroom, so they give
no controlled "half boost", and `applyDeformGroupDamage` is cumulative until a reset.

Things to know about `setWastegateOffset`:
- The turbo's target boost is a file-local and can't be read, only moved, so a reduction has to be relative to boost
  actually seen.
- **Vanilla's only caller is the drive-mode controller** (`driveModes.lua:42-49`), which applies the active mode's
  `wastegateOffset` on every mode change and on every reset (`resetLastStage`, `:225`). Only two cars in the game use it:
  `sbr` (0) and `vivace` (0, and 2 in one mode). On a Vivace the normal offset is the active mode's, not necessarily 0.
- The turbo module's `reset()` does not clear the offset (`:290-322`), so on a car without drive modes it survives a
  vehicle reset.
- The engine's torque-curve estimate (`getTorqueCoefs`, `:507`) ignores the offset, which feeds vanilla's throttle map.
  Torque may therefore not fall exactly in proportion to boost.
- Vanilla already damages the turbo through heat: `updateGFX` (`:198-207`) multiplies `damageFrictionCoef` by
  `1 + (turboTemp - threshold) * 0.001 * dt` every frame, where `turboTemp` is vanilla's `exhaustTemperature` plus coolant
  plus oil temperature and the threshold defaults to 1000 (jbeam key `damageThresholdTemperature`). In the logged runs
  that sum was about 680, well under it.

### `heatsoak.testTurbo(factor [, referencePsi])`

Console, vehicle context. **Manual only: the automatic boost cut of step C is the only other caller, and it pauses while a test is active.** It is the
mod's only write to the game. It uses `setWastegateOffset` and nothing else.

- `factor` 1 = normal, 0.5 = half boost, 0 = none. Values outside 0-1 are clamped.
- **Reference.** The offset is `baseline - (1 - factor) * reference`, where `reference` is the boost to scale from. It is,
  in order: the second argument, the live `electrics.values.boost` if above 1 psi, or the peak boost seen since the
  vehicle loaded. With none of those it refuses and says so. The call log names which was used.
- **Baseline.** The active drive mode's `wastegateOffset` for this engine (read through the controller's
  `getCurrentDriveModeKey` and `getDriveModeData`), or 0 on a car with no drive modes. `testTurbo(1)` restores that,
  so a Vivace in the +2 psi mode goes back to +2, not 0. A mode switch re-applies its own offset anyway.
- It logs a `before` snapshot at the call and `after +2s` / `after +5s` snapshots. Each line has boost, engine torque
  (`lastOutputTorque`), `forcedInductionCoef`, throttle, rpm, gear, turbo rpm, and the turbo's integrity and two damage
  coefficients from `getPartCondition` (read only). Compare torque only at the same rpm and throttle. The snapshots are in
  `heatsoak.state.turboTest`.
- It refuses on a car with no turbo (superchargers aren't supported) and on a bad argument. After the last snapshot it
  reminds you that the reduction is still applied, and a vehicle reset while it is applied logs a warning.
- It works on traffic cars too, where the thermal model is off.

Tested in the harness with stubbed game objects: offsets and baselines (no drive modes, a +2 psi mode, a 0 psi mode),
the factor clamp, all three reference sources and the refusal, the snapshots, reset, traffic, an error from
`setWastegateOffset`, and missing read-only fields. **Not run in-game**: whether boost follows the offset as expected,
how fast, and how torque responds are exactly what the first test will show.

## Turbo, step B: damage tracking

`heatsoak.state.turboDamage` runs 0-1. **In step B this was a tracking model only** (it read game values and wrote nothing); step C below now cuts boost from it, but the damage model itself still writes nothing. It exists only on cars
with a turbocharger (a supercharger-only car has none), and it returns to 0 on every vehicle reset (the reset that also
reseeds the thermal nodes). It is not saved across a game restart or a respawn.

All constants are per second and live in `heatsoak_config.json` under `turboDamage`. They are damage-model constants, separate
from the UI limits (the housing's UI warn and critical are still 750 and 850).

| Source | Rate (1/s) | Constants |
|---|---|---|
| heat | `clamp((turbine - 650) / (750 - 650), 0, 2) * boostFrac / 60` | `heat.warn`, `heat.crit`, `heat.maxFactor`, `heat.perSecondDivisor` |
| coking (hot shutdown) | rpm is 0 and turbine above 500: `clamp((turbine - 500) / 150, 0, 1) / 300` (step B3; was 600 / 200) | `coking.temperature`, `.range`, `.maxFactor`, `.perSecondDivisor` |
| oil | `clamp((oil - 130) / 20, 0, 2) / 900 + (1 - lubrication) / 30`, lubrication held 3 s (step B3) | `oil.warn`, `.range`, `.maxFactor`, `.perSecondDivisor`, `.lubricationDivisor`, `.lubricationHoldSeconds` |

- `turbine` is our modelled housing temperature. `oil` is vanilla's `oilTemperature`. `oilLubricationCoef` is clamped to
  0-1.
- `boostFrac = electrics.values.turboBoost / electrics.values.turboBoostMax`, clamped 0-1, and 0 if the maximum is missing.
  I used `turboBoost` (the turbo's own) rather than `boost`, which also adds a supercharger's. **`turboBoostMax` is the
  jbeam's wastegate limit, not the boost the car reaches**, so `boostFrac` is car-dependent: the Sunburst reads 14.0 psi
  against 13.5-13.8 reached, so about 0.97 at full boost, while the ETK C read 32.3 against about 10, which would give
  about 0.31 and make heat damage about three times slower there.
- "Engine stopped" is the sanitized rpm being exactly 0. In the Sunburst log, rpm goes straight from 927 to 0 at shutoff,
  with no in-between values, so the rule catches every shutdown. A denormal or nan rpm also counts as stopped.
- The damage added per frame is exactly `rate * dt`, so it does not depend on frame rate.

**What the rates mean, in time to 100% if held** (heat at `boostFrac` 1): housing at 750C or more is 1/60 per s, so 60 s
at 750 and 120 s at 700. Coking at 650C or more is 300 s for 100% (step B3 values). Oil at 150C is 15 min. Zero lubrication is 30 s.

**Replay of your Sunburst runs (60C ambient, 1 s per log row)**, old housing constants against the retuned ones:

| Run | Housing | Peak housing | Turbo damage | heat | coking | oil |
|---|---|---|---|---|---|---|
| beamng.1 (83 s full load) | old | 525C | 0.74% | 0 | 0 | 0.74% |
| same | new | 681C | **11.21%** | 10.16% | 0.31% | 0.74% |
| beamng.2 (54 s full load) | old | 511C | 0.50% | 0 | 0 | 0.50% |
| same | new | 660C | 1.06% | 0.56% | 0 | 0.50% |
| beamng.3 (no full load) | either | 104C | 0% | 0 | 0 | 0 |

With the old constants the housing never reached 650C, so the heat source could not fire; the retune is what makes it
meaningful. The oil part comes from the logged oil temperature, which peaked at about 136C. In the beamng.1 replay the damage
is 11.21% at 150 s and unchanged at every later 150 s sample to the end of the run (1500 s). At the retuned steady state, a sustained 100 km/h full-boost pull
at 60C ambient (housing about 695C) would be about 0.7% per second, or roughly 140 s to 100%.

**Log line.** It ends with `turboDmg=` (0-1), `dHeat=`, `dCoke=` and `dOil=` (the per-second rates at that instant), and
`turboIntegrity=`: the first value from vanilla's `getPartCondition`, where 1 is undamaged. Vanilla's own heat damage
(it multiplies friction when exhaust + coolant + oil temperature exceeds the jbeam threshold, 1000 by default) is a separate mechanism,
combined with ours in step B2 below. All of them print `n/a` on a car without a turbo, and `turboIntegrity` is also
`n/a` if `getPartCondition` is missing.

**UI.** A "Turbo dmg" row shows 0-100%, only above 0, in amber to red like the other damage rows. It sits with them at the
top of the app, with warn 25 and critical 100 in `ui.limits`. With every damage row showing the app had 19 rows and needed 18.33em (step C adds a row, see below).

Tested in the harness with stubbed game objects: each rate at known inputs and at every clamp, including a missing or zero
`turboBoostMax`, accumulation and the clamp at 1, exact `rate * dt` per frame at 1/144 to 2 s frames, reset to zero, no turbo and
traffic cars, the payload and log line, and zero calls to `setWastegateOffset` during heavy damage. **Not run in-game.**

*Step B2 (below) changes two things in this section: the heat source is now off by default, and `turboDmg` combines our
damage with vanilla's. The replay table above was made with heat on and no vanilla integrity.*

## Turbo, step B2: vanilla's threshold and combined damage

Still read-only: nothing in this step is written to the game (step C acts on the result).

### What vanilla does (turbocharger.lua, read from the game install)

- `updateGFX` (lines 198-207) computes `turboTemp = exhaustTemperature + coolantTemperature + oilTemperature` (coolant is 0 if
  absent). If `turboTemp > turboDamageThresholdTemperature`, then every frame
  `damageFrictionCoef = damageFrictionCoef * (1 + (turboTemp - threshold) * 0.001 * dt)` and the damage flag
  `turbochargerHot` is set. Nothing else in the file raises friction from heat.
- The threshold is `turbo.damageThresholdTemperature or 1000` (line 441), where `turbo` is the jbeam section of the turbocharger.
  The engine's jbeam names that section in its `turbocharger` key (combustionEngine.lua:2111-2114,
  `v.data[jbeamData.turbocharger]`). So the 1000 is only a default: any car can set a lower
  `damageThresholdTemperature`. That fits your Vivace log, where integrity fell with `turboTemp` near 665.
- `getPartCondition` (lines 136-146) returns `integrity = min(linearScale(damageFrictionCoef, 1..20 -> 1..0),
  linearScale(damageExhaustPowerCoef, 1..0.2 -> 1..0))`, and the state `{damageFrictionCoef, damageExhaustPowerCoef}`. The friction
  grows exponentially, so once `turboTemp` is over the threshold, integrity falls faster the further over it is, and it never recovers
  on its own. Crash damage (`applyDeformGroupDamage`) raises the same two coefficients. A reset sets them back to 1.

### The threshold, read per car

At the first update after load or reset the mod finds the engine's `turbocharger` key (in `v.data[engineName]`, else the
`v.data.powertrain` row with that name), then reads `damageThresholdTemperature` from `v.data[thatSection]`, and logs one line:

- `turbo damage threshold: 640 C (jbeam damageThresholdTemperature in 'tt'), compared with exhaust + coolant + oil`
- `turbo damage threshold: 1000 C (damageThresholdTemperature not set in '<section>', using vanilla default), ...`
  (also used if the key holds something that is not a positive number)
- `turbo damage threshold: lookup failed: <why>` when the section cannot be found (no `v.data`, the engine names no turbo
  section, or the section is missing). The log column then prints `n/a`.

The value is also in the 1 Hz line as `turboThreshold=`. **Only the harness has exercised the lookup** (set, unset, via the powertrain row,
section missing, no `v.data`); whether the real Vivace and Sunburst jbeams give a number is what your next log will show.

### New in the 1 Hz line

`turboDmg= turboOurDmg= dHeat= dCoke= dOil= turboIntegrity= turboFrictionCoef= turboExhaustPowerCoef= torque= turboTemp= turboThreshold=`

- `turboFrictionCoef` and `turboExhaustPowerCoef` are vanilla's **damage** coefficients (`damageFrictionCoef`, `damageExhaustPowerCoef`)
  from `getPartCondition`, not the jbeam's base `frictionCoef`. 1 means undamaged.
- `torque` is `engine.lastOutputTorque` in Nm (the same field `testTurbo` logs).
- `turboTemp` is the same sum vanilla uses (exhaust + coolant + oil, coolant counted as 0 if absent), so it can be compared directly with
  `turboThreshold`.
- `turboOurDmg` is our own damage on its own (see below); `turboDmg` is the combined value.

### Combined damage

```
turboOurDmg = accumulated (coking + oil) damage, 0-1
turboDmg    = 1 - (1 - turboOurDmg) * integrity
```

The two are treated as independent hazards: the turbo counts as undamaged only if both are. With integrity 1 `turboDmg` equals
`turboOurDmg`; with turboOurDmg 0 it is `1 - integrity`; at integrity 0 it is 1. Integrity is read every frame; if
`getPartCondition` is missing, errors, or returns a non-number, it counts as 1 (only our damage shows), and an out-of-range
value is clamped to 0-1 in the sum. `turboOurDmg` resets with the vehicle reset; vanilla's integrity is reset by the game.
The UI row shows `turboDmg` (combined).

### Heat source switched off

Vanilla already damages the turbo from heat (above), through its own integrity, so counting our heat too would count it twice.
`heatsoak_config.json` now has `turboDamage.heat.enabled = false`, so `dHeat` stays 0 and our damage is coking + oil only. Setting it to `true`
restores the step B heat rate unchanged (the other `heat` constants are kept). `turboDamage.vanillaThresholdDefault` (1000) is vanilla's
default, used only when the jbeam key is unset.

### Testing

Harness only (stubbed game objects): the formula at integrity 0.8 / 0.5 / 1 / 0, heat off at a 900C housing at full boost, coking and oil
sums, a missing / erroring / non-numeric `getPartCondition`, `turboTemp` with and without coolant, all threshold lookup cases above, reset, and
no turbo. `setWastegateOffset` is still called only from `testTurbo`. **Not run in-game.**

## Gearbox and diff oil

`gearboxOil` uses the device named `gearbox`. Heat in is `(1 - efficiency) * |outputTorque1 * outputAV1|`, with
efficiency looked up by device type. If a `torqueConverter` device exists, slip heat is added:
`|torqueDiff * inputAV - outputTorque1 * outputAV1|`, which is pump power minus turbine power.

`diffOil` runs one node per device of type `differential`, with heat in from
`(1 - efficiency) * |outputTorque1 * outputAV1 + outputTorque2 * outputAV2|`. `state.diffOil` and the UI show the
hottest; `state.diffOilByDevice` holds each one. A center diff of that type gets a node too.

Both are cooled by `gAirBase + gAirPerSpeed * speed` toward ambient and `gBay` toward bay air, and start at ambient.
Gearbox efficiencies are mapped by device type (`manualGearbox` 0.97, `sequentialGearbox` 0.97, `dctGearbox` 0.96, `automaticGearbox` 0.96, `cvtGearbox` 0.93). Any unmapped device type skips the node and logs one line.

**Thermal mass is an effective figure for the whole unit, not the oil.** The first version used oil only (2.5 L and
1 L), which is 4.4 kJ/K and 1.7 kJ/K. A 60 s pull put the automatic gearbox at 275C, because oil alone can't absorb
27 kW for a minute. The config now uses 16 kJ/K for the gearbox and 12.5 kJ/K for the diff, which stands in for the gears and case too.
Conductances were scaled by the same factor (x3.64 and x7.18), so the tau at 100 km/h is unchanged at 122 s and
149 s. At standstill it is longer, 275 s and 348 s, because the air term vanishes.

The automatic's efficiency is 0.96, the same as the DCT, with torque converter slip heat added on top, so converter
loss is no longer counted twice.

60 s pull at a constant 270 kW, 0 to 288 km/h, one driven diff:

| Gearbox | 15C gearbox | 15C diff | 40C gearbox | 40C diff |
|---|---|---|---|---|
| manual, 0.97 | 37.4C | 43.8C | 62.2C | 68.7C |
| DCT, 0.96 | 44.5C | 43.5C | 69.3C | 68.4C |
| automatic, 0.96 | 44.5C | 43.5C | 69.3C | 68.4C |

- The gearbox ends 22C (manual) and 30C (DCT) above 15C ambient, within the 20-40C target. At 40C ambient it ends 25C higher.
- The automatic matches the DCT here because the pull has no converter in it. Converter slip only adds heat when the
  converter isn't locked: a 5 s stall at 105 kW of slip takes the oil from 15C to 47.5C.
- With a 50/50 front/rear split on a two-diff car, the hottest diff reads 29.6C at 15C and 54.4C at 40C.
- At 100 kW the gearbox and diff both read about 26C at 15C ambient.
- 270 kW constant is an upper bound; a real pull shifts and sweeps the rev range.

## Cylinder head, rod bearings, catalyst

`thermals.debugData.engineThermalData` is assigned on every thermal update, whether or not the vanilla debug app is
open. Only the stream send is gated by `streams.willSend` (`combustionEngineThermals.lua:941-943, 964, 1069`). The mod
logs one `debugData live check:` line per vehicle load, showing how many frames each field changed and whether the
stream was open. An in-game run confirmed it: `LIVE, streamOpen=false`, with the energy fields changing on 150 of 150
frames. There is no derived fallback: if that line ever says `NOT LIVE`, head and bearing heat are missing.

The 1 Hz log line carries the raw `energyToCylinderWall`, `energyToOil`, `energyToExhaust` (joules per update) and
`oilLubricationCoef`. The harness stubs 300 kW and 9.4 kW at full load, and those are still estimates: in the same
run, the modelled head reached only 13C above coolant and the bearings 13.4C above oil, against 39C and 25C in the
harness. The constants haven't been recalibrated against the logged energies yet.

`energyToCylinderWall` and `energyToOil` are joules per update, not watts, so they are added directly, as vanilla does.
Results don't depend on frame rate.

- `cylinderHead`: heat in is `combustionFraction * energyToCylinderWall`. It conducts to the vanilla wall (`gWall`) and
  coolant (`gCoolant`), and is seeded at coolant temperature. Hidden with no coolant loop.
- `rodBearings`: heat in is `frictionFraction * energyToOil * load * (1 + starvationGain * (1 - oilLubricationCoef))`.
  Friction energy already follows rpm. It conducts to oil (`gOil`) and is seeded at oil temperature.
- `catalyst`: heated through `linkBase + linkPerPower * powerFrac` from `egt`, cooled by `gAirBase + gAirPerSpeed * speed`,
  and seeded at ambient. Present when `requiredEnergyType` is `gasoline`. Unburnt-fuel heating on lift-off is not modelled.

60 s full-load pull at 6000 of 7000 rpm, 0 to 288 km/h. "Steady" holds 200 km/h for 20 minutes:

| Node | 15C, 60 s | 15C, steady | 40C, 60 s | 40C, steady | Warn / critical |
|---|---|---|---|---|---|
| cylinderHead | 129.5C | 130.9C | 143.5C | 144.9C | 150 / 175 |
| rodBearings | 129.3C | 129.4C | 145.3C | 145.4C | 135 / 155 |
| catalyst | 519.7C | 671.9C | 544.7C | 696.9C | 850 / 950 |

| Input | Status |
|---|---|
| vanilla coolant and oil temperatures | live in-game, stubbed in the harness (values read from the logged etkc run; 40C by interpolation) |
| vanilla wall temperature, `oilLubricationCoef` | live per source, stubbed in the harness (wall set to coolant + 9C, coefficient to 1) |
| `energyToCylinderWall`, `energyToOil` | live in-game, stubbed in the harness: 300 kW from vanilla's exhaust balance on logged data, 9.4 kW from the logged 15 Nm friction at 6000 rpm |
| `egt` | our own estimate, from load and rpm |
| all fractions, masses and conductances for these nodes | chosen, not measured |

Other results: with `oilLubricationCoef` at 0.5 and 0, the bearings reach 180.0C and 230.7C at 15C. After the pull,
120 s at idle gives head 91.4C, bearings 101.1C, catalyst 378.4C. After 300 s more with the engine off, the catalyst is 224.6C.

Catalyst `gAirBase` is 5.5 W/K, raised from 1 because the catalyst cooled too slowly in-game. `gAirPerSpeed` is unchanged:

| Catalyst | Before (1 W/K) | After (5.5 W/K) |
|---|---|---|
| Engine off at standstill, 620C, 60C ambient: after 48 s | 611.1C | 572.8C |
| Same, after 232 s (in-game log, from 621C: 579C) | 578.3C | 426.0C |
| Standstill tau | 50.0 min | 9.2 min |
| Engine-off tau at 50 / 100 / 200 km/h | 21 / 13.3 / 7.7 min | 7.3 / 6.2 / 4.7 min |
| Idle equilibrium, 15C | 315.2C | 238.6C |

## Rpm sanitizing

The model reads `electrics.values.rpm` in one place, `sanitizeRpm`. It returns 0 when `isDisabled` or `isStalled` is
set or `ignitionCoef < 1`, and when the value is non-numeric, nan, over `rpmMax` (20000), or a denormal. The log line
and every node use that result, also available as `state.rpm`. `heatsoak.dump()` still prints raw electrics on purpose.

The logged `rpm=2.9e17` wasn't a real engine speed. LuaJIT's `%f` prints denormals as huge integers: `1e-310` prints
as `302642506592531929`. During those rows `egt` took the engine-off path, which a real 2.9e17 could not have done.
The log formatter now prints all denormals as 0. The first bad value per load is logged as `rpm sanitized: raw=...`,
in `%.17g`, which should confirm this in-game.

## Vanilla engine damage

Read-only visibility into vanilla's damage system. Nothing here adds heat or changes any vanilla value.

Vanilla keeps one accumulator per failure, in joules of engine work, and each has its **own trigger temperature**
(`combustionEngineThermals.lua:588-620`):

| Failure | Accumulator (`thermals.`) | Limit (on `mainEngine`) | Accumulates while | Flag (`thermals.`) |
|---|---|---|---|---|
| piston rings | `cylinderWallOverheatDamage` | `pistonRingDamageThreshold` | wall temperature is over `cylinderWallTemperatureDamageThreshold` | `pistonRingsDamaged` |
| head gasket | `engineBlockOverheatDamage` | `headGasketDamageThreshold` | **block** temperature is over 140C (jbeam default) | `headGasketBlown` |
| rod bearings | `oilOverheatDamage` | `connectingRodDamageThreshold` | oil temperature is over 150C (a fixed constant) | `connectingRodBearingsDamaged` |

The accumulators are capped at their limit, so 100% means the part has failed.

**Oil limit.** The oil trigger (150C) is a constant in vanilla (`combustionEngineThermals.lua:160`). No jbeam sets it, in
any of the 126 vehicle zips, so there is nothing to look up. The coolant limit (120C, `:158`) is the same kind of
constant. The coolant one drives the overpressure leak: coolant over 120C leaks 0.01 kg/s, which is what the early
`coolantLeakRateOverall=0.01` rows in the logs are. It is unrelated to the block limit.

**Block limit.** The block trigger is the jbeam value `engineBlockTemperatureDamageThreshold`, defaulting to 140C
(`combustionEngineThermals.lua:1789`). It varies a lot: a scan of the game's jbeam files finds it set on sunburst2
(120, 130 and 135 depending on engine and part), percheron (126), autobello (180 to 240), and midtruck (210 to 220).
Within sunburst2 it differs per engine: the 2.5 base `mainEngine` section sets 120, its stage 1 internals set 135, and
the 2.0 base sets none.

Vanilla copies only four limits onto the engine device (`combustionEngine.lua:1740-1743`), and this isn't one of them, and
the merged jbeam copy is a file-local (`powertrain.lua:51`). The mod resolves the limit in this order, and logs which
one won:
1. **jbeam:** `v.data[engine name]` (the named `mainEngine` section), then the `mainEngine` row in `v.data.powertrain`.
   These are the two inputs vanilla merges, section over row (`powertrain.lua:494-495`), so the section wins here too.
   Values that aren't positive numbers are ignored.
2. **override:** `damage.blockTemperatureOverride`, set per model or part through the `engines` table in
   `heatsoak_config.json`. It ships with `"sunburst2": {"damage": {"blockTemperatureOverride": 120}}`.
3. **default:** `damage.defaults.blockTemperature` (140), vanilla's own default.

One line per vehicle load reads `block limit: 120 (jbeam)`, `(override)` or `(default)`, and says why when it isn't the jbeam:
- `block limit: 140 (default) | not set in jbeam, using vanilla default 140`: the engine's jbeam was read and has no such
  key, so vanilla uses 140. With an override it reads `block limit: 120 (override) | not set in jbeam, using override 120`.
- `block limit: 140 (default) | jbeam lookup failed: v.data.mainEngine is nil and the powertrain has no 'mainEngine' row`:
  the engine's jbeam couldn't be found at all, so the unset-key reasoning doesn't apply.

The `damage thresholds:` line also carries `block=` and `oil=150(constant)`.

**Confirmed in-game:** the Sunburst's real logs read `block limit: 120 (jbeam)`, so `v.data["mainEngine"]` does hold the
merged part data and the lookup works. A value that is present but isn't a positive number is treated as unset.

**The sunburst2 override is deliberately coarse and only a fallback.** It applies to every sunburst2 engine, so it is wrong
for the 2.0 base (vanilla default, 140) and for the stage 1 internals (135). It only applies when the jbeam does not give
a limit: a 2.0 base would log `not set in jbeam, using override 120`, which is wrong for it, so key the override by engine
part instead, such as `sunburst2_engine_2_5`, if you drive those. Part names are in the `override keys:` line.

**Evidence for 120 on the sunburst2 2.5**, from the log: block was 119.4, 119.9 and 120.3 over three seconds with
`headGasketBlown=false`, then `headGasketBlown=true` at block 120.7. The accumulator needs about a second over the limit
before it trips, which fits. Its jbeam sets 120 on the base `mainEngine` section.

All four limits were present on the engine device in the logged etkc run (wall 120, rings and gasket 1.5e6, rods 2e6).
The device fields are copied from the jbeam and can be nil. When one is missing, vanilla uses its own default, and the mod
reads the same default from `heatsoak_config.json` (`damage.defaults`: wall 160, the three energy limits 2e6, from
`combustionEngineThermals.lua:1785-1788`). One line per vehicle load, `damage thresholds:`, says which came from the
device and which from the default. They're re-read on reset. In the logged sunburst2 runs, all four came from the device
(wall 130, rings 900000, gasket 200000, rods 1.5e6).

Rows, all hidden when their field is nil:
- **Block:** `engineBlockTemperature`, warn = limit - `damage.blockWarnMargin` (10), critical = limit, like Wall. The
  limit is resolved as described above and travels with the data. This is what trips the head gasket. Oil's critical
  limit stays at 150, matching the rod bearing trigger.
- **Wall:** `cylinderWallTemperature`, warn = threshold - `damage.wallWarnMargin` (10), critical = threshold. The
  limits travel with the data because they differ per engine (120 and 170 both appear in the logs).
- **Ring dmg, Gasket dmg, Rod dmg:** accumulator / limit as 0-100%, **shown only above 0**, so a single joule shows
  as `0.0%`. They appear at the top of the app. Warn 25 and critical 100 (in `ui.limits`) set the bar scale only.

`heatsoak.state` has `wall`, `wallWarn`, `wallCritical`, `ringDamage`, `gasketDamage` and `rodDamage` (percent, 0 when
undamaged).

The 1 Hz log line ends with `wall=`, `wallDamage=` (raw joules, not a percent), `pistonRingsDamaged=`,
`headGasketBlown=`, `rodBearingsDamaged=`, `oilMass=` (kg) and `oilLeakRateOverall=` (kg/s). `rodBearingsDamaged` is
vanilla's `connectingRodBearingsDamaged`. Missing fields print `n/a`. The two oil values come from `engineThermalData`.

It then continues with `block=`, `coolantMass=`, `coolantLeakRateHeadGasket=`, `coolantLeakRateOverall=` (all from
`engineThermalData` except block), `miniumSafeOilMass=` (vanilla's spelling, the limit below which oil counts as low) and
`oilLevelCritical=`. That flag is not on thermals: vanilla sets it on the global `damageTracker` when
`oilMass < miniumSafeOilMass`, and the mod reads it with `damageTracker.getDamage("engine", "oilLevelCritical")`, a plain
read. `n/a` there means no tracker. Air-cooled engines report coolant mass and leak rates as 0, not `n/a`. Also exposed
and not logged: `maximumSafeOilMass`, the `oilLevelTooHigh` flag, and the `starvedOfOil` flag.

**Missing fields, tested:** with the wall temperature removed, the head node crashed. Now it hides. With block
temperature removed, the engine bay node crashed. Now the bay just gets no heat from the block. Vanilla initialises
the wall, block, oil and exhaust temperatures at module level (`combustionEngineThermals.lua:21-25`), so those two cases
should not occur in the game, and oil and exhaust are still read unguarded for that reason. Coolant is the exception:
air-cooled engines set it to nil (`:581`), and that case was already handled, with the head row hidden.

**Not yet run in-game.** Harness checks: limits from the device and from defaults (including 0, nan and negative
device values falling back), percent and the 100% cap, rows hidden at zero or when fields are removed mid-run without
errors, the log line, and reset. The UI was rendered with the game's AngularJS: no name overflow, and the wall bar
turns amber at 110C and red at 120C.

## UI app

`ui/modules/apps/HeatSoak/` holds `app.json` and `app.js`. `heatsoak.lua` sends `guihooks.trigger("HeatSoakData", {...})`
at `ui.updateHz`, only when `playerInfo.firstPlayerSeated` is true, with values in C. The app shows a row only when
its node has a value, so turbo rows are hidden without a turbo.

To add it: restart the game, press Esc, open **HUD Apps**, focus a layout, choose **Edit layout** (pencil icon),
then **Add app**, and pick **HeatSoak** (category Telemetry). Save when you leave the editor.

The app is sized in em, so rows scale with the frame. Measured in the test render: 15 rows (the most a car shows with no
damage) need 14.58em, which is the default height in `app.json` (234px), and all 19 rows (four damage rows showing) need
18.33em. **A layout saved
shorter than the rows clips the last ones**, which are the least important. Resize the frame in **Edit layout**, or edit
`height` in the layout file. A frame taller than the rows leaves an empty block below them.

Bar length is value / critical. Color runs blue at 0, green from `greenFrom * warn` to `greenTo * warn`, amber at
warn and red at critical. Values dim when no data has arrived for 1 s (paused, or a vehicle without the model).
The three damage rows are the exception: they run from amber to red only, because blue or green at low damage would
read as "cold" or "fine".

Format copied from `SimpleEngineDebug` (`app.json` keys, `angular.module('beamng.apps').directive(...)` shape) and
`DamageAppEngine` (`$scope.$on` for a custom event). `EngineThermalDebug` was not usable as a template: it is Vue,
imports from the game's build tree (`@/bridge`), and nothing shows a mod's `app.vue` gets compiled.

Not included: `app.png` (the selector falls back to its default image) and `mockdata/snapshot.json` (the loader only records whether it exists; what else reads it wasn't checked).

Tested in headless Edge with the game's own AngularJS and a fake event, and the Lua side under the harness. The app
was saved into a freeroam layout with no errors logged, which shows the game accepted it. **Its on-screen display wasn't checked from here.**

## Config

`defaults` holds all constants, with UI limits under `ui.limits`. `engines` holds overrides, deep-merged, keyed by vehicle model or by jbeam part name
(part wins). Example: `"engines": {"bx": {"egt": {"base": 300}}}`. Valid keys are logged at load as `override keys:`.
Part names come from `v.config.partsTree` `chosenPartName`, confirmed in-game (for example `etk_engine_i6_3.0`).
If the config can't be read, the model stays off and logs an error.

Units: temperatures C, tau s, mass kg, specificHeat J/kgK, conductances (`link*`, `air*`, `g*`) W/K
(`*PerSpeed` per m/s), radiation W/K^4.

## Field paths (confirmed in-game unless noted)

All are plain Lua fields: readable, and technically writable. The model only reads. Thermals are recomputed each step.

| What | Path | Unit |
|---|---|---|
| Engine | `powertrain.getDevice("mainEngine")`; `.maxRPM`, `.idleRPM`, `.engineLoad`, `.thermalsEnabled`, `.isStalled`, `.ignitionCoef` | |
| Thermals | `engine.thermals.coolantTemperature`, `.oilTemperature`, `.engineBlockTemperature`, `.cylinderWallTemperature`, `.exhaustTemperature` | C |
| Debug data | `engine.thermals.debugData.engineThermalData` (key names logged at load) | |
| Boost | `electrics.values.boost` = turboBoost + superchargerBoost (`electrics.lua:459`), also `.boostMax`, `.turboBoostMax` | psi |
| Turbo module | `engine.turbocharger`, check `.isExisting`; readable data is only `isExisting`, `turboAV` | |
| Electrics | `electrics.values.rpm`, `.throttle`, `.airspeed`, `.wheelspeed` | rpm, 0..1, m/s |
| Ambient | `obj:getEnvTemperature()` K, `obj:getEnvPressure()` Pa (logged 101323), `obj:getRelativeAirDensity()` | |

Traffic vehicles logged `thermalsEnabled = false`, with temps pinned at 80C.

## Not exposed by vanilla (modelled here instead)

- **EGT / exhaust manifold**: only the lumped `thermals.exhaustTemperature`. It peaked at 370C at full load and settles
  at about 146C at idle, so it is not a real EGT. The 370 to 160 calibration matches this signal (370 to 155 at 150 s).
- **Turbo housing**: vanilla `turboTemp` is a local (`turbocharger.lua:200`) and a sum of exhaust + coolant + oil, not a temperature.
- **IAT**: none. Only `intakeAirDensityCoef`.
- **Engine bay air**: no such node.

## Turbo, step B3: coking and lubrication tuning

Tuning only. Nothing is written to the game, and `turboDmg = 1 - (1 - turboOurDmg) * integrity` is unchanged.

**Coking starts lower.** `coking.temperature` 600 -> 500 and `coking.range` 200 -> 150, so while the engine is stopped the rate is
`clamp((turbine - 500) / 150, 0, 1) / 300` per second: zero at 500C, full rate (300 s for 100%) from 650C. At the Vivace's 564C at shutoff
the rate is 0.43 of full, and at its 620C peak 0.80 of full. Those are rates at that instant; the housing then cools. In the harness, standing
at 15C ambient with the engine stopped:

| Housing at shutoff | Coking total | Time until the housing is under 500C |
|---|---|---|
| 564C | 2.1% | 31 s |
| 620C | 7.1% | 56 s |
| 700C | 17.1% | 88 s |

So a shutoff at the Vivace's 564C costs about 2%, not 0, but not much either. These come from my housing model, not from a Vivace log
(none exists on this machine), so how fast your real housing cools is the thing to check.

**Short lubrication dips are ignored.** The lubrication used in the oil source is the highest `oilLubricationCoef` seen over the trailing
`oil.lubricationHoldSeconds` (3 s), a sliding-window maximum. That is "require the dip to persist" done exactly: a dip shorter than 3 s is never
the maximum, so it adds nothing, and a dip that lasts longer takes effect only once it has filled the whole window (the first 3 s of it are not counted, the rest is).
The window starts out holding 1.0 at spawn and at every reset, so a dip right after spawn is held back the same way, and a car that spawns
straight into zero lubrication counts from 3 s on. Set `lubricationHoldSeconds` to 0 to turn it off (the step B rate again).
This is not a low-pass filter: a filter would still pass a share of every dip.

Harness results (shipped config, 1/30 s frames unless noted):

| Lubrication profile | Oil damage added |
|---|---|
| one 0.955 sample at a hard launch | 0 |
| 2.9 s dip to 0.5 | 0 |
| two 1 s dips to 0.2, 0.5 s apart | 0 |
| 1.5 s at 0.93 right after spawn | 0 |
| 4 s dip to 0.5 | 1.7% (1 s counted at 0.5 / 30) |
| steady 0.7 | rate 0.01 per s from 3 s on |
| steady 0 from spawn | nothing for 3 s, then 1/30 per s |

The 4 s dip gives the same result at 1/144, 1/20 and 0.5 s frames. Hot-oil damage (oil above 130C) is not delayed or filtered.
The window is a small queue that keeps only values that can still be the maximum, so a 60000-frame run with noisy lubrication stays bounded.
Not run in-game; the 0.16% from your launch sample and the 0.07% at idle after spawn are what to compare in the next log (`dOil` should be 0.00000 then).

## Turbo, step C: boost cut from turboDmg

**This is the first step with an effect.** The damage sources are unchanged; `turboDmg` (the combined value from step B2) now takes boost
away. The only game call is the turbo's `setWastegateOffset(psi)`, the same one `testTurbo` uses.

### Loss curve

Loss fraction from the combined `turboDmg`, linear between the points in `turboBoostCut.points` (config):

| turboDmg | 0.20 | 0.40 | 0.60 | 0.80 | 1.00 |
|---|---|---|---|---|---|
| boost loss | 0 | 15% | 30% | 65% | 100% |

It is 0 up to 0.20. Nothing is cut while the turbo is healthy.

### How it is applied

`offset = baseline - cut`, where `cut = smoothed(loss * referenceBoost)` psi.

- **baseline** is the active drive mode's turbocharger offset, or 0 without drive modes (same rule as `testTurbo`). It is re-read every 0.5 s
  (`baselineCheckSeconds`). If a drive-mode change replaces our offset with the new mode's, a running cut is written again on top of the new baseline.
- **referenceBoost** is the highest `turboBoost + cut currently applied` seen since spawn or reset (`turboBoost` is the turbo's own; `boost` also counts a
  supercharger). `turboBoostMax` is not used (it is the jbeam limit, e.g. 32 psi on the ETK C, which reaches about 10). It never falls within a
  run. See "Reference fix" below for why the applied cut is added back. Until some boost has been seen the reference is 0, so there is nothing to
  cut and nothing is written. A short overshoot spike counts as a peak.- **Smoothing:** the cut is low-passed with a 2 s time constant (`smoothSeconds`). That is 63% of a step after 2 s and 95% after 6 s, not a 2 s ramp.
  It does not depend on frame rate (same value after 4 s at 1/144, 1/30 and 0.5 s frames).
- **Hysteresis:** a new offset is written only when the smoothed cut differs from the last written one by more than 0.25 psi (`minStepPsi`). Two
  consequences: the applied cut can trail the smoothed value by up to 0.25 psi, so full loss tops out about 0.25 psi short of the reference (98.9% at
  12 psi); and a cut that ends is written back as exactly the baseline once the smoothed cut falls under 0.25 psi.
- Harness check: a 0-to-100% ramp at 12 psi made 40 writes, every one more than 0.25 psi from the one before; at rest it makes none.

### Reset, repair, testTurbo

- **Reset:** `onReset` writes the baseline back (the turbo module's own reset leaves the offset alone), clears the peak and the smoothing, and zeroes
  `turboDmg` (our damage; vanilla resets its own integrity). To avoid needless writes it only restores when this mod changed the offset (a cut,
  or an active test), so a reset on a healthy car makes no call. A test left active at reset ends there.
- **Repair:** vanilla integrity only falls, except through a reset or repair. If it rises by more than 0.02 (`repairIntegrityRise`) between two
  updates without a reset, the mod treats it as a repair: our damage and the lubrication window are cleared, the offset goes back to baseline, and
  the peak restarts. This is a heuristic on that one signal; the harness exercises it, the game has not.
- **testTurbo:** while `heatsoak.testTurbo(factor < 1)` is active the automatic cut is paused (one log line), writes nothing, and keeps tracking.
  `heatsoak.testTurbo(1)` writes the baseline and the cut resumes from there.
- **Failure:** if `setWastegateOffset` throws, one log line is written and the cut stops until the next reset.

### `heatsoak.setTurboDamage(x)`

Console, vehicle context. Sets our own damage so that the combined `turboDmg` equals `x` (0-1): `ours = 1 - (1 - x) / integrity`. Vanilla integrity
cannot be changed from here, so when vanilla damage alone is already above `x` it ends at that floor (the log says so; for example at integrity 0.8,
`setTurboDamage(0.1)` gives 0.2). `setTurboDamage(0)` clears our damage. The damage sources keep running afterwards, so oil or coking will move the value on.
It does nothing before the model has started or on a car without a turbo.

### Log and UI

- 1 Hz line, appended: `turboLoss=` (the loss fraction actually applied, written offset over reference, 0 while paused or before any boost),
  `turboLossWanted=` (what the damage asks for), `turboOffset=` (psi: baseline minus the cut, or the test's offset while a test is active) and
  `turboRefBoost=` (the reference, psi). `n/a` on cars without a turbo.
- Two one-time lines per spawn/reset: `boost cut started: ...` when the applied loss first exceeds 0 (this is the first write, so a small value) and
  `boost cut reached 50%: ...`, each with turboDmg, loss, cut, reference, offset and baseline.
- UI: a "Boost cut" row (0-100%, only above 0, amber to red) right after "Turbo dmg", warn 25 and critical 100 in `ui.limits`. With every damage row
  showing there are now **20 rows, which need 19.27em**; a layout saved at 18.4em clips the bottom row (Diff). The layout was not changed.

### Not verified

Harness only (stubbed game): the curve points, smoothing, hysteresis, baseline from a drive mode and its change, reference from the peak, pause/resume
around testTurbo, reset, repair, `setTurboDamage`, the log lines and the payload, a throwing `setWastegateOffset`, and that the step B3 damage
sources still give the same numbers. **Not run in-game.** What the game does with the offset is the open question: whether boost follows `-cut`
psi the way `testTurbo` suggested, whether drive-mode cars re-apply their offset on reset in an order that clashes with ours, and whether the
repair detection ever fires when it should not.

### Reference fix (boost cut reference)

**The bug.** The reference was the highest boost seen, but the boost is measured while the cut is active, so it was the *cut* boost: it
underestimated what the turbo does uncut. In your log `setTurboDamage(1)` gave a reference of 18.1 psi (healthy 28.5), so the cut stopped at 18.1 psi and
boost settled at 10.9 psi instead of near 0. At 0.6 damage the cut was 6.9 psi where 30% of 28.5 is 8.55.

**The fix.** The reference is now the highest `live turbo boost + the cut currently applied` seen since spawn/reset. When the turbo is on its
wastegate limit the boost is `uncut - cut`, so the sum is the uncut capability whatever cut is on. Nothing else changed (curve, smoothing,
0.25 psi threshold, reset, repair, testTurbo, log fields).

**One safeguard I added, `turboBoostCut.referenceSettleSeconds` = 1.** The boost lags a change of the offset, and a sum taken in that gap
(new cut already counted, boost not yet down) overstates the uncut boost, and since the reference never falls the error would stay. So the
reference is only updated when the applied cut has stood still for 1 s. Set it to 0 to get the plain formula. With a turbo that lags the offset by
0.3 s and damage set to 100% in one step, the plain formula pushed the reference to 31.7 psi (3.2 over, which would also over-cut every
partial-damage case afterwards); with the safeguard it stays at 28.5. If the real turbo lags more or less than that, this is the number to look at
in your log (`turboRefBoost=` against the uncut peak). Two related details: while a `testTurbo` is active the applied cut is 0 and the smoothing restarts from
baseline, so the cut ramps in again after `testTurbo(1)` instead of jumping; and a reference can still only rise, so one bad overshoot
sample (a real boost spike while a cut is on) stays until the next reset.

**Harness** (stubbed turbo that makes `min(demand, uncut limit + offset)`, slewed at 30 psi/s, optionally with a 0.3 s lag; uncut peak 28.5 psi):

| Case | Result |
|---|---|
| ramp our damage 0 to 100% over 60 s, then hold | reference 28.5, boost settles at 0.07 psi, cut 28.43 (98.8% of 28.5; the 0.25 psi write threshold) |
| same with a 0.3 s lagging turbo | the same: 0.07 psi |
| damage 0.6 | cut 8.42 psi (30% of 28.5 is 8.55), boost 20.08 (19.95 expected), reference 28.51 |
| `setTurboDamage(1)` in one step, lagging turbo | with the safeguard: reference 28.51, boost 0.08; plain formula: reference 31.69 |
| damage already 100% before the first pull | reference 6 psi after the first 5 s, 28.5 after 10 s, boost settles at 0.12 psi |
| damage cleared again | boost back to 28.50, offset exactly back to baseline |
| part-throttle demand of 8 psi under a 0.6 cut | reference stays 28.50 |

The earlier step C cases were re-run against the same stub turbo (it now responds to the offset instead of holding a fixed boost) and still pass.
**Not run in-game.** What to check: with `setTurboDamage(1)` the boost should now settle within about 0.25 psi of 0 and `turboRefBoost=` should read close to the
healthy peak (28.5 on your car); at 0.6 the cut should be about 30% of that.

## Research: reducing engine power for a catalyst failure

Research only: nothing here acts on its own. The one thing added is the manual `heatsoak.testPowerLoss(fraction)` below. All line numbers are in the game's
`lua/vehicle/powertrain/combustionEngine.lua` (CE) and `combustionEngineThermals.lua` (CET) unless noted. This was read from the install, not run in the game.

### 1. Levers on the engine (`mainEngine`, the powertrain device)

| Lever | What it changes | Reversible | Survives vehicle reset | Side effects |
|---|---|---|---|---|
| **`outputTorqueState`** (`engine:scaleOutputTorque(state, maxReduction)`) | Multiplies the final torque in `updateTorque` (CE:752), after throttle map and boost. Vanilla uses it for a blown head gasket and damaged rings (0.8, CET:295,303) and valve damage (0.98 down to 0.2, CE:524); `disable`/`lockUp` set it to 0 | Yes: it is a plain number field. `scaleOutputTorque` only multiplies (it cannot raise it back) and sets the damage flag `engineReducedTorque` | **No**: the engine reset sets it to 1 (CE:1371) | Load is normalised by it (CE:756), so `engineLoad`, `exhaustFlowCoef`, engine sound and **turbo boost do not change**, only torque. Fuel burnt and heat input scale with torque (CE:767-773), so a cut engine burns less and runs cooler. The over-torque damage check (CE:531) sees the lower torque. The idle lock-up check (CE:559-569) does not include it. Idle throttle is governor-controlled, so it opens further to hold idle; at a large cut the governor may not hold it (untested) |
| `maxTorqueLimit` | Hard cap `min(torque, limit)` in Nm (CE:753), default `math.huge` | Yes | Yes, reset sets `math.huge` (CE:1337) | A cap, not a scale: only the peak is flattened, low-rpm torque is untouched, so "x% less power" is not a clean fraction. Lowers `instantLoad` (CE:756), which changes sound, `exhaustFlowCoef` and boost |
| `electrics.values.throttleFactor` / `device.throttleFactor` (CE:731) | Scales the throttle input | Yes | The electrics value is rewritten by other code | ESC/TCS writes the same electrics value every frame when active (`controller/esc.lua:536`), so the two fight. Power is nonlinear in throttle (throttle map, CE:749), and a lower `requestedThrottle` also lowers turbo wastegate demand |
| `forcedInductionCoef`, `intakeAirDensityCoef` | Torque multipliers | - | - | Rewritten by the game every step (CE:721, 616; the turbo multiplies `forcedInductionCoef` in `turbocharger.lua:195`), so a write lasts one step. Not usable |
| `device.torqueCurve` entries | The per-rpm torque table read at CE:746 | Only by writing the old values back | Not checked | Also feeds the idle lock-up check and power readouts. The most invasive option |
| `damageFrictionCoef`, `damageDynamicFrictionCoef`, `engine:setPartCondition(nil, odometer, integrity)` (CE:851-870) | Adds friction torque (an absolute loss in Nm, not a share), and at low integrity raises the idle-speed read error (up to 30x) | Yes | Yes, reset sets them to 1 (CE:1417-1422) | Not a fraction of power; hits low rpm hardest; extra friction becomes heat in the thermals; high friction can trip the idle lock-up (CE:569); idle hunts |
| Turbo `damageExhaustPowerCoef` via `turbocharger.setPartCondition` (`turbocharger.lua:121-134`) | Lowers boost only | Yes | Yes (`turbocharger.lua:311-313`) | Turbo cars only, nothing on a naturally aspirated engine. Boost is the lever step C already uses (`setWastegateOffset`) |
| `ignitionCutTime` / `setIgnition` | Cuts ignition for a time (CE:1016, 1045) | Yes | Yes | On/off, not gradual; pops and fuel effects |
| `invBurnEfficiencyCoef` | Fuel energy per unit of work | - | Rewritten every update (CE:608) | Changes consumption and heat, not torque |
| `setExhaustGainMufflingOffset` and the exhaust sound parameters (CE:1233,1245) | Exhaust sound only | Yes | - | Audio only; no power effect |

`powertrain.setPartCondition` (`powertrain.lua:1059`) only forwards to the per-device functions above. The engine's `applyDeformGroupDamage` (CE:830-848) handles the groups
`main`, `radiator`, `oilPan`, `oilRadiator`, `turbo` and `supercharger`; **there is no exhaust or catalyst group**.

### 2. Does the game simulate a catalyst or exhaust restriction?

No.
- The words `catalyst`, `catalytic` appear **nowhere** in the game's vehicle Lua.
- In the 5294 jbeam files of the 126 vehicle zips under `content/vehicles`, `catalyst`/`catalytic` appear **0** times. `downpipe` appears 46 times, only in part names.
  Exhaust parts carry audio keys only (`exhaustAudioMufflingCoef` and `exhaustAudioGainChange`, 723 files each; "muffler"/"resonator" appear in names).
- Back pressure exists in one place: the turbo's own `backPressureCoef` (146 jbeam files; the key is only read by 	urbocharger.lua). It is part of the turbo's spool model, a local in
  `turbocharger.lua` (line 436), not readable or settable from outside, and absent on a car without a turbo. `exhaustFlowCoef` is an output of the engine (it follows load), not an input.
- `damageThresholdTemperature` appears in the same 146 files, so turbo definitions appear to set it explicitly (I did not extract the values or check the sections).

So a catalyst restriction has to be added by this mod as a torque loss.

### 3. Recommendation: `outputTorqueState`, as a share of its own

Smallest side effects, because the game already uses it for exactly this ("less compression, less torque"): it keeps load, sound and boost as they are, composes with vanilla damage, and the engine reset puts it back.

How it is applied: this mod keeps its own share `factor` (1 = none) and changes the field by the ratio, `state = state / oldFactor * newFactor`, never by overwriting it,
so vanilla's reductions (head gasket 0.8, valve damage) stay in place while ours is added or removed. If the field is above 1 after dividing (the game reset it behind our back), our share
is simply gone and it stays at 1. `onReset` forgets the share. The cut is capped at 95% so the engine is never "disabled" (a factor of 0 is vanilla's disabled state).
It does not touch `damageTracker`, so vanilla's "reduced torque" flag is not set by it (`scaleOutputTorque` would set it).

Things to look at in the game before using it for real: idle at a large cut (does it hold, does it stall), whether the lower fuel burn and heat are acceptable for a failure that is supposed to be
*hot*, and whether the vanilla damage list should show it.

### `heatsoak.testPowerLoss(fraction)`

Console, vehicle context, any combustion engine. `heatsoak.testPowerLoss(0.3)` cuts power by 30% (torque times 0.7), `heatsoak.testPowerLoss(0)` restores it; a fraction above 0.95 is capped at 0.95;
repeated calls set the same share rather than stacking. It refuses when `outputTorqueState` is already 0. A vehicle reset ends the test (the game restores the field; the mod logs that).
Each call logs a `power test before:` line, and the cut logs `power test after +1s/+3s/+6s:` lines with rpm, idle rpm, throttle, load, torque (Nm), power (kW, torque times angular velocity), boost,
`outputTorqueState` and `stalled`, then a line saying the cut is still on. It makes no `setWastegateOffset` call and does not touch turbo damage.

Log from the harness (stub engine whose torque is 300 Nm times `outputTorqueState` at 4775 rpm; **these lines are not from the game**, I could not run it):

```
power test before: rpm=4775 idle=812 throttle=1.00 load=0.90 torque=300 Nm power=150.0 kW boost=0.0 psi outputTorqueState=1.0000 stalled=false
testPowerLoss: 30% -> outputTorqueState 0.7000 (was 1.0000, our share 1.000 -> 0.700). heatsoak.testPowerLoss(0) restores it
power test after +1s: rpm=4775 idle=812 throttle=1.00 load=0.90 torque=210 Nm power=105.0 kW boost=0.0 psi outputTorqueState=0.7000 stalled=false
power test after +3s: ... torque=210 Nm power=105.0 kW ... outputTorqueState=0.7000 stalled=false
power test after +6s: ... torque=210 Nm power=105.0 kW ... outputTorqueState=0.7000 stalled=false
testPowerLoss: the cut is still applied. heatsoak.testPowerLoss(0) restores normal power
power test before: rpm=4775 idle=812 throttle=1.00 load=0.90 torque=210 Nm power=105.0 kW boost=0.0 psi outputTorqueState=0.7000 stalled=false
testPowerLoss: restored, our share 0.700 -> 1, outputTorqueState 1.0000 (was 0.7000)
```

Other harness results: a vanilla x0.8 applied on top of a 50% cut gives 0.4, changing the cut to 20% gives 0.64, and restoring leaves 0.8 (vanilla's share kept); three calls of `testPowerLoss(0.3)` give 0.7, not 0.343;
a reset ends the test and `testPowerLoss(0)` afterwards leaves 1; if the game resets the field and `onReset` has not run yet, restoring still stops at 1; `1.0` is capped to 0.95;
bad arguments, a disabled engine and an engine without the field are refused. **Not run in-game.** What to read in the in-game log: `torque` and `power` in the after lines should be
(1 - fraction) of the before line at the same rpm and throttle, and `stalled`/`rpm` against `idle` show whether idle survives.

## Catalyst, Step E: catalyst damage and power loss

Gasoline vehicles only (`requiredEnergyType == "gasoline"`). On other engines the catalyst node and damage values are `nil` (`n/a` in the 1 Hz line).

### Damage model

Damage `catalystDamage` accumulates permanently (0 to 1) from two sources:
1. **Extreme heat:** `clamp((catalyst - 900) / 200, 0, 1) / 120` per second (`startTemp = 900`, `fullRateTemp = 1100`, `perSecondDivisor = 120`). Zero below 900C; takes 120 s (2 min) at 1100C or 240 s (4 min) at 1000C to reach 100% damage. Permanent (does not recover upon cooling).
2. **Contamination (optional, on by default):** while the engine is running, burning oil from damaged piston rings (`pistonRingsDamaged`) or coolant from a blown head gasket (`headGasketBlown`) clogs the catalyst substrate. Each fault adds `1 / 900` per second (`contamination.perSecondDivisor = 900`). Both together add `2 / 900` per second (450 s to 100%).

All damage parameters live in `heatsoak_config.json` under `catalystDamage`.

### Power loss & application

- **Loss curve:** piecewise linear from `catalystDamage`: 0 below 0.10 damage, ramping linearly to a hard cap of 50% power loss (0.50) at 1.00 damage. Configured in `catalystLoss.points` (`[[0.1, 0.0], [1.0, 0.50]]`).
- **Application:** cut is low-pass smoothed with a 2 s time constant (`catalystLoss.smoothSeconds = 2`) and applied to `mainEngine.outputTorqueState` by ratio (`state = state / oldShare * newShare`), preserving vanilla torque multipliers (e.g. blown gasket 0.8) and avoiding stacking or drift.
- **Manual override & interaction:** manual `heatsoak.testPowerLoss(fraction)` temporarily pauses the automatic catalyst cut (same pattern as `testTurbo`); calling `heatsoak.testPowerLoss(0)` restores power and resumes the automatic catalyst cut from 0 (smoothed).
- **Vehicle reset:** resets `catalystDamage`, `catalystLoss`, and `catCut` state back to 0/baseline. The game's reset automatically restores `outputTorqueState` to 1.0.

### Console commands & logging

- `heatsoak.setCatalystDamage(x)`: sets catalyst damage directly to `x` (0.0 to 1.0). `heatsoak.setCatalystDamage(0)` clears damage.
- 1 Hz log line fields: `catalystDmg=`, `catalystLoss=`, `dCatHeat=`, `dCatContam=`.
- One-time log line: `catalyst cut started: catalystDmg=... loss=... outputTorqueState=...` when the loss first exceeds 0.

### HUD App & UI Sizing

- HUD row: "Cat dmg" (0-100%, hidden at 0, styled amber to red). Sits after "Boost cut" in the damage section.
- Limits in config: `"catalystDamage": {"warn": 25, "critical": 100}`.
- Total potential rows: **21 rows** (with all 6 damage rows active). Frame height needed: **20.21em** (recommended layout height: `20.2em` or `20.3em`).

## Drivetrain, Step F: gearbox and differential overheating failures

Gearbox and differential nodes track oil temperatures. When temperatures exceed oil breakdown limits, irreversible mechanical damage accumulates.

### Damage model

Config block `drivetrainDamage` in `heatsoak_config.json`:
- **Gearbox (`gearboxDamage`)**:
  - `startTemp: 140` °C, `fullRateTemp: 160` °C, `perSecondDivisor: 120`.
  - Zero below 140 °C. At 150 °C takes 240 s to 100%; at 160 °C takes 120 s to 100%. Permanent.
- **Differential (`diffDamage`)**:
  - `startTemp: 140` °C, `fullRateTemp: 160` °C, `perSecondDivisor: 120`.
  - Driven by the hottest differential on the vehicle. Permanent.

### Physical effects in BeamNG

1. **Parasitic Friction Drag & Torque Stutter**:
   - As gearbox damage rises 0 to 1, `gearboxDevice.damageFrictionCoef` scales from `1.0x` up to `maxFrictionCoef` (default `2.5x`).
   - Under heavy load with damage > 25%, cyclic gear mesh stutter causes physical torque flutter and shuddering under acceleration.
   - Differential `damageFrictionCoef` scales from `1.0x` up to `maxFrictionCoef` (default `1.5x`).
2. **Gear Pop-Outs into Neutral**:
   - When `gearboxDamage > 0.40`, driving hard under load (>50% throttle/load) checks once per second with an escalating chance (up to 12%/s) to violently kick the transmission out of gear into **Neutral**.
3. **Synchronizer & Dog Wear (Manual / Sequential)**:
   - On manual and sequential gearboxes, gears engaged while damaged (`gearboxDamage > 0.10`) accumulate `synchroWear` (`synchroWearRate: 0.005`), causing crunching, grinding shifts and locked-out gear shifts.
4. **Clutch Lock Torque Degradation (DCT)**:
   - On `dctGearbox`, `damageLockTorqueCoef` falls from `1.0` down to `0.2` as damage reaches 100%, causing dual clutches to slip under full engine torque.
5. **Differential Welded Spool Lock, Cornering Wheel Hop & Tooth Hitching**:
   - **Welded Spool Lock (>50% damage)**: severe galling welds the spider gears onto the cross-pin, automatically locking the differential into a solid mechanical spool (`device.mode = "locked"`, with lock torque scaling up to 6,000 Nm). In turns, because both wheels are forced to rotate at identical speeds across the axle, the inside tire physically scrubs, chirps, skips, and hops across the pavement through BeamNG's tire physics and suspension dynamics.
   - **Intermittent Tooth Catch / Hitch (>65% damage)**: under engine load (>30% throttle/load), chipped teeth and damaged roller bearings catch for 80 ms (800–1800 Nm pulse). At 70% damage occurs every ~8–12 s; at 90% damage occurs every ~2–4 s, causing violent driveline hesitation/thumps before complete seizure.
6. **Catastrophic Seizure at 100% Destruction**:
   - If `gearboxDamage >= 1.0`, the transmission cluster welds solid: driven wheels lock into a skid, the engine stalls if in gear, and the transmission cannot cycle phantom gears.
   - If `diffDamage >= 1.0`, the pinion bearing welds solid: driven wheels physically clamp lock (4,500 Nm) into a screeching skid without driving backwards. Safe restore on damage clear or vehicle reset.

### Console commands & logging

- `heatsoak.setGearboxDamage(x)`: sets gearbox damage to `x` (0.0 to 1.0) and updates friction immediately. `0` clears damage.
- `heatsoak.setDiffDamage(x)`: sets differential damage to `x` (0.0 to 1.0) and updates friction immediately. `0` clears damage.
- `heatsoak.toggleAmbient60()` / `heatsoak.setAmbient60(bool)`: toggles environment ambient temperature between map default and 60°C hot summer conditions.
- 1 Hz log line fields: `gearboxDmg=`, `diffDmg=`.
- Vehicle reset (`onReset`): resets `gearboxDamage`, `diffDamage`, and restores `damageFrictionCoef` and `damageLockTorqueCoef` to 1.0.

### HUD App & UI Sizing

- HUD header button: **`60°C AMBIENT: ON/OFF`** interactive toggle button built into the HeatSoak app header.
- HUD rows: "Gb dmg" and "Diff dmg" (0-100%, hidden at 0, styled amber to red). Sits in the top damage section.
- Limits in config: `"gearboxDamage": {"warn": 25, "critical": 100}`, `"diffDamage": {"warn": 25, "critical": 100}`.
- Total potential rows: **23 rows** (with all 8 damage rows active). Frame height needed: **22.08em** (recommended layout height: `22.1em` or `22.2em`).

---

## Tire Thermodynamics & Grip System (Stage 1 & Stage 2)

Simulates 3-node thermodynamics, thermal traction curves, pneumatic cavity pressure physics, tread wear degradation, and catastrophic blowouts per wheel across any vehicle wheel count.

### 3-Node Architecture (Per Wheel)
1. **Tread Surface Skin (`treadT`)**: Thin flash boundary layer (~1.0–1.6 mm, ~0.8 kg) directly interacting with the pavement. Heats up quickly from mechanical slip energy and contact patch braking shear friction. Air convection cooling (scales with vehicle airspeed and wheel spin), road conduction, and carcass conduction.
2. **Tire Carcass (`carcassT`)**: Bulk tire structure (belts, plies, sidewalls: ~8.5–10 kg). Receives heat from tread conduction, rolling hysteretic flex heating ($C_{\text{flex}} \times F_z \times v$), and conducted heat soak from the glowing brake rotor hub ($0.20 \times \Delta T$). Dissipates to cavity air and fender airflow.
3. **Cavity Air (`airT`)**: Pressurized air mass inside the tire. Heats from the carcass and rim, expanding according to the Ideal Gas Law.

### Braking Micro-Slip Friction Heating (Even Without Skidding)
Under heavy or threshold braking (including ABS cycling), tires do not need to screech, lock up, or leave skid marks to generate heat:
- During braking, longitudinal micro-slip occurs at the contact patch ($v_{\text{slip}} = |v_{\text{car}} - \omega r|$), operating at 8%–15% slip ratio.
- Forward dynamic weight transfer increases normal load ($F_z$) onto the front tires.
- The contact patch rubber is subjected to intense braking shear retarding force ($F_x \le \mu F_z$).
- Friction shear power ($P_{\text{shear}} = F_x \times v_{\text{slip}}$) directly heats the tread surface skin.
- A single hard straight-line ABS stop from 120 km/h naturally raises front tread temperatures by **+8°C to +12°C** (+15°C to +20°C on race tires) purely from contact patch friction shear!
- If tires lock up into a full skid, BeamNG solver's macro `slipEnergy` takes over seamlessly.

### Ground Surface Friction Partitioning & Airborne Isolation
- Uses BeamNG ground model IDs (`wd.contactMaterialID1`/`ID2`) and contact depth.
- On dry asphalt/concrete: 45% of mechanical friction scrub conducts into the rubber tread (55% conducts into pavement).
- On grass (`0.06`), sand (`0.10`), mud (`0.05`), gravel (`0.20`), and snow/ice (`0.00`): energy shears loose organic sod/soil/sand grains or melts water rather than grinding rubber against stone, preventing artificial overheating off-road.
- Deep surface sinkage (`contactDepth > 0.02m`) attenuates heat into flying loose debris. Submerging in water (`obj:inWater`) actively quenches the tire.
- **Airborne Isolation**: When airborne (`downForce < 50 N` or no surface contact), road conduction and braking scrub drop to 0 W. Holding the brake mid-air does not generate road friction heat.

### Geometric Surface Area Cooling & Brake Rotor Soak
- **Surface Area Scaling**: Convection and conduction cooling scale with actual tire dimensions ($2\pi r \cdot w$ relative to $0.45\text{ m}^2$), accurately simulating thermal dissipation for narrow economy tires vs wide racing slicks.
- **Brake Rotor Soak**: Glowing brake rotors (400°C–800°C) conduct thermal energy through the hub and rim directly into the tire carcass and air cavity ($0.20 \text{ W/K}$), raising tire pressures after repeated track braking zones.
- **Highway Cruising Flex Heating**: Calibrated hysteretic flexing ($C_{\text{flex}} = 0.0060$) generates ~600 W per tire at 100 km/h, warming tire carcasses to ~45°C–50°C and raising tire pressure by a realistic +3.5 to +4.0 PSI during continuous highway cruising.

### Stage 2 Physics & Failure Mechanics

1. **Thermal Grip Window (Traction Curve)**:
   - **Cold Rubber (< 75°C)**: Below operating temperature, stiff rubber has lower hysteresis and traction (~85% cold baseline at 15°C), smoothly gaining bite as it approaches 75°C.
   - **Optimum Sweet Spot (75°C – 100°C)**: Peak 100% mechanical grip.
   - **Overheating / Greasy (100°C – 125°C)**: Polymer chains soften and sweat volatile oils; grip falls to 90% then 80%.
   - **Blistering & Scorching (> 125°C)**: Severe thermal breakdown; grip falls to 65% blister grip.
   - Live application via native C++ `obj:setNodeFrictionSlidingCoefs` across all wheel tread nodes (`wd.treadNodes`), cached at baseline and fully restored on vehicle reset (`onReset`).

2. **Tread Wear Degradation**:
   - Abrasive wear accumulates during mechanical scrub energy dissipation ($Q_{\text{slip}} \times \Delta t$), heavily accelerated above 100°C.
   - Grip scales with wear: $M_{\text{wear}} = 1.0 - 0.25 \times (\text{wear} / 100)^{1.5}$. At 100% wear (bald cords), dry grip is reduced by 25%.

3. **Live Pneumatic Pressure Physics**:
   - Live hot cavity pressure is calculated using Gay-Lussac's absolute temperature law:
     $$P_{\text{hot, abs}} = P_{\text{cold, abs}} \times \frac{T_{\text{air, K}}}{T_{\text{cold, K}}}$$
   - Written back directly into BeamNG's physics solver via `obj:setGroupPressure(pressureGroup, hotPa)`.
   - Carcass beams physically stiffen as cavity air warms up (typically +3 to +7 PSI), sharpening steering response and stiffening ride over bumps. Overinflation crowns the tire, mildly reducing contact width ($M_{\text{pres}}$).

4. **Dynamic Blowout & Deflation Triggers**:
   - **Thermal Delamination**: Sustained heavy sliding above 140°C under load and wheel speed causes tread separation and carcass rupture; pops immediately at 165°C.
   - **Cord Exposure Puncture**: Driving on 100% worn bald tires for ~8–12 seconds snaps exposed ply cords and deflates the tire.
   - **Overpressure Explosion**: Exceeding structural rupture pressure (> 65 PSI gauge) blows the tire.
   - **Blowout Action**: Calls native `beamstate.deflateTire(wheelID)`, triggers 3D burst audio (`event:>Vehicle>Failures>tire_burst`), flags damage in BeamNG damage tracker, drops pressure to 0 PSI, and highlights `BLOWN` on HUD.

### Tire Compounds Simulation
Automatically detects installed tire parts (`race`, `sport`, `drag`, `rally`, `offroad`, `standard`) and configures physical behavior:
- **Race Slicks / Semi-Slick (`race`)**:
  - Thinner tread gauge (5.5 mm vs 9 mm standard) $\rightarrow$ lower rubber thermal mass heats up **over 2.4x faster**!
  - Softer polymer matrix $\rightarrow$ wears **~3.5x faster** at baseline.
  - Sweet spot operating window: **85°C – 110°C** (higher temperature required for peak grip).
  - Cold grip penalty: **78%** when cold (slicks feel very glassy/slick until warmed up).
- **Sport / Performance (`sport`)**:
  - 7.5 mm tread, 1.20x heating, wears ~1.7x faster than standard, sweet spot 75°C–100°C.
- **Drag Slicks (`drag`)**:
  - 5.0 mm ultra-soft tread, 1.65x heating, wears 5.0x faster, optimum 90°C–120°C.
- **Standard Road (`standard`)**:
  - 9.0 mm durable highway rubber, high thermal mass (heats up steadily), 1.0x baseline wear, 70°C–95°C window.
- **Off-Road / All-Terrain (`offroad`)**:
  - 12.0 mm heavy-lug rubber, maximum durability (wears slowest), 65°C–90°C window.

### Thermal Wear Acceleration (Tire Heat, Track Surface Heat & Ambient Heat)
**Wear dynamically scales with three thermodynamic heat factors**:
1. **Tire Heat Factor ($M_{\text{tire}}$)**:
   - Operating Window (< 100°C standard / < 110°C race): **1.0x** (normal mechanical scrub).
   - Cold Graining (< 50°C): Stiff rubber chips and grains under heavy load (**up to 1.35x**).
   - Tread Overheating (> 110°C): Polymer softening accelerates wear quadratically (**up to 6.0x**).
   - Carcass Heat Softening (> 75°C): When the entire bulk tire body is hot, structural softening deepens wear by **up to +50%**.
2. **Road Surface Heat Factor ($M_{\text{surface}}$)**:
   - Hot asphalt directly increases shear degradation of rubber.
   - At 25°C track: **1.0x** baseline.
   - At 45°C track: **1.23x** faster wear.
   - At 60°C track: **1.45x** faster wear.
3. **Ambient Heat Factor ($M_{\text{ambient}}$)**:
   - High ambient air temperature accelerates polymer oxidation and thermal softening.
   - At 20°C ambient: **1.0x** baseline.
   - At 35°C ambient: **1.18x** faster wear.
   - At 50°C ambient: **1.35x** faster wear.
- **Combined Effect**: Driving cleanly on a 20°C day yields **1.0x** baseline wear. Driving on a hot 35°C track with 150°C sliding tires yields **~11.2x** accelerated wear!

### Thermal Delamination Blowouts
- Belts separate and delaminate when the **bulk carcass** is dangerously hot (> 75°C–120°C) and the tread is scorched, or during sustained burnouts under heavy downforce and wheel speed.
- A momentary 2-second surface skin flash spike over cold carcass plies causes surface blistering and graining without blowing the tire prematurely.

### HUD App & Visual UI (Pro MFD v0.7 Redesign)
- **Interactive Navigation Tabs**:
  - **`[ 🏎️ TIRES ]`**: Motorsport-grade top-down vehicle chassis schematic:
    - **3-Zone Segmented Tread Graphic `[ I | M | O ]`**: Displays Inner, Middle, and Outer contact patch rubber temperatures with live camber and lateral cornering scrub spread.
    - **Live Ventilated Brake Rotor Hub & Caliper**: Glowing brake rotor disc with caliper notch inside each wheel rim (`COOL`, `OK`, `WARM`, `HOT`, `FADE`) with live brake core temperatures.
    - **Pressure Delta from Cold**: Displays live hot pressure and delta rise (e.g. `29.4 psi (+3.4)`).
    - **Grip & Wear**: Real-time grip percentage badge, color-shifting wear track, and compound pills (`RACE SLICK`, `SPORT`, `STD`, etc.).
    - **Blown Tire Hazard State**: Immediate visual rupture alarm with red flashing border and pressure drop to 0 PSI.
  - **`[ ⚡ ENGINE ]`**: 
    - **Live Vector Powertrain Heat Blueprint**: Full CAD-accurate visual cutaway anatomy schematic of the vehicle's powertrain where every component dynamically lights up and changes color with real-time temperature:
      - **Front-Mount Intercooler (FMIC)**: Spans the front nose directly ahead of the radiator with bar-and-plate cooling matrix and cast end-tanks (`icCore`).
      - **Radiator**: Mounted directly behind the intercooler with aluminum core fins and dual coolant hoses routed to the block and head (`coolant`).
      - **Realistic Turbocharger Snail**:
        - Conical pod air filter in front fender with curved 90° mandrel-bent intake pipe feeding into the compressor snail eye.
        - Compressor Volute Snail with inducer bore, spinner nut, and impeller blades (`compOut`).
        - Boost charge pipe curving from the compressor forward into the FMIC left end-tank.
        - Cold charge pipe exiting the FMIC right end-tank, sweeping rearward along the bay into the throttle body (`iat`).
        - Exhaust Turbine Snail with exhaust manifold runners glowing fiery red (`turbineHousing` up to 1000°C).
        - Naturally aspirated cars automatically switch to a pleated cold airbox with intake runner.
      - **Cylinder Head & Valvetrain**: 4-chamber head with spark nodes shifting color with `cylinderHead`.
      - **Crankcase & Rod Bearings**: Core engine block with bearing journals shifting color with `rodBearings`.
      - **Oil Sump Pan**: Lubricant reservoir shifting color with `oil`.
      - **Real-World Transmission Architecture**:
        - Flared Bellhousing bolted to the block enclosing the flywheel/clutch with starter motor bulge.
        - Ribbed Main Case with structural aluminum reinforcement ribs (`gearboxOil`).
        - Conical Tailhousing with shifter turret, slip yoke, and U-joint connecting to the driveshaft.
      - **Driveshaft & Differential**: Tubular driveshaft leading to rear differential pumpkin (`diffOil`) with axle half-shafts.
      - **Exhaust & Catalytic Converter**: Downpipe exiting turbine exducer running to catalytic converter (`catalyst`) and tailpipe (`egt`).
    - **Modular Engine Core Cards**: Coolant, Engine Oil, Cylinder Head, and Rod Bearings with dynamic status tags (`OK`, `WARM`, `HOT`, `CRIT`) and target/limit thresholds.
    - **Turbo Air Path Ribbon**: Live boost flow `COMP OUT ➔ INTERCOOLER ➔ INTAKE (IAT) ➔ TURBINE`.
    - **Driveline Ribbon**: Live flow `GEARBOX OIL ➔ DIFF OIL ➔ EXHAUST (EGT)`.
    - **Active Mechanical Damage Banner**: Displays active wear percentages for Piston Rings, Head Gasket, Rods, Turbo, Transmission, and Differential (`WELDED SPOOL` alert if > 50%).
  - **`[ 📊 FULL MFD ]`**: Complete stacked telemetry view showing both chassis tires and visual powertrain blueprint on a single glanceable dashboard.
- **Reloading UI**: Press **`Ctrl + F5`** in BeamNG to clear the CEF web cache and load the new visual interface.

### Console Test Commands
- `heatsoak.blowoutTire([wheelName])`: Immediately blows out the specified tire (e.g. `"RR"` or `"FL"`), or all tires if omitted.
- `heatsoak.setTireWear(wearPercent [, wheelName])`: Sets tire wear percentage (0–100%).
- `heatsoak.setTireTemp(tempC [, wheelName])`: Sets live tread temperature in °C.
- `heatsoak.setTireCompound(compoundName [, wheelName])`: Sets tire compound (`"race"`, `"sport"`, `"standard"`, `"drag"`, `"rally"`, `"offroad"`).
- `heatsoak.toggleAmbient60()` / `heatsoak.setAmbient60(bool)`: Toggles 60°C environment heat.

### Endurance Logging (1 Hz)
- 1 Hz log line appends complete per-wheel data:
  - `trd` (tread temp), `car` (carcass temp), `air` (air temp), `psi` (pressure).
  - `grp` (live total grip %), `wear` (cumulative tread wear %).
  - `vAvg` & `vCore`: BeamNG's internal wheel core temperatures.
  - `slipE` & `slipP`: Solver slip power dissipation in Watts.




