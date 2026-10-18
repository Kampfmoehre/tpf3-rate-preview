# Gradient Speed in the Vehicle Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The vehicle store's speed row shows the slowest speed the cart's consist reaches on a climb of the line ("· Gradient 12 %: ≈ 18 km/h"), from real track heights.

**Architecture:** `track_limits.lua` (shared collector, also in tpf3-top-speed) stores a resampled, travel-oriented height profile per section. `rate_model.lua` gets a pure, luajit-tested grade simulation and the mass rule. `rate_preview.script.lua` passes profiles and cart physics in and appends the result to the existing speed row.

**Tech Stack:** Lua 5.1 / LuaJIT (game GUI state), plain `luajit` test scripts in `test/`.

**Spec:** `docs/superpowers/specs/2026-10-18-gradient-speed-design.md`

## Global Constraints

- G = 3.27 (game constant), grade force = G · s · m (kN with m in t).
- Mass rule: m = weightEmpty + weightMaxPayload × weightFactor, factor 1/6 if the consist carries only passengers, else 1.0. One function, so a later measurement changes one place.
- Affected threshold 0.9 (min speed below 0.9 × v_flat at the same position); cruising candidate threshold 0.9 × flat reachable speed; grade window 200 m; stall text "< 5 km/h"; integration speed floor 0.5 m/s.
- Profile format in section summaries: `profile = { step = 10, h = { h(0), h(10), … } }` (metres, travel direction).
- `track_limits.lua` `API_VERSION = 3`; both copies (tpf3-rate-preview, tpf3-top-speed) byte-identical; `LOG_READS = false` at the end.
- No engine queries while the `reachableSpeed` param is Off; no new per-frame work outside the existing 2 s bar cache.
- No third text row: the climb part is appended to the existing speed row.
- Lua: never `_` as a loop variable in GUI code (use `__`); no `rawget`/`rawset`; syntax check with `luajit -bl`.
- Texts English first, German in `strings.json` `de`. Log lines start with `[kampfmoehre_rate_preview]`.
- **No commits.** The user commits, pushes and uploads himself. Each task ends with tests + `./sync.sh` instead of a commit.

## Review Focus

- Section without `profile` (older collector, heights missing, param Off) → no climb part, no error. Test in Task 1 (`climbOnSection` returns nil) and Task 3 (in-game with param Off).
- Pure downhill or flat sections → never affected. Test in Task 1.
- Section shorter than the 200 m grade window or than the train → window = whole section, no index errors. Test in Task 1.
- Long sections (10 km, 1000 samples) → computation stays cheap. Timing test in Task 1 (< 5 ms per section in luajit).
- Profile edges stored backwards without `dir` → orientation by height continuity still yields a rising profile. Test in Task 2.

---

### Task 1: Grade simulation and mass rule (rate_model.lua)

**Files:**
- Modify: `kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/rate_model.lua` (new block after `reachableSpeedOnLine`)
- Test: `test/rate_model_test.lua` (append before the final summary lines)

**Interfaces:**
- Consumes: existing `phys = { weight, power, tractiveEffort, friction, topSpeed, brakeDecel }`, plus new optional `phys.length` (train length, m; default 20 if missing).
- Produces:
  - `M.GRAVITY = 3.27`, `M.PASSENGER_WEIGHT_FACTOR = 1 / 6`, `M.CLIMB_AFFECTED = 0.9`, `M.CLIMB_WINDOW = 200`, `M.STALL_SPEED = 5 / 3.6`
  - `M.consistMass(weightEmpty, weightMaxPayload, passengersOnly) -> number` (t)
  - `M.climbOnSection(section, phys) -> result | nil`, section = `{ length, cap?, profile = { step, h } }`; result = `{ minSpeed = m/s, at = m, grade = fraction, flatSpeed = m/s, affected = bool, stalls = bool }`; nil without profile or with invalid phys.
  - `M.climbOnSections(sections, phys) -> worst | nil, affected` — `affected` = list of results (each with `index` = 1-based section index) that are affected; `worst` = the one with the lowest `minSpeed`, nil if none.

- [ ] **Step 1: Write the failing tests**

