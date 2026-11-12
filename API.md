# Reaction-Diffusion Laboratory scripting API

Use [`RDLabAPI`](src/RDLabAPI.jl) to build simulation states, cut and join
pieces, apply perturbations, and run experiments from Julia. The module
loads the numerical core without a graphical display.

## Run an example

From the repository root, use Julia 1.11 and the project's environment.
The installation command skips precompilation of the desktop packages.

```bash
julia --project -e 'using Pkg; Pkg.instantiate(; allow_autoprecomp=false)'
julia --project --threads=auto scripts/experiments/E4a.jl
```

The [experiment scripts](scripts/experiments) are ready-to-run Julia
examples. Launch them from the terminal. The app provides the underlying
models and presets through its own controls.

To write a script, save the example below as `experiment.jl` in the repository
root. Julia resolves `include` relative to the script file, so adjust the path
if you save it elsewhere.

```julia
include(joinpath(@__DIR__, "src", "RDLabAPI.jl"))
using .RDLabAPI

body = Body(2.0, 1.0, 0.5)
start = make_state(
    :gierer_meinhardt_rho;
    body,
    N = 300,
    params = (Du = 0.01, Dv = 1.0),
    initial = (u = 1.0, v = 2.0),
)
intact = steady_state(start)
fragment = cut(intact, 0.2, 0.8; rename = "middle")

spec = SeriesSpec(
    experiment = "E4b",
    name = "middle",
    start = fragment,
    wounds = [Wound(:ends; width = (0.07, 0.16), height = (2.0, 4.0))],
    runs = 10,
    seed = 12345,
    save_fields = 2,
)
result = run_series(spec)
println(result.summary["head_counts"])
println(result.dir)
```

Run it with `julia --project --threads=auto experiment.jl`. The script
integrates an intact body, cuts out the middle 60%, then wounds both ends of
the fragment in ten realizations. Check `intact.info["converged"]` if the
experiment requires a stationary start.

## Coordinates and source density

| Coordinate | Meaning |
| --- | --- |
| `s` | Body fraction from head (`0`) to foot (`1`) |
| `x` | Panel fraction from left (`0`) to right (`1`). On an unflipped piece, the headward end is on the right. |
| Physical position | Distance from the left edge of the panel, in the same units as body length and absolute wound widths |

`Body(L, ρ0, ρ1)` describes a body of length `L` with source density
`ρ_body(s) = ρ0 + ρ1 (1/2 − s)`. Use `body_rho(body, s)` to evaluate it or
`without_sd(body)` to create a body with uniform source density `ρ0`.

`piece(body, s_a, s_b)` returns a `Piece` with geometry and a profile. For
`f = s_b − s_a`, the length is `f L`, the slope is `ρ1_panel = f ρ1`, and
the midpoint value is `ρ0_panel = ρ_body((s_a + s_b) / 2)`. The resulting
panel profile is `ρ0_panel − ρ1_panel/2 + ρ1_panel x`.

The solver uses a unit domain. A panel of physical length `ℓ` scales each
diffusion coefficient by `1/ℓ²` by default. Model parameters retain their
original values, such as `Du = 0.01`.

## Create and transform a state

### Select a model

| Call | Result |
| --- | --- |
| `list_models()` | Prints the model keys, IDs, variables, parameters and profile sets |
| `load_models()` | Returns the model registry keyed by `family/model` |
| `find_model(id)` | Returns `(key, model)` for a key such as `"GiererMeinhardt/rho"`, an ID such as `:gierer_meinhardt_rho`, or an unambiguous folder name such as `"rho"` |

### Create a state

```julia
make_state(model_id;
    N = 300, body = nothing, piece = nothing, length = nothing,
    diffusion_scale = nothing, params = (;), rho = nothing, initial = :rest,
    boundary_condition = :neumann, dtmax = 1e-2, label = "body", seed = nothing,
)
```

- `N` is the number of grid points, with a minimum of three.
  `boundary_condition` accepts `:neumann` and `:periodic`.
- Supply `body` for a whole body, `body` and `piece = (s_a, s_b)` for an
  interval, or `piece = piece(body, s_a, s_b)`. Without a piece, length
  defaults to `1` unless you supply `length` or `diffusion_scale`. Set
  `diffusion_scale` to match a specific solver scale.
- `params` overrides the model defaults. Use the model's parameter names
  and unscaled diffusion coefficients.
- `initial` accepts `:rest` for zero fields, `:model` for the model's
  initializer, constants such as `(u = 1.0, v = 2.0)`, another `RDState`, or
  an `N × nvars` matrix. Omitted constants are zero. An input state is
  interpolated by panel fraction. Set `seed` with `:model` to repeat a
  random initialization.
