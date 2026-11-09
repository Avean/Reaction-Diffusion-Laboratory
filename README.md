# Reaction-Diffusion Laboratory

Explore how one-dimensional reaction–diffusion systems form patterns and
respond to perturbations. The Julia desktop app lets you change model
parameters while a simulation is running, perturb fields on the plots, and
split the domain into panels to compare what happens to different pieces.

Use **Series mode** to repeat a perturbation with different random draws and
compare the peaks, or *heads*, that form.

## Get started

Install Julia 1.11 or later, then run these commands from a terminal on a
machine with a graphical display.

```bash
git clone https://github.com/Avean/Reaction-Diffusion-Laboratory.git
cd Reaction-Diffusion-Laboratory
julia install_dependencies.jl
julia --project --threads=auto app.jl
```

The first installation can take several minutes while Julia precompiles
the dependencies. The app uses Qt Quick for the interface and Makie for the
plots.

## Try your first simulation

1. Open **Models** and choose **Basic** from the Gierer–Meinhardt family.
2. Use the **Running / Stopped** toggle to control time integration. Change
   a parameter and watch the activator and inhibitor fields respond.
3. Open **Perturbations** to add a bump to a field. Use **Split / Merge**
   to divide the domain and follow the resulting pieces in separate panels.
4. Try **Domain rescale** to change the physical length. Diffusion in the
   solver scales as `D/L²`, while the parameter fields show the original
   model values.

The model controls show the equations and offer Neumann (no-flux) and
periodic boundary conditions. **Reset** starts from the model's initial
condition with the current parameters and panels.

## Run a series

1. Choose a model and set up the domain in the main window. The
   Gierer–Meinhardt **Rho profile** model has presets for trying different
   perturbation locations.
2. Open **Series mode**. Pick a preset or add perturbations to the selected
   panel. For each panel, choose **Current state** to start from its live
   fields, or **Preset** when the preset supplies initial values.
3. Set **Number of runs** and click **Start series**. Each start takes a fresh
   snapshot of the setup. The app draws new perturbations for each run,
   checks for a steady state and tallies head counts, locations and
   configurations.

## Save your work

| Control | What it saves |
| --- | --- |
| **Save** in the main window | The state of every panel, model parameters, profiles, domain and solver settings. Use **Load** with the same model to preview and restore a saved simulation. |
| **Save series** in the series window | The setup used by **Start series** and the accumulated statistics for each panel. Use this export for analysis. A save made during a run covers the realizations completed so far. |

The JSON files are stored in `saves/simulation/<model id>/` and
`saves/series/<model id>/`. In a series export, `completed_runs` records how
many realizations finished. Per panel, `head_counts` starts with the count
for zero heads, and `location_counts` follows the grid described by `x0`,
`dx` and `N`. Series exports contain summary statistics. API runs can also
export individual field profiles.

## Browse the models

| Family | Examples |
| --- | --- |
| [Gierer–Meinhardt](Models/GiererMeinhardt) | Activator–inhibitor systems with degradation, oscillations, spatial source density and grafting variants |
| [Mechanochemical](Models/Mechanochemical) | Global coupling, local and normalized kernels, and an oscillating ramp |
| [Stem cells](Models/StemCells) | Quiescent and active stem-cell populations |

<details>
<summary>Add a model or series preset</summary>

The app discovers `Models/<family>/<model>/model.jl` at startup. Use the
[basic model](Models/GiererMeinhardt/basic/model.jl) as a template for an
`RDModel(...)` definition. Choose a unique, stable `id` because it identifies
the model's save folder. The solver provides the physical domain length
through `p.domain_length`.

Put series presets in TOML files beside the model. The
[Rho profile preset](Models/GiererMeinhardt/rho/left_center_right.toml) shows
how to specify a description, constant `[initial_values]` and one
`[[perturbations]]` entry per bump. In **Preset** mode, variables omitted
from `[initial_values]` keep their live values.

For spatial profiles, see the [Rho profile model](Models/GiererMeinhardt/rho/model.jl).
A profile set groups functions of the unit grid `x` and parameters `p`. A
function can also accept `rng` to draw a new profile for each series
realization. The set can provide a displayed `formula`, a `note` and an
explicit list of profile `parameters`. The app shows the relevant parameters
for the active profile set.

</details>

## Run experiments from scripts

The repository includes runnable Julia experiments in `scripts/experiments/`.
Run them from a terminal and use **Models** and **Series mode** to explore
the underlying models and presets in the app. For setup, examples and
output formats, see the [API guide](API.md).