Helper in the test file: `profile(step, segments)` builds `{ step = step, h = {...} }` from `{ {length, grade}, ... }` (heights accumulate from 0). Consist `alco = { weight = 233, power = 450, tractiveEffort = 125, friction = 0.16, topSpeed = 70 / 3.6, brakeDecel = 2.5, length = 69 }`.

```lua
near("mass passengers", M.consistMass(395, 158.4, true), 395 + 158.4 / 6)
near("mass goods", M.consistMass(233, 84, false), 317)
-- long 11.8 % climb: balance speed P / (G s m + f) = 450 / (3.27*0.118*233 + 0.16) = 5.0 m/s
local r = M.climbOnSection({ length = 2400, profile = profile(10, { {300, 0}, {1500, 0.118}, {600, 0} }) }, alco)
near("long climb min speed", r and r.minSpeed * 3.6, 18.0, 0.7)
check("long climb affected", r and r.affected)
near("long climb grade", r and r.grade, 0.118, 0.002)
-- climb straight from the stop (Emmaboda case): monotone start, still found
r = M.climbOnSection({ length = 2400, profile = profile(10, { {1800, 0.118}, {600, 0} }) }, alco)
near("climb from stop min speed", r and r.minSpeed * 3.6, 18.0, 0.7)
-- 60 m hump at 5 % on 2 km: momentum carries it
r = M.climbOnSection({ length = 2000, profile = profile(10, { {1000, 0}, {60, 0.05}, {940, 0} }) }, alco)
check("short hump not affected", r and not r.affected)
-- flat and downhill never affected
check("flat not affected", not M.climbOnSection({ length = 2000, profile = profile(10, { {2000, 0} }) }, alco).affected)
check("downhill not affected", not M.climbOnSection({ length = 2000, profile = profile(10, { {2000, -0.05} }) }, alco).affected)
-- cannot climb: 3.27 * 0.2 * 233 = 152 kN > 125 kN
r = M.climbOnSection({ length = 2000, profile = profile(10, { {200, 0}, {800, 0.2}, {1000, 0} }) }, alco)
check("stall detected", r and r.stalls and r.affected)
-- section shorter than window and train
check("tiny section no error", M.climbOnSection({ length = 50, profile = profile(10, { {50, 0.03} }) }, alco) ~= nil)
check("no profile -> nil", M.climbOnSection({ length = 2000 }, alco) == nil)
-- filter first, then worst: mild section (index 1) must not hide the mountain (index 2)
local worst, list = M.climbOnSections({
	{ length = 800, profile = profile(10, { {800, 0.01} }) },
	{ length = 2400, profile = profile(10, { {300, 0}, {1500, 0.118}, {600, 0} }) },
}, alco)
check("worst is the mountain", worst and worst.index == 2)
check("only affected listed", #list == 1)
-- cost: 10 km section
local t0 = os.clock()
M.climbOnSection({ length = 10000, profile = profile(10, { {10000, 0.02} }) }, alco)
check("10 km section < 5 ms", os.clock() - t0 < 0.005)
```

