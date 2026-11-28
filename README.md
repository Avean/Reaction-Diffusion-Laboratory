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
   **Save preset** stores the perturbations of the selected panel as a preset
   of the model, and **Delete preset** removes the file of the selected
   preset after you confirm. Saved presets appear in the list after a restart.
3. Set **Number of runs** and click **Start series**. Each start takes a fresh
   snapshot of the setup. The app draws new perturbations for each run,
   checks for a steady state and tallies head counts, locations and
   configurations.

## Freeze and cut the source density

The Gierer–Meinhardt **Source** model has extra controls in **Models**.

- **Freeze SD** stops the source density `sd`: its reaction and diffusion are zero, so it acts as a fixed profile, drawn red and dashed.
- **Cut** keeps a piece of the given length from the middle of the domain. The domain becomes `[0, length]` and keeps its grid points; the length snaps to an even number of points, so the two halves match exactly.
- **Cut and run** starts the whole body of the given length from zero (`sd` from the model's initial condition) with a bump at the left end, which grows into a single head. The **Bump** row under the buttons has one field per variable: the height of the bump (a cos² over 0.1 of the body) added to that variable. The fields start at the model's heights, a large bump of the first variable (`u = 4`) unless the model declares others, and return to them when you change the model or load a save. Cut and run runs the body to a steady state with the series check (tolerance and limits from the series window; the rate of `sd` counts times `τ`, so `sd` must reach its equilibrium), then cuts the piece and freezes SD. It needs Neumann boundary conditions.
- **Swap halves**, **Flip left**, **Flip right**, **Copy left → right** and **Copy right → left** rearrange `u`, `v` and `sd` together. Each click acts on the current state, so **Save** first and use **Load** to go back.

The series presets of **Rho profile 2 piece** are also available for this model.

**Body length** and **Cut length** start at 7.17 and 2.43, the body and doublet of the RoleOfSource simulations.

The **Receptor + Source** model has the same controls. Its head forms only when both receptors `u` and ligand `v` are raised, so its **Bump** starts at `u = 4`, `v = 1`. The receptors do not diffuse, so a small basal production `pu` keeps them off the state `u ≡ 0`, which would otherwise be invariant and make the width of a head depend on the initial data. The ligand diffuses and has no basal production (`pv = 0` since 27.11.2026, in every receptor model): **Cut and run** starts it with its bump. Its parameters are for a body of length 7.17, as in the RoleOfSource simulations: use **Body length** 7.17 and the cut lengths 4.30 (0.6 of the body), 2.15 (0.3) or 2.43 (doublet). Its source density is produced linearly by the receptors (`ksd u`, default `ksd = μ1/m1`).

**Receptor + Source (c)** is the same model with the source density produced by the receptor signal `c = uv/(1+uv)`; until 26.11.2026 it was named Receptor + Source. With the default `ksd` the two give the same source density up to `pu/(m1 μsd)` ≈ 0.009.

**Load** for **Receptor + Source (c)** also offers **Reference S1**: the same Reference state with the source density of set S1 of the RoleOfSource frozen-SD search (Dsd = 0.562, μsd = 0.052: lower and flatter `sd`) and without the basal ligand production (`pv = 0`, the default since 27.11.2026); loading it sets these parameters. The series presets named S1 hold the wounds of that set for fragments, doublets and a graft at the middle of the body; read them out with **Freeze SD** at the steady state.

The **Wnt-Dkk (S = Wl) + Source** model has the same controls too. Its parameters are for a body of length 7.17, as for the receptor models: use **Body length** 7.17. Its bump goes into `W`, the first variable, and `A`, `Wd` and `C` start from zero. The switches `sdW`, `sdD` and `sdA` choose which productions the source density multiplies; keep `sdW` and `sdA` on, otherwise the rest state loses its stability where `sd` is high or the head cannot hold there (see the model file).

**Load** offers a save named Reference for Receptor, Receptor + Source, Receptor + Source (c), Wnt-Dkk (S = Wl) and Wnt-Dkk (S = Wl) + Source: the steady state of the whole body of length 7.17 (N = 300) with one head at the left end, with the default parameters. After loading it, **Cut** and **Cut and run** work at once.

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
| [Receptor-based](Models/ReceptorBased) | Non-diffusing receptors with a ligand and a ligand-degrading enzyme (system (5.2) of Münnich, Cygan, André and Marciniak-Czochra), without and with a dynamic source density |
| [Wnt-Dkk](Models/WntDkk) | The Wnt-Dkk model of Mercker et al. reduced by S = Wl (non-diffusing Wl, diffusing A, Wd and Dkk), without and with a dynamic source density |

<details>
<summary>Add a model or series preset</summary>

The app discovers `Models/<family>/<model>/model.jl` at startup. Use the
[basic model](Models/GiererMeinhardt/basic/model.jl) as a template for an
`RDModel(...)` definition. Choose a unique, stable `id` because it identifies
the model's save folder. The solver provides the physical domain length
through `p.domain_length`. List slow variables in `freezable = (:sd,)` to get
the parameter `frozen` and the **Freeze SD** control; `freezable = (sd = :τ,)`
also names the time scale the variable's equation is divided by, so that
**Cut and run** waits until it reaches its equilibrium. `cut_run_bump =
(u = 4.0, v = 1.0)` sets the heights of the **Cut and run** bump (the
variables not named get 0); without it the bump is 4 on the first variable.

Put series presets in TOML files beside the model. The
[Rho independent preset](Models/GiererMeinhardt/rho_independent/left_center_right.toml) shows
how to specify a description, constant `[initial_values]` and one
`[[perturbations]]` entry per bump. In **Preset** mode, variables omitted
from `[initial_values]` keep their live values. **Save preset** in the series
window writes files in the same format, named after the preset.

For spatial profiles, see the [Rho profile 2 piece model](Models/GiererMeinhardt/rho_two_piece/model.jl).
A profile set groups functions of the unit grid `x` and parameters `p`. A
function can also accept `rng` to draw a new profile for each series
realization, as in the [Rho independent model](Models/GiererMeinhardt/rho_independent/model.jl). The set can provide a displayed `formula`, a `note` and an
explicit list of profile `parameters`. The app shows the relevant parameters
for the active profile set.

</details>

## Run experiments from scripts

The repository includes runnable Julia experiments in `scripts/experiments/`.
Run them from a terminal and use **Models** and **Series mode** to explore
the underlying models and presets in the app. For setup, examples and
output formats, see the [API guide](API.md).
