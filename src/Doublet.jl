# src/Doublet.jl

# ============================================================
# Doublets: the halves of a panel and a centred cut
# ============================================================
#
# Headless operations behind the Source tools of the application (Freeze
# SD, Cut, Cut and run and the half buttons). They act on all variables at
# once, so u, v and a frozen source density move together.
#
# Halves: of N grid points the left half is 1:N÷2 and the right half the last
# N÷2 points. With odd N the middle point belongs to neither and stays where
# it is. Every operation maps grid points to grid points, so nothing is
# interpolated, and the grid itself does not change.
#
# A cut keeps the grid points of the piece: a piece of M points of a panel of
# N points becomes a panel of its own on the unit interval, with the domain
# length (M - 1) / (N - 1) times the old one, so its physical grid spacing
# and every value stay the same.
#
# ============================================================


const HALF_OPERATIONS = (
    :swap,
    :flip_left,
    :flip_right,
    :copy_left_to_right,
    :copy_right_to_left,
)

# Cut and run starts the whole body from zero (every variable that cannot be
# frozen is zero, the source density keeps the model's initial condition)
# with a cos² bump at the left end, so that a single head forms there. Its
# heights, one per variable, are the model's (ModelSpec.cut_run_bump: by
# default CUT_RUN_BUMP_HEIGHT on the first variable only) or the Bump fields
# of the window; its width is CUT_RUN_BUMP_WIDTH of the body (Types.jl).


"Grid points of the left and the right half of a panel of `N` points."
function half_ranges(N::Integer)
    N >= 2 || error("A panel needs at least two grid points to have halves.")
    h = N ÷ 2
    return 1:h, (N - h + 1):N
end


"""
    apply_half_operation(U, operation) -> Matrix

The N × nvars matrix `U` with its halves rearranged. `operation`:

- `:swap`: the halves change places, each keeping its orientation.
- `:flip_left`, `:flip_right`: that half is reversed in place.
- `:copy_left_to_right`, `:copy_right_to_left`: one half replaces the
  other, with the same orientation.
"""
function apply_half_operation(U::AbstractMatrix, operation::Symbol)
    left, right = half_ranges(size(U, 1))
    V = Matrix{Float64}(U)

    if operation == :swap
        V[left, :] = U[right, :]
        V[right, :] = U[left, :]
    elseif operation == :flip_left
        V[left, :] = U[reverse(left), :]
    elseif operation == :flip_right
        V[right, :] = U[reverse(right), :]
    elseif operation == :copy_left_to_right
        V[right, :] = U[left, :]
    elseif operation == :copy_right_to_left
        V[left, :] = U[right, :]
    else
        error("Unknown half operation :$operation (use " * join(string.(":", HALF_OPERATIONS), ", ") * ").")
    end

    return V
end


"""
    centered_cut_range(N, fraction) -> UnitRange

Grid points of a piece covering `fraction` of a Neumann panel of `N` points
(both ends on the grid), centred on the panel. The number of points is the
one closest to the requested length that has the parity of `N`, so the piece
is symmetric about the centre of the panel; with even `N` it has an even
number of points and two equal halves.
"""
function centered_cut_range(N::Integer, fraction::Real)
    minimum_points = iseven(N) ? 4 : 5
    N >= minimum_points || error("The panel has too few grid points to cut a piece with two halves.")
    f = Float64(fraction)
    isfinite(f) && 0.0 < f <= 1.0 + 1e-12 ||
        error("The cut must be longer than zero and not longer than the panel.")

    target = min(f, 1.0) * (N - 1) + 1
    M = round(Int, target)
    if isodd(N - M)
        M = target >= M ? M + 1 : M - 1
    end
    M = clamp(M, minimum_points, N)

    first_point = (N - M) ÷ 2 + 1
    return first_point:(first_point + M - 1)
end


