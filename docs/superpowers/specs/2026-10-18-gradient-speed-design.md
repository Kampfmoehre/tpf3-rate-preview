# Gradient speed in the vehicle store — design

Date: 2026-10-18. Mod: Line Rate Preview (`kampfmoehre_rate_preview_1`), current version 0.16.1.
Shared file: `track_limits.lua` (identical copy in tpf3-top-speed).

## Why

The user extended a cement line (Emmaboda) up a steep mountain and bought an ALCO HH 600
(450 kW, 125 kN) for 7 wagons. The store said "reaches 70 km/h ✓", which is true on the flat and
downhill. Uphill the train drops from ~26 to 18 km/h on an 11.8 % stretch. Had the store shown
that, he would have picked a different locomotive or added a second one. He decides among
wagons' top speed, running costs, electrification and needed rate. The mod should give him the
missing fact (how slow does this consist get on this line's climbs) and leave the judgement to him.

## Goals

- In the vehicle store (buy, modify, replace) show the slowest speed the cart's consist reaches on
  a climb of the line, when it is noticeably below what the consist otherwise reaches.
- Use the real track height profile of the line's sections that the shared collector already
  reads (sections a vehicle of the line has driven since loading).
- Correct the consist mass used by the existing "reaches ≈ X km/h" calculation (see Physics).

## Non-goals

- No judgement ("too slow", "a truck would be cheaper"). The useful threshold depends on the era
  and the available fleet; the user decides.
- No change to the line-rate estimate itself (rate numbers, rough estimate travel time).
- No downhill effects, no per-section display in Top Speed Reached (planned later as a
  collapsible panel there, it will reuse the profile data).
- No data for lines without vehicles (no driven sections, no heights).

## Anti-goals

- A third text row in the cart: the replace-mode cart entry cannot grow, the bottom bar likely
  neither. Everything goes into the existing speed row and its tooltip.
- Extra per-frame cost: the cart re-renders every frame (see CLAUDE.md, Rate Preview 0.15.2).
- Engine queries while the `reachableSpeed` param is Off (memory: gate expensive features behind
  their param; the track sampler already only runs when it is On).

## Physics (measured 2026-10-18, see CLAUDE.md "Gradients")

Per position x along a section, with v in m/s, forces in kN, mass in t:

    a = (min(TE, P / v) − friction − G · s(x) · m) / m

- G = 3.27, the game's own constant (`vehicle_util.tl` `calcDownhillSlopeForce`). The fit on 81
  engine-reported accelerations gave rms 0.005 m/s² with G 3.27 and the empty mass.
- s(x) = mean grade under the train: (h(x) − h(x − trainLength)) / trainLength, trainLength =
  the consist's `vehicleData.length` (sum of part lengths); before x reaches trainLength use the
  grade from the section start.
- **Mass: open, see "Mass" below.** Today `physicsFromData` adds the full `weightMaxPayload`,
  which is too heavy for passenger trains (Zug 28: shows 124 km/h, drives 130–131). The mass rule
  is isolated in one function so the decision below changes one place. Update the param tooltip
  strings ("fully loaded weight") to match whatever rule ships.
- Known small deviations, not modelled: ~3–4 kN extra resistance in the power regime (≈5 %),
  an acceleration cap of ~1.45 m/s² at low speed, some air drag above ~100 km/h.
- Road vehicles (trams, buses, trucks) are not verified; bus probes reported accelerations that
  do not fit this formula. The feature runs for all land vehicles with section data; the user
  tests trams afterwards and short city sections matter less.

## Mass

Every cargo type has a `weightFactor` (`base/content/cargos/*/…cargo.lua`): 1.0 for all goods,
1/6 for passengers. The game's own model is therefore likely
m = weightEmpty + weightMaxPayload × weightFactor (full load). Measurements so far:

| Consist | empty | max payload | model (full) | measured |
|---|---|---|---|---|
| GG1 + 6 coaches, 132/132 pax, flat | 395 t | 158.4 t | 421 t | ~410 t |
| Ge 2/2 tram + 5, 40/40 chemicals | 33 t | 48 t | 81 t | closer to 81 than 33 (noisy fit) |
| ALCO HH 600 + 7, 70/70 stones, 12 % climb | 233 t | 84 t | 317 t | 233–250 t (clean fit; 317 t needs an impossible −10 kN push) |

Default rule (builder implements this): **m = weightEmpty + weightMaxPayload × weightFactor of
the consist's primary cargo** (1/6 if it carries passengers, else 1.0), i.e. full load. It is the
game's data model and errs on the slow side for the warning (Emmaboda: ≈ 16 km/h shown, 18
driven). One more in-game measurement (the stone train accelerating out of the quarry on the
first, almost flat 250 m) decides whether goods count; if they do not, the rule becomes
weightEmpty (+ passengers × 1/6).

## Data: height profile per section (track_limits.lua)

- `pathEdges` already returns per edge `length`, `h0`, `h1` (TRANSPORT_NETWORK edge
  `geometry.height.x/.y`) and `fwd` (MOVE_PATH entry `.dir`; true = forward). Orientation: use
  `fwd` when present, else height continuity with the neighbour edge (as `gradeProfile` does).
