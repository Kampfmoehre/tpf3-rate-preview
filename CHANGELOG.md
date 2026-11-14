# Changelog

## 0.18.0 (2026-11-14)

- Real routes: the game's pathfinder gives the track between the stops, also for lines without vehicles. The speed
  row of an empty line now knows track limits, climbs and missing catenary, and the rough estimate uses the real
  round-trip length once enough of your lines have a route (first test: 127 instead of 137, the game settled at 123).
- Engine physics for trains and trams, measured in game: twice the tractive effort, empty weight (a loaded train
  climbs like an empty one), rolling resistance 0.02 kN per tonne and the slow last 5 % below the speed limit. The
  "reaches ≈ X km/h" line and the climb speeds of trains come out higher and closer to what they drive. Road vehicles
  keep the old model.
- Missing catenary and the slowest climb speed are shown on their own short lines below the speed row instead of
  after it, so the text takes less width from the vehicle preview in the cart (the game's preview branch enlarged it).

## 0.17.1 (2026-11-02)

- Capacity counts the cargo types loaded at the line's stops, not only those the line's vehicles can
  already carry: adding goods wagons for fish to an oil train now raises the estimate like the game
  does (147 -> 189 instead of staying at 147, reported in Steinwallen's video).
- New lines: the game's capacity stays 0 for about a minute after the first vehicle joins while its
  rate is already known; the estimate then counts the line's vehicles itself instead of showing
  "n/a (no vehicle on the line yet)". If the game has no rate yet, the text now says so.
- Log line when the store opens (cargo types behind the capacity) and on each changed estimate.

## 0.17.0 (2026-10-18)

- Climbs: on sections the line's vehicles have driven, the store simulates the cart's consist over
  the real track heights and appends the slowest speed to the speed row, e.g.
  "Gradient 12 %: ≈ 18 km/h" (tooltip: every affected section).
- Catenary: warns when the consist needs catenary (electric engines) and a known section has none,
  e.g. "no catenary (1 of 3 sections, 2 not known yet)" (tooltip: missing metres and where they start).
- Reachable speed: the weight now uses the game's cargo weights (goods 1.0, passengers 1/6 of the
  max payload), which brings the shown speed of passenger trains closer to what they drive.

## 0.16.1 (2026-10-16)

- Opening the store or a window re-reads the line's track, so a track upgrade shows within seconds
  instead of up to 5 minutes.

## 0.16.0 (2026-10-16)

- Reachable speed uses the real track length and speed limit of the sections driven since loading
  (shared with Top Speed Reached), the straight-line distance only for the others.

## 0.15.2 (2026-10-11)

- Performance: the cart text and the line's reference speed are cached; replacing many vehicles at
  once no longer drops the frame rate.

## 0.15.1 (2026-10-11)

- Replace mode: the preview moves into the cart entry, because the bottom bar is already full
  there (works together with Better Vehicle Stats).

## 0.15.0 (2026-10-11)

- Reachable speed between the stops of the line for land vehicles (mod parameter, on by default):
  "reaches ≈ X km/h", or a green check mark when the top speed is reached.

## 0.14.0 (2026-10-09)

- Optional rough estimate for lines without vehicles (mod parameter): the round trip is modelled
  from the straight-line distance, the stops and the loading times, calibrated on your other lines.

## 0.12.6 (2026-10-07)

- Fix: correct recalculation when the new vehicle does not differ from the current one.

## 0.12.5 (2026-10-07)

- Improved calculation; a (+)/(-) indicator shows when the new vehicle is faster or slower than the
  line's current ones.

## 0.11.0 (2026-10-04)

- First release: estimated line rate and frequency when vehicles are bought, modified or replaced.