"Physical length of a panel: its extent on the solver grid times the domain length."
panel_physical_length(sim::SimulationState) =
    (last(sim.x) - first(sim.x)) * sqrt(diffusion_scale(sim.params))


"""
    cut_plan(sim, cut_length) -> (range, length)

The grid points of the centred piece of `sim` closest to the physical length
`cut_length`, and the length of that piece. Reads only the grid and the
parameters, never the solution.
"""
function cut_plan(sim::SimulationState, cut_length::Real)
    sim.boundary_condition == :neumann ||
        error("Cut needs Neumann boundary conditions.")
    isempty(sim.model.spatial_profile_sets) ||
        error("Cut works only for models without spatial profiles: a profile would not follow the piece.")

    panel_length = panel_physical_length(sim)
    requested = Float64(cut_length)
    isfinite(requested) && requested > 0.0 || error("The cut length must be a positive number.")
    requested <= panel_length * (1 + 1e-9) ||
        error(@sprintf("The cut length %.6g is longer than the domain (%.6g).", requested, panel_length))

    range = centered_cut_range(sim.N, requested / panel_length)
    actual_length = panel_length * (length(range) - 1) / (sim.N - 1)

    return range, actual_length
end


"""
    cut_simulation_state(sim, cut_length; displayed_time, dtmax, reltol, abstol)
        -> (state, length)

A new panel holding the centred piece of `sim` of physical length
`cut_length` (snapped to the grid, see `centered_cut_range`) with all its
values. The piece lies on the unit interval with Neumann boundaries and the
domain length `length`, so its physical grid spacing is the one of `sim`.
With `freeze = true` the piece's freezable variables are frozen.
"""
function cut_simulation_state(
    sim::SimulationState,
    cut_length::Real;
    displayed_time::Float64 = current_display_time(sim),
    dtmax::Float64 = current_dtmax(sim),
    reltol::Float64 = 1e-5,
    abstol::Float64 = 1e-7,
    freeze::Bool = false,
)
    range, actual_length = cut_plan(sim, cut_length)
    M = length(range)
    y = vec(Matrix{Float64}(solution_matrix(sim)[range, :]))
    x, dx = make_grid_1d(M; boundary_condition = :neumann)
    params = deepcopy(sim.params)
    params[DIFFUSION_SCALE_PARAM] = actual_length^2
    freeze && !isempty(sim.model.freezable_variables) && (params[FROZEN_PARAM] = 1.0)

    state = create_simulation_state_from_data(
        sim.model,
        x,
        dx,
        y,
        params;
        boundary_condition = :neumann,
        displayed_time = displayed_time,
        dtmax = dtmax,
        reltol = reltol,
        abstol = abstol,
    )

    return state, actual_length
end


"""
    cut_run_initial_state(model, params; N, body_length, ...) -> SimulationState

The whole body Cut and run starts from: a Neumann panel of `N` points and
physical length `body_length`, with the parameters `params` (unfrozen), the
model's initial condition for the freezable variables (the source density),
zero for every other variable, and a bump at the left end added to every
variable j: `bump_heights[j]` · cos²(π s / (2 · bump_width)) for
s < bump_width, where s is the fraction of the body from the left end.
`bump_heights` has one height per variable (finite, ≥ 0, at least one
positive); by default the model's `cut_run_bump`.
"""
function cut_run_initial_state(
    model::ModelSpec,
    params::AbstractDict{Symbol};
    N::Int,
    body_length::Real,
    bump_heights::AbstractVector{<:Real} = model.cut_run_bump,
    bump_width::Real = CUT_RUN_BUMP_WIDTH,
    dtmax::Float64 = 1e10,
    reltol::Float64 = 1e-5,
    abstol::Float64 = 1e-7,
)
    N >= 4 || error("Cut and run needs at least four grid points.")
    L = Float64(body_length)
    isfinite(L) && L > 0.0 || error("The body length must be a positive number.")
    w = Float64(bump_width)
    0.0 < w <= 1.0 || error("The bump width must be a fraction of the body between 0 and 1.")
    heights = validate_cut_run_bump(bump_heights, model.varnames)

    parameters = Dict{Symbol, Any}(params)
    parameters[DIFFUSION_SCALE_PARAM] = L^2
    isempty(model.freezable_variables) || (parameters[FROZEN_PARAM] = 0.0)

    sim = create_simulation_state(
        model;
        N = N,
        boundary_condition = :neumann,
        dtmax = dtmax,
        reltol = reltol,
        abstol = abstol,
        parameters = parameters,
    )

    U = Matrix{Float64}(solution_matrix(sim))
    for j in 1:model.nvars
        j in model.freezable_variables && continue
        U[:, j] .= 0.0
    end

    x0 = first(sim.x)
    extent = last(sim.x) - x0
    for (i, xi) in enumerate(sim.x)
        s = (xi - x0) / extent
        s < w || continue
        for j in 1:model.nvars
            U[i, j] += heights[j] * cos(π * s / (2w))^2
        end
    end

    restart_after_manual_change!(sim, vec(U); reltol = reltol, abstol = abstol)
    sim.step_counter[] = 0

    return sim