- `label` identifies the piece in output and disambiguates body coordinates
  when several pieces cover the same interval.

| `rho` | Profile |
| --- | --- |
| `nothing` | Apply the piece rule if there is a body piece. Otherwise use the model's active profile, if present. |
| A profile set name such as `"FootHead"` | Use the model's formula. For the Gierer–Meinhardt Rho profile, `FootHead` uses `ρ0 + ρ1 x`, with `ρ0` at the left edge. |
| `(ρ0 = 1.0, ρ1 = 0.3)` | Use the centered formula `ρ0 − ρ1/2 + ρ1 x`. |
| A vector of `N` values or a function `x -> ...` | Set values on the panel grid. |

The piece rule and profiles supplied as a tuple, vector or function give
fixed values. Series runs reevaluate model-defined profiles by default,
which affects profiles that draw random values.

### Transform and inspect a state

Each operation returns a new `RDState`. The state records how it was built
in `st.recipe`.

| Call | Result |
| --- | --- |
| `steady_state(st; tolerance = 1e-6, check_interval = 1e3, ...)` | Integrate to stationarity. Read `st.info` on the returned state for `converged`, `steady_time`, `steady_steps`, `steady_residual`, `heads` and `head_fractions`. |
| `cut(st, s_a, s_b; label = nothing, rename = nothing)` | Extract a piece by body coordinates, carrying the fields and source density. Use `label` to select the source piece and `rename` to name the result. |
| `cut_fraction(st, lo, hi)` | Extract a piece by panel fractions. |
| `flip(st)` | Reverse the panel and its coordinate mapping. |
| `join(left, right; flip_left = false, flip_right = false, N = nothing)` | Join Neumann panels of the same model in left-to-right order. Pieces retain their physical lengths and profiles. The result uses the left panel's parameters. |
| `graft(host, donor, s; flip_donor = false, label = nothing)` | Insert the donor at body coordinate `s`. To specify a panel fraction, call `graft(host, donor; fraction = x)`. |
| `resample(st, N)` | Interpolate onto `N` grid points. |

Cuts snap to the grid. Read `st.info["cut"]` on the result to see the panel
fractions used. Each cut piece keeps the original point count. A join uses
the larger point count by default. Cutting and rejoining can change the
sampled values when the grids do not align.

```julia
join(lower, upper)                    # Head to foot, oriented
join(upper, lower)                    # Head to foot, anti-oriented
join(lower, upper; flip_right = true) # Head to head
join(lower, upper; flip_left = true)  # Foot to foot
```

Use `describe(st)` for a summary or `panel_parameters(st)` for the metadata
record. Read `field(st, :u)` or `rho_values(st)` for samples.
`panel_fractions(st)`, `positions(st)` and `body_coordinates(st)` give the
coordinates of each sample. Body coordinates are `NaN` where undefined.
`panel_length(st)` gives the physical length and `junctions(st)` gives the
panel fractions at joins.

## Run an experiment

### Specify wounds

```julia
Wound(:ends; width = (0.07, 0.16), height = (2.0, 4.0))
Wound(; s = 0.3, width_fraction = 0.08, variable = :u)
```

Place a wound at `:left`, `:right`, `:ends`, `:junctions`, a numeric panel
fraction, or a body coordinate `s`. Use `label` with `s` to target a piece
when the coordinate is ambiguous.

Use `width` for physical units or `width_fraction` for a fraction of the
panel. Give a number for a fixed width or a pair for a uniform draw between
the endpoints. `height` accepts the same forms and defaults to `(1.0, 2.0)`.
Each grid point within half the width of the center gets the drawn height
times a uniform sample in `[0, 1]`. Wound order determines the order of draws.

### Repeat a run with different draws

```julia
spec = SeriesSpec(;
    experiment, name = "", start, wounds,
    runs = 100, seed = 12345, head_variable = "u",
    tolerance = 1e-6, check_interval = 1e3, required_consecutive_checks = 3,
    maximum_time = 1e15, maximum_steps = 10_000_000,
    dtmax = 1e10, reltol = 1e-5, abstol = 1e-7,
    save_fields = :none, redraw_profiles = nothing, notes = "",
)
result = run_series(spec; out = RESULTS_DIR, threads = Threads.nthreads(),
                    mkl_threads = solver_threads(), verbose = true)
```

`run_series` requires at least one wound. Realization `k` draws perturbations
from `Xoshiro(seed + k − 1)`. TRBDF2 integrates until the scaled maximum
time derivative stays below `tolerance` for the required checks or a run
limit is reached. The solver detects peaks in `head_variable`.

