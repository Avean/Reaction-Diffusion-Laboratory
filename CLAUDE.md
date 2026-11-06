# RD Lab: guide for AI agents

Reaction-Diffusion Laboratory is a Julia application for 1D reaction-diffusion
models (Gierer-Meinhardt with a source density ρ, among others), used to study
head formation and regeneration (hydra-like body, head at one end). There are
two ways in:

- **the interactive app** (`app.jl`, QML + Makie) – a person uses it;
- **the scripting API** (`src/RDLabAPI.jl`) – batch experiments from Julia
  scripts, with results written to plain files. **Use this one.**

Both run the same headless core (`src/RDLabCore.jl`), so a series run by a
script gives the same realizations as the series window of the app.

## Running

```bash
julia --project --threads=auto scripts/experiments/E4a.jl   # an experiment script
julia --project --threads=auto test/runtests.jl              # tests (about 2 min)
```

- Julia 1.11 (the Manifest is 1.11.5). Loading the API takes about 15 s.
- Always pass `--threads=auto` (or `--threads=N`): a series runs one
  realization per thread.
- A script loads the API with a path relative to **its own file**
  (`include` resolves against the including file, not the working folder):

  ```julia
  include(joinpath(@__DIR__, "..", "..", "src", "RDLabAPI.jl"))  # from scripts/experiments/
  using .RDLabAPI
  ```

  From a REPL started in the repository folder, `include("src/RDLabAPI.jl")`.
- Output goes to `results/<experiment>/<date>_<time>_<name>/` (git-ignored).
- The app needs a display. On a headless machine, run `test/gui_vs_api.jl`
  (and anything else that loads QML/GLMakie) with `xvfb-run -a julia ...`.
  GLMakie cannot even precompile without a display.

## Rules for changes

- Do not change numerics, default tolerances, model files (`Models/`) or the
  app's behaviour. The API exists so that scripts compute exactly what the
  app computes.
- `src/RDLabCore.jl` must load without QML, QMLMakie, GLMakie or CairoMakie
  (`test/runtests.jl` checks this). Window code belongs in
  `ReactionDiffusionApp.jl`, `AppTypes.jl`, `DomainPartitionApp.jl`,
  `PlotPanel.jl`, `PerturbationPanel.jl`, `UIRuntime.jl`, `QMLInterface.jl` and
  `SaveLoadQML.jl`.
- `ReactionDiffusionApp` includes the core and imports every core name, so the
  window code calls core functions unqualified and `QMLInterface.jl` reaches
  them as `RD.<name>`. A new core function is available there automatically.
- After changing core files, run `test/runtests.jl`. After changing anything
  the app uses, also run `xvfb-run -a julia --project --threads=4 test/gui_vs_api.jl`,
  which drives the real series window and compares it with the API bitwise.

## Concepts

**Body coordinates.** `s ∈ [0, 1]` runs along the body: `s = 0` is the head,
`s = 1` the foot. `Body(L, ρ0, ρ1)` has length `L` and source density
`ρ_body(s) = ρ0 + ρ1 (1/2 − s)`, highest at the head. `ρ1 = 0`
(`without_sd(body)`) is the body without source density (SD): `ρ ≡ ρ0`.

**Panels.** A state is one panel. Positions on it are **panel fractions**
`x ∈ [0, 1]`, left to right. The head side is on the **right**: a piece of the
body that is not flipped has its foot end at `x = 0` and its head end at `x = 1`.

**Piece rule.** The piece `[s_a, s_b]`, `f = s_b − s_a`, becomes a panel of
length `f L`, with `ρ1_panel = ρ1 f` and `ρ0_panel = ρ_body` at the piece centre.
On the panel `ρ(x) = ρ0_panel − ρ1_panel/2 + ρ1_panel x`, so `x = 1` is `s_a` and
`x = 0` is `s_b`. `make_state(...; body, piece = (s_a, s_b))` applies it.