end


"""
    cut_and_run(model, params; N, body_length, cut_length, settings, ...) -> NamedTuple

Cut and run without a window: the whole body from `cut_run_initial_state`
integrated to a stationary state with the series check (`settings`: tolerance,
check interval, consecutive checks, dtmax, maximum time and steps), the rate
of each freezable variable weighted by its time scale (freezable_rate_weights),
then the freezable variables frozen and the centred piece of `cut_length` cut out.

`bump_heights` (one per variable, by default the model's `cut_run_bump`) and
`bump_width` shape the bump of the initial state.

Returns `(cancelled, outcome, body, state, length)`: the series outcome of
the whole body (converged, time, steps, residual, heads), the body, and the
piece with its length (both `nothing` when `cancelled()` stopped the run).
The piece starts at time 0 with the maximum time step `cut_dtmax`.
"""
function cut_and_run(
    model::ModelSpec,
    params::AbstractDict{Symbol};
    N::Int,
    body_length::Real,
    cut_length::Real,
    settings::SeriesSettings = SeriesSettings(),
    cut_dtmax::Float64 = 1e-2,
    bump_heights::AbstractVector{<:Real} = model.cut_run_bump,
    bump_width::Real = CUT_RUN_BUMP_WIDTH,
    cancelled::Function = () -> false,
    on_residual::Function = _ -> nothing,
)
    Float64(cut_length) <= Float64(body_length) * (1 + 1e-9) ||
        error("The cut length must not exceed the body length.")

    run_settings = deepcopy(settings)
    run_settings.live_preview = false

    body = cut_run_initial_state(
        model,
        params;
        N = N,
        body_length = body_length,
        bump_heights = bump_heights,
        bump_width = bump_width,
        dtmax = run_settings.dtmax,
        reltol = run_settings.reltol,
        abstol = run_settings.abstol,
    )
    # Checked before the run, so a wrong length fails at once.
    cut_plan(body, cut_length)

    # The rate of a slow freezable variable is weighted by its time scale, so
    # it must reach its equilibrium, not only change slowly.
    outcome = run_series_panel!(
        body,
        run_settings,
        0;
        cancelled = cancelled,
        on_residual = on_residual,
        rate_weights = freezable_rate_weights(model, body.params),
    )

    outcome.cancelled &&
        return (cancelled = true, outcome = outcome, body = body, state = nothing, length = nothing)

    state, actual_length = cut_simulation_state(
        body,
        cut_length;
        displayed_time = 0.0,
        dtmax = cut_dtmax,
        reltol = run_settings.reltol,
        abstol = run_settings.abstol,
        freeze = true,
    )

    return (cancelled = false, outcome = outcome, body = body, state = state, length = actual_length)
end
