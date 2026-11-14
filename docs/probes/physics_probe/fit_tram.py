import re, sys, math
rx = re.compile(r"veh 270742 stop (\d+) .*?speed ([\d.]+) km/h, accel ([+-][\d.]+), edge ([+-]?[\d.]+)%.*?last \d+ m ([+-]?[\d.]+)%")
m0, P, TE = 26.0, 120.0, 45.0
rows = []
for line in open(sys.argv[1]):
    mm = rx.search(line)
    if not mm: continue
    v, a, se, sl = float(mm.group(2)) / 3.6, float(mm.group(3)), float(mm.group(4)) / 100, float(mm.group(5)) / 100
    if a <= 0.001 or v < 0.5: continue   # cruising/held (road vehicles report 0), braking
    rows.append((v, a, se, sl))
print(len(rows), "tram samples accelerating")
for k in (1, 2):
    for mu in (0.0, 0.02, 0.1):
        errs = []
        for v, a, se, sl in rows:
            F = min(k * TE, P / v)
            p = (F - mu * m0 - 3.27 * se * m0) / m0
            errs.append(a - p)
        errs.sort()
        med = errs[len(errs) // 2]
        q1, q3 = errs[len(errs) // 4], errs[3 * len(errs) // 4]
        print("TEx%d mu=%.2f  median err %+.3f  IQR %+.3f..%+.3f" % (k, mu, med, q1, q3))
print("samples below the TE knee (v < P/TE = %.1f km/h):" % (P / TE * 3.6))
for v, a, se, sl in sorted(rows)[:8]:
    print("  %.1f km/h a=%.3f  TEx1 %.3f TEx2 %.3f" % (v * 3.6, a, (min(TE, P / v) - 0.52 - 3.27 * se * m0) / m0, (min(2 * TE, P / v) - 0.52 - 3.27 * se * m0) / m0))
