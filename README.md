# Reaction-Diffusion Laboratory

An interactive desktop laboratory for one-dimensional reaction-diffusion
systems, written in Julia with a Qt Quick (QML) interface and Makie plots.
Pick a model, change its parameters while it runs, perturb the solution with
the mouse, split the domain into independent panels, and run statistical
*series* of perturbed simulations to see which patterns a model settles into.

## Features

- **Stiff time integration** – TRBDF2 with adaptive steps
  (DifferentialEquations.jl), finite differences on a uniform grid with
  Neumann or periodic boundaries.
- **Live parameters** – every model parameter can be edited while the
  simulation runs; the equations are shown in LaTeX, optionally with the
  current values substituted.
- **Domain length** – the domain slider sets the length L of the domain.
  Every model is solved on the unit interval, so L acts only through the
  diffusion coefficients, as D/L²; the parameter fields always show the
  model's own values.
- **Interactive perturbations** – add local or random bumps to any variable
  directly on the plots.
- **Domain partitioning** – split the domain into panels, merge, swap or
  delete them, and run them independently or synchronised.
- **Save and Load** – write the complete state of the simulation to a file
  and load it again later; see [Saves](#saves).
- **Series mode** – run many realisations with random perturbations until
  each reaches a steady state, detect the resulting peaks ("heads") and
  collect statistics of head counts, positions and configurations. The main
  window stays usable while no series runs; **Start series** takes the state,
  parameters, profiles, panels, boundary conditions and domain as they are at
  that moment and always counts the statistics afresh. **Save series** writes
  the settings and the head statistics to a file; see [Saves](#saves).
- **Startup splash** – a progress window with per-stage timing and a Cancel
  button.

## Models

Models live in `Models/<family>/<model>/model.jl` and are loaded
automatically at startup. The repository ships with:

| Family | Models |
|---|---|
| Gierer–Meinhardt | basic, degradation, no K, oscillations, ρ profile, ρ profile independent, ρ graft, source, source head, linear source head, zero diffusion |
| Mechanochemical | global integral, squared global integral, local kernel, normalized kernel, normalized ring kernel, oscillating ramp |
| Stem cells | quiescent / active stem-cell populations |

`TOML` files next to a `model.jl` are presets for Series mode (initial
values and perturbations). Each `[[perturbations]]` entry adds one
perturbation, so a preset can define any number of them. The optional
`description` is shown under the preset selector and says what the
perturbations are. `[initial_values]` holds constants for the variables it
lists. The **Initial condition** switch under the selector decides per panel
whether a series uses them: **Preset** sets the listed variables to these
constants on the whole panel and leaves the others in their current state,
**Current state** starts every variable from the live state. Choosing a preset
with initial values selects **Preset**; without any, only **Current state**
exists:

```toml
name = "u three bumps"
description = "Adds noise to u at three points."

[initial_values]
u = 0.0
v = 0.0

[[perturbations]]
variable = "u"
position = 0.25            # centre, as a fraction of the panel length (0 to 1)
width_min_fraction = 0.13  # width range, as fractions of the panel length
width_max_fraction = 0.25
height_min = 1.0
height_max = 2.0
```

### Adding a model

A model file ends with an `RDModel(...)` call:

```julia
RDModel(
    id = :my_model,
    display_name = "My model",
    description = "What the model describes.",
    variables = (:u, :v),
    parameters = (Du = 1e-2, Dv = 1.0, a = 1.5, b = 2.0),
    initial = function (U, x, p)
        U.u .= 1.0 .+ 0.01 .* randn(length(x))
        U.v .= 2.0
        return nothing
    end,
    reaction = function (F, U, x, p, t)
        @. F.u = p.a * U.u^2 / (U.v + 1) - U.u
        @. F.v = p.b * U.u^2 - U.v
        return nothing
    end,
    diffusion = (u = :Du, v = :Dv),
    latex_equations = (
        raw"\partial_t u = D_u \partial_{xx} u + a \frac{u^2}{v + 1} - u",
        raw"\partial_t v = D_v \partial_{xx} v + b u^2 - v",
    ),
)
```

Create `Models/<Family>/<my_model>/model.jl` and restart the application; the
model appears in the model menu. The domain length L is available inside the
model as `p.domain_length`, e.g. for an interaction kernel with a fixed
physical range (see the normalized kernel models); `domain_length` is
therefore not allowed as a parameter name.

### Spatial profiles

Spatial profiles (e.g. a source density `ρ(x)`) are declared with
`spatial_profiles`, grouped in profile sets; the active set is chosen with the
Previous / Next buttons under the profile plots. A profile is a function of
the grid `x`, which always runs from 0 to 1 whatever the domain length, and of
the parameters `p`; with a third argument `rng` it is drawn anew in every
Series realization. Besides its profiles a set can carry a `formula`, shown
under Model parameters (with the current values when the equations show
them), and a short `note`:

```julia
spatial_profiles = (
    FootHead = (
        ρ = (x, p) -> [p.ρ0 + p.ρ1 * xi for xi in x],
        formula = raw"\rho(x) = \rho_0 + \rho_1 x",
    ),
    HeadFoot = (
        ρ = (x, p) -> @. ifelse(
            x < p.ρsplit,
            p.ρ0 + p.ρ1 * (x + 1 - p.ρsplit),
            p.ρ0 + p.ρ1 * (x - p.ρsplit),
        ),
        formula = piecewise(raw"\rho(x)",
            raw"\rho_0 + \rho_1 (x + 1 - \rho_{split})" => raw"x < \rho_{split}",
            raw"\rho_0 + \rho_1 (x - \rho_{split})" => raw"x \geq \rho_{split}",
        ),
    ),
),
```

`piecewise` draws the parts with a curly brace. In formulas a parameter is
written the way the application substitutes its value: a Greek first letter
becomes its command and the rest a subscript, in braces when it is longer than
one character (`ρ0` → `\rho_0`, `ρsplit` → `\rho_{split}`, `ρpeak_pos` →
`\rho_{peak\_pos}`). The LaTeX engine (MathTeXEngine) has no environments
such as `cases`.

The parameter fields show only the parameters the active set uses, besides
those of the reaction, the initial condition and the diffusion. They are found
by evaluating every set once at startup; a set can also list them itself with
`parameters = (:ρ0, :ρ1)`.

## Installation

Requires Julia 1.11 or newer.

```bash
git clone https://github.com/Avean/Reaction-Diffusion-Laboratory.git
cd Reaction-Diffusion-Laboratory
julia install_dependencies.jl
```

The first installation precompiles Makie, DifferentialEquations and Qt, which
takes several minutes.

## Running

```bash
julia --threads=auto --project=. app.jl
```

Use `--threads=auto` so that domain panels and series runs use separate
threads. From an open REPL, `include("app.jl")` works as well; a second
start in the same session is much faster.

## Saves

Every save is one JSON file in `saves/`, named after its date and the optional
name given when saving. The folder is not tracked by git.

```
saves/simulation/<model id>/2026-11-05_18-41-07_my name.json
saves/series/<model id>/2026-11-05_20-00-00.json
```

**Save** in the main window stores the simulation: the variables of every panel,
all parameters and profiles, the domain, the boundary conditions and the time
step, but nothing of the series. **Load** lists the saves of the active model
with a preview and restores one; the series setup stays as it is, except for
the perturbations of panels that no longer exist, and the series results are
cleared. Both work in series mode too, but not while a series runs. If the model
changed since the save, new parameters keep their default and removed ones are
ignored, with a message; a save with other variables cannot be loaded.

**Save series** in the series window stores what the last Start used (settings,
model parameters, active profile set, domain, boundary conditions, and per panel
the preset, the initial condition and the perturbations) with its results per
panel: `location_counts` over the grid given by `x0`, `dx` and `N`, `head_counts`
(entry `k` counts the realizations with `k` heads, from 0), `not_converged` and
`configurations`. During a run it stores the results so far; `completed_runs`
tells how many. These files are for processing elsewhere: the application does
not read them, and they hold no patterns.

Reading a save in Python takes only the standard library:

```python
import json

with open(path, encoding="utf-8") as file:
    save = json.load(file)
u = save["panels"][0]["u"]
```

The `id` in a `model.jl` names the folder of its saves, so it must be unique
among the models, which the application checks at startup, and must not change
afterwards.

## Scripting API

Batch experiments run from Julia scripts, without the window, with
`src/RDLabAPI.jl`. It builds on the same core as the application
(`src/RDLabCore.jl`, which loads neither QML nor Makie), so a series computes
the same realizations as the series window: the same solver, perturbations,
random stream per run (seed + run − 1), stationarity check and head detection.
[CLAUDE.md](CLAUDE.md) is a complete guide to the API (concepts, every function,
output files, pitfalls), written so that an AI agent can use it right away.

**Body coordinates.** `Body(L, ρ0, ρ1)` is a body of length `L` with the source
density ρ_body(s) = ρ0 + ρ1 (1/2 − s), where s ∈ [0, 1] runs from the head
(s = 0) to the foot (s = 1). A piece [s_a, s_b] of length f = s_b − s_a becomes a
panel by the *piece rule*: length f L, ρ1 f, and ρ0 = ρ_body at the piece centre;
on the panel the head side is on the right, ρ(x) = ρ0 − ρ1/2 + ρ1 x. `ρ1 = 0`
(`without_sd(body)`) is the body without source density, ρ ≡ ρ0.

| Function | |
|---|---|
| `load_models()`, `list_models()` | the model registry |
| `make_state(model; body, piece, length, N, params, rho, initial)` | a panel; `rho` may be a profile set of the model, `(ρ0 = …, ρ1 = …)`, an array or a function; `initial` is `:rest`, constants, another state or a matrix |
| `steady_state(state)` | run until stationary (the series check) |
| `cut(state, s_a, s_b)` | a piece; keeps u, v and ρ (`split_simulation_state`) |
| `join(left, right; flip_left, flip_right)` | a doublet (`merge_simulation_states`); ρ is carried by the pieces |
| `graft(host, donor, s)` | the host split at s with the donor inserted |
| `run_series(spec)`, `run_single(spec; times)` | a series in parallel over realizations; one realization with profiles at given times |

Wounds are `Wound(:ends | :left | :right | :junctions | fraction; width, height)`
or `Wound(s = …; …)`, with `width = (min, max)` in absolute length units and
`height = (min, max)`, drawn per realization as the series window draws them.

A complete example, the E4b experiment (`scripts/experiments/E4b.jl` is the
full version):

```julia
include("src/RDLabAPI.jl")      # from the repository folder; a script elsewhere
using .RDLabAPI                 # includes joinpath(<repository>, "src", "RDLabAPI.jl")

body = Body(2.0, 1.0, 0.5)                       # L, ρ0, ρ1
params = (Du = 0.01, Dv = 1.0)

# The intact animal, run to its steady state (one head at the head end).
intact = steady_state(make_state(:gierer_meinhardt_rho; body = body, N = 300,
                                 params = params, initial = (u = 1.0, v = 2.0)))

# Cut out the middle 0.6 L and wound it at both ends, 100 times.
fragment = cut(intact, 0.2, 0.8)
spec = SeriesSpec(
    experiment = "E4b",
    name = "middle",
    start = fragment,
    wounds = [Wound(:ends; width = (0.07, 0.16), height = (2.0, 4.0))],
    runs = 100,
    seed = 12345,
    save_fields = 5,                              # fields/run_001.csv … run_005.csv
)
result = run_series(spec)
result.summary["head_counts"]                     # Dict("0" => 33, "1" => 67)
```

Run scripts with threads, one realization per thread:

```bash
julia --project --threads=auto scripts/experiments/E4a.jl
```

Every `run_series` / `run_single` call writes one folder
`results/<experiment>/<date>_<time>_<name>/` (not tracked by git):

- `spec.toml` – the complete input, including how the start state was built
  (make_state, steady_state, cut, join …); `rerun("…/spec.toml")` runs it again;
- `meta.json` – git commit and dirty flag, Julia version, threads, seed, date,
  model, and the panel parameters actually used (length, N, ρ, piece-rule ρ0 and
  ρ1 of every piece, D and D / length²);
- `outcomes.csv` – one row per realization: run, converged, final time, steps,
  residual, number of heads, head positions as panel fraction (`head_x`) and
  body coordinate (`head_s`), the piece, amplitudes and prominences;
- `summary.json` – head counts and head configurations as in the series window;
- `fields/initial.csv` and `fields/run_XXX.csv` – x, position, s, u, v, ρ.

The dense factorizations of the solver use one MKL thread each in the API
(set_solver_threads!), so realizations can run side by side; the application
leaves MKL at one thread per core, which changes results only in the last
digits (~1e-12). `run_series(spec; threads = 1, mkl_threads = :default)`
computes exactly as the application does.

Tests: `julia --project --threads=auto test/runtests.jl`. Among them,
`test/gui_reproduction.jl` rebuilds series saved by the application's former
Save graph button (`saved_graphs/<date>_<time>/`: parameters.txt, metadata.json
and the CSV files) and checks that the API gives the same head counts,
configurations and final profiles; put such folders in `saved_graphs/` or run
`julia --project test/gui_reproduction.jl <folder> ...`. `test/gui_vs_api.jl`
(needs a display or `xvfb-run`) drives the application's series window and
checks that the API computes the same series bitwise.

## Project layout

```
app.jl                 entry point of the application
src/
  RDLabCore.jl             headless core: models, grid, solver, partitions, series, saves
  RDLabAPI.jl              scripting API on the core (body coordinates, series, files)
  ReactionDiffusionApp.jl  application module: the core plus plots and window state
  ModelDSL.jl              RDModel definition layer
  Simulation.jl            TRBDF2 integration, snapshots
  DomainPartition.jl       split / merge of simulation states (core)
  DomainPartitionApp.jl    split / merge / swap / delete of the window's panels
  SeriesSimulation.jl      series runs and steady-state detection
  SaveLoad.jl              save files: names, JSON, simulation documents (core)
  SaveLoadQML.jl           Save, Load and Save series of the window
  HeadDetection.jl         peak ("head") detection
  QMLInterface.jl          bridge between Julia and the QML interface
  StartupSplash.jl         startup progress, stages and Cancel
  SplashProcess.jl         the splash window's own process
qml/                   QML windows (main window, series window, dialogs, splash)
Models/                model definitions and series presets
scripts/experiments/   example experiment scripts (E3, E4a, E4b, E5_scan, E6a)
test/                  tests of the core and the API
saves/                 saves of the simulation and the series (not tracked)
results/               output of the scripting API (not tracked)
```

## Platform notes

Developed on Windows; also intended for Linux. Qt settings that must reach
Qt regardless of platform (the basic render loop required by Makie) are set
with `QML.qputenv`, because on Windows changes to Julia's `ENV` after Qt has
started are not visible to Qt.
