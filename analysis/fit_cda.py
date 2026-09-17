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
  * GLOBAL  — one-step-ahead RK4 fit of the whole (power, speed) trace. Headline,
              reported with standard errors, 95% CIs and parameter correlations.
  * STEADY  — regress eta*P/v on v^2 over settled plateaus  -> CdA and C_roll.
  * COAST   — regress dv/dt on v^2 over 0 W coasts (efficiency-free)
              -> CdA/m_eff and C_roll/m_eff; combine with STEADY for m_eff.

Trust diagnostics:
  * GLOBAL uncertainty — Jacobian standard errors, inflated for lag-1 residual
    autocorrelation, plus the condition number of the problem.
  * timing check — refits with the power trace shifted by -2..+2 s. A clearly
    better shift means power and speed are misaligned in time (fix: --power-lag).
  * --plot — per-ride PNGs (speed vs model, residuals, STEADY/COAST regressions)
    and, for two or more rides, a setup-comparison chart. Needs matplotlib.

Usage:
    python fit_cda.py ride.fit                      # fit one ride
    python fit_cda.py base.fit wheelsA.fit ...      # compare setups (deltas vs first)
    python fit_cda.py ride.fit --mass 78.5          # also split Crr and mass
    python fit_cda.py --csv ride.csv                # CSV with columns time,power,speed[,altitude]
    python fit_cda.py a.fit b.fit --plot            # also write diagnostic PNGs to ./fit_plots
    python fit_cda.py ride.fit --power-lag 1        # speed responds 1 s after the recorded power
    python fit_cda.py --self-test                   # validate the fitter on synthetic data
