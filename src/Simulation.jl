# src/Simulation.jl

# ============================================================
# Simulation engine
# ============================================================
#
# This file contains the numerical part of the application.
# It does not create UI elements and does not know how the solution
# is plotted.
#
# In the threaded version, the live integrator belongs to the
# simulation worker. The UI should receive SimulationSnapshot objects
# instead of reading directly from the integrator while the worker runs.
#
# ============================================================


function solution_matrix(sim::SimulationState)
    # Return the current solution reshaped as an N × nvars matrix.
    #
    # Convention:
    #
    #     U[:, 1] = first variable
    #     U[:, 2] = second variable
    #     ...

    return reshape(sim.integrator_ref[].u, sim.N, sim.model.nvars)
end


function solution_matrix(y::AbstractVector, N::Int, nvars::Int)
    # Reshape a raw solver vector as an N × nvars matrix.

    return reshape(y, N, nvars)
end


function make_initial_state(
    model::ModelSpec,
    x::Vector{Float64};
    parameters::AbstractDict{Symbol} = Dict{Symbol, Float64}(),
)
    # Create the initial condition for a given model.
    #
    # The model initializes a matrix U0 of size N × nvars.
    # The solver receives vec(U0). `parameters` override the model defaults.

    N = length(x)

    params = Dict{Symbol, Any}(model.default_params)
    merge!(params, parameters)
    U0 = zeros(Float64, N, model.nvars)

    model.initialize!(U0, x, params)

    return vec(U0), params
end


# ============================================================
# Sparse Jacobian
# ============================================================
#
# TRBDF2 solves a nonlinear system with Newton's method at every stage and
# needs the Jacobian of the right-hand side. Without a prototype,
# OrdinaryDiffEq computes it densely with ForwardDiff (one right-hand-side
# call per column: the wrapped function only takes dual numbers of chunk
# size 1, so 600 calls for N = 300 and two variables) and factorizes the
# dense matrix. A reaction–diffusion Jacobian is almost empty (below 1 % for
# N = 300), so make_problem passes a sparse prototype: OrdinaryDiffEq then
# colors the columns, computes the Jacobian with a few calls and factorizes
# it with a sparse LU.
#
# The pattern is detected for each model, because some models are nonlocal
# (Models/Mechanochemical: global, kernel). It is the union of
#   (a) the Laplacian pattern for every variable,
#   (b) the full local block: all variables at the same grid point,
#   (c) the nonzeros of the dense ForwardDiff Jacobian at a few random,
#       strictly positive states, with the actual parameters.
# Above JACOBIAN_DENSITY_LIMIT the dense path stays. Patterns are cached,
# because make_problem runs at every wound and restart.
#
# RDLAB_DENSE_JACOBIAN=1 in the environment forces the dense path (for
# comparisons); it is read at every make_problem call.

const JACOBIAN_DENSITY_LIMIT = 0.10
# Scales of the random states of part (c): the values are scale · (0.1 + U[0, 1]).
const JACOBIAN_PATTERN_SCALES = (1.0, 10.0, 0.1)
const JACOBIAN_PATTERN_SEED = 0x6a61636f
const JACOBIAN_PATTERN_CACHE_LIMIT = 64
const FORWARDDIFF_PKGID = Base.PkgId(Base.UUID("f6369f11-7733-5829-9624-2563aa707210"), "ForwardDiff")
# key => sparse pattern, or nothing for the dense path.
const JACOBIAN_PATTERN_CACHE = Dict{UInt64, Union{Nothing, SparseMatrixCSC{Float64, Int}}}()
const JACOBIAN_PATTERN_LOCK = ReentrantLock()


"Whether make_problem is forced to the dense Jacobian (RDLAB_DENSE_JACOBIAN=1)."
dense_jacobian_forced() = lowercase(get(ENV, "RDLAB_DENSE_JACOBIAN", "")) in ("1", "true", "yes")

"Jacobian setting of make_problem: \"dense\" when forced, \"auto\" otherwise (sparse below the density limit)."
jacobian_setting() = dense_jacobian_forced() ? "dense" : "auto"


