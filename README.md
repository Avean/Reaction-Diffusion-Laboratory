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
- **Interactive perturbations** – add local or random bumps to any variable
  directly on the plots.
- **Domain partitioning** – split the domain into panels, merge, swap or
  delete them, and run them independently or synchronised.
- **Checkpoints** – save and restore the full simulation state.
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
| Gierer–Meinhardt | basic, degradation, no K, oscillations, ρ profile, source, source head, linear source head, zero diffusion |
| MathBio | Gierer–Meinhardt variants (basic, ρ, source, source τ, zero diffusion) |
| Mechanochemical | global integral, squared global integral, local kernel, normalized kernel, normalized ring kernel, oscillating ramp |
| Stem cells | quiescent / active stem-cell populations |

`TOML` files next to a `model.jl` are presets for Series mode (initial
values and perturbations).

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
model appears in the model menu. Spatial profiles (e.g. a source density
`ρ(x)`) can be declared with `spatial_profiles`; see the existing models.

## Installation

Requires Julia 1.11 or newer.

```bash
git clone https://github.com/Avean/reaction-diffusion-laboratory.git
cd reaction-diffusion-laboratory
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
ModelsOld/             older models, not loaded
```

## Platform notes

Developed on Windows; also intended for Linux. Qt settings that must reach
Qt regardless of platform (the basic render loop required by Makie) are set
with `QML.qputenv`, because on Windows changes to Julia's `ENV` after Qt has
started are not visible to Qt.
