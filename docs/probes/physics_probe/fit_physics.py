import re, sys, math, itertools, collections
src = sys.argv[1]
rx = re.compile(r"probe line (\d+) veh (\d+) stop (\d+) edge (\d+)/(\d+) pos (-?[\d.]+) m: speed ([\d.]+) km/h, accel ([+-][\d.]+), edge ([+-]?[\d.]+)%(?:\(dir\?\))?, last (\d+) m ([+-]?[\d.]+)%, h")
cons = {  # from the consist log lines
 '156547': dict(m0=254.0, pay=168.0, P=1150, TE=250, top=80/3.6, parts=15),
 '47526':  dict(m0=254.0, pay=168.0, P=1150, TE=250, top=80/3.6, parts=15),
 '134436': dict(m0=1.5, pay=14.4, P=34, TE=5, top=30/3.6, parts=1),
 '55748':  dict(m0=1.5, pay=14.4, P=34, TE=5, top=30/3.6, parts=1),
 '130883': dict(m0=1.5, pay=14.4, P=34, TE=5, top=30/3.6, parts=1),
 '270742': dict(m0=26.0, pay=14.4, P=120, TE=45, top=60/3.6, parts=1),
}
S = []
for line in open(src, errors='replace'):
    mm = rx.search(line)
    if not mm: continue
    l, v, stop, e, n, pos, kmh, acc, eg, lastn, lg = mm.groups()
    if v not in cons: continue
    S.append(dict(line=l, veh=v, stop=int(stop), v=float(kmh)/3.6, a=float(acc), se=float(eg)/100, sl=float(lg)/100))
print(len(S), "samples")
G = 3.27
def pred(s, c, k, mass, mu, grade, fade, cap=None):
    m = c['m0'] + (c['pay'] if mass == 'full' else 0)
    v = max(s['v'], 0.01)
    F = min(k * c['TE'], c['P'] / v)
    g = {'edge': s['se'], 'last': s['sl'], 'mean': (s['se'] + s['sl']) / 2}[grade]
    R = mu * m + G * g * m
    a = (F - R) / m
    if fade and a > 0:
        lim = c['top'] if cap is None else min(c['top'], cap)
        x = min(1, max(0, (v / (lim + 0.136) - 0.95) * 20))
        a *= (1 - x * x)
    return a
groups = collections.defaultdict(list)
for s in S:
    if s['a'] <= 0.0005: continue          # braking / standing
    kind = 'train' if cons[s['veh']]['parts'] > 1 else ('truck' if cons[s['veh']]['m0'] < 5 else 'tram')
    groups[kind].append(s)
for kind, ss in groups.items():
    print(f"\n== {kind}: {len(ss)} samples with accel > 0")
    res = []
    for k, mass, mu, grade, fade in itertools.product((1, 2), ('empty', 'full'), (0, 0.01, 0.02, 0.03, 0.05, 0.1), ('edge', 'last', 'mean'), (False, True)):
        err = [s['a'] - pred(s, cons[s['veh']], k, mass, mu, grade, fade) for s in ss]
        rms = math.sqrt(sum(x * x for x in err) / len(err))
        res.append((rms, k, mass, mu, grade, fade, sum(err) / len(err)))
    res.sort()
    for r in res[:8]:
        print("rms %.4f  TEx%d  mass=%-5s mu=%.2f grade=%-4s fade=%-5s bias %+.4f" % r)
    # split by stop (direction) and regime for the best model
    best = res[0]
    by = collections.defaultdict(list)
    for s in ss:
        c = cons[s['veh']]
        regime = 'top' if s['v'] > 0.95 * c['top'] else ('TE' if s['v'] < c['P'] / (2 * c['TE']) else 'power')
        for mass in ('empty', 'full'):
            by[(s['stop'], regime, mass)].append(s['a'] - pred(s, c, best[1], mass, best[3], best[4], best[5]))
    for key in sorted(by):
        e = by[key]
        print("  stop %d %-5s mass=%-5s n=%3d mean err %+.4f rms %.4f" % (key[0], key[1], key[2], len(e), sum(e)/len(e), math.sqrt(sum(x*x for x in e)/len(e))))