function detect_jacobian_pattern(rhs!, Lap::SparseMatrixCSC, N::Int, nvars::Int)
    n = N * nvars
    forward_diff = get(Base.loaded_modules, FORWARDDIFF_PKGID, nothing)
    forward_diff === nothing && return nothing

    rows = Int[]
    cols = Int[]

    # (a) The Laplacian pattern for every variable.
    lap_rows, lap_cols, _ = findnz(Lap)
    for variable in 1:nvars
        offset = (variable - 1) * N
        append!(rows, lap_rows .+ offset)
        append!(cols, lap_cols .+ offset)
    end

    # (b) All variables at the same grid point.
    for i in 1:N, a in 1:nvars, b in 1:nvars
        push!(rows, i + (a - 1) * N)
        push!(cols, i + (b - 1) * N)
    end

    # (c) The nonzeros of the dense Jacobian at random strictly positive states.
    rng = Xoshiro(JACOBIAN_PATTERN_SEED)
    J = zeros(n, n)
    dy = zeros(n)
    f!(out, y) = rhs!(out, y, nothing, 0.0)
    try
        for scale in JACOBIAN_PATTERN_SCALES
            y = scale .* (0.1 .+ rand(rng, n))
            forward_diff.jacobian!(J, f!, dy, y)
            for column in 1:n, row in 1:n
                iszero(J[row, column]) && continue
                push!(rows, row)
                push!(cols, column)
            end
        end
    catch err
        @warn "Sparse Jacobian: the pattern could not be detected, the dense Jacobian is used." exception = err maxlog = 1
        return nothing
    end

    pattern = sparse(rows, cols, ones(length(rows)), n, n)
    fill!(nonzeros(pattern), 1.0)
    nnz(pattern) > JACOBIAN_DENSITY_LIMIT * n^2 && return nothing
    return pattern
end


# Hash of the whole content: Base.hash of a long array samples only some of
# its elements, and two profiles ρ may differ elsewhere.
content_hash(v::AbstractArray, h::UInt) = foldl((acc, e) -> content_hash(e, acc), v; init = hash(size(v), h))
content_hash(d::AbstractDict, h::UInt) =
    foldl((acc, k) -> content_hash(d[k], hash(k, acc)), sort!(collect(keys(d)); by = string); init = hash(:dict, h))
content_hash(v, h::UInt) = hash(v, h)


function jacobian_pattern(model::ModelSpec, rhs!, Lap::SparseMatrixCSC, x::Vector{Float64}, params::Dict{Symbol, Any})
    # The pattern depends on the model, the grid (N, boundary condition through
    # the Laplacian, positions for kernels) and the parameters (e.g. a kernel
    # radius), so all of them make the key.
    N = length(x)
    nvars = model.nvars
    key = hash((model.id, N, nvars))
    for part in (Lap.colptr, Lap.rowval, x, params)
        key = content_hash(part, key)
    end

    return lock(JACOBIAN_PATTERN_LOCK) do
        haskey(JACOBIAN_PATTERN_CACHE, key) && return JACOBIAN_PATTERN_CACHE[key]
        length(JACOBIAN_PATTERN_CACHE) >= JACOBIAN_PATTERN_CACHE_LIMIT && empty!(JACOBIAN_PATTERN_CACHE)
        pattern = detect_jacobian_pattern(rhs!, Lap, N, nvars)
        JACOBIAN_PATTERN_CACHE[key] = pattern
        return pattern
    end
end


function make_problem(
    model::ModelSpec,
    y0::Vector{Float64},
    Lap::SparseMatrixCSC{Float64, Int},
    x::Vector{Float64},
    params::Dict{Symbol, Any},
    time_offset::Base.RefValue{Float64},
)
    # Build an ODEProblem from a ModelSpec.
    #
    # Internally, DifferentialEquations.jl works with vectors.
    # Inside the RHS we reshape the vector into an N × nvars matrix.

    N = length(x)
    nvars = model.nvars

    function rhs!(dy, y, _p, t)
        U  = reshape(y,  N, nvars)
        dU = reshape(dy, N, nvars)

        model.rhs!(dU, U, Lap, x, params, t + time_offset[])

        return nothing
    end

    dense_jacobian_forced() && return ODEProblem(rhs!, y0, (0.0, Inf))

    pattern = jacobian_pattern(model, rhs!, Lap, x, params)
    pattern === nothing && return ODEProblem(rhs!, y0, (0.0, Inf))

    return ODEProblem(ODEFunction(rhs!; jac_prototype = copy(pattern)), y0, (0.0, Inf))
end