`save_fields` accepts `:none`, `:all`, the number of initial runs to export,
or a vector of run indices. Use `redraw_profiles` to override profile
reevaluation. `threads` controls concurrency, up to the number of Julia threads.

The result contains `dir`, `summary`, `wall_time`, the `profiles` per run
and `outcomes`. Each outcome has convergence status, time, steps, residual,
heads and `final_snapshot.y`. The final vector has one block of `N` samples
per variable, in model order. Each head has a position in solver coordinates,
an amplitude (`value`) and a prominence. Use
`RDLabAPI.head_fractions(outcome.heads, spec.start.sim)` for panel fractions.

### Record a time course

```julia
spec = SingleSpec(;
    experiment = "time_course", start = fragment, wounds = Wound[],
    seed = 12345, run = 1, times = [0.0, 10.0, 100.0], until_steady = true,
)
result = run_single(spec)
```

`SingleSpec` accepts the same solver settings as `SeriesSpec`. `run` selects
the random stream for that realization of a series. Time zero is immediately
after the wounds. `result.snapshots` holds the `(t, y)` pairs, and
`result.outcome` holds the final result when `until_steady` is enabled.
Recording at specified times adds solver stops, which can affect final values.

### Reproduce an experiment

`load_spec(path)` rebuilds a saved input from `spec.toml` for inspection.
`rerun(path)` executes the saved input in a new output directory. Record the
seed, source revision, Julia version and solver thread settings when
comparing runs. For time courses, put the sample times in `SingleSpec` so
the saved specification carries them.

The API defaults to one MKL thread per dense factorization so realizations
can run in parallel. To match the desktop solver threading on the same
machine, use `run_series(spec; threads = 1, mkl_threads = :default)`.
Different processors or solver thread settings can change numerical results.

TRBDF2 uses a sparse Jacobian: the solver detects its pattern for each model
(the Laplacian, all variables at one grid point and the nonzeros of the dense
Jacobian at a few random states), colors the columns and factorizes with a
sparse LU. A model whose pattern fills more than 10 % of the matrix (a global
coupling) keeps the dense Jacobian. Set `RDLAB_DENSE_JACOBIAN=1` in the
environment to force the dense Jacobian for every new problem, for example to
compare the two; `meta.json` records the setting under `jacobian` (`auto` or
`dense`). The two paths agree to round-off, not bit for bit.

## Read the output

Each run writes to `results/<experiment>/<date>_<time>_<name>/` by default.
Pass `out` to change the base directory.

| File | Contents |
| --- | --- |
| `spec.toml` | Experiment settings, wounds and the recipe for the start state |
| `meta.json` | Source revision, Julia and thread settings, model, panel parameters, effective diffusion, piece geometry and wound locations |
| `outcomes.csv` | Seed, convergence, time, steps, residual, head count, positions, amplitudes, prominences and elapsed time per realization. `head_x` is the panel fraction and `head_s` the body coordinate. Multiple heads in one cell are separated by semicolons. |
| `summary.json` | Series counts by convergence and number of heads, configurations and timings |
| `fields/initial.csv` | State before wounds. Columns include panel fraction, physical position, body coordinate, piece label, fields and profiles. |
| `fields/run_XXX.csv` | Final fields for the realizations selected by `save_fields` |
| `profiles.csv` and `fields/t_XXX.csv` | Time-course samples from `run_single` |
| `fields/final.csv` | Final profile from `run_single` with `until_steady = true` |

## Example experiments

| Script | Experiment |
| --- | --- |
| [E3](scripts/experiments/E3.jl) | Wound both ends of a whole body from rest, with and without a source-density gradient |
| [E4a](scripts/experiments/E4a.jl) | Make a fragment using the piece rule and wound both ends |
| [E4b](scripts/experiments/E4b.jl) | Cut the middle 60% from a body that has reached a steady state |
| [E5 scan](scripts/experiments/E5_scan.jl) | Compare centered fragments from 10% to 60% of body length |
| [E6a](scripts/experiments/E6a.jl) | Compare four doublet orientations with wounds at the ends and junction |

## Compare with a saved desktop series

[test/gui_reproduction.jl](test/gui_reproduction.jl) compares API results
with compatible exports from the former **Save graph** command. It
supports single-panel series whose initial fields can be reconstructed
from the export.

```bash
julia --project --threads=auto test/gui_reproduction.jl "saved_graphs/my_export"
```

The test also discovers exports under `saved_graphs/` and fixtures under
`test/saved_graphs/`. The repository fixtures compare head counts and
configurations exactly and allow a numerical tolerance for final profiles.
