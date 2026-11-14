# Route probe (2026-11-14)

Question (plan `docs/superpowers/plans/2026-11-13-route-and-physics.md`, Task 1): does
`api.engine.util.pathfinding.findPathNodeToNode({fromNode}, {toNode}, {modes})` give the track between two stops of a
line, with which transport modes per carrier, at what cost, and does its length match the section the line's vehicles
drive (track_limits)?

`route_probe.lua` ran from the entry plugin's 2 s step timer (one line per tick, 20 lines, every candidate mode set per
section). Big save, build 40425, 2026-11-14.

## Facts

- Node of a stop: `STATION_GROUP.stations[stop.station + 1]` → `STATION.terminals[stop.terminal + 1].vehicleNodeId`.
- Result: a plain table of `{ EdgeId, bool }` pairs (`e[1]` = EdgeId userdata with `.entity`/`.index`, `e[2]` = direction),
  i.e. what the tealdef says (MOVE_PATH entries differ). Wrong modes give an empty table, no error.
- Carrier enum: ROAD 0, RAIL 1, TRAM 2, AIR 3, WATER 4.
- **A mod's new file is found only after a game restart**; reloading the savegame picks up changed files but a new
  `.lua` gives "module … not found" until the game is restarted.

## Results (sections, median / max ms per call)

| Line carrier | Modes | ok / fail | ms | route / straight | route / driven |
|---|---|---|---|---|---|
| RAIL | TRAIN | 12 / 0 | 0.06 / 0.77 | 1.17 | 0.98 |
| RAIL | TRAIN + ELECTRIC_TRAIN | 12 / 0 | 0.20 / 2.47 | 1.17 | 0.98 |
| ROAD | BUS | 32 / 0 | 0.09 / 1.21 | 1.37 | 0.90 |
| ROAD | TRUCK | 32 / 0 | 0.03 / 0.73 | 1.37 | 0.90 |
| ROAD | CAR | 14 / 18 | – / 16.1 | | |
| TRAM | TRAM + ELECTRIC_TRAM | 12 / 0 | 0.06 / 0.21 | 1.20 | 0.98 |
| TRAM | BUS / TRUCK | 12 / 0 | 0.4-0.7 / 13.7 | 1.49 | (street detours) |
| AIR | AIRCRAFT + SMALL_AIRCRAFT + HELICOPTER | 2 / 0 | 0.06 | 0.04 | nonsense (taxi path only) |

No ship line among the first 20 lines: WATER untested.

Route vs driven: the driven section (MOVE_PATH, track_limits) is 2-10 % longer than the terminal-to-terminal route
(in-station paths, road lanes). Route vs straight line: rail +17 %, tram +20 %, road +37 % (median).

## Verdict

- Cost far below the 20 ms gate (max 2.5 ms per section with the right modes).
- `line_route.MODES`: RAIL `{ TRAIN }` (same length as with ELECTRIC_TRAIN, 3× cheaper; catenary is checked
  separately), ROAD pax `{ BUS }`, ROAD cargo `{ TRUCK }`, TRAM `{ TRAM, ELECTRIC_TRAM }`; AIR none (no network path);
  WATER `{ SHIP, SMALL_SHIP }` provisional until a ship line is probed (a failed path only falls back to the straight
  line).
- Wrong modes are expensive (tram line with bus modes: 13.7 ms for a 15.9 km street detour) → modes strictly per carrier.