function create_simulation_state(
    model::ModelSpec;
    N::Int = 1000,
    xmin::Float64 = 0.0,
    xmax::Float64 = 1.0,
    boundary_condition::Symbol = :neumann,
    dtmax::Float64 = 1e-2,
    reltol::Float64 = 1e-5,
    abstol::Float64 = 1e-7,
    parameters::AbstractDict{Symbol} = Dict{Symbol, Float64}(),
)
    # Create a complete simulation state for the selected model.

    validate_model(model)
    validate_boundary_condition(boundary_condition)

    x, dx = make_grid_1d(
        N;
        xmin = xmin,
        xmax = xmax,
        boundary_condition = boundary_condition,
    )

    Lap = laplacian_1d(
        N,
        dx;
        boundary_condition = boundary_condition,
    )

    y0, params = make_initial_state(model, x; parameters = parameters)

    time_offset = Ref(0.0)
    prob = make_problem(model, y0, Lap, x, params, time_offset)

    integrator = init(
        prob,
        TRBDF2();
        adaptive = true,
        dt = min(1e-4, dtmax),
        dtmax = dtmax,
        reltol = reltol,
        abstol = abstol,
        save_everystep = false,
    )

    return SimulationState(
        model,
        N,
        x,
        dx,
        Lap,
        boundary_condition,
        params,
        prob,
        Ref{Any}(integrator),
        time_offset,
        Ref(0),
    )
end


function current_internal_dt(sim::SimulationState)
    # Return the current internal/proposed solver time step.
    #
    # If the integrator is temporarily unavailable, return NaN.

    try
        return sim.integrator_ref[].dt
    catch
        return NaN
    end
end


function current_display_time(sim::SimulationState)
    # Return the displayed physical time.
    #
    # This is solver internal time plus accumulated time offset.

    return sim.integrator_ref[].t + sim.time_offset[]
end


function current_dtmax(sim::SimulationState)
    # Return the current maximum allowed solver time step.

    return sim.integrator_ref[].opts.dtmax
end


function set_dtmax!(sim::SimulationState, new_dtmax::Float64)
    # Change the maximum allowed time step of the current integrator.

    isfinite(new_dtmax) && new_dtmax > 0 ||
        error("dtmax must be positive and finite.")

    sim.integrator_ref[].opts.dtmax = new_dtmax

    dt = current_internal_dt(sim)

    if isfinite(dt) && dt > new_dtmax
        set_proposed_dt!(sim.integrator_ref[], new_dtmax)
    end

    return nothing
end


function step_simulation!(sim::SimulationState)
    # Advance the simulation by one accepted solver step.

    step!(sim.integrator_ref[])
    sim.step_counter[] += 1

    shift_time_to_zero_if_needed!(sim)

    return nothing
end


function step_simulation!(sim::SimulationState, nsteps::Int)
    # Advance the simulation by n accepted solver steps.

    nsteps >= 1 || return nothing

    for _ in 1:nsteps
        step_simulation!(sim)
    end

    return nothing
end


function warm_up_solver!(
    sim::SimulationState;
    reltol::Float64 = 1e-5,
    abstol::Float64 = 1e-7,
)
    # Compile the first TRBDF2 step before the user presses Start. Work on a
    # disposable state so the visible simulation remains at t = 0.
    temporary = create_simulation_state_from_data(
        sim.model,
        sim.x,
        sim.dx,
        copy(sim.integrator_ref[].u),
        sim.params;
        boundary_condition = sim.boundary_condition,
        dtmax = current_dtmax(sim),
        reltol = reltol,
        abstol = abstol,
    )
    step_simulation!(temporary)
    return nothing
end


function shift_time_to_zero_if_needed!(
    sim::SimulationState;
    threshold::Float64 = 10000.0,
    reltol::Float64 = 1e-5,
    abstol::Float64 = 1e-7,
)
    # Reset internal solver time to zero if it becomes too large.
    #
    # This avoids floating-point precision problems for very large times.
    # The displayed time is preserved by adding the internal solver time
    # to sim.time_offset.

    integrator = sim.integrator_ref[]

    if integrator.t <= threshold
        return nothing
    end

    sim.time_offset[] += integrator.t

    current_u = copy(integrator.u)
    dtmax = current_dtmax(sim)
    dt = min(current_internal_dt(sim), dtmax)

    sim.prob = make_problem(
        sim.model,
        current_u,
        sim.Lap,
        sim.x,
        sim.params,
        sim.time_offset,
    )

    sim.integrator_ref[] = init(
        sim.prob,
        TRBDF2();
        adaptive = true,
        dt = dt,
        dtmax = dtmax,
        reltol = reltol,
        abstol = abstol,
        save_everystep = false,
    )

    return nothing
