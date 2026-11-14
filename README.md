# Line Rate Preview (Transport Fever 3)

A small UI mod for Transport Fever 3 that shows the **estimated line rate in
the vehicle dialog** before you buy, replace or modify vehicles:

    Line rate: 124  →  ≈ 186      Frequency: 2 min 21 s  →  ≈ 1 min 58 s

The left numbers are the line's current rate (cargo or passengers per year,
as in the line manager) and frequency, the right ones the estimate after the
purchase, replacement or modification of what is currently in the cart. The
frequency estimate is shown when buying (cycle time divided by the new number
of vehicles); replacing or modifying does not change the vehicle count.

- Works for all carriers: road, rail, tram, water, air.
- Shows the speed a land vehicle can actually reach between the line's stops
  when that is below its top speed, otherwise a green check mark (see
  "Reachable speed between stops").
- Buy: the configured vehicle or consist times the amount field.
- Replace: the replaced vehicles' capacity is swapped for the new consist.
- Modify: only the checked entries count; the estimate appears once you
  actually changed something in the cart.
- Multi-purpose wagons ("all goods") are counted once, not once per cargo
  type, and only the capacity matching the line's cargo counts (a helicopter
  with 20 seats and 12 cargo slots counts 12 on an oil line).
- Purely cosmetic: achievements stay enabled. English and German.

Available on mod.io: <https://mod.io/g/transportfever3/m/line-rate-preview1>

## Limitations

- **A line without vehicles normally shows "n/a".** The game computes the
  rate from the vehicles actually running (travel times from its
  pathfinding, which is not accessible to mods). Buy the first vehicle, then
  the preview works for every further one.
- **Optional rough estimate for empty lines** (mod parameter, off by
  default): shown as "≈ 150 (rough)". The round trip is modelled as travel
  time plus the dwell time of every stop, calibrated on your other lines of
  the same carrier and cargo kind (see "How the rough estimate works").
  Measured on a large savegame the median error of the travel part is
  8-16 %, individual lines can be off by 30 % and more. Needs at least one
  other line of the same carrier with vehicles; six or more give the full
  travel model. Note that the game's own rate right after the purchase is
  provisional and can be off by 50 % until the vehicle completed a full
  round trip.
- The estimate scales the game's current rate with the capacity change and
  assumes the new vehicle keeps the same cycle time. A faster vehicle than
  the line's current ones shortens the cycle, so the real rate ends up
  higher than estimated; a slower one lower. The bar marks this with (+) / (-)
  after the estimate (compared by top speed, 2 % tolerance). The game's own
  rate also starts as an estimate and settles after the first full cycle.
- Only when the dialog was opened from the line manager for a line (the
  "Buy Vehicles" button of a line, or Replace/Modify of its vehicles). Opened
  from a depot without a line there is nothing to compute.

## Installation

Subscribe on mod.io or in the in-game Mod-Hub, then enable the mod when
loading or creating a game.

Manual installation: copy the folder `kampfmoehre_rate_preview_1` into the
game's local mod directory, on Linux
`~/.local/share/Steam/userdata/<steam-id>/3493540/local/mods/`.

## How it works

Transport Fever 3's UI is written in Lua/Teal on top of an in-house,
React-like component system. Mods can load code into it through a
`react-plugin` resource (`entry.res.lua` registers at the game's
`ModEntryPointExtension`). The GUI Lua state has no debug library and
recipes cannot be looked up by name, so everything goes through exported
helper functions and the builtin layout calls (module tables are cached, so
wrapping their fields affects the base scripts):

- `line_util.getBestDepotForLine(line)` is called by the line manager's
  "Buy Vehicles" button right before the store opens → target line.
- `react.fireEvent(nil, "buyVehicles" | "replaceVehicles" | "modifyVehicles", param)`
  → store opened; replace/modify carry the vehicle entities → line and old
  capacity.
- `vehicle_store_util.makeMultipleVehiclesFromParts` / `collectVehicleData`
  are called once per cart entry → capacities per entry; `builtin.CheckBox`
  gives the entry's checkbox state, `builtin.DoubleSpinBox` the amount.
- `builtin.BoxLayout` with class `bottom-bar-layout` is the cart's bottom
  bar → the text is inserted in front of its stretch spacer (Buy, Modify).
- Replace: the bottom bar is already filled by the "Vehicles To Replace"
  widget, which other mods extend (e.g. Better Vehicle Stats), so the text
  goes into the single cart entry instead: the `builtin.BoxLayout` holding
  the `builtin.Button` with class `consist-delete`, aligned bottom right by
  `rate_preview.css.lua`.
- Rate: `api.engine.util.line.calcLineStationThroughput`; capacities:
  `statistics_react_util.calculateCargoColumnDataForLine/-ForVehicle(...).demand`
  and `cargo_util.getSortedProducedCargoTypes` for the line's cargo types.

## Reachable speed between stops

