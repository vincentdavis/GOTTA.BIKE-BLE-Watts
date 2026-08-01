#!/usr/bin/env python3
"""Fit CdA, Crr and effective mass from a Zwift .FIT ride recorded while the
phone CPS emulator played the scripted "CdA · Crr · Mass estimation" profile.

Physics — the flat-ground, solo (no-wind) cycling power balance Zwift approximates:

    m_eff * dv/dt  =  eta*P/v  -  (0.5*rho*CdA*v^2 + Crr*m*g)

On a flat, solo course the only unknowns are CdA, the rolling force
C_roll = Crr*m*g, and effective mass m_eff. eta (drivetrain efficiency) and rho
(air density) are DEGENERATE with the overall force scale, so they are pinned
(eta=1, rho=1.225) — the fitted CdA/Crr are therefore "Zwift-model units".
Compare equipment as DELTAS, not absolutes.

What is identifiable on the flat: {CdA, C_roll = Crr*m*g, m_eff}. You cannot
split Crr from mass without the Drop-Shop catalog weight (pass --mass) or a
known gradient. Wheel rotational inertia is below the noise floor here.

Three independent estimators are computed and cross-checked:
  * GLOBAL  — one-step-ahead RK4 fit of the whole (power, speed) trace. Headline.
  * STEADY  — regress eta*P/v on v^2 over settled plateaus  -> CdA and C_roll.
  * COAST   — regress dv/dt on v^2 over 0 W coasts (efficiency-free)
              -> CdA/m_eff and C_roll/m_eff; combine with STEADY for m_eff.

Usage:
    python fit_cda.py ride.fit                      # fit one ride
    python fit_cda.py base.fit wheelsA.fit ...      # compare setups (deltas vs first)
    python fit_cda.py ride.fit --mass 78.5          # also split Crr and mass
    python fit_cda.py --csv ride.csv                # CSV with columns time,power,speed[,altitude]
    python fit_cda.py --self-test                   # validate the fitter on synthetic data
"""

from __future__ import annotations

import argparse
import os
import sys

import numpy as np

G = 9.80665  # m/s^2
RHO_DEFAULT = 1.225  # kg/m^3 (Zwift sea-level)
ETA_DEFAULT = 1.0  # Zwift treats broadcast power as delivered power
P_REF = 250.0  # W, reference power for the 40 km "seconds saved" ranking

# The scripted profile as (duration_s, power_W) — mirrors kCdaCrrMassProfile in
# lib/power_profile.dart. Used only by --self-test (fitting itself reads the
# recorded power, not this table).
PROFILE = [
    (55, 130), (60, 200), (60, 320), (60, 480), (48, 0), (50, 550),
    (60, 250), (55, 400), (48, 0), (60, 100), (44, 300),
]


# --------------------------------------------------------------------------- #
# Forward model (shared by the global fit and the synthetic generator)
# --------------------------------------------------------------------------- #
def _accel(v, P, CdA, C_roll, m_eff, rho, eta, v_floor):
    """Instantaneous dv/dt (m/s^2)."""
    ve = v if v > v_floor else v_floor  # avoid the P/v singularity near v=0
    f_prop = (eta * P / ve) if P > 0.0 else 0.0
    f_res = 0.5 * rho * CdA * v * v + C_roll
    return (f_prop - f_res) / m_eff


def _rk4_step(v, P, params, dt, rho, eta, v_floor):
    CdA, C_roll, m_eff = params
    k1 = _accel(v, P, CdA, C_roll, m_eff, rho, eta, v_floor)
    k2 = _accel(v + 0.5 * dt * k1, P, CdA, C_roll, m_eff, rho, eta, v_floor)
    k3 = _accel(v + 0.5 * dt * k2, P, CdA, C_roll, m_eff, rho, eta, v_floor)
    k4 = _accel(v + dt * k3, P, CdA, C_roll, m_eff, rho, eta, v_floor)
    return v + (dt / 6.0) * (k1 + 2 * k2 + 2 * k3 + k4)


def simulate(P, params, v0, dt, rho, eta, v_floor=0.5):
    """Forward-integrate speed from a power series (used to make synthetic data)."""
    v = np.empty(len(P))
    v[0] = v0
    for i in range(1, len(P)):
        v[i] = max(_rk4_step(v[i - 1], P[i - 1], params, dt, rho, eta, v_floor), 0.0)
    return v


