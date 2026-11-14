# Real Routes and Engine Physics (0.18.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The rough estimate for empty lines and the speed row use the real track route between the stops (from the game's pathfinder) instead of the straight line, and the speed physics follows the engine's rules (empty weight, rolling friction per tonne, doubled tractive effort, top-speed fade) once each rule is confirmed in game.

**Architecture:** `track_limits.lua` (shared with tpf3-top-speed) gets an engine helper that turns any path entry list into its edge entries. A new pure module `line_route.lua` keeps a per-line route cache (one `track_limits.summarize` per section) that the existing 2 s sampler fills within a time budget; its engine adapter lives in `rate_preview.script.lua` (stops → terminal nodes → `api.engine.util.pathfinding.findPathNodeToNode`). The calibration fits its travel model on route lengths when the target line and enough reference lines have a route, else on straight lines as today. `rate_model.lua` gets the physics constants and the fade; the script feeds it empty weight.

**Tech Stack:** Lua 5.1 / LuaJIT (game GUI state), plain `luajit` test scripts in `test/`.

**Spec:** Design section below (agreed in chat 2026-11-13). Background: Vehicle Power Tooltip 6419746 rev 7 `physics.txt` (decompiled engine formulas, partly tested by its author) and our own gradient measurement of 2026-10-18 (`CLAUDE.md`, "Gradients").

## Design

- **Pathfinder.** `api.engine.util.pathfinding.findPathNodeToNode({fromNode}, {toNode}, {modes})` returns the edges between two nodes (`game-src/api_tealdef/api/engine/util.d.tl:398`). Node of a stop: `STATION_GROUP.stations[stop.station + 1]` → `STATION.terminals[stop.terminal + 1].vehicleNodeId`. Section i runs from stop i to stop `i % n + 1` (closed round trip), the same order as `lineSectionsWithTrack` and track_limits' key `i % n`. Waypoints are ignored in 0.18.0 (a line with waypoints keeps the straight-line basis for that section, see Task 3).
- **Route cache.** Per line: `{ fp, at, sections = { [i] = summary or false }, length = m or nil }`, `fp` = fingerprint of the stops (station, terminal per stop) plus the mode set; a changed fingerprint or an age above `MAX_AGE` re-reads the line. `length` is set only when every section has a summary. Filled in the 2 s sampler step: wanted lines (store open) first, then all player lines of the carriers that have a mode set; budget per step like track_limits.
- **Section priority in the speed row:** track_limits section (driven, newest) > route section > straight line.
- **Calibration basis.** Each reference sample keeps `straight` and, when known, `route`. The target line decides: route length known and at least `MIN_FIT_SAMPLES` (6) same-basis samples (same kind, or the whole carrier as today) → basis "route", else "straight". Never mix the two in one fit. The rough log line names the basis and also prints the straight-basis rate, so one store visit compares both.
- **Physics** (each rule only after Task 5 confirms it): mass = empty weight; rolling resistance = μ × mass kN with μ = 0.02 for rail (road/tram per Task 5, keep the old per-part value where unconfirmed); pull = min(2 × TE, P / v); fade above 95 % of (limit + 0.136 m/s): `x = clamp((v / (limit + 0.136) − 0.95) × 20, 0, 1)`, positive acceleration × (1 − x²); limit = min(top speed, section cap). Brake stays 2.5 m/s².
- **Gating** (memory "gate expensive features behind a param"): route reading for all lines only while `roughEstimate` is On; the target line's route only while `roughEstimate` or `reachableSpeed` is On; both Off → no pathfinder call at all.

## Global Constraints

- `track_limits.lua` stays byte-identical in tpf3-rate-preview and tpf3-top-speed; `API_VERSION` stays 3 (the Collector interface does not change); `LOG_READS = false`.
- Route budget: at most `line_route.TIME_BUDGET = 0.003` s of path reading per 2 s step, at least one section per step, `MAX_AGE = 300` s, `MAX_SECTIONS_PER_STEP = 4`.
- No new per-frame work: the cart text keeps its 2 s cache; the store only reads the cache.
- Lua: never `_` as a loop variable in GUI code (use `__`); no `rawget`/`rawset`; `luajit -bl` for every changed file; tests run from the repo root with `luajit test/<name>_test.lua`.
- Log lines start with `[kampfmoehre_rate_preview]`; route lines with `[kampfmoehre_rate_preview] route:`.
- Texts English first, German in `strings.json` `de` (0.18.0 adds no visible text unless a task says so).
- Version `local VERSION = "0.18.0"`, `revision` 11 in `mod.json` (Task 7).
- No commits unless the user asks; each task ends with tests + `./sync.sh` and tells the user what to check in game.