For land vehicles the preview also shows `reaches ≈ 227 km/h` when the
consist cannot reach its top speed between the stops of the line (mod
parameter, on by default). Per section (straight-line distance between
consecutive stops, waypoints included) the largest speed is searched for
which the acceleration distance plus the braking distance fit into the
section; the maximum over all sections is shown. Trains and trams use the
engine's own rules (decompiled by the author of Vehicle Power Tooltip,
mod 6419746, and measured in this repo, `docs/probes/physics_probe/`): pull
`min(2 x tractive effort, power / v)` minus a rolling resistance of 0.02 kN
per tonne, divided by the **empty** weight (a loaded train accelerates and
climbs like an empty one), and the acceleration fades out in the last 5 %
below the speed limit. Road vehicles keep the store tooltip's physics (pull
`min(tractive effort, power / v)`, the parts' summed friction, full load:
empty + max payload times the cargo's `weightFactor`, 1.0 for goods, 1/6 for
passengers), road could not be measured. Braking uses the parts'
`brakeDeceleration` (2.5 m/s² for most vehicles). Below
98 % of the top speed the line shows `reaches ≈ X`, otherwise
the top speed in green with a check mark (tooltip `reaches top speed (X)`),
so the check is visible either way. The (+)/(-) hint
when replacing then compares reachable instead of nominal speeds.

For lines with vehicles the real track is used where it is known: a
background collector (`track_limits.lua`, shared with the mod Top Speed
Reached) reads the section a vehicle is driving from its `MOVE_PATH`
component, i.e. the edges from the previous stop to the next, and the edges'
`speedLimit`/`curveSpeedLimit` from the `TRANSPORT_NETWORK` components. Such
a section uses its real length, and the reachable speed is capped at the
highest limit that holds for 200 m at a stretch (tooltip "Limited by the
track …" when the cap decides). Sections no vehicle has driven since loading
take the route from the game's pathfinder instead (see "Real routes" below),
and only where that fails the straight-line distance. The collector reads about 3 ms every 2 s,
open line/vehicle windows and the line in the store first (opening the store
or a window re-reads that line's sections, so a track upgrade shows within
seconds; otherwise a section is read again after 5 minutes), and runs only
while this parameter is on; with both mods loaded each section is read once.

For road vehicles the weight assumes a full load. Every cargo type has a
`weightFactor` (`base/content/cargos/*/*.cargo.lua`): 1.0 for goods, 1/6 for
passengers. A section counts its highest limit only, not slower stretches in
between. Ships and aircraft are not covered.

### Real routes

`line_route.lua` asks the game's pathfinder
(`api.engine.util.pathfinding.findPathNodeToNode`) for the track between the
terminal nodes of consecutive stops, also for lines without vehicles, and
summarises the edges like the collector does (length, limits, heights,
catenary). Transport modes per carrier come from a probe
(`docs/probes/route_probe/`): rail `TRAIN`, road `BUS` or `TRUCK`, tram
`TRAM` + `ELECTRIC_TRAM`; aircraft have no network, and ships keep the
straight line until their pathfinding cost is measured. A section after a stop with waypoints keeps the straight line (the
pathfinder would ignore them). The cache reads at most 4 sections or 3 ms
per 2 s step, the line in the store first; all lines with vehicles only while
the rough estimate is on (for its calibration), and nothing while both
parameters are off. A line is read again after 5 minutes or when its store
opens. On the test save the route was 17 % (rail), 20 % (tram) and 37 %
(road) longer than the straight line.

### Gradients

The collector also keeps each known section's height profile (the edges'
`geometry.height`, resampled every 10 m in travel direction). For every
consist in the cart the section is simulated from a standing start with

    a = (min(k * tractive effort, power / v) - friction - G * s * m) / m

(trains and trams: k = 2, friction = 0.02 kN/t x m, m = empty weight; road:
k = 1, the parts' friction, m = full load)

where `s` is the mean grade under the train (over its length) and
G = 3.27, the game's own constant (`vehicle_util.tl`
`calcDownhillSlopeForce`, about a third of real gravity; measured against the
engine's reported acceleration on a 12 % climb with an rms error of
0.005 m/s²). Per position the climb holds the train to the higher of its
simulated speed and the speed it could hold on that grade (pull = grade force
+ friction, capped at the top speed and the track limit), so a train that
accelerates up a ramp right from the stop is measured by what the ramp lets
it reach, and a gentle grade on which the top speed is still reachable does
not count. Positions below 90 % of a flat run at the same place are
affected (braking zone excluded); the slowest of them is the section's
result, and the worst affected section
is shown on its own line below the speed row in a warning colour, e.g.
`Gradient 12 %: ≈ 18 km/h` (steepest 200 m before that point), without the
green check mark, and the tooltip lists every affected section by its stops.
A consist that cannot pull the grade at all shows `< 5 km/h`. Sections a
vehicle of the line has driven or the pathfinder found are known.

### Catenary