# --------------------------------------------------------------------------- #
# Estimators
# --------------------------------------------------------------------------- #
def fit_global(t, P, v, rho, eta, v_min=3.0):
    """One-step-ahead RK4 fit of {CdA, C_roll, m_eff}. Robust to integration
    drift because each sample is predicted from the *recorded* previous sample."""
    from scipy.optimize import least_squares

    dt = float(np.median(np.diff(t)))
    target = v[1:]
    mask = target > v_min  # skip the low-speed cap / launch region

    def resid(params):
        pred = np.array([
            _rk4_step(v[i - 1], P[i - 1], params, dt, rho, eta, 0.5)
            for i in range(1, len(v))
        ])
        return (pred - target)[mask]

    x0 = [0.30, 5.0, 80.0]
    bounds = ([0.10, 0.0, 40.0], [0.60, 60.0, 130.0])
    res = least_squares(resid, x0, bounds=bounds, method="trf")
    r = res.fun
    rms = float(np.sqrt(np.mean(r ** 2))) if r.size else float("nan")
    return dict(CdA=res.x[0], C_roll=res.x[1], m_eff=res.x[2],
                rms_ms=rms, success=bool(res.success), n=int(mask.sum()))


def _runs(mask):
    """Yield (start, end) index runs where mask is True (end exclusive)."""
    i, n = 0, len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j < n and mask[j]:
                j += 1
            yield i, j
            i = j
        else:
            i += 1


def find_coasts(P, t, p_thresh=5.0, min_dur=12.0):
    return [(a, b) for a, b in _runs(P <= p_thresh) if t[b - 1] - t[a] >= min_dur]


def fit_coasts(t, P, v, rho, edge_skip=2.0, v_tail_min=3.0):
    """Regress dv/dt on v^2 over coasts -> CdA/m_eff and C_roll/m_eff."""
    from scipy.signal import savgol_filter

    xs, ys, nseg = [], [], 0
    for a, b in find_coasts(P, t):
        vv, tt = v[a:b], t[a:b]
        if len(vv) < 9:
            continue
        w = min(11, len(vv) - (1 - len(vv) % 2))  # odd window <= len
        if w < 5:
            continue
        vs = savgol_filter(vv, w, 2)
        dvdt = np.gradient(vs, tt)
        keep = ((tt - tt[0]) > edge_skip) & (vs > v_tail_min)
        if keep.sum() < 3:
            continue
        xs.append(vs[keep] ** 2)
        ys.append(dvdt[keep])
        nseg += 1
    if not xs:
        return None
    x, y = np.concatenate(xs), np.concatenate(ys)
    A = np.vstack([x, np.ones_like(x)]).T
    slope, intercept = np.linalg.lstsq(A, y, rcond=None)[0]
    return dict(CdA_over_meff=-2.0 * slope / rho,
                Croll_over_meff=-intercept, n=len(x), segs=nseg)


def find_steady(t, P, tol=8.0, min_dur=30.0, min_power=20.0):
    segs = []
    i, n = 0, len(P)
    while i < n:
        if P[i] <= min_power:
            i += 1
            continue
        j = i
        while j < n and abs(P[j] - P[i]) <= tol:
            j += 1
        if t[j - 1] - t[i] >= min_dur:
            segs.append((i, j))
        i = max(j, i + 1)
    return segs


def fit_steady(t, P, v, rho, eta, tail=15.0):
    """Regress eta*P/v on v^2 over settled plateau tails -> CdA and C_roll."""
    pts = []
    for a, b in find_steady(t, P):
        tt = t[a:b]
        keep = tt >= (tt[-1] - tail)
        vm, pm = float(np.mean(v[a:b][keep])), float(np.mean(P[a:b][keep]))
        if vm > 3.0:
            pts.append((vm, pm))
    if len(pts) < 2:
        return None
    varr = np.array([p[0] for p in pts])
    parr = np.array([p[1] for p in pts])
    y = eta * parr / varr
    A = np.vstack([varr ** 2, np.ones_like(varr)]).T
    slope, intercept = np.linalg.lstsq(A, y, rcond=None)[0]
    return dict(CdA=2.0 * slope / rho, C_roll=intercept,
                points=sorted(zip(varr.tolist(), parr.tolist())))