(`check(name, cond)` like in `track_limits_test.lua`; add it to this file if missing.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd tpf3-rate-preview && luajit test/rate_model_test.lua | grep -v '^ok'`
Expected: FAIL / "attempt to call field 'consistMass' (a nil value)".

- [ ] **Step 3: Implement `consistMass`, `climbOnSection`, `climbOnSections` in rate_model.lua**

Pure Lua, no game API. Algorithm (spec "Calculation"):
- Height at x by linear interpolation in `profile.h`; grade under the train s(x) = (h(x) − h(x − L)) / L with L = phys.length, for x < L the grade from the section start (h(x) − h(0)) / max(x, step).
- Forward passes in steps of `profile.step`: `v² += 2 · a · dx`, a = (pull(v) − friction − G · s · m) / m (s = 0 for the flat pass), v clamped to [0.5 m/s, min(topSpeed, cap)].
- Candidates before the braking zone (x ≤ length − v_flat(x)² / (2 · brakeDecel or 2.5)): local minima of v_grade, and x with v_flat(x) ≥ 0.9 · max(v_flat). Result at the lowest candidate; `grade` = steepest 200 m mean grade ending at or before `at` (whole section if shorter); `affected` = minSpeed < 0.9 · v_flat(at); `stalls` = G · s · m + friction ≥ tractiveEffort for a stretch ≥ L.
- Reuse the existing local `pull` and `physValid`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `luajit test/rate_model_test.lua | tail -1 && luajit -bl kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/rate_model.lua > /dev/null && echo syntax ok`
Expected: `all tests passed`, `syntax ok`.

### Task 2: Height profile per section (track_limits.lua, both repos)

**Files:**
- Modify: `kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/track_limits.lua`
- Test: `test/track_limits_test.lua`
- Copy afterwards: `../tpf3-top-speed/kampfmoehre_top_speed_1/content/gui/kampfmoehre_top_speed/track_limits.lua` and the test body (keep top-speed's two `package.path` header lines)
- Modify: `../tpf3-top-speed/kampfmoehre_top_speed_1/content/gui/kampfmoehre_top_speed/top_speed.script.lua:21` VERSION `0.4.1` → `0.4.2`

**Interfaces:**
- Consumes: edges from `pathEdges` with `length, h0, h1, fwd` (already produced).
- Produces:
  - `M.API_VERSION = 3`, `M.PROFILE_RESAMPLE_STEP = 10`
  - `M.resampleProfile(edges, step) -> { step = step, h = {...} } | nil` (travel-oriented, h[1] at 0 m; nil if any edge lacks heights)
  - `summarize(edges)` result gains `profile` (from `resampleProfile`) when heights exist; `Collector:section(line, stopIndex)` therefore returns it.

- [ ] **Step 1: Write the failing tests**

```lua
local rp = M.resampleProfile({
	{ length = 100, h0 = 0, h1 = 10 },
	{ length = 100, h0 = 20, h1 = 10 },   -- stored backwards, no fwd: continuity flips it
}, 10)
check("resample step", rp and rp.step == 10)
check("resample count", rp and #rp.h == 21, rp and tostring(#rp.h))
near("resample start", rp and rp.h[1], 0)
near("resample middle", rp and rp.h[11], 10)
near("resample end rises", rp and rp.h[21], 20)
near("resample honours fwd=false", M.resampleProfile({ { length = 100, h0 = 5, h1 = 0, fwd = false } }, 10).h[11], 5)
check("resample without heights", M.resampleProfile({ { length = 100 } }, 10) == nil)
check("summary carries profile", M.summarize({ { limit = 20, curve = 200, length = 100, h0 = 0, h1 = 5 } }).profile ~= nil)
check("api version 3", M.API_VERSION == 3)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `luajit test/track_limits_test.lua | grep -v '^ok'`
Expected: FAIL lines for the new checks.

- [ ] **Step 3: Implement**

Extract the orientation part of `gradeProfile` into a local `orientedHeights(edges) -> a, b` (start/end height per edge in travel direction, or nil) and use it in both `gradeProfile` and `resampleProfile`. `summarize` sets `profile`. In `Collector:step` drop the `LOG_READS`-only `sum.profile = M.gradeProfile(edges)` line and keep the diagnostic heights log reading `M.gradeProfile(edges)` directly when `LOG_READS`. Set `API_VERSION = 3`, `LOG_READS = false`, update the header comment (interface list, profile).

- [ ] **Step 4: Run tests, copy, sync**

Run in tpf3-rate-preview: `luajit test/track_limits_test.lua | tail -1`
Copy file + test body to tpf3-top-speed, bump its VERSION, then run there: `luajit test/track_limits_test.lua | tail -1 && diff <(sed 1,2d test/track_limits_test.lua) <(sed 1,2d ../tpf3-rate-preview/test/track_limits_test.lua) && cmp kampfmoehre_top_speed_1/content/gui/kampfmoehre_top_speed/track_limits.lua ../tpf3-rate-preview/kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/track_limits.lua && ./sync.sh`
Expected: `all tests passed` in both repos, no diff output, `synced -> …`.

### Task 3: Store display (rate_preview.script.lua, strings, docs, release)

**Files:**
- Modify: `kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/rate_preview.script.lua` — `physicsFromData` (~127), `lineSectionsWithTrack` (~522), `bottomBarText` reach block (~986-1028), `cachedBottomBarText` (~1085-1096), `makeRateNode` and its two call sites (~1165, ~1252, ~1277), VERSION (39) `0.17.0`
- Modify: `kampfmoehre_rate_preview_1/strings.json`, `kampfmoehre_rate_preview_1/mod.json` (`revision` 8 → 9), `README.md` ("Reachable speed between stops")

**Interfaces:**
- Consumes: `rate_model.consistMass`, `rate_model.climbOnSections` (Task 1); `tracks:section(...).profile` (Task 2).
- Produces: `physicsFromData` returns `weight = rate_model.consistMass(data.weight, data.weightMaxPayload, passengersOnly)` and `length = data.length`; passengersOnly = `data.allCargoTypes` has exactly the passenger cargo type (`api.res.cargoTypeRep.getPassengerCargoTypeId()`, pcall-guarded, false on error). `lineSectionsWithTrack` sections carry `profile = sec.profile`. `bottomBarText` returns a 5th value `climbText` (string or nil); `makeRateNode(text, extra, extraReached, extraTooltip, climbText, pad, boxClass)`.

- [ ] **Step 1: Wire the data**

Mass and length in `physicsFromData`; `profile` in `lineSectionsWithTrack`. In the reach block, for every cart entry with `phys` (or the Buy-mode `newPhys` fallback) call `rate_model.climbOnSections(sections, phys)` and keep the overall worst; one `roughLog` line `climb line %s: worst section %s min %.1f km/h at %.0f m grade %.1f%% stalls %s, affected %d` (or `none`).

- [ ] **Step 2: Texts and row**

When a worst result exists: `reachReached = false` (no green, no check mark); `climbText = lang_util.format(_("rate_climb"), { grade = string.format("%d %%", math.floor(grade*100 + 0.5)), speed = stalls and ("< " .. formatSpeed(5/3.6)) or ("≈ " .. formatSpeed(minSpeed)) })`; append to `reachTooltip` a header line `_("rate_climb_tooltip")` and one `_("rate_climb_section")` line per affected section with `from = index`, `to = index % n + 1` (line stop numbers as in the line window), `grade`, `speed`. `makeRateNode` appends `"· " .. climbText` as its own `TextView` in the speed row with class `"font-scale-body, negative"`. Carry `climbText` through `barCache`.

Strings (en / de):
- `rate_climb`: `"Gradient {grade}: {speed}"` / `"Steigung {grade}: {speed}"`
- `rate_climb_tooltip`: `"Slow on climbs (fully loaded, game physics):"` / `"Langsam an Steigungen (voll beladen, Spielphysik):"`
- `rate_climb_section`: `"Stop {from} → {to}: up to {grade}, min {speed}"` / `"Halt {from} → {to}: bis {grade}, min. {speed}"`
- `rate_reach_param_tooltip` en/de: replace "the fully loaded weight" / "voll beladenem Gewicht" with the new rule (empty weight + full load; passengers count 1/6, as in the game) and add one sentence that climbs of known sections are shown.

README "Reachable speed between stops": short paragraph on gradients (G = 3.27, mass rule, what is shown, only known sections).

- [ ] **Step 3: Syntax check, unit tests, sync**

Run: `luajit -bl kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/rate_preview.script.lua > /dev/null && python3 -c "import json;json.load(open('kampfmoehre_rate_preview_1/strings.json'))" && luajit test/rate_model_test.lua | tail -1 && luajit test/track_limits_test.lua | tail -1 && ./sync.sh`
Expected: no errors, `all tests passed` twice, `synced -> …`.

- [ ] **Step 4: In-game check by the user** (reload the save; report to him what to look at)

- "Schwieriges Schweden", Zug 18 modify, line 131749: speed row ends with "· Steigung 12 %: ≈ 16–19 km/h", no check mark, tooltip lists "Halt 3 → 1" (or the matching stop pair).
- Zug 28 (GG1) modify: "erreicht ≈ 128–130 km/h", no climb part.
- A flat tram line: row unchanged.
- Param `reachableSpeed` Off: no speed row, no `[kampfmoehre_track_limits` reads in `stdout.txt`.
- `stdout.txt`: one `climb line …` log per cart change, no Lua errors.

After his confirmation update CLAUDE.md ("Published mods" Rate Preview row, "Gradients" bullet with the mass outcome).
