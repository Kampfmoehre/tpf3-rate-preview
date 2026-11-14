# Physics probe (2026-11-14)

Question (plan `docs/superpowers/plans/2026-11-13-route-and-physics.md`, Task 5): do the engine rules from Vehicle
Power Tooltip 6419746 rev 7 `physics.txt` (decompiled, partly tested by its author) hold: doubled tractive effort,
empty weight, rolling resistance 0.02 kN per tonne, top-speed fade?

Data: `track_limits.lua` with `LOG_READS = true` (both copies, the shared collector belongs to whichever mod loads
first) logs every 2 s for vehicles of lines with an open window: speed, `MOVE_PATH.dyn.accel`, grade of the current edge
and of the last ~300 m. Big save, build 40444, 10 min at 1×: two identical freight trains (Chinesische Baureihe JF1 +
14 wagons, 254 t empty, 168 t payload, 1150 kW, 250 kN, 80 km/h, loaded one way), Tram 101 (Gotha T1, 26 t, 120 kW,
45 kN, 60 km/h), three trucks (Benz Dreitonner, 1.5 t, 34 kW, 5 kN, 30 km/h). Fits: `fit_physics.py`, `fit_tram.py`
(run with `python3 -I fit_physics.py <probe lines>`).

Model: `a = fade(v) · (min(k · TE, P / v) − μ · m − 3.27 · s · m) / m`,
`fade = 1 − x²`, `x = clamp((v / (limit + 0.136) − 0.95) · 20, 0, 1)` for positive accelerations.

## Train (724 accelerating samples)

| Variant | rms (m/s²) |
|---|---|
| **k = 2, empty mass, μ = 0.02, grade of the current edge, fade** | **0.018** |
| same, μ = 0.01 | 0.018 (bias −0.004) |
| same, grade over the last 300 m | 0.021 |
| k = 2, empty, μ = 0, fade | 0.021 (bias −0.010) |
| full mass (empty + payload) | ≥ 0.15 in every regime |

- **Tractive effort counts twice:** starting at 2.8 km/h `a = 1.96`; 2 · 250 kN gives 1.95, 1 · 250 kN 0.96.
- **Empty weight in both directions:** loaded and empty legs (stops 0-3) all fit the empty mass (mean error < 0.02);
  the full mass is off by +0.15 in the power regime and +0.8 at the start. Matches our gradient measurement of
  2026-10-18 (`simulateCargoWeight == true` notwithstanding).
- **Rolling resistance 0.02 kN per tonne** (5.1 kN for 254 t), not 0.02 per part.
- **Fade at top speed:** at 80 km/h the engine reports `a ≈ 0.04` with the fade, rms 0.002 on three of four legs.
- G = 3.27 confirmed again (grade term).

## Tram (203 accelerating samples, held/braking excluded)

- **k = 2** below the knee (2.5 km/h: `a = 3.46`, k = 2 gives 3.44, k = 1 1.71).
- Power regime: μ between 0 and 0.02 (median error −0.009 / +0.011); 0.02 adopted like rail.
- Street speed limits hold the tram often (accel reported as 0 while held), so the fade was not checked.

## Road (trucks)

Not usable: road vehicles report `accel = 0` while cruising or held, and the trucks drove at 30 km/h nearly all the
time (1 accelerating sample of 250). The one sample (19 km/h, 5.3 m/s²) is above every variant with friction, so road
may use other rules. **Road stays on the old model.**

## Verdict

Adopt for rail and tram: TE × 2, empty weight, μ = 0.02 kN/t, fade with offset 0.136 m/s. Road: unchanged.