# --------------------------------------------------------------------------- #
# Ranking
# --------------------------------------------------------------------------- #
def steady_speed(power, CdA, C_roll, rho):
    """Solve power = 0.5*rho*CdA*v^3 + C_roll*v for v>0 (bisection)."""
    lo, hi = 0.1, 40.0
    for _ in range(100):
        mid = 0.5 * (lo + hi)
        if 0.5 * rho * CdA * mid ** 3 + C_roll * mid - power > 0:
            hi = mid
        else:
            lo = mid
    return 0.5 * (lo + hi)


def time_40k(CdA, C_roll, rho, power=P_REF, dist=40000.0):
    return dist / steady_speed(power, CdA, C_roll, rho)


# --------------------------------------------------------------------------- #
# I/O
# --------------------------------------------------------------------------- #
def _resample_1hz(t, P, v, alt):
    grid = np.arange(0.0, np.floor(t[-1]) + 1.0, 1.0)
    Pg = np.interp(grid, t, P)
    vg = np.interp(grid, t, v)
    altg = (np.interp(grid, t, alt)
            if np.isfinite(alt).any() else np.full_like(grid, np.nan))
    return grid, Pg, vg, altg


def load_fit(path):
    try:
        from fitparse import FitFile
    except ImportError:
        sys.exit("Missing dependency: pip install fitparse  (see requirements.txt)")
    rows = []
    for msg in FitFile(path).get_messages("record"):
        d = {f.name: f.value for f in msg}
        ts = d.get("timestamp")
        spd = d.get("enhanced_speed", d.get("speed"))
        if ts is None or spd is None:
            continue
        pwr = d.get("power")
        alt = d.get("enhanced_altitude", d.get("altitude"))
        rows.append((ts, float(pwr) if pwr is not None else 0.0, float(spd),
                     float(alt) if alt is not None else np.nan))
    if not rows:
        sys.exit(f"No usable 'record' messages (need speed) in {path}")
    rows.sort(key=lambda r: r[0])
    t0 = rows[0][0]
    t = np.array([(r[0] - t0).total_seconds() for r in rows])
    return _resample_1hz(t, np.array([r[1] for r in rows]),
                         np.array([r[2] for r in rows]),
                         np.array([r[3] for r in rows]))


def load_csv(path):
    import csv
    t, P, v, alt = [], [], [], []
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            t.append(float(row["time"]))
            P.append(float(row.get("power", 0) or 0))
            v.append(float(row["speed"]))
            alt.append(float(row.get("altitude", "nan") or "nan"))
    if not t:
        sys.exit(f"No rows in {path}")
    return _resample_1hz(np.array(t), np.array(P), np.array(v), np.array(alt))


# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #
def analyse(label, t, P, v, alt, rho, eta, mass):
    g = fit_global(t, P, v, rho, eta)
    s = fit_steady(t, P, v, rho, eta)
    c = fit_coasts(t, P, v, rho)

    print(f"\n=== {label} ===")
    if np.isfinite(alt).any():
        drop = float(np.nanmax(alt) - np.nanmin(alt))
        flag = "  <-- NOT flat: add a gradient term!" if drop > 3.0 else ""
        print(f"altitude range: {drop:.1f} m{flag}")
    print(f"samples: {len(t)}s   speed {v.min():.1f}-{v.max():.1f} m/s "
          f"({v.min()*3.6:.0f}-{v.max()*3.6:.0f} km/h)")

    print("GLOBAL (headline):  "
          f"CdA={g['CdA']:.4f} m^2   C_roll={g['C_roll']:.2f} N   "
          f"m_eff={g['m_eff']:.1f} kg   (fit RMS {g['rms_ms']*3.6:.2f} km/h)")
    if s:
        print(f"STEADY cross-check: CdA={s['CdA']:.4f}   C_roll={s['C_roll']:.2f} N "
              f"  ({len(s['points'])} plateaus)")
    if c:
        line = (f"COAST cross-check:  CdA/m_eff={c['CdA_over_meff']:.2e}   "
                f"C_roll/m_eff={c['Croll_over_meff']:.4f}   ({c['segs']} coasts)")
        if s:
            m_from_cda = s["CdA"] / c["CdA_over_meff"] if c["CdA_over_meff"] else float("nan")
            m_from_roll = s["C_roll"] / c["Croll_over_meff"] if c["Croll_over_meff"] else float("nan")
            line += f"\n                    -> m_eff (steady x coast): " \
                    f"{m_from_cda:.1f} kg (via CdA), {m_from_roll:.1f} kg (via C_roll)"
        print(line)

    crr_m = g["C_roll"] / G  # Crr * m  (kg)
    if mass:
        print(f"With catalog mass {mass:.1f} kg:  "
              f"Crr={g['C_roll'] / (mass * G):.5f}   "
              f"m_eff-m={g['m_eff'] - mass:+.1f} kg (rotational-inertia check)")
    else:
        print(f"Crr*mass product = {crr_m:.2f} kg  "
              f"(pass --mass to split Crr from mass)")
    return g


