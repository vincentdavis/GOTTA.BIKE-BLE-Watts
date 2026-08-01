# CdA / Crr / mass analysis

Fit the effective **CdA**, **Crr** and **mass** that Zwift assigns to an
equipment setup, from a `.FIT` ride recorded while the phone app played the
built-in **"CdA · Crr · Mass estimation"** profile — then compare setups.

This closes the loop: the app is the *data generator* (it plays an identical,
scripted power profile so the only variable between runs is the equipment);
this script is the *estimator*.

## Setup

```bash
cd analysis
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Validate the fitter first

```bash
python fit_cda.py --self-test
```

Generates synthetic speed from **known** CdA/Crr/mass using the profile's power,
adds noise, refits, and checks it recovers the inputs. Prints `SELF-TEST: PASS`.

## Analyse a ride / compare setups

```bash
python fit_cda.py baseline.fit                        # one ride
python fit_cda.py base.fit wheels_A.fit wheels_B.fit  # compare (deltas vs first)
python fit_cda.py ride.fit --mass 78.5                # split Crr from mass via catalog weight
python fit_cda.py --csv ride.csv                      # CSV: time,power,speed[,altitude]
```

## How it works

Flat, solo (no-wind) power balance that Zwift approximates:

```
m_eff * dv/dt = eta*P/v − (0.5*rho*CdA*v² + Crr*m*g)
```

Three estimators are computed and cross-checked:

- **GLOBAL** (headline) — one-step-ahead RK4 fit of `{CdA, C_roll=Crr·m·g, m_eff}`
  over the whole (power, speed) trace.
- **STEADY** — regress `eta*P/v` on `v²` across settled plateaus → CdA, C_roll.
- **COAST** — regress `dv/dt` on `v²` over the 0 W coasts (efficiency-free) →
  `CdA/m_eff`, `C_roll/m_eff`; combine with STEADY for an independent `m_eff`.

## Honest limits (read these)

- **Only frames and wheels change Zwift performance** — helmets, skinsuits,
  socks, shoes are cosmetic. Don't waste runs on them.
- **Report deltas, not absolutes.** `eta` and `rho` are pinned (they trade
  against the force scale), so absolute CdA/Crr are "Zwift-model units". The
  *differences* between setups are robust.
- **On the flat you get `{CdA, Crr·mass, m_eff}`** — Crr and mass are confounded
  unless you pass `--mass` (Drop-Shop rider+bike weight) or add a graded segment.
- **Mass barely affects flat speed** (aero dominates); the 40 km ranking uses a
  fixed 250 W on the flat.
- Coast on **flat only** (a 0 W coast on a descent triggers Zwift's supertuck),
  ride **solo** (draft biases CdA low), and keep the run on **one road surface**.
