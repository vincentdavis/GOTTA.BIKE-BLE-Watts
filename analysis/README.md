# CdA / Crr / mass analysis

Fit the effective **CdA**, **Crr** and **mass** that Zwift assigns to an
equipment setup, from a `.FIT` ride recorded while the phone app played the
built-in **"CdA · Crr · Mass estimation"** profile, then compare setups. For
rolling resistance on gravel or dirt, ride the **"Surface Crr (off-road)"**
profile instead and compare its `C_roll` with your tarmac run.

This closes the loop: the app is the *data generator* (it plays an identical,
scripted power profile so the only variable between runs is the equipment);
this script is the *estimator*.

## Setup

```bash
cd analysis
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

`matplotlib` is only needed for `--plot`; the text report works with just
numpy, scipy and fitparse.

## Validate the fitter first

```bash
python fit_cda.py --self-test
```

Generates synthetic speed from **known** CdA/Crr/mass using the profile's power,
adds noise, refits, and checks that:

- the estimates are close to the truth, and the truth lies inside each 95% CI;
- the timing check picks the true power/speed alignment and flags a 1 s offset;
- a repeat of the same setup is *not* significant, while a −0.020 m² CdA
  change *is*;
- the plots render (when matplotlib is installed).

It prints `SELF-TEST: PASS` and exits 0, or exits 1.

## Analyse a ride / compare setups

```bash
python fit_cda.py baseline.fit                        # one ride
python fit_cda.py base.fit wheels_A.fit wheels_B.fit  # compare (deltas vs first)
python fit_cda.py ride.fit --mass 78.5                # split Crr from mass via catalog weight
python fit_cda.py --csv ride.csv                      # CSV: time,power,speed[,altitude]
python fit_cda.py base.fit wheels_A.fit --plot        # + diagnostic PNGs in ./fit_plots
python fit_cda.py ride.fit --plot-dir out/            # PNGs in out/ (implies --plot)
python fit_cda.py ride.fit --power-lag 1              # speed responds 1 s after the power
```

## How it works

Flat, solo (no-wind) power balance that Zwift approximates:

```
m_eff * dv/dt = eta*P/v − (0.5*rho*CdA*v² + Crr*m*g)
```

Three estimators are computed and cross-checked:

- **GLOBAL** (headline): a one-step-ahead RK4 fit of `{CdA, C_roll=Crr·m·g, m_eff}`
  over the whole (power, speed) trace.
- **STEADY**: regress `eta*P/v` on `v²` across settled plateaus → CdA, C_roll.
- **COAST**: regress `dv/dt` on `v²` over the 0 W coasts (efficiency-free) →
  `CdA/m_eff`, `C_roll/m_eff`; combine with STEADY for an independent `m_eff`.

## Reading the output

**Uncertainty (GLOBAL).** Standard errors come from the fit's Jacobian:
`cov = s² · pinv(JᵀJ)` with `s² = RSS/(n − p)`. The report prints the
column-scaled condition number and warns when the problem is ill-conditioned.
1 Hz residuals are serially correlated, which makes naive error bars too
small, so the covariance is multiplied by `(1 + r1)/(1 − r1)` (`r1` = lag-1
autocorrelation of the residuals; a negative `r1` is treated as 0, so this only
ever *widens* the error bars). The table shows raw and inflated σ, and 95% CIs
use Student's t with the effective sample size. The correlation matrix matters:
a strong `C_roll` / `m_eff` correlation means the ride could not separate them.

**Cross-checks.** STEADY and COAST report R², standard errors and point
counts. They should broadly agree with GLOBAL. The STEADY `C_roll` is the
least precise number here (it is an extrapolation to v = 0).

**Long-horizon check.** A free-running forward simulation, re-anchored to the
recorded speed at each coast / steady / transition segment start (at least
every 120 s), is compared with the one-step fit. A forward-sim RMS more than
2× the one-step RMS flags a slow model misfit the error bars do not capture.

**Timing check.** The one-step RMS is shown for power/speed offsets of
−2…+2 s. If an offset other than 0 fits clearly better, re-run with
`--power-lag S`.

**Comparison table.** Per setup: CdA ± σ, `C_roll`, `m_eff`, and the 40 km time
at a fixed 250 W. Versus the first file: ΔCdA ± σ (quadrature, assuming
independent runs) and Δtime ± σ (propagated numerically from the CdA/`C_roll`
covariance). **signif.** is `YES` when |Δ| > 2σ (z = |Δ|/σ is shown). A `no`
is not proof of no difference, and the σ's are statistical only. Repeat each
setup to see the real run-to-run spread.

## Plots (`--plot`)

Per ride:

- **`<label>_timeseries.png`**: recorded speed vs the model (one-step
  predictions and the re-anchored forward simulation), power on the right axis,
  coasts shaded purple and steady tails amber. The lower panel shows the
  one-step residuals with a ±RMS band and a 15 s moving mean. The mean should
  hug 0; slow waves mean the model misfits.
- **`<label>_regressions.png`**: the STEADY (`η·P/v` vs `v²`) and COAST
  (`dv/dt` vs `v²`, one colour per coast) fits, each with the line the GLOBAL
  fit implies (dashed). Solid and dashed lines should nearly coincide.

With two or more rides, **`comparison.png`** shows CdA per setup with 95% CIs,
and ΔCdA and Δ40 km time vs the first setup with ±1.96σ bars (filled marker =
significant).

## Honest limits (read these)

- **Only frames and wheels change Zwift performance.** Helmets, skinsuits,
  socks and shoes are cosmetic, so don't spend runs on them.
- **Report deltas, not absolutes.** `eta` and `rho` are pinned (they trade
  against the force scale), so absolute CdA/Crr are "Zwift-model units". The
  *differences* between setups are robust.
- **On the flat you get `{CdA, Crr·mass, m_eff}`.** Crr and mass are confounded
  unless you pass `--mass` (Drop-Shop rider+bike weight) or add a graded segment.
- **Mass barely affects flat speed** (aero dominates); the 40 km ranking uses a
  fixed 250 W on the flat.
- **The error bars assume the model is right.** If Zwift smooths the recorded
  speed, `m_eff` is biased (both the one-step and coast estimates). Trust
  repeated runs over a single fit's σ.
- Coast on **flat only** (a 0 W coast on a descent triggers Zwift's supertuck),
  ride **solo** (drafting biases CdA low), and keep each run on **one road
  surface**.