A consist needs catenary when one of its parts has engines and all of them
are electric (`landVehicle.engines[i].type`, the same as the store's
"Electric" filter). The models' `transportModes` do not tell it: every base
locomotive, diesel too, lists `TRAIN` and `ELECTRIC_TRAIN`. The collector counts, per known section, the metres of edges that
have rails but not their electric variant (edge `transportModes`). If the
cart needs catenary and a known section lacks it, two warning lines below the
speed row show `no catenary:` / `1 of 3 sections` (short lines, so the text
takes little width from the cart's vehicle preview) and the tooltip lists
each section with the missing metres and where they start. Sections a vehicle
of the line has driven or the pathfinder found are checked; the depot is not. Single
vehicles bought without a cart list (buses, single trams) are not checked.

## How the rough estimate works

The game computes a line's rate as capacity x vehicles x (year / round trip),
with the round trip measured from the running vehicles. For a line without
vehicles the mod reconstructs the round trip:

    travel  = p * len / topSpeed + q * len + b * stops
    dwell   = per stop: 2 s arrive + 2 s depart + waiting + loading
    rate    = capacity * k / (travel + dwell)

- `len` is the real round trip from the pathfinder ("Real routes") when the
  line and at least six reference lines have a complete route, else the
  straight-line round trip through the stops and waypoints; the two bases are
  never mixed in one fit (the detour factor means something else on each).
  First test, a 13.5 km mountain line (9.7 km straight): route basis 127,
  straight basis 137, the game 123 after two round trips. `p`, `q`, `b` are fitted by least squares on your other lines
  of the same carrier and cargo kind (passengers vs freight), using the
  engine's per-section travel times of their vehicles, which exclude dwell.
  `p` is the share limited by the vehicle's top speed, `q` the share limited
  by the road or track (buses: almost all of it, about 30 km/h effective),
  `b` the seconds per stop for braking and accelerating (buses ~17 s,
  trucks ~40 s, ships ~90 s per harbour). With fewer than six reference
  lines a single factor on the top speed is used instead.
- `k` is the year length the game's rate uses (about 1460 s at default
  settings), also taken from the reference lines.
- Loading time per unit is `16 x penalty / loadSpeed` seconds for freight
  and `1 / loadSpeed` for passengers, where `penalty = 1 / (terminal
  modifier x stock modifier)`. The terminal modifier is read from the stop's
  terminal (industry terminals 2, plain station terminals 1, specialised
  cargo stations 2 for their cargo class); the stock (warehouse) modifier is
  not reachable from the UI API and assumed 1. Freight is loaded once and
  unloaded once per round trip with full capacity, plus 2.3 s overhead and
  5.5 s mean waiting per stop. Passenger stops take 8.4 s plus the boarding
  and alighting passengers divided by the load speed, with about 1.75 x
  capacity per stop on two-stop lines and 0.5 x capacity from six stops on
  (measured). The load speed of a consist is the sum over its wagons, they
  load in parallel.

All constants were measured in-game (5700 terminal stops of 445 vehicles).
The pure formulas live in `rate_model.lua` and are covered by
`test/rate_model_test.lua` (`luajit test/rate_model_test.lua`), including a
fixture of 79 real reference lines.

## Development

```
kampfmoehre_rate_preview_1/        the mod (this is what gets published)
  mod.json                         mod id, "rough estimate" and "reachable speed" parameters
  strings.json                     translations (en, de)
  _metadata/modinfo.json           name, summary, description (+ de)
  _metadata/0.png                  title image, 1920x1080
  content/gui/kampfmoehre_rate_preview/
    entry.res.lua                  plugin registration (entry point)
    rate_preview.script.lua        the actual code (UI hooks, game API)
    rate_model.lua                 pure formulas of the rough estimate
    track_limits.lua               track speed limits per line section (same file as in Top Speed Reached)
test/rate_model_test.lua           unit tests for rate_model.lua (luajit)
test/track_limits_test.lua         unit tests for track_limits.lua (luajit)
test/caldata_fixture.lua           79 real reference lines for the tests
sync.sh                            copies the mod into the game's staging area
```

Workflow:

1. Edit the files in `kampfmoehre_rate_preview_1/`.
2. Run `./sync.sh`. It copies the mod into the game's staging area
   (`.../userdata/<steam-id>/3493540/local/staging_area/`), where the game
   loads it as a development mod. Returning to the main menu and reloading
   the savegame is enough to pick up changes, no restart needed.
3. Lua errors show up as a red error screen in the game ("Copy to clipboard")
   and in `.../3493540/local/crash_dump/stdout.txt`. The script logs with the
   prefix `[kampfmoehre_rate_preview]`. The game's Lua is 5.1-compatible; check syntax
   with `luajit -bl file.lua`, not `luac` 5.4.
4. Before uploading a new version through the in-game Mod-Hub, increase
   `revision` in `mod.json`. mod.io rejects a package whose content is
   byte-identical to an already uploaded one.

The staging copy also contains files generated by the game (`.cooked_*`,
`_metadata/mod.io_fileid.txt`). `sync.sh` leaves them alone and they are
ignored by git.

## License

MIT, see `LICENSE`.