- New: the section summary stores a resampled profile oriented in travel direction, e.g.
  `profile = { step = 10, h = { h(0), h(10), h(20), … } }` (m). Long sections (10 km) give ~1000
  numbers; that is acceptable.
- Bump `API_VERSION` to 3 (summary has `profile`). `getShared` keeps the highest version, so a
  newer copy in either mod replaces an older collector. Keep both copies identical and run both
  repos' `test/track_limits_test.lua`.
- The diagnostic code added on 2026-10-18 (`gradeProfile`, probes, `logEntryKeys`) stays behind
  `LOG_READS`, which goes back to `false`.

## Calculation (rate_model.lua, pure, unit-tested with luajit)

New function, e.g. `rate_model.climbOnSections(sections, phys)`, sections as today
(`{ length, cap }`) plus optional `profile`. For each section with a profile:

1. Forward pass from v = 0 at the section start in distance steps (≈ profile step), speed capped
   at min(topSpeed, cap). Gives v_grade(x). Speed floor 0.5 m/s in the integration.
2. Same pass with s = 0 gives v_flat(x) (the train on a flat section of the same length).
3. Per position, before the braking zone (x ≤ length − v_flat(x)²/(2b)): e(x) = max(v_grade(x),
   balance speed on s(x)), the balance speed being where pull = G·s·m + friction, capped at
   min(topSpeed, cap), 0 if the consist cannot climb s. A train accelerating up a ramp from the
   stop is measured by what the ramp lets it reach; slower acceleration on a gentle grade whose
   balance speed is above the top speed does not count. (Revised after the code review: the first
   rule, local minima plus "flat run cruises", showed ≈ 50 km/h for a short 12 % ramp from the
   stop that really holds ~13 km/h, and flagged 1–2 % grades.)
4. A position is affected when e(x) < 0.9 × v_flat(x). Section result: the lowest e among the
   affected positions (none → not affected), and the steepest mean grade over a 200 m window
   that ends at or before that position.

Line result: among the affected sections, the one with the lowest minimum (filter first, then
take the worst, so a mild city section never hides a mountain). Nothing affected → nothing shown.
If the consist cannot climb a stretch at all (G·s·m + friction ≥ TE over at least one train
length) the speed text is "< 5 km/h" (what the game does then is unverified).

## Display (rate_preview.script.lua)

- Same speed row as today (`makeRateNode`), climb part appended:
  `⏲ 50 km/h · Gradient 12 %: ≈ 18 km/h` (en) / `⏲ 50 km/h · Steigung 12 %: ≈ 18 km/h` (de).
  The first part stays whatever it is today ("reaches ≈ 62 km/h" when the top speed is not
  reached, else the top speed).
  The grade is the steepest 200 m window, rounded to whole percent; the speed via
  `api.util.formatSpeed`.
- With a climb shown: no green check mark and the first part is not green; the climb part uses a
  warning style of the base GUI (classes `warning`/`negative` exist; pick one that reads well on
  the cart's grey). Without a climb the row is exactly as today.
- Tooltip of the row: the existing tooltip text plus one line per affected section (steepest
  grade, minimum speed, section identified by its stops).
- Buy/modify: bottom bar. Replace: inside the cart entry; clipped text shows in full as tooltip
  (`tooltipWhenClipped`, as today).
- Modify with several different consists in the cart: compute per cart entry and show the worst.
  Buy mode for single-vehicle carriers: the shown vehicle, as for "reaches".
- Results go through the existing 2 s bar cache (`cachedBottomBarText`); no extra caching layer
  unless profiling shows a need.
- New strings in `strings.json` en/de; README section "How it works" gets a short paragraph on
  gradients and the mass finding.

## Versions and release

- Rate Preview 0.17.0, `revision` bump before upload. Top Speed gets the identical
  `track_limits.lua` (API 3) as a patch version; uploading it is optional because the newer
  collector wins anyway.
- The user tests in-game ("Schwieriges Schweden", Zug 18 / line 131749: expect ≈ 16–19 km/h at
  12 % depending on the mass rule; Zug 28 / GG1: "reaches" ≈ 128–130 km/h) and with a cargo tram,
  then commits and uploads.

## Left to the builder

- Step size, data layout of the profile, function names, test fixtures (the Emmaboda profile
  from the 2026-10-18 log: section 131749 stop 0, 2175 m, heights every 250 m
  `5 8 33 58 77 93 108 118 119`, steepest 200 m +11.67 %).
- The exact warning CSS class and tooltip wording.

## Addendum (2026-10-18): catenary warning

Requested after an E 94 bought for the non-electrified Emmaboda line stopped with "no electric
path" in front of a switch. Same data path: per known section `unelectrified` (m) and
`unelectrifiedAt` (m) from edges whose `transportModes` have TRAIN / TRAM / TRAM_TRACK without
the electric variant; a cart entry needs catenary when a part has engines and all are
`VehicleEngineType.ELECTRIC` (first built on `tv.transportModes`, which failed in-game: every base
locomotive's model lists TRAIN and ELECTRIC_TRAIN, the ALCO diesel too). Any missing metres
warn equally (a short gap stops the train completely): `· no catenary (1 of 3 sections)` before
the climb part, tooltip per section with metres and start position, plus "x of n sections known"
when not all are known. Depot not checked; single vehicles without cart list not checked.
