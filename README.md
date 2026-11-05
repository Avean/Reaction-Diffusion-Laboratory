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
- **Checkpoints** – save and restore the full simulation state.
- **Save graph** – save the current plots (PNG and PDF), their data (CSV)
  and a Jupyter notebook that draws them again to a new folder in
  `saved_graphs/`; in series mode the series results of every panel too.
- **Series mode** – run many realisations with random perturbations until
  each reaches a steady state, detect the resulting peaks ("heads") and
  collect statistics of head counts, positions and configurations.
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
perturbation, so a preset can define any number of them:

```toml
name = "u: three bumps"

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

## Project layout

```
app.jl                 entry point of the application
src/
  ReactionDiffusionApp.jl  core module: models, grid, solver, series
  ModelDSL.jl              RDModel definition layer
  Simulation.jl            TRBDF2 integration, snapshots
  SeriesSimulation.jl      series runs and steady-state detection
  HeadDetection.jl         peak ("head") detection
  QMLInterface.jl          bridge between Julia and the QML interface
  StartupSplash.jl         startup progress, stages and Cancel
  SplashProcess.jl         the splash window's own process
qml/                   QML windows (main window, series window, splash)
Models/                model definitions and series presets
```

## Platform notes

Developed on Windows; also intended for Linux. Qt settings that must reach
Qt regardless of platform (the basic render loop required by Makie) are set
with `QML.qputenv`, because on Windows changes to Julia's `ENV` after Qt has
started are not visible to Qt.