"""

from __future__ import annotations

import argparse
import math
import os
import re
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

PARAMS = ("CdA", "C_roll", "m_eff")
PARAM_UNITS = {"CdA": "m^2", "C_roll": "N", "m_eff": "kg"}
PARAM_DECIMALS = {"CdA": 4, "C_roll": 2, "m_eff": 1}

V_FLOOR = 0.5  # m/s, floor under v in P/v (avoids the singularity at standstill)
V_MIN_FIT = 3.0  # m/s, samples at or below this are left out of the fits

# Uncertainty model (see README "Uncertainty model").
AC_MAX = 0.95  # cap on the lag-1 autocorrelation used for inflation (variance x <= 39)
COND_WARN = 1e3  # column-scaled cond(J^T J) above this -> parameters nearly degenerate
PINV_RCOND = 1e-8  # singular values of the scaled Jacobian below this x max are dropped
SIG_Z = 2.0  # a delta is "significant" when |delta| > SIG_Z * sigma

# Timing check: refit with the power trace shifted by these many seconds.
LAG_SCAN = (-2, -1, 0, 1, 2)
LAG_WARN_RATIO = 0.9  # warn when another shift's RMS is below 90% of the in-use RMS

SIM_MAX_HORIZON = 120.0  # s, the forward simulation re-anchors at least this often
MISFIT_WARN = 2.0  # forward-sim RMS / one-step RMS above this -> slow model misfit
RESID_SMOOTH = 15  # samples, moving mean drawn over the residual plot


# --------------------------------------------------------------------------- #
# Forward model (shared by the global fit, the plots and the synthetic generator)
# --------------------------------------------------------------------------- #
def _accel(v, P, CdA, C_roll, m_eff, rho, eta, v_floor):
    """Instantaneous dv/dt (m/s^2). ``v`` and ``P`` may be scalars or arrays."""
    ve = np.maximum(v, v_floor)  # avoid the P/v singularity near v=0
    f_prop = np.where(P > 0.0, eta * P / ve, 0.0)
    f_res = 0.5 * rho * CdA * v * v + C_roll
    return (f_prop - f_res) / m_eff


def _rk4_step(v, P, params, dt, rho, eta, v_floor):
    CdA, C_roll, m_eff = params
    k1 = _accel(v, P, CdA, C_roll, m_eff, rho, eta, v_floor)
    k2 = _accel(v + 0.5 * dt * k1, P, CdA, C_roll, m_eff, rho, eta, v_floor)
    k3 = _accel(v + 0.5 * dt * k2, P, CdA, C_roll, m_eff, rho, eta, v_floor)
    k4 = _accel(v + dt * k3, P, CdA, C_roll, m_eff, rho, eta, v_floor)
    return v + (dt / 6.0) * (k1 + 2 * k2 + 2 * k3 + k4)


def simulate(P, params, v0, dt, rho, eta, v_floor=V_FLOOR):
    """Forward-integrate speed from a power series (used to make synthetic data)."""
    v = np.empty(len(P))
    v[0] = v0
    for i in range(1, len(P)):
        v[i] = max(_rk4_step(v[i - 1], P[i - 1], params, dt, rho, eta, v_floor), 0.0)
    return v


def one_step(P, v, params, dt, rho, eta, v_floor=V_FLOOR):
    """pred[i] = one RK4 step from the RECORDED v[i-1] under P[i-1]; pred[0] = nan."""
    pred = np.full(len(v), np.nan)
    pred[1:] = _rk4_step(v[:-1], P[:-1], params, dt, rho, eta, v_floor)
    return pred


def shift_power(P, lag):
    """Delay the power trace by ``lag`` samples: lag > 0 means the speed responds
    ``lag`` seconds after the recorded power (lag < 0: before). Edges repeat."""
    if not lag:
        return P
    idx = np.clip(np.arange(len(P)) - int(lag), 0, len(P) - 1)
    return P[idx]


# --------------------------------------------------------------------------- #
# Uncertainty helpers
# --------------------------------------------------------------------------- #
def lag1_autocorr(r, pos=None):
    """Lag-1 autocorrelation of a residual series. With ``pos`` (the sample index
    of each residual) only pairs that are adjacent in time count, so gaps and
    segment boundaries are never bridged. Returns nan when undefined."""
    r = np.asarray(r, dtype=float)
    if r.size < 3:
        return float("nan")
    e = r - r.mean()
    den = float(e @ e)
    adj = np.ones(r.size - 1, dtype=bool) if pos is None else (np.diff(pos) == 1)
    m = int(adj.sum())
    if den <= 0.0 or m < 2:
        return float("nan")
    num = float(np.sum(e[:-1][adj] * e[1:][adj]))
    return float(np.clip(num / den * (r.size / m), -1.0, 1.0))


def _inflation(r1):
    """AR(1) variance inflation (1 + r1)/(1 - r1) = n / n_eff. Negative or
    undefined r1 is treated as 0: the correction only ever widens the SEs."""
    used = min(max(r1, 0.0), AC_MAX) if np.isfinite(r1) else 0.0
    return used, (1.0 + used) / (1.0 - used)


def _lsq_uncertainty(J, r, pos, x):
    """Covariance of a nonlinear least-squares fit from its Jacobian:
    cov = s2 * pinv(J^T J), s2 = RSS/(n - p), inflated for lag-1 autocorrelation."""
    from scipy.stats import t as student_t

    J = np.asarray(J, dtype=float)
    n, p = J.shape
    dof = n - p
    nan_p = np.full(p, np.nan)
    if dof <= 0:
        return dict(cov=np.full((p, p), np.nan), cov_raw=np.full((p, p), np.nan),
                    se=dict(zip(PARAMS, nan_p)), se_raw=dict(zip(PARAMS, nan_p)),
                    corr=np.full((p, p), np.nan),
                    ci95={k: (np.nan, np.nan) for k in PARAMS},
                    r1=np.nan, r1_used=0.0, infl=1.0, n_eff=float(n), dof=dof,
                    dof_eff=np.nan, tcrit=np.nan, cond=np.inf, rank_deficient=True,
                    s2=np.nan)
    s2 = float(r @ r) / dof
    # Column scaling makes the condition number unit-free (CdA ~0.3 vs m ~80).
    norms = np.linalg.norm(J, axis=0)
    norms[norms == 0.0] = 1.0
    _, sv, vt = np.linalg.svd(J / norms, full_matrices=False)
    keep = sv > PINV_RCOND * sv[0]
    cond = float((sv[0] / sv[-1]) ** 2) if sv[-1] > 0.0 else float("inf")
    # Pseudo-inverse of the scaled J^T J (V diag(1/s^2) V^T), then undo the scaling.
    inv_scaled = (vt[keep].T / sv[keep] ** 2) @ vt[keep]
    cov_raw = s2 * inv_scaled / np.outer(norms, norms)

    r1 = lag1_autocorr(r, pos)
    r1_used, infl = _inflation(r1)
    cov = cov_raw * infl
    se_raw = np.sqrt(np.diag(cov_raw))
    se = np.sqrt(np.diag(cov))
    n_eff = n / infl
    dof_eff = max(n_eff - p, 1.0)
    tcrit = float(student_t.ppf(0.975, dof_eff))
    with np.errstate(invalid="ignore", divide="ignore"):
        corr = cov / np.outer(se, se)
    ci95 = {k: (float(x[i] - tcrit * se[i]), float(x[i] + tcrit * se[i]))
            for i, k in enumerate(PARAMS)}
    return dict(cov=cov, cov_raw=cov_raw, se=dict(zip(PARAMS, se.tolist())),
                se_raw=dict(zip(PARAMS, se_raw.tolist())), corr=corr, ci95=ci95,
                r1=r1, r1_used=r1_used, infl=infl, n_eff=n_eff, dof=dof,
                dof_eff=dof_eff, tcrit=tcrit, cond=cond,
                rank_deficient=bool(not keep.all()), s2=s2)


def _ols(x, y, pos=None):
    """Straight line y = slope*x + intercept with standard errors and R^2. With
    ``pos`` the covariance is also inflated for lag-1 residual autocorrelation."""
    x = np.asarray(x, dtype=float)
    y = np.asarray(y, dtype=float)
    A = np.column_stack([x, np.ones_like(x)])
    coef = np.linalg.lstsq(A, y, rcond=None)[0]
    resid = y - A @ coef
    rss = float(resid @ resid)
    tss = float(np.sum((y - y.mean()) ** 2))
    dof = x.size - 2
    if dof > 0:
        cov_raw = rss / dof * np.linalg.pinv(A.T @ A)
    else:
        cov_raw = np.full((2, 2), np.nan)
    r1 = lag1_autocorr(resid, pos) if pos is not None else float("nan")
    r1_used, infl = _inflation(r1)
    return dict(slope=float(coef[0]), intercept=float(coef[1]),
                r2=(1.0 - rss / tss) if tss > 0.0 else float("nan"),
                n=int(x.size), dof=dof, cov_raw=cov_raw, cov=cov_raw * infl,
                r1=r1, r1_used=r1_used, infl=infl, resid=resid)


# --------------------------------------------------------------------------- #
# Estimators
# --------------------------------------------------------------------------- #
def _fit_one_step(P, v, dt, rho, eta, mask):
    """least_squares on the one-step-ahead residuals selected by ``mask``."""
    from scipy.optimize import least_squares

    target = v[1:]

    def resid(params):
        pred = _rk4_step(v[:-1], P[:-1], params, dt, rho, eta, V_FLOOR)
        return (pred - target)[mask]

    x0 = [0.30, 5.0, 80.0]
    bounds = ([0.10, 0.0, 40.0], [0.60, 60.0, 130.0])
    # Central differences: the Jacobian at the solution also feeds the covariance.
    return least_squares(resid, x0, bounds=bounds, method="trf", jac="3-point")


def fit_global(t, P, v, rho, eta, v_min=V_MIN_FIT):
    """One-step-ahead RK4 fit of {CdA, C_roll, m_eff}. Robust to integration
    drift because each sample is predicted from the *recorded* previous sample."""
    dt = float(np.median(np.diff(t)))
    mask = v[1:] > v_min  # skip the low-speed cap / launch region
    if mask.sum() < 10:
        raise ValueError(f"only {int(mask.sum())} samples above {v_min} m/s; "
                         "not enough to fit")
    res = _fit_one_step(P, v, dt, rho, eta, mask)
    r = res.fun
    pos = np.flatnonzero(mask) + 1  # sample index of each residual
    out = dict(CdA=float(res.x[0]), C_roll=float(res.x[1]), m_eff=float(res.x[2]),
               x=np.array(res.x, dtype=float),
               rms_ms=float(np.sqrt(np.mean(r ** 2))), success=bool(res.success),
               n=int(mask.sum()), dt=dt, resid=r, resid_idx=pos,
               at_bound=[PARAMS[i] for i in np.flatnonzero(res.active_mask)])
    out.update(_lsq_uncertainty(res.jac, r, pos, res.x))
    return out


def lag_scan(t, P, v, rho, eta, lags=LAG_SCAN, v_min=V_MIN_FIT):
    """Refit with the power trace shifted by each lag (relative to ``P``) on a
    common sample set; the one-step RMS tells which alignment the data prefer."""
    dt = float(np.median(np.diff(t)))
    trim = max(abs(k) for k in lags) + 1
    mask = v[1:] > v_min
    mask[:trim] = False
    mask[-trim:] = False
    if mask.sum() < 10:
        return None
    rows = []
    for lag in lags:
        res = _fit_one_step(shift_power(P, lag), v, dt, rho, eta, mask)
        rows.append(dict(lag=lag, rms_ms=float(np.sqrt(np.mean(res.fun ** 2))),
                         x=np.array(res.x, dtype=float)))
    best = min(rows, key=lambda row: row["rms_ms"])
    rms0 = next(row["rms_ms"] for row in rows if row["lag"] == 0)
    return dict(rows=rows, best=best["lag"], rms_best=best["rms_ms"], rms0=rms0,
                warn=bool(best["lag"] != 0 and best["rms_ms"] < LAG_WARN_RATIO * rms0))


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


def fit_coasts(t, P, v, rho, edge_skip=2.0, v_tail_min=V_MIN_FIT):
    """Regress dv/dt on v^2 over coasts -> CdA/m_eff and C_roll/m_eff."""
    from scipy.signal import savgol_filter

    xs, ys, idx, grp, nseg = [], [], [], [], 0
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
        idx.append(np.arange(a, b)[keep])
        grp.append(np.full(int(keep.sum()), nseg))
        nseg += 1
    if not xs:
        return None
    x, y = np.concatenate(xs), np.concatenate(ys)
    pos = np.concatenate(idx)
    fit = _ols(x, y, pos=pos)  # dv/dt samples are smoothed -> strongly autocorrelated
    k = 2.0 / rho
    se_raw = np.sqrt(np.diag(fit["cov_raw"]))
    se = np.sqrt(np.diag(fit["cov"]))
    return dict(CdA_over_meff=-k * fit["slope"], Croll_over_meff=-fit["intercept"],
                se_CdA_over_meff=k * se[0], se_Croll_over_meff=se[1],
                se_raw_CdA_over_meff=k * se_raw[0], se_raw_Croll_over_meff=se_raw[1],
                slope=fit["slope"], intercept=fit["intercept"], r2=fit["r2"],
                r1=fit["r1"], infl=fit["infl"], n=len(x), segs=nseg,
                x=x, y=y, group=np.concatenate(grp), idx=pos)


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
    pts, tails = [], []
    for a, b in find_steady(t, P):
        tt = t[a:b]
        keep = tt >= (tt[-1] - tail)
        vm, pm = float(np.mean(v[a:b][keep])), float(np.mean(P[a:b][keep]))
        if vm > V_MIN_FIT:
            pts.append((vm, pm))
            tails.append((a + int(np.argmax(keep)), b))
    if len(pts) < 2:
        return None
    varr = np.array([p[0] for p in pts])
    parr = np.array([p[1] for p in pts])
    x, y = varr ** 2, eta * parr / varr
    fit = _ols(x, y)  # one point per plateau: treated as independent
    k = 2.0 / rho
    se = np.sqrt(np.diag(fit["cov"]))
    return dict(CdA=k * fit["slope"], C_roll=fit["intercept"],
                se_CdA=k * se[0], se_C_roll=se[1],
                slope=fit["slope"], intercept=fit["intercept"], r2=fit["r2"],
                k=len(pts), dof=fit["dof"], n_samples=int(sum(b - a for a, b in tails)),
                x=x, y=y, tails=tails,
                points=sorted(zip(varr.tolist(), parr.tolist())))


# --------------------------------------------------------------------------- #
# Long-horizon check: forward simulation re-anchored per detected segment
# --------------------------------------------------------------------------- #
def segment_ride(t, P):
    """Cover the ride with (start, end, kind) segments: 'coast', 'steady', and
    'transition' for everything in between (end exclusive)."""
    marks = sorted([(a, b, "coast") for a, b in find_coasts(P, t)]
                   + [(a, b, "steady") for a, b in find_steady(t, P)])
    out, pos = [], 0
    for a, b, kind in marks:
        a = max(a, pos)
        if a >= b:
            continue
        if a > pos:
            out.append((pos, a, "transition"))
        out.append((a, b, kind))
        pos = b
    if pos < len(P):
        out.append((pos, len(P), "transition"))
    return out


def forward_sim(P, v, params, dt, rho, eta, segments, max_horizon=SIM_MAX_HORIZON):
    """Free-running model speed, re-anchored to the RECORDED speed at the start of
    each segment (and at least every ``max_horizon`` s) so drift stays bounded.
    Returns pieces (i0, speeds): speeds[0] is the anchor v[i0]; each piece runs up
    to and including the first sample of the next piece (its pre-anchor value)."""
    n = len(v)
    chunk = max(int(round(max_horizon / dt)), 1)
    pieces = []
    for a, b, _kind in segments:
        for s in range(a, b, chunk):
            stop = min(s + chunk, b, n - 1)
            vals = [float(v[s])]
            for k in range(s + 1, stop + 1):
                nxt = _rk4_step(vals[-1], P[k - 1], params, dt, rho, eta, V_FLOOR)
                vals.append(max(float(nxt), 0.0))
            pieces.append((s, np.array(vals)))
    return pieces


def _sim_rms(pieces, v, v_min=V_MIN_FIT):
    err = []
    for i0, vals in pieces:
        rec = v[i0 + 1:i0 + len(vals)]
        sim = vals[1:]
        use = rec > v_min
        err.append((sim - rec)[use])
    err = np.concatenate(err) if err else np.array([])
    return float(np.sqrt(np.mean(err ** 2))) if err.size else float("nan")


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


def time_40k_sigma(g, rho, power=P_REF):
    """1-sigma of the 40 km time: numerical gradient of time_40k with respect to
    (CdA, C_roll), propagated through their (inflated) covariance — linearised."""
    x = np.array([g["CdA"], g["C_roll"]], dtype=float)
    cov = np.asarray(g["cov"], dtype=float)[:2, :2]
    grad = np.empty(2)
    for k in range(2):
        h = 1e-4 * max(abs(x[k]), 1e-2)
        hi, lo = x.copy(), x.copy()
        hi[k] += h
        lo[k] -= h
        grad[k] = (time_40k(hi[0], hi[1], rho, power) - time_40k(lo[0], lo[1], rho, power)) / (2 * h)
    var = float(grad @ cov @ grad)
    return math.sqrt(var) if var > 0.0 else float("nan")


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
# Analysis + reporting
# --------------------------------------------------------------------------- #
def analyse(label, t, P, v, alt, rho, eta, mass, lag=0, quiet=False):
    """Run every estimator and diagnostic on one ride (``P`` already shifted by
    ``lag``). Prints the report unless ``quiet``; returns everything as a dict."""
    g = fit_global(t, P, v, rho, eta)
    s = fit_steady(t, P, v, rho, eta)
    c = fit_coasts(t, P, v, rho)
    segments = segment_ride(t, P)
    pieces = forward_sim(P, v, g["x"], g["dt"], rho, eta, segments)
    pred = np.full(len(v), np.nan)
    pred[g["resid_idx"]] = one_step(P, v, g["x"], g["dt"], rho, eta)[g["resid_idx"]]
    sim_rms = _sim_rms(pieces, v)
    lags = lag_scan(t, P, v, rho, eta)
    res = {"label": label, "t": t, "P": P, "v": v, "alt": alt, "rho": rho, "eta": eta,
           "lag": lag, "global": g, "steady": s, "coast": c, "segments": segments,
           "sim_pieces": pieces, "sim_rms_ms": sim_rms, "pred": pred,
           "coasts": find_coasts(P, t), "lags": lags,
           "misfit_ratio": sim_rms / g["rms_ms"] if g["rms_ms"] > 0 else float("nan")}
    res["misfit"] = bool(res["misfit_ratio"] > MISFIT_WARN)
    # Any reason to distrust this ride's SEs (and so its significance flags).
    res["suspect"] = bool(res["misfit"] or (lags is not None and lags["warn"])
                          or g["cond"] > COND_WARN or g["rank_deficient"] or g["at_bound"])
    if not quiet:
        report(res, mass)
    return res


def _fmt(x, decimals):
    return "n/a" if x is None or not np.isfinite(x) else f"{x:.{decimals}f}"


def _report_global(g):
    print(f"  uncertainty: {g['n']} one-step residuals, p=3; lag-1 autocorr "
          f"r1={g['r1']:+.2f}"
          + (" (<= 0: no inflation)" if not g["r1_used"] > 0 else "")
          + f" -> variance x{g['infl']:.2f} (SE x{math.sqrt(g['infl']):.2f}), "
          f"n_eff={g['n_eff']:.0f}")
    flag = ("ok" if g["cond"] <= COND_WARN else
            "WARNING: ill-conditioned (parameters nearly degenerate; "
            "SEs are large and the linearised CIs unreliable)")
    print(f"  cond(J^T J), column-scaled = {g['cond']:.3g}   {flag}")
    if g["rank_deficient"]:
        print("  WARNING: rank-deficient Jacobian; the pseudo-inverse drops the "
              "unidentifiable direction(s), so the SEs understate it.")
    if g["at_bound"]:
        print(f"  WARNING: {', '.join(g['at_bound'])} ended on a fit bound; "
              "its SE/CI is not meaningful.")
    print(f"  {'param':<12}{'value':>9}  {'+/-1 sigma raw':>15}  {'+/-1 sigma infl':>15}"
          f"   95% CI (t, dof {g['dof_eff']:.0f}, inflated)")
    for k in PARAMS:
        d = PARAM_DECIMALS[k]
        lo, hi = g["ci95"][k]
        print(f"  {k + ' (' + PARAM_UNITS[k] + ')':<12}{g[k]:>9.{d}f}  "
              f"{_fmt(g['se_raw'][k], d + 1):>15}  {_fmt(g['se'][k], d + 1):>15}"
              f"   [{_fmt(lo, d)}, {_fmt(hi, d)}]")
    print("  correlation " + "".join(f"{k:>9}" for k in PARAMS))
    for i, k in enumerate(PARAMS):
        cells = "".join(f"{g['corr'][i, j]:>+9.3f}" for j in range(len(PARAMS)))
        print(f"  {k:<11} {cells}")
    rc = g["corr"][1, 2]
    if np.isfinite(rc):
        note = ("strongly coupled: trust their combination more than either value"
                if abs(rc) >= 0.9 else "separately determined on this ride")
        print(f"  corr(C_roll, m_eff) = {rc:+.2f}: {note}")


def _report_lags(ls, lag):
    if ls is None:
        print("  timing check: skipped (too few samples)")
        return
    cells = []
    for row in ls["rows"]:
        tag = []
        if row["lag"] == 0:
            tag.append("in use")
        if row["lag"] == ls["best"]:
            tag.append("best")
        cells.append(f"{lag + row['lag']:+d}s {row['rms_ms'] * 3.6:.3f}"
                     + (f" ({', '.join(tag)})" if tag else ""))
    print("  timing check, one-step RMS (km/h) if speed lags the recorded power by:")
    print("    " + " | ".join(cells))
    if ls["warn"]:
        best = lag + ls["best"]
        print(f"  WARNING: a {best:+d} s lag fits clearly better "
              f"({ls['rms_best'] * 3.6:.3f} vs {ls['rms0'] * 3.6:.3f} km/h RMS). "
              "Power and speed look misaligned in time,\n"
              "           which biases CdA, C_roll and especially m_eff. Re-run with "
              f"--power-lag {best} (use the same lag for every setup).")


def report(res, mass):
    label, t, v, alt = res["label"], res["t"], res["v"], res["alt"]
    g, s, c = res["global"], res["steady"], res["coast"]

    print(f"\n=== {label} ===")
    if np.isfinite(alt).any():
        drop = float(np.nanmax(alt) - np.nanmin(alt))
        flag = "  <-- NOT flat: add a gradient term!" if drop > 3.0 else ""
        print(f"altitude range: {drop:.1f} m{flag}")
    print(f"samples: {len(t)}s   speed {v.min():.1f}-{v.max():.1f} m/s "
          f"({v.min()*3.6:.0f}-{v.max()*3.6:.0f} km/h)")
    if res["lag"]:
        print(f"power trace delayed by {res['lag']:+d} s (--power-lag)")

    print("GLOBAL (headline):  "
          f"CdA={g['CdA']:.4f} m^2   C_roll={g['C_roll']:.2f} N   "
          f"m_eff={g['m_eff']:.1f} kg   (fit RMS {g['rms_ms']*3.6:.2f} km/h)")
    _report_global(g)
    print(f"  long-horizon check: forward-sim RMS {res['sim_rms_ms'] * 3.6:.2f} km/h = "
          f"{res['misfit_ratio']:.1f}x the one-step RMS (free-running model re-anchored at "
          f"each segment\n    start; about 1x or less when the model fits, warning above "
          f"{MISFIT_WARN:g}x)")
    if res["misfit"]:
        print("  WARNING: slow model misfit: an unmodelled force (gradient, draft, surface change) "
              "or a timing offset.\n           The SEs, CIs and significance flags understate "
              "the real uncertainty; check the\n           residual plot (--plot) and repeat "
              "the run.")
    _report_lags(res["lags"], res["lag"])

    if not s:
        print("STEADY cross-check: none (needs at least 2 settled plateaus above 20 W)")
    if not c:
        print("COAST cross-check:  none (needs a 0 W coast of at least 12 s above 3 m/s)")
    if s:
        print(f"STEADY cross-check: CdA={s['CdA']:.4f} +/- {_fmt(s['se_CdA'], 4)}   "
              f"C_roll={s['C_roll']:.2f} +/- {_fmt(s['se_C_roll'], 2)} N   "
              f"R^2={_fmt(s['r2'], 5)}")
        print(f"                    ({s['k']} plateaus = {s['k']} points from "
              f"{s['n_samples']} tail samples; OLS dof {s['dof']})")
    if c:
        print(f"COAST cross-check:  CdA/m_eff={c['CdA_over_meff']:.2e} "
              f"+/- {c['se_CdA_over_meff']:.1e}   "
              f"C_roll/m_eff={c['Croll_over_meff']:.4f} +/- {c['se_Croll_over_meff']:.4f} m/s^2   "
              f"R^2={_fmt(c['r2'], 4)}")
        r1 = "n/a" if not np.isfinite(c["r1"]) else f"{c['r1']:+.2f}"
        print(f"                    ({c['segs']} coasts, {c['n']} samples; SEs inflated "
              f"x{math.sqrt(c['infl']):.1f} for lag-1 autocorr r1={r1}; raw "
              f"+/- {c['se_raw_CdA_over_meff']:.1e} / {c['se_raw_Croll_over_meff']:.4f})")
        if s:
            m1, sm1 = _ratio(s["CdA"], s["se_CdA"], c["CdA_over_meff"], c["se_CdA_over_meff"])
            m2, sm2 = _ratio(s["C_roll"], s["se_C_roll"],
                             c["Croll_over_meff"], c["se_Croll_over_meff"])
            print(f"                    -> m_eff (steady x coast): {_fmt(m1, 1)} +/- "
                  f"{_fmt(sm1, 1)} kg (via CdA), {_fmt(m2, 1)} +/- {_fmt(sm2, 1)} kg "
                  "(via C_roll)")

    crr_m = g["C_roll"] / G  # Crr * m  (kg)
    if mass:
        print(f"With catalog mass {mass:.1f} kg:  "
              f"Crr={g['C_roll'] / (mass * G):.5f} +/- {g['se']['C_roll'] / (mass * G):.5f}   "
              f"m_eff-m={g['m_eff'] - mass:+.1f} +/- {g['se']['m_eff']:.1f} kg "
              "(rotational-inertia check)")
    else:
        print(f"Crr*mass product = {crr_m:.2f} kg  "
              f"(pass --mass to split Crr from mass)")


def _ratio(a, sa, b, sb):
    """a/b with first-order relative-error propagation (a, b independent)."""
    if not (a and b and np.isfinite(a) and np.isfinite(b)):
        return float("nan"), float("nan")
    q = a / b
    return q, abs(q) * math.sqrt((sa / a) ** 2 + (sb / b) ** 2)


def compare(results, rho):
    """Print the setup table (deltas vs the first ride) and return its rows."""
    if len(results) < 2:
        return []
    rows = []
    base = results[0]["global"]
    t_base = time_40k(base["CdA"], base["C_roll"], rho)
    st_base = time_40k_sigma(base, rho)
    for i, res in enumerate(results):
        g = res["global"]
        tt = time_40k(g["CdA"], g["C_roll"], rho)
        st = time_40k_sigma(g, rho)
        row = dict(label=res["label"], CdA=g["CdA"], se_CdA=g["se"]["CdA"],
                   ci_CdA=g["ci95"]["CdA"], C_roll=g["C_roll"], m_eff=g["m_eff"],
                   t40=tt, se_t40=st, base=(i == 0), suspect=res["suspect"],
                   # a delta is only as trustworthy as both fits behind it
                   doubtful=bool(res["suspect"] or results[0]["suspect"]))
        if i == 0:
            row.update(dCdA=0.0, se_dCdA=float("nan"), z_CdA=float("nan"), sig_CdA=None,
                       dt=0.0, se_dt=float("nan"), z_t=float("nan"), sig_t=None)
        else:
            d = g["CdA"] - base["CdA"]
            sd = math.hypot(g["se"]["CdA"], base["se"]["CdA"])  # independent runs
            dtt = tt - t_base
            sdt = math.hypot(st, st_base)
            z_c = abs(d) / sd if sd > 0 else float("nan")
            z_t = abs(dtt) / sdt if sdt > 0 else float("nan")
            row.update(dCdA=d, se_dCdA=sd, z_CdA=z_c, sig_CdA=bool(z_c > SIG_Z),
                       dt=dtt, se_dt=sdt, z_t=z_t, sig_t=bool(z_t > SIG_Z))
        rows.append(row)

    def sig(flag, z, doubtful):
        if flag is None:
            return "-"
        if not np.isfinite(z):
            return "n/a"
        word = ("YES" if flag else "no") + ("*" if doubtful else "")
        return f"{word:<4} z={z:.1f}"

    print("\n=== SETUP COMPARISON (deltas vs first; +CdA/+time = slower) ===")
    print(f"{'setup':20} {'CdA':>7} {'sigma':>7} {'dCdA':>8} {'sigma':>7} {'signif.':>11}"
          f" {'C_roll':>7} {'m_eff':>6} {'40km@250W':>10} {'d(s)':>7} {'sigma':>6}"
          f" {'signif.':>11}")
    for r in rows:
        if r["base"]:
            d_cda = sd_cda = d_t = sd_t = "-"
        else:
            d_cda, sd_cda = f"{r['dCdA']:+.4f}", f"{r['se_dCdA']:.4f}"
            d_t, sd_t = f"{r['dt']:+.1f}", f"{r['se_dt']:.1f}"
        print(f"{r['label'][:20]:20} {r['CdA']:7.4f} {r['se_CdA']:7.4f} "
              f"{d_cda:>8} {sd_cda:>7} {sig(r['sig_CdA'], r['z_CdA'], r['doubtful']):>11} "
              f"{r['C_roll']:7.2f} {r['m_eff']:6.1f} {r['t40'] / 60:9.2f}m "
              f"{d_t:>7} {sd_t:>6} {sig(r['sig_t'], r['z_t'], r['doubtful']):>11}")
    print("sigma = 1-sigma from each GLOBAL fit (autocorrelation-inflated). Deltas vs the first setup\n"
          "combine both runs in quadrature (assumes independent runs). signif. = |delta| > "
          f"{SIG_Z:g} sigma\n(z = |delta|/sigma shown). 40km@250W: fixed 250 W on the flat (aero "
          "dominates, mass barely matters);\nits sigma propagates the CdA/C_roll covariance "
          "numerically (linearised). 'no' is not proof of\nno difference: repeat each setup to "
          "see the real run-to-run spread.")
    flagged = [r["label"] for r in rows if r["suspect"]]
    if flagged:
        print("* this setup's or the baseline's fit printed a WARNING (misfit, timing, "
              "conditioning or bound),\n  so its sigma is likely too small and the flag is "
              f"unreliable. Rides with warnings: {', '.join(flagged)}")
    return rows


# --------------------------------------------------------------------------- #
# Plots (optional: matplotlib is imported only when plotting)
# --------------------------------------------------------------------------- #
# Colours: validated default data-viz palette (categorical slots 1-3 pass the
# all-pairs colour-vision checks on this light surface) plus neutral inks.
C_SURFACE = "#fcfcfb"
C_INK = "#0b0b0b"
C_INK2 = "#52514e"
C_MUTED = "#898781"
C_GRID = "#e1e0d9"
C_AXIS = "#c3c2b7"
C_SERIES = ("#2a78d6", "#eb6834", "#1baf7a")  # blue, orange, aqua
C_BLUE, C_ORANGE = C_SERIES[0], C_SERIES[1]
C_COAST = "#4a3aa7"  # violet wash behind coasts
C_TAIL = "#eda100"  # amber wash behind steady tails
DASH = (0, (5, 2))  # GLOBAL-implied lines
SIM_DASH = (0, (4, 3))  # forward simulation

_RC = {
    "figure.facecolor": C_SURFACE, "axes.facecolor": C_SURFACE,
    "savefig.facecolor": C_SURFACE, "savefig.dpi": 140,
    "font.size": 10, "text.color": C_INK,
    "axes.edgecolor": C_AXIS, "axes.linewidth": 0.8, "axes.labelcolor": C_INK2,
    "axes.titlesize": 10.5, "axes.titleweight": "bold", "axes.titlecolor": C_INK,
    "axes.titlelocation": "left", "axes.labelsize": 9.5,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": C_GRID, "grid.linewidth": 0.6, "grid.linestyle": "-",
    "xtick.color": C_AXIS, "ytick.color": C_AXIS,
    "xtick.labelcolor": C_INK2, "ytick.labelcolor": C_INK2,
    "xtick.labelsize": 8.5, "ytick.labelsize": 8.5,
    "legend.fontsize": 8.5, "legend.frameon": False,
    "figure.titlesize": 12.5, "figure.titleweight": "bold",
}


def import_pyplot(required=True):
    """Import pyplot on the headless Agg backend. Without matplotlib: exit with an
    install hint (``required``) or return None."""
    try:
        import matplotlib
        matplotlib.use("Agg")  # render straight to PNG; no display needed
        import matplotlib.pyplot as plt
    except ImportError:
        if not required:
            return None
        sys.exit("error: --plot needs matplotlib, which is not installed for this Python.\n"
                 "  install it:  pip install matplotlib   (or: pip install -r requirements.txt)\n"
                 "  or re-run without --plot for the text report only.")
    return plt


def plot_stems(labels):
    """File-name-safe, unique stems for ride labels."""
    stems, seen = [], set()
    for label in labels:
        base = re.sub(r"[^A-Za-z0-9._-]+", "_", label).strip("._") or "ride"
        stem, k = base, 2
        while stem in seen:
            stem, k = f"{base}-{k}", k + 1
        seen.add(stem)
        stems.append(stem)
    return stems


def _um(text):
    """Typographic minus for a formatted number (matches the tick labels)."""
    return text.replace("-", "−")


def _moving_mean(x, w):
    ok = np.isfinite(x)
    kernel = np.ones(w)
    total = np.convolve(np.where(ok, x, 0.0), kernel, mode="same")
    count = np.convolve(ok.astype(float), kernel, mode="same")
    with np.errstate(invalid="ignore", divide="ignore"):
        return np.where(count >= 0.67 * w, total / count, np.nan)


def _shade(ax, res):
    t = res["t"]
    for a, b in res["coasts"]:
        ax.axvspan(t[a], t[b - 1], color=C_COAST, alpha=0.10, lw=0, zorder=0)
    if res["steady"]:
        for a, b in res["steady"]["tails"]:
            ax.axvspan(t[a], t[b - 1], color=C_TAIL, alpha=0.24, lw=0, zorder=0)


def _plot_timeseries(res, path, plt):
    from matplotlib.lines import Line2D
    from matplotlib.patches import Patch

    t, P, v, g = res["t"], res["P"], res["v"], res["global"]
    kmh = 3.6
    fig, (ax, axr) = plt.subplots(2, 1, sharex=True, figsize=(13, 8.6),
                                  height_ratios=[3.0, 1.35], layout="constrained")

    # Power: recessive context on the right axis, drawn underneath the speed axes.
    axp = ax.twinx()
    ax.set_zorder(axp.get_zorder() + 1)
    ax.patch.set_visible(False)
    axp.grid(False)
    axp.spines["right"].set_visible(True)
    axp.fill_between(t, 0, P, step="post", color=C_MUTED, alpha=0.16, lw=0)
    axp.step(t, P, where="post", color=C_MUTED, lw=0.9)
    axp.set_ylim(0, max(float(np.max(P)), 1.0) * 1.7)
    axp.set_ylabel("power (W)  [right axis]")

    for a in (ax, axr):
        _shade(a, res)

    # Recorded speed is a wide halo; the one-step line sits on top of the dashed
    # forward simulation so both stay visible where the three coincide.
    ax.plot(t, v * kmh, color=C_BLUE, lw=3.2, alpha=0.45, zorder=2)
    for i0, vals in res["sim_pieces"]:
        tt = t[i0:i0 + len(vals)]
        ax.plot(tt, vals * kmh, color=C_INK, lw=1.0, ls=SIM_DASH, zorder=3)
        ax.plot(tt[:1], vals[:1] * kmh, "o", ms=4.2, mfc=C_INK, mec=C_SURFACE,
                mew=0.8, zorder=5)
    ax.plot(t, res["pred"] * kmh, color=C_ORANGE, lw=0.9, zorder=4)
    ax.set_xlim(t[0], t[-1])
    ax.set_ylim(0, max(float(np.nanmax(v)), 1.0) * kmh * 1.1)
    ax.set_ylabel("speed (km/h)")
    ax.set_title(
        f"Speed: recorded vs GLOBAL model (CdA {g['CdA']:.4f} m², C_roll {g['C_roll']:.2f} N, "
        f"m_eff {g['m_eff']:.1f} kg)\n"
        f"one-step RMS {g['rms_ms'] * kmh:.2f} km/h, "
        f"forward-sim RMS {res['sim_rms_ms'] * kmh:.2f} km/h "
        f"({res['misfit_ratio']:.1f}× one-step" + ("  ⚠ misfit)" if res["misfit"] else ")"))

    # Residuals of the one-step fit.
    rk = np.full(len(t), np.nan)
    rk[g["resid_idx"]] = g["resid"] * kmh
    rms = g["rms_ms"] * kmh
    axr.axhspan(-rms, rms, color=C_MUTED, alpha=0.16, lw=0, zorder=1)
    axr.axhline(0.0, color=C_AXIS, lw=0.9, zorder=1)
    axr.plot(t, rk, color=C_ORANGE, lw=0.8, zorder=2)
    axr.plot(t, _moving_mean(rk, RESID_SMOOTH), color=C_INK, lw=1.5, zorder=3)
    peak = float(np.nanmax(np.abs(rk))) if np.isfinite(rk).any() else rms
    lim = max(3.0 * rms, 1.1 * peak, 1e-3)
    axr.set_ylim(-lim, lim)
    axr.set_ylabel("predicted − recorded\n(km/h)")
    axr.set_xlabel("time (s)")
    axr.set_title(f"One-step residuals: RMS {rms:.2f} km/h; lag-1 autocorrelation "
                  f"r1 = {_um(format(g['r1'], '+.2f'))} → SE × {math.sqrt(g['infl']):.2f}")

    # One legend for both panels, below the plots (column-major: speed, context, residuals).
    handles = [
        Line2D([], [], color=C_BLUE, lw=3.2, alpha=0.45, label="recorded speed"),
        Line2D([], [], color=C_ORANGE, lw=0.9,
               label="model, one-step-ahead: each second predicted from\n"
                     "the recorded previous second (what GLOBAL minimises)"),
        Line2D([], [], color=C_INK, lw=1.0, ls=SIM_DASH, marker="o", ms=4.2, mfc=C_INK,
               mec=C_SURFACE,
               label="model, forward simulation: free-running from the recorded\n"
                     "speed (dot) at each coast / steady / transition segment start\n"
                     f"(re-anchored at least every {SIM_MAX_HORIZON:.0f} s): long-horizon "
                     "behaviour\nshows, drift stays bounded"),
        Patch(facecolor=C_MUTED, alpha=0.35, label="power (right axis)"),
        Patch(facecolor=C_COAST, alpha=0.22, label="coast (0 W): COAST regression data"),
        Patch(facecolor=C_TAIL, alpha=0.4, label="steady tail: STEADY regression data"),
        Line2D([], [], color=C_ORANGE, lw=0.8, label="residual (lower panel)"),
        Line2D([], [], color=C_INK, lw=1.5,
               label=f"{RESID_SMOOTH} s moving mean of the residual: should hug 0;\n"
                     "slow waves = model misfit the SEs do not capture"),
        Patch(facecolor=C_MUTED, alpha=0.3, label=f"±RMS band ({rms:.2f} km/h)"),
    ]
    fig.legend(handles=handles, loc="outside lower center", ncol=3)
    fig.suptitle(f"{res['label']}: speed, model and residuals")
    fig.savefig(path)
    plt.close(fig)
    return path


def _plot_regressions(res, path, plt):
    g, s, c = res["global"], res["steady"], res["coast"]
    rho, eta = res["rho"], res["eta"]
    fig, (axs, axc) = plt.subplots(1, 2, figsize=(13, 5.8), layout="constrained")

    # (c) STEADY: eta*P/v = 0.5*rho*CdA*v^2 + C_roll
    if s:
        x, y = s["x"], s["y"]
        xx = np.linspace(0.0, float(x.max()) * 1.08, 100)
        y_fit = s["slope"] * xx + s["intercept"]
        y_glb = 0.5 * rho * g["CdA"] * xx + g["C_roll"]
        axs.plot(xx, y_fit, color=C_INK2, lw=1.6, zorder=3,
                 label=f"STEADY fit: CdA {s['CdA']:.4f} ± {_fmt(s['se_CdA'], 4)} m², "
                       f"C_roll {s['C_roll']:.2f} ± {_fmt(s['se_C_roll'], 2)} N, "
                       f"R² {_fmt(s['r2'], 4)}")
        axs.plot(xx, y_glb, color=C_INK, lw=1.3, ls=DASH, zorder=3,
                 label=f"GLOBAL-implied: CdA {g['CdA']:.4f} m², C_roll {g['C_roll']:.2f} N")
        axs.scatter(x, y, s=50, color=C_BLUE, edgecolors=C_SURFACE, linewidths=1.2,
                    zorder=4, label=f"plateau tail means ({s['k']} plateaus, "
                                    f"{s['n_samples']} samples)")
        axs.set_xlim(0.0, xx[-1])
        axs.set_ylim(0.0, max(float(y.max()), float(y_fit[-1]), float(y_glb[-1])) * 1.1)
        axs.legend(loc="upper left")
    else:
        axs.text(0.5, 0.5, "no STEADY estimate\n(needs at least 2 settled plateaus)",
                 ha="center", va="center", transform=axs.transAxes, color=C_INK2)
    axs.set_title("STEADY: η·P/v vs v² over settled plateau tails")
    axs.set_xlabel("v² (m²/s²)")
    axs.set_ylabel(f"η·P/v (N), η = {eta:g}")

    # (d) COAST: dv/dt = -(0.5*rho*CdA/m_eff)*v^2 - C_roll/m_eff
    if c:
        markers = ("o", "s", "^")
        for k in range(c["segs"]):
            sel = c["group"] == k
            if k < len(C_SERIES):
                color, mk, lab = C_SERIES[k], markers[k], f"coast {k + 1} ({int(sel.sum())} samples)"
            else:  # more than three coasts: fold the rest into one neutral group
                color, mk = C_MUTED, "D"
                lab = "coasts 4+" if k == len(C_SERIES) else "_nolegend_"
            axc.scatter(c["x"][sel], c["y"][sel], s=24, marker=mk, color=color,
                        edgecolors=C_SURFACE, linewidths=0.6, zorder=4, label=lab)
        xx = np.linspace(0.0, float(c["x"].max()) * 1.08, 100)
        y_fit = c["slope"] * xx + c["intercept"]
        y_glb = -0.5 * rho * g["CdA"] / g["m_eff"] * xx - g["C_roll"] / g["m_eff"]
        axc.axhline(0.0, color=C_AXIS, lw=0.9, zorder=1)
        axc.plot(xx, y_fit, color=C_INK2, lw=1.6, zorder=3,
                 label=f"COAST fit: CdA/m_eff {_um(format(c['CdA_over_meff'], '.3e'))} ± "
                       f"{_um(format(c['se_CdA_over_meff'], '.1e'))} m²/kg,\n"
                       f"C_roll/m_eff {_um(format(c['Croll_over_meff'], '.4f'))} ± "
                       f"{c['se_Croll_over_meff']:.4f} m/s², R² {_fmt(c['r2'], 4)}")
        axc.plot(xx, y_glb, color=C_INK, lw=1.3, ls=DASH, zorder=3,
                 label="GLOBAL-implied (slope −½ρ·CdA/m_eff, intercept −C_roll/m_eff):\n"
                       f"CdA/m_eff {_um(format(g['CdA'] / g['m_eff'], '.3e'))} m²/kg, "
                       f"C_roll/m_eff {_um(format(g['C_roll'] / g['m_eff'], '.4f'))} m/s²")
        lo = min(float(c["y"].min()), float(y_fit[-1]), float(y_glb[-1]))
        axc.set_xlim(0.0, xx[-1])
        axc.set_ylim(lo * 1.12, max(0.0, float(c["y"].max())) + abs(lo) * 0.08)
        axc.legend(loc="lower left")
    else:
        axc.text(0.5, 0.5, "no COAST estimate\n(needs a 0 W coast of at least 12 s)",
                 ha="center", va="center", transform=axc.transAxes, color=C_INK2)
    axc.set_title("COAST: dv/dt vs v² during 0 W coasts")
    axc.set_xlabel("v² (m²/s²)")
    axc.set_ylabel("dv/dt (m/s²)")

    fig.suptitle(f"{res['label']}: cross-checks against the GLOBAL fit "
                 "(solid = this estimator, dashed = GLOBAL-implied)")
    fig.savefig(path)
    plt.close(fig)
    return path


def plot_ride(res, plot_dir, plt, stem):
    """Write <stem>_timeseries.png and <stem>_regressions.png; return the paths."""
    os.makedirs(plot_dir, exist_ok=True)
    with plt.rc_context(_RC):
        return [
            _plot_timeseries(res, os.path.join(plot_dir, f"{stem}_timeseries.png"), plt),
            _plot_regressions(res, os.path.join(plot_dir, f"{stem}_regressions.png"), plt),
        ]


def plot_comparison(rows, plot_dir, plt, name="comparison.png"):
    """CdA with 95% CIs, and the CdA / 40 km time deltas vs the first setup."""
    from matplotlib.lines import Line2D

    os.makedirs(plot_dir, exist_ok=True)
    path = os.path.join(plot_dir, name)
    n = len(rows)
    y = np.arange(n)
    z95 = 1.959964  # two-sided 95% normal quantile
    with plt.rc_context(_RC):
        fig, axes = plt.subplots(1, 3, sharey=True, figsize=(13.5, 2.3 + 0.7 * n),
                                 layout="constrained")

        def marker(ax, xv, yi, row):
            if row["base"]:
                ax.plot([xv], [yi], "D", ms=7, mfc=C_INK, mec=C_SURFACE, mew=1.2, zorder=4)
            else:
                filled = bool(row["sig_CdA"] if ax is not axes[2] else row["sig_t"])
                ax.plot([xv], [yi], "o", ms=8, mfc=C_BLUE if filled else C_SURFACE,
                        mec=C_BLUE, mew=1.6, zorder=4)

        def span(ax, lows, highs, zero=None):
            lo, hi = min(lows), max(highs)
            if zero is not None:
                lo, hi = min(lo, zero), max(hi, zero)
            pad = (hi - lo) * 0.14 or abs(hi) * 0.05 or 1e-3
            ax.set_xlim(lo - pad, hi + pad)

        # CdA with its 95% CI
        ax = axes[0]
        for i, r in enumerate(rows):
            lo, hi = r["ci_CdA"]
            ax.errorbar([r["CdA"]], [i], xerr=[[r["CdA"] - lo], [hi - r["CdA"]]], fmt="none",
                        ecolor=C_INK if r["base"] else C_BLUE, elinewidth=1.6, capsize=4,
                        zorder=3)
            marker(ax, r["CdA"], i, r)
        ax.axvline(rows[0]["CdA"], color=C_AXIS, lw=0.9, zorder=1)
        span(ax, [r["ci_CdA"][0] for r in rows], [r["ci_CdA"][1] for r in rows])
        ax.set_xlabel("CdA (m²), bars = 95% CI")
        ax.set_title("CdA per setup")

        # Deltas vs the baseline
        panels = (
            (axes[1], "dCdA", "se_dCdA", "z_CdA", "ΔCdA vs baseline (m²), bars = ±1.96σ (95%)",
             "ΔCdA", "{:+.4f} ± {:.4f}"),
            (axes[2], "dt", "se_dt", "z_t",
             f"Δ time for 40 km at {P_REF:.0f} W (s), bars = ±1.96σ (95%)"
             "\n← faster | slower →", "Δ 40 km time", "{:+.1f} ± {:.1f} s"),
        )
        for ax, key, skey, zkey, xlabel, title, fmt in panels:
            lows, highs = [0.0], [0.0]
            for i, r in enumerate(rows):
                d = r[key]
                if not r["base"] and np.isfinite(r[skey]):
                    half = z95 * r[skey]
                    ax.errorbar([d], [i], xerr=[[half], [half]], fmt="none", ecolor=C_BLUE,
                                elinewidth=1.6, capsize=4, zorder=3)
                    ax.annotate(_um(fmt.format(d, half)) + f"   z = {r[zkey]:.1f}", (d, i),
                                xytext=(0, 8), textcoords="offset points", ha="center",
                                va="bottom", fontsize=8.5, color=C_INK2)
                    lows.append(d - half)
                    highs.append(d + half)
                marker(ax, d, i, r)
            ax.axvline(0.0, color=C_INK2, lw=0.9, zorder=1)
            span(ax, lows, highs, zero=0.0)
            ax.set_xlabel(xlabel)
            ax.set_title(f"{title} vs baseline")

        axes[0].set_yticks(y, [("⚠ " if r["suspect"] else "") + r["label"][:28] for r in rows])
        axes[0].set_ylim(n - 0.45, -0.75)  # first setup on top, room for the value labels
        for ax in axes:
            ax.grid(axis="y", visible=False)
        handles = [
            Line2D([], [], ls="none", marker="D", ms=7, mfc=C_INK, mec=C_SURFACE,
                   label=f"baseline ({rows[0]['label'][:28]})"),
            Line2D([], [], ls="none", marker="o", ms=8, mfc=C_BLUE, mec=C_BLUE,
                   label=f"significant: |Δ| > {SIG_Z:g}σ"),
            Line2D([], [], ls="none", marker="o", ms=8, mfc=C_SURFACE, mec=C_BLUE, mew=1.6,
                   label="not significant"),
        ]
        if any(r["suspect"] for r in rows):
            handles.append(Line2D([], [], ls="none", marker="$⚠$", ms=9, color=C_INK,
                                  label="fit printed a WARNING: σ likely too small, "
                                        "its deltas are unreliable"))
        fig.legend(handles=handles, loc="outside lower center", ncol=len(handles))
        fig.suptitle("Setup comparison: GLOBAL fits, σ inflated for residual "
                     "autocorrelation, independent runs")
        fig.savefig(path)
        plt.close(fig)
    return path


# --------------------------------------------------------------------------- #
# Self-test: recover known parameters from synthetic data
# --------------------------------------------------------------------------- #
def _profile_1hz():
    P = []
    for dur, pw in PROFILE:
        P.extend([float(pw)] * dur)
    return np.array(P), np.arange(len(P), dtype=float)


def synthetic_ride(CdA, C_roll, m_eff, seed, noise=0.02, lag=0,
                   rho=RHO_DEFAULT, eta=ETA_DEFAULT):
    """(t, P, v, alt) for the built-in profile with Gaussian speed noise (m/s).
    ``lag`` > 0 makes the simulated speed respond that many seconds late."""
    P, t = _profile_1hz()
    v = simulate(shift_power(P, lag), (CdA, C_roll, m_eff), v0=0.5, dt=1.0,
                 rho=rho, eta=eta)
    v_noisy = v + np.random.default_rng(seed).normal(0.0, noise, len(v))
    return t, P, v_noisy, np.zeros_like(v)


def self_test():
    import tempfile

    rho, eta = RHO_DEFAULT, ETA_DEFAULT
    truth = dict(CdA=0.3030, C_roll=3.00, m_eff=78.0)  # Crr ~ 0.0039 @ 78 kg
    t, P, v_noisy, alt = synthetic_ride(truth["CdA"], truth["C_roll"], truth["m_eff"], seed=0)
    v_true = simulate(P, tuple(truth.values()), v0=0.5, dt=1.0, rho=rho, eta=eta)

    print("Synthetic recovery test (2 cm/s speed noise):")
    print(f"  speed range {v_true.min()*3.6:.0f}-{v_true.max()*3.6:.0f} km/h")
    res = analyse("SYNTHETIC", t, P, v_noisy, alt, rho, eta, mass=78.0)
    g = res["global"]

    checks = [("point estimates within tolerance",
               abs(g["CdA"] - truth["CdA"]) < 0.005
               and abs(g["C_roll"] - truth["C_roll"]) < 0.5
               and abs(g["m_eff"] - truth["m_eff"]) < 3.0)]
    for k in PARAMS:
        lo, hi = g["ci95"][k]
        d = PARAM_DECIMALS[k]
        checks.append((f"true {k}={truth[k]:.{d}f} inside 95% CI [{lo:.{d + 1}f}, {hi:.{d + 1}f}]",
                       bool(lo <= truth[k] <= hi)))
    checks.append(("timing check prefers the true alignment (0 s)",
                   res["lags"] is not None and res["lags"]["best"] == 0
                   and not res["lags"]["warn"]))
    lagged = lag_scan(*synthetic_ride(truth["CdA"], truth["C_roll"], truth["m_eff"],
                                      seed=3, lag=1)[:3], rho, eta)
    checks.append(("timing check flags a +1 s power/speed offset",
                   lagged is not None and lagged["best"] == 1 and lagged["warn"]))

    # Significance logic: a repeat of the same setup must not differ, a
    # 0.020 m^2 aero gain must.
    repeat = analyse("SYNTH-REPEAT", *synthetic_ride(truth["CdA"], truth["C_roll"],
                                                     truth["m_eff"], seed=1),
                     rho, eta, mass=78.0, quiet=True)
    aero = analyse("SYNTH-AERO-0.020", *synthetic_ride(truth["CdA"] - 0.020, truth["C_roll"],
                                                       truth["m_eff"], seed=2),
                   rho, eta, mass=78.0, quiet=True)
    rows = compare([res, repeat, aero], rho)
    checks.append(("repeat of the same setup is NOT significant",
                   rows[1]["sig_CdA"] is False and rows[1]["sig_t"] is False))
    checks.append(("-0.020 m^2 CdA setup IS significant (CdA and 40 km time)",
                   rows[2]["sig_CdA"] is True and rows[2]["sig_t"] is True))

    plt = import_pyplot(required=False)
    if plt is None:
        print("\nplot check: SKIPPED (matplotlib not installed; --plot would need it)")
    else:
        with tempfile.TemporaryDirectory() as tmp:
            paths = plot_ride(res, tmp, plt, "synthetic") + [plot_comparison(rows, tmp, plt)]
            sizes = [os.path.getsize(p) if os.path.isfile(p) else 0 for p in paths]
            checks.append((f"plots rendered: {len(paths)} non-empty PNGs "
                           f"({', '.join(os.path.basename(p) for p in paths)})",
                           len(paths) == 3 and all(sz > 0 for sz in sizes)))

    print(f"\ntruth: {truth}")
    print(f"fit:   CdA={g['CdA']:.4f} C_roll={g['C_roll']:.2f} m_eff={g['m_eff']:.1f}")
    for name, ok in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    ok = all(ok for _, ok in checks)
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
    ap.add_argument("--power-lag", type=int, default=0, metavar="S",
                    help="delay the recorded power by S seconds before fitting (speed responds "
                         "S s after the power; negative = earlier). Default 0")
    ap.add_argument("--plot", action="store_true",
                    help="write diagnostic PNGs (needs matplotlib)")
    ap.add_argument("--plot-dir", default=None, metavar="DIR",
                    help="directory for the PNGs (default ./fit_plots; implies --plot)")
    ap.add_argument("--self-test", action="store_true", help="validate the fitter on synthetic data")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.files:
        ap.error("provide one or more ride files, or --self-test")

    want_plots = args.plot or args.plot_dir is not None
    plot_dir = args.plot_dir or "fit_plots"
    plt = import_pyplot(required=True) if want_plots else None  # fail fast, before fitting

    loader = load_csv if args.csv else load_fit
    results = []
    for i, path in enumerate(args.files):
        if not os.path.exists(path):
            sys.exit(f"No such file: {path}")
        label = (args.labels[i] if args.labels and i < len(args.labels)
                 else os.path.splitext(os.path.basename(path))[0])
        t, P, v, alt = loader(path)
        try:
            results.append(analyse(label, t, shift_power(P, args.power_lag), v, alt,
                                   args.rho, args.eta, args.mass, lag=args.power_lag))
        except ValueError as exc:
            sys.exit(f"{label}: {exc}")

    rows = compare(results, args.rho)

    if plt is not None:
        written = []
        for res, stem in zip(results, plot_stems([r["label"] for r in results])):
            written += plot_ride(res, plot_dir, plt, stem)
        if len(rows) >= 2:
            written.append(plot_comparison(rows, plot_dir, plt))
        print(f"\nplots written to {os.path.abspath(plot_dir)}:")
        for p in written:
            print(f"  {os.path.basename(p)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
