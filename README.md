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
  bar → the text is inserted in front of its stretch spacer.
- Rate: `api.engine.util.line.calcLineStationThroughput`; capacities:
  `statistics_react_util.calculateCargoColumnDataForLine/-ForVehicle(...).demand`
  and `cargo_util.getSortedProducedCargoTypes` for the line's cargo types.

## How the rough estimate works

The game computes a line's rate as capacity x vehicles x (year / round trip),
with the round trip measured from the running vehicles. For a line without
vehicles the mod reconstructs the round trip:

    travel  = p * len / topSpeed + q * len + b * stops
    dwell   = per stop: 2 s arrive + 2 s depart + waiting + loading
    rate    = capacity * k / (travel + dwell)

- `len` is the straight-line round trip through the line's stops and
  waypoints. `p`, `q`, `b` are fitted by least squares on your other lines
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
  mod.json                         mod id, "rough estimate" parameter
  strings.json                     translations (en, de)
  _metadata/modinfo.json           name, summary, description (+ de)
  _metadata/0.png                  title image, 1920x1080
  content/gui/kampfmoehre_rate_preview/
    entry.res.lua                  plugin registration (entry point)
    rate_preview.script.lua        the actual code (UI hooks, game API)
    rate_model.lua                 pure formulas of the rough estimate
test/rate_model_test.lua           unit tests for rate_model.lua (luajit)
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
   prefix `[rate_preview]`. The game's Lua is 5.1-compatible; check syntax
   with `luajit -bl file.lua`, not `luac` 5.4.
4. Before uploading a new version through the in-game Mod-Hub, increase
   `revision` in `mod.json`. mod.io rejects a package whose content is
   byte-identical to an already uploaded one.

The staging copy also contains files generated by the game (`.cooked_*`,
`_metadata/mod.io_fileid.txt`). `sync.sh` leaves them alone and they are
ignored by git.

## License

MIT, see `LICENSE`.