end


function restart_after_manual_change!(
    sim::SimulationState,
    ynew::Vector{Float64};
    dt_after_kick::Float64 = 1e-8,
    reltol::Float64 = 1e-5,
    abstol::Float64 = 1e-7,
)
    # Restart the solver after a manual change of the solution.
    #
    # This is important because the adaptive solver should not reuse
    # step-size history from before the perturbation.

    length(ynew) == sim.N * sim.model.nvars ||
        error("New state has wrong length.")

    sim.time_offset[] += sim.integrator_ref[].t

    dtmax = max(dt_after_kick, current_dtmax(sim))

    sim.prob = make_problem(
        sim.model,
        copy(ynew),
        sim.Lap,
        sim.x,
        sim.params,
        sim.time_offset,
    )

    sim.integrator_ref[] = init(
        sim.prob,
        TRBDF2();
        adaptive = true,
        dt = dt_after_kick,
        dtmax = dtmax,
        reltol = reltol,
        abstol = abstol,
        save_everystep = false,
    )

    sim.step_counter[] = 0

    return nothing
end


# ============================================================
# Snapshots
# ============================================================


function make_snapshot(sim::SimulationState, generation::Int)
    # Create a thread-safe copy of the current simulation state.
    #
    # This function should be called while holding app.simlock if the
    # worker thread may be stepping the integrator.

    return SimulationSnapshot(
        copy(sim.integrator_ref[].u),
        sim.N,
        sim.model.nvars,
        sim.model.id,
        generation,
        current_display_time(sim),
        current_internal_dt(sim),
        current_dtmax(sim),
        sim.step_counter[],
    )
end


function create_simulation_state_from_data(
    model::ModelSpec,
    x::AbstractVector{<:Real},
    dx::Real,
    y0::AbstractVector{<:Real},
    params::AbstractDict{Symbol};
    boundary_condition::Symbol = :neumann,
    displayed_time::Float64 = 0.0,
    dtmax::Float64 = 1e-2,
    reltol::Float64 = 1e-5,
    abstol::Float64 = 1e-7,
)
    validate_model(model)
    validate_boundary_condition(boundary_condition)

    x_values = Float64.(collect(x))
    N = length(x_values)

    N >= 2 || error("A domain segment must contain at least two points.")
    length(y0) == N * model.nvars ||
        error("Segment state has wrong length.")

    dx_value = Float64(dx)
    isfinite(dx_value) && dx_value > 0 ||
        error("Segment grid spacing must be positive and finite.")

    segment_params = Dict{Symbol, Any}(params)
    Lap = laplacian_1d(
        N,
        dx_value;
        boundary_condition = boundary_condition,
    )

    time_offset = Ref(displayed_time)
    prob = make_problem(
        model,
        Float64.(collect(y0)),
        Lap,
        x_values,
        segment_params,
        time_offset,
    )

    integrator = init(
        prob,
        TRBDF2();
        adaptive = true,
        dt = min(1e-4, dtmax),
        dtmax = dtmax,
        reltol = reltol,
        abstol = abstol,
        save_everystep = false,
    )

    return SimulationState(
        model,
        N,
        x_values,
        dx_value,
        Lap,
        boundary_condition,
        segment_params,
        prob,
        Ref{Any}(integrator),
        time_offset,
        Ref(0),
    )
end


# ============================================================
# Domain length
# ============================================================

function set_diffusion_scale!(sim::SimulationState, scale::Real)
    # The domain slider sets the squared domain length L^2. The model keeps
    # its parameters; the right-hand side divides every diffusion coefficient
    # by L^2 (see DIFFUSION_SCALE_PARAM in ModelDSL.jl).
    scale_float = Float64(scale)

    isfinite(scale_float) || error("Diffusion scale must be finite.")
    scale_float > 0.0 || error("Diffusion scale must be positive.")

    sim.params[DIFFUSION_SCALE_PARAM] = scale_float

    # Restart the integrator from the current solution, with changed parameters.
    ynew = copy(sim.integrator_ref[].u)

    restart_after_manual_change!(
        sim,
        ynew,
    )

    return nothing
end