def compare(results, rho):
    if len(results) < 2:
        return
    base = results[0][1]
    print("\n=== SETUP COMPARISON (deltas vs first; +CdA/+time = slower) ===")
    hdr = f"{'setup':22} {'CdA':>7} {'dCdA':>8} {'C_roll':>7} {'m_eff':>7} " \
          f"{'40km@250W':>10} {'d(s)':>7}"
    print(hdr)
    t_base = time_40k(base["CdA"], base["C_roll"], rho)
    for label, g in results:
        tt = time_40k(g["CdA"], g["C_roll"], rho)
        print(f"{label[:22]:22} {g['CdA']:7.4f} {g['CdA'] - base['CdA']:+8.4f} "
              f"{g['C_roll']:7.2f} {g['m_eff']:7.1f} "
              f"{tt/60:9.2f}m {tt - t_base:+7.1f}")
    print("(40km time at a fixed 250 W on the flat; mass barely moves it — aero dominates.)")


# --------------------------------------------------------------------------- #
# Self-test: recover known parameters from synthetic data
# --------------------------------------------------------------------------- #
def _profile_1hz():
    P = []
    for dur, pw in PROFILE:
        P.extend([float(pw)] * dur)
    return np.array(P), np.arange(len(P), dtype=float)


def self_test():
    P, t = _profile_1hz()
    rho, eta = RHO_DEFAULT, ETA_DEFAULT
    truth = dict(CdA=0.3030, C_roll=3.00, m_eff=78.0)  # Crr ~ 0.0039 @ 78 kg
    v = simulate(P, (truth["CdA"], truth["C_roll"], truth["m_eff"]),
                 v0=0.5, dt=1.0, rho=rho, eta=eta)
    rng = np.random.default_rng(0)
    v_noisy = v + rng.normal(0.0, 0.02, len(v))  # 2 cm/s of noise
    alt = np.zeros_like(v)

    print("Synthetic recovery test (2 cm/s speed noise):")
    print(f"  speed range {v.min()*3.6:.0f}-{v.max()*3.6:.0f} km/h")
    g = analyse("SYNTHETIC", t, P, v_noisy, alt, rho, eta, mass=78.0)

    ok = (abs(g["CdA"] - truth["CdA"]) < 0.005
          and abs(g["C_roll"] - truth["C_roll"]) < 0.5
          and abs(g["m_eff"] - truth["m_eff"]) < 3.0)
    print(f"\ntruth: {truth}")
    print(f"fit:   CdA={g['CdA']:.4f} C_roll={g['C_roll']:.2f} m_eff={g['m_eff']:.1f}")
    print("SELF-TEST:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


# --------------------------------------------------------------------------- #
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help=".fit (or .csv with --csv) rides")
    ap.add_argument("--csv", action="store_true", help="inputs are CSV: time,power,speed[,altitude]")
    ap.add_argument("--mass", type=float, default=None, help="catalog rider+bike mass (kg) to split Crr from mass")
    ap.add_argument("--rho", type=float, default=RHO_DEFAULT, help="air density (default 1.225)")
    ap.add_argument("--eta", type=float, default=ETA_DEFAULT, help="drivetrain efficiency (default 1.0)")
    ap.add_argument("--labels", nargs="*", default=None, help="labels for the files (for comparison)")
    ap.add_argument("--self-test", action="store_true", help="validate the fitter on synthetic data")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.files:
        ap.error("provide one or more ride files, or --self-test")

    loader = load_csv if args.csv else load_fit
    results = []
    for i, path in enumerate(args.files):
        if not os.path.exists(path):
            sys.exit(f"No such file: {path}")
        label = (args.labels[i] if args.labels and i < len(args.labels)
                 else os.path.splitext(os.path.basename(path))[0])
        t, P, v, alt = loader(path)
        results.append((label, analyse(label, t, P, v, alt, args.rho, args.eta, args.mass)))

    compare(results, args.rho)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