**Length.** Every model is solved on a unit interval; a panel of physical
length `ℓ` divides each diffusion coefficient by `ℓ²` (the "diffusion scale",
exactly as the app's domain slider does). Parameters always keep the model's
own values (`Du = 0.01` stays `0.01`). `panel_length(st)` is the physical length.

**States are values.** `steady_state`, `cut`, `join`, `flip`, `graft` and
`resample` return new states and never change their input. Every state carries a
**recipe** (how it was built), which is written to `spec.toml`; `rerun` builds
it again from scratch.

**Series.** A realization = the start state + random wounds, integrated with
TRBDF2 until stationary (the app's check: scaled max |du/dt| < 1e-6 at 3
consecutive checks 1e3 time units apart), then heads (peaks of u) are detected.
Realization `k` draws from `Xoshiro(seed + k − 1)`, as in the app.

## Quick start

```julia
include(joinpath(@__DIR__, "src", "RDLabAPI.jl"))   # a script in the repository root
using .RDLabAPI

body = Body(2.0, 1.0, 0.5)                    # L, ρ0, ρ1
params = (Du = 0.01, Dv = 1.0)

intact = steady_state(make_state(:gierer_meinhardt_rho; body = body, N = 300,
                                 params = params, initial = (u = 1.0, v = 2.0)))
fragment = cut(intact, 0.2, 0.8)              # middle 0.6 L, keeps u, v, ρ

spec = SeriesSpec(
    experiment = "E4b", name = "middle",
    start = fragment,
    wounds = [Wound(:ends; width = (0.07, 0.16), height = (2.0, 4.0))],
    runs = 100, seed = 12345, save_fields = 5,
)
result = run_series(spec)
result.summary["head_counts"]                 # Dict("0" => 33, "1" => 67)
result.dir                                    # results/E4b/<date>_<time>_middle
```

## API reference

### Models

| Call | Result |
|---|---|
| `load_models()` | `Dict` registry key → `ModelSpec` (loaded with the module) |
| `list_models()` | prints key, id, variables, parameters, profile sets of every model |
| `find_model(id)` | `(key, model)`; `id` may be the key `"GiererMeinhardt/rho"`, the id `:gierer_meinhardt_rho` or the folder name `"rho"` |

The usual model is `:gierer_meinhardt_rho` (variables `u`, `v`; parameters
`Du = 0.01, Dv = 1, a = 1.5, b = 2, μu = 0.5, μv = 1, pu = 0, pv = 0`, plus
profile parameters):

```
u_t = Du u_xx + a ρ u²/(v + 1) − μu u + pu
v_t = Dv v_xx + b ρ u² − μv v + pv
```

### make_state

```julia
make_state(model_id;
    N = 300,                  # grid points
    body = nothing,           # Body: ρ and length by the piece rule
    piece = nothing,          # (s_a, s_b), with body; default (0, 1)
    length = nothing,         # physical length (default 1, or f L with a body)
    diffusion_scale = nothing,# set length² directly (to match a GUI slider value exactly)
    params = (;),             # e.g. (Du = 0.01, Dv = 1.0); unknown names are an error
    rho = nothing,            # see below
    initial = :rest,          # see below
    boundary_condition = :neumann,
    label = "body",           # piece name, reported with the heads
    seed = nothing,           # for initial = :model
)
```

`rho`:
- `nothing`: the piece rule with a `body`; otherwise the model's active profile.
- `"FootHead"` (any profile set name of the model): evaluated by the model file.
  **Careful:** the model's own formula applies; in the `rho` model FootHead is
  `ρ0 + ρ1 x` (ρ0 = value at the left end), not the API's centred convention.
- `(ρ0 = 1.0, ρ1 = 0.3)`: the panel profile `ρ0 − ρ1/2 + ρ1 x`.
- a vector of `N` values, or a function of the panel fraction, `x -> ...`.

ρ given as an array (piece rule, vector, function, and every state made by
cut/join/flip/graft) stays fixed. A model profile is redrawn in every
realization of a series, as in the app; this only matters for random profiles
(`ρσa`, `ρσb`, `ρσc ≠ 0`).

`initial`: `:rest` (every variable 0), constants `(u = 1.0, v = 2.0)` (missing
variables 0), `:model` (the model's noisy initial condition; pass `seed`), another
`RDState` (interpolated by panel fraction), or an `N × nvars` matrix.

### Operations

| Call | Result |
|---|---|
| `steady_state(st; tolerance = 1e-6, check_interval = 1e3, maximum_time = 1e15, ...)` | runs to stationary; `info["converged"]`, `["steady_time"]`, `["steady_steps"]`, `["heads"]`, `["head_fractions"]` |
| `cut(st, s_a, s_b; rename = nothing, label = nothing)` | the piece `[s_a, s_b]` of `st`, keeps u, v, ρ; `rename` sets the piece label; `label` picks the piece when several pieces of one body are present |
| `cut_fraction(st, p_lo, p_hi)` | the same by panel fractions |
| `flip(st)` | turned around (x → 1 − x), body coordinates too |
| `join(left, right; flip_left = false, flip_right = false, N = nothing)` | doublet: the right end of `left` against the left end of `right`; ρ travels with the pieces; parameters are taken from `left` |
| `graft(host, donor, s; flip_donor = false)` | the host split at body coordinate `s` (or `fraction = p`) with the donor inserted |
| `resample(st, N)` | onto N grid points |

`join` is a method of `Base.join` (call it as `join(a, b)`).

Doublet configurations (on the panel, an unflipped piece points →, head on the right):

```julia
join(lower, upper)                    # H2F oriented: body order, lower's head end meets upper's foot end
join(upper, lower)                    # H2F anti-oriented: pieces swapped, ρ jumps at the junction
join(lower, upper; flip_right = true) # H2H: head end meets head end (→←)
join(lower, upper; flip_left = true)  # F2F: foot end meets foot end (←→)
```

### Inspecting a state

`describe(st)` prints a summary. `panel_length(st)`, `panel_fractions(st)`
(x of every grid point), `positions(st)` (physical), `body_coordinates(st)` (s of
every point, NaN where undefined), `field(st, :u)`, `rho_values(st)`,
`junctions(st)` (panel fractions between pieces), `panel_parameters(st)` (the
dict that goes to meta.json), `st.info`, `st.recipe`.

### Wounds

```julia
Wound(at; width = (min, max), height = (min, max), variable = :u)
Wound(; s = 0.3, width = ..., height = ...)
```

- `at`: `:left`, `:right`, `:ends` (both), `:junctions` (every junction), or a
  panel fraction in `[0, 1]`; or `s = ...` for a body coordinate.
- `width = (min, max)` is in **absolute length units** (converted to the
  panel fraction internally); `width_fraction = (min, max)` gives it as a
  fraction of the panel, as the app does. Exactly one of the two.
- Every realization draws a width and a height uniformly, then adds
  `height × uniform(0, 1)` to `variable` at every grid point within half the
  width of the centre, the same as the app's series perturbations.
- Wounds are applied in the order given; the order matters for the random
  stream.

### SeriesSpec and run_series

```julia
SeriesSpec(;
    experiment, name = "", start, wounds,       # at least one wound
    runs = 100, seed = 12345,
    tolerance = 1e-6, check_interval = 1e3, required_consecutive_checks = 3,
    maximum_time = 1e15, dtmax = 1e10, reltol = 1e-5, abstol = 1e-7, maximum_steps = 10^7,
    head_variable = "u",
    save_fields = :none,        # :all, n (first n runs), or a vector of run numbers
    redraw_profiles = nothing,  # nothing: only when ρ is the model's own profile
    notes = "",
)
result = run_series(spec; out = RESULTS_DIR, threads = Threads.nthreads(),
                    mkl_threads = solver_threads(), verbose = true)
```

`result` has `dir`, `summary` (as summary.json), `wall_time`, `profiles` (ρ per
run) and `outcomes`. `outcomes[k]` has `converged`, `time`, `steps`,
`residual`, `heads` (each with `position` in the solver's x, `value` = amplitude
of u, `prominence`) and `final_snapshot.y` (all variables stacked:
`y[1:N]` is u, `y[N+1:2N]` is v). For panel fractions of the heads use
`RDLabAPI.head_fractions(o.heads, spec.start.sim)`.

### SingleSpec and run_single

```julia
spec = SingleSpec(; experiment, name = "", start, wounds = Wound[], seed = 12345,
                  run = 1, times = [0.0, 10.0, 100.0], until_steady = true, ...)
r = run_single(spec)        # r.snapshots: [(t, y)], r.outcome (if until_steady), r.dir
```

Realization `run` of the corresponding series (same draws), with all variables
and ρ written at the requested solver times (0 = right after the wounds). The
solver stops exactly at those times, so its steps (and the last digits of the
final state) can differ from the series run.

### Rerun

`rerun("results/.../spec.toml")` builds the start state from its recipe
(including steady states and cuts) and runs the series again into a new
folder; the realizations are bitwise identical. `load_spec(path)` returns the
spec without running it.

## Output files

One folder per `run_series` / `run_single` call:

| File | Content |
|---|---|
| `spec.toml` | the complete input: settings, wounds, the start state's recipe |
| `meta.json` | git commit + dirty flag, Julia version, threads, solver threads, seed, date, model, `panel` (length, N, dx, diffusion scale, all parameters, `diffusion.Du.D_over_length2`, ρ summary, every piece with its body and piece-rule ρ0/ρ1), wounds as used (fraction, s, absolute and relative widths), head-detection settings |
| `outcomes.csv` | `run, seed, converged, final_time, steps, residual, n_heads, head_x, head_s, head_piece, head_amplitude, head_prominence, wall_time_s`; multiple heads are `;`-separated in one cell; `head_x` is the panel fraction, `head_s` the body coordinate |
| `summary.json` | `runs, converged, not_converged, head_counts` ("k" → realizations with k heads), `configurations` (grouped as in the app's series window: label such as `------H`, count, reference positions as x and s), wall times |
| `fields/initial.csv` | the start state: `x, position, s, piece, u, v, ρ` |
| `fields/run_XXX.csv` | the final state of the runs selected by `save_fields` |
| `profiles.csv`, `fields/t_XXX.csv`, `fields/final.csv` | run_single only |

Numbers are written with full precision (they read back as the same Float64).
Positions are stored raw: classify heads (head end / foot end / both / none)
afterwards from `head_x` or `head_s`.

## Example scripts

`scripts/experiments/`: body and experiment parameters are constants at the top.

| Script | Experiment |
|---|---|
| `E3.jl` | whole body from rest, wounds at both ends, with and without SD |
| `E4a.jl` | fragment `[S_A, S_B]` from rest by the piece rule, wounds at both ends, with and without SD |
| `E4b.jl` | intact steady state → cut the middle 0.6 L → series from that state |
| `E5_scan.jl` | fragment lengths 0.1–0.6 L centred at s = 0.5, with and without SD; also writes a scan table |
| `E6a.jl` | doublets H2F oriented, H2F anti-oriented, H2H, F2F; wounds at both ends and the junction |

Start from the closest one when writing a new experiment.

## Gotchas

- **Solver threads.** TRBDF2 factorizes a dense Jacobian with Intel MKL. MKL's
  default (one thread per core per factorization) makes parallel realizations
  run tens of times slower, so the API uses 1 MKL thread
  (`set_solver_threads!`). This changes results only in the last digits
  (~1e-12) relative to the app. `run_series(spec; threads = 1, mkl_threads = :default)`
  computes exactly as the app (bitwise, on the same machine).
- **Cuts snap to the grid.** A split falls on a multiple of 1/N of the panel it
  splits; `st.info["cut"]` holds the panel fractions actually used.
- **Cut + join resample.** `cut` gives each piece N points and `join` takes
  max(N) points, both by linear interpolation (the app's Split and Merge).
  Rejoining reproduces the original exactly only where the grids align (a cut
  in the middle); otherwise to ~1e-4 of max u at a sharp head. A doublet of two
  N-point pieces has N points (pass `N = ...` to `join` for more).
- **Pieces of different lengths** join at their physical size (the right piece
  is converted to the left one's diffusion scale).
- **A uniform state is stationary.** `steady_state` from `:rest` stays at rest;
  start the intact animal from constants such as `(u = 1.0, v = 2.0)`.
- **Timing** (4 cores, `--threads=4`): one series of 100 realizations of an
  E4a fragment (N = 300) takes about 20 s, plus about 15 s to load the API.

## Reproducing a series saved by the app

The app's former Save graph button wrote `saved_graphs/<date>_<time>/` with
`parameters.txt`, `metadata.json` and CSV files. `test/gui_reproduction.jl`
rebuilds such a series (model, parameters typed at scale 1, the slider's domain
scale, wounds, ρ from spatial_profiles.csv), runs it as the app did and compares
head counts, configurations and every final profile:

```bash
julia --project --threads=auto test/gui_reproduction.jl saved_graphs/<folder> ...
```

Expected counts for named experiments go in `test/gui_reference.toml`. Two
folders written by the app at commit 7e05f77 are in `test/saved_graphs/` and
reproduce bitwise.

## Files

```
src/RDLabAPI.jl            the scripting API (docstrings on every exported function)
src/RDLabCore.jl           headless core: includes Types, Spatial, ModelDSL, ModelLoader,
                           Simulation, DomainPartition, HeadDetection, HeadConfigurations,
                           SeriesSimulation, SaveLoad
src/SeriesSimulation.jl    one realization: perturbations, stationarity check, heads
src/DomainPartition.jl     split_simulation_state / merge_simulation_states
src/HeadDetection.jl       head detection thresholds (prominence 5 % of range, at least 0.1)
Models/<family>/<model>/   model.jl (RDModel) and the app's series presets (*.toml)
scripts/experiments/       example experiments
test/                      runtests.jl, gui_reproduction.jl, gui_vs_api.jl, fixtures
```