## Review Focus

- Pathfinder returns nothing for a stop pair (not connected, wrong modes, ships/aircraft) → that section stays straight-line, the line has no route `length`, one log line per line and reason, no error spam. Test in Task 2 (`fails` adapter) and Task 3 (in game: an aircraft line).
- Line edited while its route is cached (stop added, removed, moved to another terminal) → fingerprint differs → re-read; a cached section count never meets a different stop count. Test in Task 2.
- Big save (~100 lines): the cache fill stays inside the budget per step; the target line has its route a few seconds after the store opens. Test in Task 2 (budget with a fake clock) and Task 3 (in game: timing log).
- Target line has a route but fewer than 6 reference samples do → straight basis, no mixed fit. Test in Task 4.
- Both params Off → no pathfinder call; `reachableSpeed` Off and `roughEstimate` On → routes for calibration, no speed row. Test in Task 3 (in game, log counter).

---

### Task 1: Probe the pathfinder in game

Answers what the plan cannot know: which mode sets find paths per carrier, the cost per call, and whether route lengths match the driven sections. Gate for Tasks 2-4: if one section costs more than ~20 ms on the big save, stop and redesign the budget with the user.

**Files:**
- Create: `kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/route_probe.lua` (temporary)
- Modify: `kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/rate_preview.script.lua` (one guarded call in the entry plugin's `react.onMount`)
- After the run: move the probe to `docs/probes/route_probe/route_probe.lua` + `docs/probes/route_probe/README.md` (results), remove the call.

- [ ] **Step 1: Write `route_probe.run(tracks)`**

Runs once, 30 s after load (count steps in the existing `trackStep` timer). For up to 20 player lines (all carriers): per section, the terminal nodes as in the Design; for each candidate mode set `RAIL {TRAIN, ELECTRIC_TRAIN}`, `RAIL {TRAIN}`, `ROAD {BUS}`, `ROAD {TRUCK}`, `ROAD {CAR}`, `TRAM {TRAM, ELECTRIC_TRAM}`, `WATER {SHIP, SMALL_SHIP}`, `AIR {AIRCRAFT, SMALL_AIRCRAFT, HELICOPTER}` call `findPathNodeToNode` in `pcall`, time it with `api.type.Clock`, and log one line: `route probe line L carrier C section i modes M: ok/err, entries N, metres X (sum of TRANSPORT_NETWORK geometry.length), straight Y, driven Z (tracks:section(line, i % n).length or -), ms T`. Also log `tostring(api.type.enum.Carrier.X)` for RAIL/ROAD/TRAM/WATER/AIR and the type of one result entry (`e[1]`, `e[2]`, `e.edgeId`, `e.dir`).

- [ ] **Step 2: Syntax check and sync**

Run: `luajit -bl kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/route_probe.lua >/dev/null && ./sync.sh`
Expected: no output from luajit, "synced -> …".

- [ ] **Step 3: User runs it on the big save and on the mods-test save**

Expected in `stdout.txt`: `route probe` lines. Record in the README: working mode set per carrier (and which kind: bus/truck), median and max ms per section, route vs driven length (should agree within a few %), entry format.

- [ ] **Step 4: Fix `line_route.MODES` from the result**

Write the table into the README; Task 2 copies it verbatim. Move the probe to `docs/probes/route_probe/`, remove the call, sync.

---

### Task 2: Route cache (`line_route.lua`) and the shared edge helper

**Files:**
- Modify: `kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/track_limits.lua` (engineAdapter: new `edgesOfPath`)
- Copy afterwards: `../tpf3-top-speed/kampfmoehre_top_speed_1/content/gui/kampfmoehre_top_speed/track_limits.lua` (byte-identical)
- Create: `kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/line_route.lua`
- Create: `test/line_route_test.lua`

**Interfaces:**
- Produces: `adapter.edgesOfPath(entries) -> { edge entry, ... }` in `track_limits.engineAdapter(owner)` (same entry format as `pathEdges`; `pathEdges(v)` becomes `edgesOfPath(mp.path.edges)`).
- Produces: `line_route.MODES = { [carrierName] = { kind = { modeName, ... } } }` from Task 1 (`kind` = "pax" | "cargo" | "any").
- Produces: `line_route.new(adapter) -> cache` with `cache:want(line, now)`, `cache:step(lines, now)`, `cache:route(line) -> { length = m or nil, sections = { [i] = summary or false }, n }` or nil, `cache:reset()`.
- Adapter for `new`: `lineStops(line) -> { { node = NodeId or nil, key = string }, ... }, modes` (`modes` nil = carrier has no route), `path(fromNode, toNode, modes) -> edges or nil, reason`, `clock() -> s`, `log(msg)`.

- [ ] **Step 1: Write the failing tests in `test/line_route_test.lua`**

Fake adapter with lines `{ [1] = 3 stops, 2 sections of 1000 m flat 100 km/h, one section 500 m }`, a counter of `path` calls and a fake clock that advances 1 ms per call. Assertions:
- `route_complete`: after enough `step` calls `route(1).length == 2500`, `#sections == 3`, `sections[3].length == 500`.
- `route_failed_section`: `path` returns nil for section 2 → `sections[2] == false`, `length == nil`, exactly one `log` line for line 1.
- `route_fingerprint`: change line 1's stop keys → next `step` re-reads it (`path` count rises by 3), old sections are gone.
- `route_max_age`: `step(lines, now + 301)` re-reads; `now + 299` does not.
- `route_budget`: with 5 lines and `TIME_BUDGET = 0.003`, one `step` makes at most 4 `path` calls and at least 1.
- `route_want_first`: `want(5, now)` → the first `path` call of the next `step` is for line 5.
- `route_no_modes`: `lineStops` returns `modes == nil` → no `path` call, `route(line) == nil`.

- [ ] **Step 2: Run, expect failure**

Run: `luajit test/line_route_test.lua`
Expected: error `module 'line_route' not found`.

- [ ] **Step 3: Implement `line_route.lua`**

Pure module (no `api` at require time), structure like `track_limits.Collector`: constants `MAX_AGE = 300`, `TIME_BUDGET = 0.003`, `MAX_SECTIONS_PER_STEP = 4`, `WANT_SECONDS = 5`; reads one section per visit (`summarize(adapter.path(...))` via the `summarize` function passed in `new(adapter, summarize)` — the script passes `track_limits.summarize`, the test a stub), so a long line spreads over several steps. `fp` = concatenated stop keys + modes.

- [ ] **Step 4: Add `edgesOfPath` to `track_limits.engineAdapter`**

Factor the loop of `pathEdges` into `edgesOfPath(entries)`; `edgeIdOf` already accepts `e[1]`, the direction `e[2]`. Run both suites: `luajit test/track_limits_test.lua && luajit test/line_route_test.lua` → all `ok`. Copy the file to tpf3-top-speed and run its suite: `(cd ../tpf3-top-speed && luajit test/track_limits_test.lua)`; check `cmp` of both copies.

- [ ] **Step 5: Syntax check and sync**

Run: `luajit -bl` on both changed modules, `./sync.sh`.

---

### Task 3: Route sections in the game (sampler, speed row)

**Files:**
- Modify: `kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/rate_preview.script.lua` (adapter, sampler step, `lineSectionsWithTrack`, `contextFromEvent` want)

**Interfaces:**
- Consumes: Task 2 (`line_route.new`, `cache:want/step/route`, `adapter.edgesOfPath`).
- Produces: `lineRoute(line) -> route or nil` (cache read, no engine query) and `lineRouteLength(line) -> m or nil` for Task 4.

- [ ] **Step 1: Adapter**

`lineStops(line)`: LINE component → per stop node as in the Design and key `stationGroup:station:terminal`; a stop with waypoints gets `node = nil` (its section stays straight); `modes` from `line_route.MODES` by the carrier of the line's first vehicle, or for an empty line the carrier stored in `ctx.carrier`, and the kind (`vehicleKind`). Enum values from `api.type.enum.TransportMode[name]`. `path`: `findPathNodeToNode` in `pcall`, then `track_limits` adapter `edgesOfPath`.

- [ ] **Step 2: Sampler step and gating**

In `trackStep` after `tracks:step`: if `roughEnabled` step the route cache over all player lines; else if `reachableEnabled` step it over the wanted line only; else nothing. `contextFromEvent` calls `routes:want(line, os.time())`. Log one line per completed line: `route: line L: n sections, X m (straight Y m), T ms`.

- [ ] **Step 3: Speed row fallback**

`lineSectionsWithTrack(line)`: per section track_limits section, else route section (`length`, `cap = runLimit or maxLimit`, `profile`, `unelectrified`, `unelectrifiedAt`), else straight. The second result counts track_limits and route sections as known.

- [ ] **Step 4: Syntax check, tests, sync; in-game checks (user)**

Run: `luajit -bl` on the script, all three test files, `./sync.sh`.
In game: (a) store on an empty rail line → within ~5 s the speed row shows a track-limited speed and climbs, the log has a `route:` line; (b) aircraft line → no route, no error; (c) both params Off → no `route:` line after a reload; (d) big save: no frame drops, route lines appear over the first minutes.

---

### Task 4: Calibration on route lengths

**Files:**
- Modify: `kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/rate_model.lua` (new `samplesForBasis`)
- Modify: `kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/rate_preview.script.lua` (`calibration`, `roughRate`)
- Test: `test/rate_model_test.lua`

**Interfaces:**
- Consumes: Task 3 `lineRouteLength(line)`.
- Produces: `rate_model.samplesForBasis(samples, basis) -> list` (samples `{ straight, route, top, stops, travel }`, basis "route" | "straight"; result entries `{ len, top, stops, travel }`, route basis drops samples without `route`); `rate_model.chooseBasis(targetHasRoute, nRoute) -> "route" | "straight"` ("route" iff targetHasRoute and nRoute >= MIN_FIT_SAMPLES).

- [ ] **Step 1: Failing tests**

```lua
local s = { { straight = 1000, route = 1300, top = 30, stops = 2, travel = 90 },
            { straight = 2000, top = 30, stops = 2, travel = 150 } }
check("route basis drops samples without route", #M.samplesForBasis(s, "route") == 1)
near("route basis uses route length", M.samplesForBasis(s, "route")[1].len, 1300)
near("straight basis keeps straight length", M.samplesForBasis(s, "straight")[2].len, 2000)
check("basis needs target route", M.chooseBasis(false, 50) == "straight")
check("basis needs 6 route samples", M.chooseBasis(true, 5) == "straight")
check("basis route", M.chooseBasis(true, 6) == "route")
```

(`check` as in `track_limits_test.lua`; add it to `rate_model_test.lua` if missing.) Run `luajit test/rate_model_test.lua` → FAIL on `samplesForBasis`.

- [ ] **Step 2: Implement both functions, run the suite → all ok**

- [ ] **Step 3: Script**

`calibration(carrier, kind)` keeps its signature and cache; samples carry `straight` and `route = lineRouteLength(line)`; the result gets both fits in one pass: `{ k, n, kind, travel = straight fit, routeTravel = route fit or nil, nRoute }`, where the kind/carrier fallback for the route fit counts route samples only. `roughRate`: `basis = chooseBasis(lineRouteLength(line) ~= nil, cal.nRoute or 0)`, then `len` and the travel params of that basis; the log line gets `basis=route|straight` and, for basis route, `straightRate=X` computed with the straight fit and straight length.

- [ ] **Step 4: Syntax check, tests, sync; in-game check (user)**

Big save, rough estimate On, new rail line with a clear detour (route ≥ 1.3 × straight): note both rates from the log, buy one train, compare with the game's rate after a full round trip. Same on a bus line. Record the numbers in the README section "How the rough estimate works".

---

### Task 5: Measure the physics rules in game

**Files:**
- Modify (temporarily): `track_limits.lua` `M.LOG_READS = true` in the Rate Preview copy only, reset to `false` afterwards (the probe logs speed, accel, grade and consist data of vehicles in open windows every 2 s).
- Create: `docs/probes/physics_probe/README.md` (results)

- [ ] **Step 1: Sync with `LOG_READS = true`; user drives these cases on the mods-test save, vehicle window open:**
  1. TE regime: heavy freight train starting on the flat (accel at < 20 km/h). Compare with (TE − R)/m and (2 TE − R)/m.
  2. Mass: same train empty and fully loaded, same section (accel at equal speeds).
  3. Friction: same train in the power regime on the flat: fit R in a = (P/v − R)/m; compare with 0.02 × m and with the old per-part sum.
  4. Road: one truck and one bus start on a flat street; tram once.
  5. Fade: last 5 % below top speed (accel × (1 − x²)).
- [ ] **Step 2: Fit each case (scratchpad script), write the table to the README:** rule, predicted, measured, verdict (adopt / keep old). Reset `LOG_READS = false`, `cmp` with the Top Speed copy, sync.

---

### Task 6: Engine physics in `rate_model.lua`

Only the rules Task 5 adopted; the constants below are the values to use when adopted.

**Files:**
- Modify: `kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/rate_model.lua`
- Modify: `kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/rate_preview.script.lua` (`physicsFromData`)
- Test: `test/rate_model_test.lua`

**Interfaces:**
- Produces: `M.TE_FACTOR = 2`, `M.ROLLING_MU = { rail = 0.02, road = <Task 5>, tram = <Task 5> }`, `M.FADE_START = 0.95`, `M.FADE_SLOPE = 20`, `M.FADE_OFFSET = 0.136`; `phys` gains `mu` (kN/t, resistance = mu × weight; the old absolute `friction` stays supported when `mu` is nil); `M.consistMass(weightEmpty)` returns the empty weight.

- [ ] **Step 1: Failing tests (exact values)**

- `pull uses 2 x TE`: phys `{ weight = 100, power = 1000, tractiveEffort = 100, mu = 0.02, topSpeed = 40 }` → `accelDistanceTime(phys, 5)` time = 100 × 5 / (200 − 2) = 2.525 s (tol 0.01).
- `friction per tonne`: same phys, power regime from 10 to 20 m/s on the flat → `reachableSpeed(1e6, phys)` limited by P / v = mu × m only above top; with `topSpeed = 1000`, balance = 1000 / 2 = 500 m/s.
- `fade slows the last 5 %`: `accelDistanceTime(phys, 0.99 × top)` with fade > without fade (compare against `M.FADE_SLOPE = 0` in the same test).
- `fade keeps reachableSpeed finite`: `reachableSpeed(1e6, phys) == phys.topSpeed`.
- `climb uses mu`: an existing climb test with `mu` set gives the same result as with `friction = mu × weight`.
- `consistMass empty`: `M.consistMass(50, 30, false) == 50`.

Run → FAIL.

- [ ] **Step 2: Implement**

One local `resistance(phys, s)` = `(phys.mu and phys.mu * phys.weight or phys.friction or 0) + G * s * phys.weight`, used by `accelDistanceTime`, `speedRun`, `balanceSpeed`, `physValid` (which compares it with `TE_FACTOR × tractiveEffort`); `pull` multiplies `tractiveEffort` by `TE_FACTOR`; one local `fade(v, limit, a)` applied to positive accelerations in `accelDistanceTime` (inside `invA`) and `speedRun`. Update the comment blocks (they cite the old rules). Run the suite → all ok.

- [ ] **Step 3: Script**

`physicsFromData`: `weight = rate_model.consistMass(data.weight)`, `mu` from `ROLLING_MU` by the carrier of the parts (rail / road / tram; unknown → old `friction = data.rollingFriction`). Remove the passenger-only branch if consistMass no longer needs it.

- [ ] **Step 4: Syntax check, tests, sync; in-game check (user)**

Speed row "erreicht ≈ X km/h" against Top Speed Reached's measured section speeds on 3 rail lines (should be within ~5 %, before: 5-13 % low); climb text on the "Schwieriges Schweden" line still plausible.

---

### Task 7: Release 0.18.0

**Files:**
- Modify: `rate_preview.script.lua` (`VERSION = "0.18.0"`), `mod.json` (`revision` 11), `CHANGELOG.md`, `README.md` ("How it works", "How the rough estimate works": route basis, physics rules with their source and our measurement), `/home/satan/dev/tpf3-modding/CLAUDE.md` (pathfinder API usable for empty lines, which mode sets work, physics verdicts).

- [ ] **Step 1: Write the docs, bump version and revision**
- [ ] **Step 2: All tests, `luajit -bl` on every module, `cmp` of both `track_limits.lua` copies, `./sync.sh`**
- [ ] **Step 3: User: final in-game pass on the big save (frame time with the store open, no `failed` log lines), then upload; the user writes the mod-hub changelog himself**
