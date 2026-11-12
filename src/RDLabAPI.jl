# src/RDLabAPI.jl

# ============================================================
# RD Lab scripting API: batch experiments without a window
# ============================================================
#
#     include("src/RDLabAPI.jl")
#     using .RDLabAPI
#
# Builds simulation states from body coordinates (Body, piece rule), runs them
# to a steady state, cuts, joins and grafts them, and runs series of wounded
# realizations exactly as the series window of the application does: the same
# solver, perturbations, random streams, stationarity check and head
# detection, all from the headless core (RDLabCore.jl). Every run_series and
# run_single call writes one folder results/<experiment>/<time>_<name>/ with
# spec.toml (the input, enough to run it again), meta.json (versions,
# parameters actually used), outcomes.csv (one row per realization) and
# optional fields/*.csv.
#
# Body coordinates
#
#     s in [0, 1] runs along the body, s = 0 at the head and s = 1 at the foot.
#     The source density of the body is ρ_body(s) = ρ0 + ρ1 (1/2 - s).
#     On a panel the head side is on the right, x = 1: a piece [s_a, s_b] of
#     length f = s_b - s_a becomes a panel of length f L with
#     ρ(x) = ρ0p - ρ1p/2 + ρ1p x, where ρ1p = ρ1 f and ρ0p = ρ_body at the
#     centre of the piece (the piece rule). ρ1 = 0 is the body without source
#     density (SD): ρ ≡ ρ0.
#
# ============================================================

module RDLabAPI

include("RDLabCore.jl")
using .RDLabCore
const C = RDLabCore

using Dates
using Libdl
using LinearAlgebra
using Printf
using Random
using Statistics
import TOML

export Body, Piece, piece, body_rho, without_sd
export load_models, find_model, list_models
export RDState, make_state, steady_state, cut, cut_fraction, flip, graft, resample
export panel_length, panel_fractions, positions, body_coordinates, field, rho_values
export junctions, describe, panel_parameters
export Wound, SeriesSpec, SingleSpec, run_series, run_single, load_spec, rerun
export RESULTS_DIR, solver_threads, set_solver_threads!

# `join(left, right)` makes a doublet; it is a method of Base.join.

const REPO_DIR = normpath(joinpath(@__DIR__, ".."))
const RESULTS_DIR = joinpath(REPO_DIR, "results")


# ============================================================
# Threads of the dense linear solver
# ============================================================
#
# Models with a sparse Jacobian (see make_problem in Simulation.jl) are
# factorized with a sparse LU and do not use these threads. For the others
# TRBDF2 factorizes a dense Jacobian at its Newton steps, through LinearSolve,
# which uses Intel MKL where it is available. MKL starts its own threads for
# every factorization; with several realizations running at once on Julia
# threads they oversubscribe the cores and a series runs tens of times slower.
# The API therefore gives MKL (and OpenBLAS) one thread by default, which also
# makes the results independent of the number of cores: the thread count of
# the factorization changes the last bits of the solution (~1e-12). The
# application leaves MKL at its default (one thread per core); to compute
# exactly as it does, run a series with threads = 1, mkl_threads = :default.

const LINEARSOLVE_PKGID = Base.PkgId(Base.UUID("7ed4a6bd-45f5-4d41-b270-4a48e9bafcae"), "LinearSolve")
const MKL_THREADS = Ref{Any}(1)

function mkl_library()
    solver = get(Base.loaded_modules, LINEARSOLVE_PKGID, nothing)
    solver === nothing && return nothing
    isdefined(solver, :MKL_jll) || return nothing
    jll = getfield(solver, :MKL_jll)
    available = try
        jll.is_available()
    catch
        false
    end
    available || return nothing
    return Libdl.dlopen(jll.libmkl_rt)
end

const MKL_LIBRARY = Ref{Any}(nothing)

function mkl_handle()
    MKL_LIBRARY[] === nothing && (MKL_LIBRARY[] = something(mkl_library(), false))
    return MKL_LIBRARY[] === false ? nothing : MKL_LIBRARY[]
end

"Number of threads MKL uses for a factorization (0 when MKL is not used)."
function mkl_threads()
    handle = mkl_handle()
    handle === nothing && return 0
    return Int(ccall(Libdl.dlsym(handle, :MKL_Get_Max_Threads), Cint, ()))
end

function set_mkl_threads!(n::Integer)
    handle = mkl_handle()
    handle === nothing && return nothing
    ccall(Libdl.dlsym(handle, :MKL_Set_Num_Threads), Cvoid, (Cint,), Cint(n))
    return nothing
end

const MKL_DEFAULT_THREADS = Ref{Int}(-1)

"""
    set_solver_threads!(n)

Threads of the dense factorization (MKL and OpenBLAS) for every API
computation: an integer, or `:default` to leave MKL at its own default (one
thread per core, as in the application). The API default is 1.
"""
function set_solver_threads!(n)
    n === :default || (n isa Integer && n >= 1) || error("Solver threads must be a positive integer or :default.")
    MKL_THREADS[] = n
    return n
end

"The threads of the dense factorization the API uses: an integer or :default."
solver_threads() = MKL_THREADS[]

# Runs f with the factorization threads `n` (an integer or :default) and
# restores the previous setting.
function with_solver_threads(f, n = MKL_THREADS[])
    MKL_DEFAULT_THREADS[] < 0 && (MKL_DEFAULT_THREADS[] = mkl_threads())
    previous_mkl = mkl_threads()
    previous_blas = BLAS.get_num_threads()
    if n === :default
        MKL_DEFAULT_THREADS[] > 0 && set_mkl_threads!(MKL_DEFAULT_THREADS[])
    else
        set_mkl_threads!(n)
        BLAS.set_num_threads(n)
    end
    try
        return f()
    finally
        previous_mkl > 0 && set_mkl_threads!(previous_mkl)
        BLAS.set_num_threads(previous_blas)
    end
end

solver_thread_entry() = Dict{String, Any}(
    "mkl_threads" => mkl_threads(),
    "mkl_used" => mkl_handle() !== nothing,
    "blas_threads" => BLAS.get_num_threads(),
    "setting" => MKL_THREADS[] isa Symbol ? String(MKL_THREADS[]) : MKL_THREADS[],
)


# ============================================================
# Body coordinates and the piece rule
# ============================================================

"""
    Body(L, ρ0, ρ1 = 0)
    Body(; L, ρ0, ρ1 = 0)

A body of length `L` whose source density is ρ_body(s) = ρ0 + ρ1 (1/2 - s),
with s = 0 at the head and s = 1 at the foot. `ρ1 = 0` is the body without
source density (ρ ≡ ρ0).
"""
struct Body
    L::Float64
    ρ0::Float64
    ρ1::Float64

    function Body(L::Real, ρ0::Real, ρ1::Real = 0.0)
        isfinite(L) && L > 0 || error("Body length L must be positive and finite.")
        isfinite(ρ0) && isfinite(ρ1) || error("Body ρ0 and ρ1 must be finite.")
        return new(Float64(L), Float64(ρ0), Float64(ρ1))
    end
end

Body(; L::Real, ρ0::Real, ρ1::Real = 0.0) = Body(L, ρ0, ρ1)

"Source density of the body at body coordinate `s`: ρ0 + ρ1 (1/2 - s)."
body_rho(body::Body, s::Real) = body.ρ0 + body.ρ1 * (0.5 - Float64(s))

"The same body without source density: ρ ≡ ρ0."
without_sd(body::Body) = Body(body.L, body.ρ0, 0.0)


"""
    piece(body, s_a, s_b)

The panel made of the piece [s_a, s_b] of `body` (piece rule): length
f L, ρ1 = ρ1_body f and ρ0 = ρ_body at the centre of the piece, with
f = s_b - s_a. On the panel ρ(x) = ρ0 - ρ1/2 + ρ1 x, head side at x = 1.
"""
struct Piece
    body::Body
    s_a::Float64
    s_b::Float64
    length::Float64
    ρ0::Float64
    ρ1::Float64
end

function piece(body::Body, s_a::Real, s_b::Real)
    0.0 <= s_a < s_b <= 1.0 || error("A piece needs 0 ≤ s_a < s_b ≤ 1, got [$s_a, $s_b].")
    f = Float64(s_b) - Float64(s_a)
    return Piece(
        body,
        Float64(s_a),
        Float64(s_b),
        f * body.L,
        body_rho(body, (Float64(s_a) + Float64(s_b)) / 2),
        body.ρ1 * f,
    )
end

"ρ of the panel of a piece at panel fraction x (head at x = 1)."
panel_rho(p::Piece, x::Real) = p.ρ0 - p.ρ1 / 2 + p.ρ1 * Float64(x)

piece_entry(p::Piece) = Dict{String, Any}(
    "s_a" => p.s_a,
    "s_b" => p.s_b,
    "fraction" => p.s_b - p.s_a,
    "length" => p.length,
    "rho0" => p.ρ0,
    "rho1" => p.ρ1,
)

body_entry(b::Body) = Dict{String, Any}("L" => b.L, "rho0" => b.ρ0, "rho1" => b.ρ1)

body_from_entry(entry) = Body(entry["L"], entry["rho0"], entry["rho1"])


# ============================================================
# Models
# ============================================================

"""
    load_models()

The model registry: registry key (e.g. "GiererMeinhardt/rho") => ModelSpec.
The model files are loaded once, with the module.
"""
load_models() = C.MODEL_REGISTRY


"""
    find_model(id) -> (key, model)

A model by registry key ("GiererMeinhardt/rho"), by model id
(:gierer_meinhardt_rho or "gierer_meinhardt_rho") or by its folder name when
that is unique ("rho").
"""
function find_model(id)
    registry = C.MODEL_REGISTRY
    text = String(id isa Symbol ? String(id) : id)

    haskey(registry, text) && return text, registry[text]

    by_id = [key for (key, model) in registry if String(model.id) == text]
    length(by_id) == 1 && return only(by_id), registry[only(by_id)]

    by_folder = [key for key in keys(registry) if basename(key) == text]
    length(by_folder) == 1 && return only(by_folder), registry[only(by_folder)]

    error("Unknown or ambiguous model '$text'. Known models: " *
          join(sort(["$key ($(registry[key].id))" for key in keys(registry)]), ", "))
end


"Print the models: registry key, id, variables, parameters and profile sets."
function list_models(io::IO = stdout)
    registry = C.MODEL_REGISTRY

    for key in sort(collect(keys(registry)))
        model = registry[key]
        println(io, key, "   id = :", model.id, "   variables = ", join(model.varnames, ", "))
        params = C.public_model_parameter_names(model)
        println(io, "    parameters: ", join(["$name = $(model.default_params[name])" for name in params], ", "))
        isempty(model.spatial_profile_sets) ||
            println(io, "    profile sets: ", join(first.(model.spatial_profile_sets), ", "))
    end

    return nothing
end


# ============================================================
# States
# ============================================================

# Body coordinates of a panel: on the panel fractions [p0, p1] the body
# coordinate runs linearly from s0 to s1. `label` names the piece (e.g.
# "body", "left", "donor") and `body` is the body it was cut from, if known.
struct MapSegment
    p0::Float64
    p1::Float64
    s0::Float64
    s1::Float64
    label::String
    body::Union{Nothing, Body}
end


"""
    RDState

One panel of a model: the core simulation state plus its body coordinates
and the recipe that built it. States are never changed in place; every
operation (steady_state, cut, join, flip, graft) returns a new one.
"""
mutable struct RDState
    sim::C.SimulationState
    model_key::String
    smap::Vector{MapSegment}
    recipe::Dict{String, Any}
    info::Dict{String, Any}
end


model_of(st::RDState) = st.sim.model
diffusion_scale(st::RDState) = C.diffusion_scale(st.sim.params)

"Solver length of the panel: its extent in the x the solver uses."
solver_length(sim::C.SimulationState) = C.segment_physical_length(sim)

"Physical length of the panel."
panel_length(st::RDState) = sqrt(diffusion_scale(st)) * solver_length(st.sim)

"Panel fractions of the grid points, 0 at the left end and 1 at the right end."
function panel_fractions(st::RDState)
    x = st.sim.x
    return (x .- first(x)) ./ solver_length(st.sim)
end

"Physical positions of the grid points, from 0 to panel_length(st)."
positions(st::RDState) = panel_fractions(st) .* panel_length(st)

"Copy of the values of `variable` (name or index) on the grid."
function field(st::RDState, variable)
    index = variable_index(model_of(st), variable)
    return copy(C.solution_matrix(st.sim)[:, index])
end

function variable_index(model, variable)
    variable isa Integer && 1 <= variable <= model.nvars && return Int(variable)
    index = findfirst(==(String(variable isa Symbol ? String(variable) : variable)), model.varnames)
    index === nothing && error("Model $(model.id) has no variable '$variable' (it has $(join(model.varnames, ", "))).")
    return index
end


function active_profile_names(model, params)
    isempty(model.spatial_profile_sets) && return String[]
    set_index = C._active_spatial_profile_set_index(params, model.spatial_profile_sets)
    _, profiles = model.spatial_profile_sets[set_index]
    return [String(first(profile)) for profile in profiles]
end


"The spatial profiles a panel carries: profile name => values on the grid."
function profile_values(sim::C.SimulationState)
    values = Dict{String, Vector{Float64}}()

    for name in active_profile_names(sim.model, sim.params)
        key = C.spatial_profile_override_key(name)
        values[name] = haskey(sim.params, key) ?
            Float64.(collect(sim.params[key])) :
            C._evaluate_spatial_profile_for_parameter(
                sim.x,
                sim.params,
                name,
                profile_function(sim.model, sim.params, name),
            )
    end

    return values
end

function profile_function(model, params, name)
    set_index = C._active_spatial_profile_set_index(params, model.spatial_profile_sets)
    _, profiles = model.spatial_profile_sets[set_index]
    return last(profiles[findfirst(profile -> first(profile) == name, profiles)])
end

"Values of the (first) spatial profile ρ on the grid; empty for a model without profiles."
function rho_values(st::RDState)
    values = profile_values(st.sim)
    isempty(values) && return Float64[]
    return values[first(active_profile_names(model_of(st), st.sim.params))]
end


function body_coordinate(smap::Vector{MapSegment}, p::Real)
    for segment in smap
        if segment.p0 - 1e-12 <= p <= segment.p1 + 1e-12
            span = segment.p1 - segment.p0
            weight = span > 0 ? clamp((p - segment.p0) / span, 0.0, 1.0) : 0.0
            return segment.s0 + weight * (segment.s1 - segment.s0)
        end
    end

    return NaN
end

function piece_label(smap::Vector{MapSegment}, p::Real)
    for segment in smap
        segment.p0 - 1e-12 <= p <= segment.p1 + 1e-12 && return segment.label
    end

    return ""
end

"Body coordinate s of every grid point (NaN where the panel has none)."
body_coordinates(st::RDState) = [body_coordinate(st.smap, p) for p in panel_fractions(st)]

"Panel fractions of the junctions between the pieces of a panel."
junctions(st::RDState) = [segment.p0 for segment in st.smap[2:end]]


"""
    panel_fraction(st, s; label = nothing)

The panel fraction of body coordinate `s`. With pieces of the same body in
one panel (a graft), `label` selects the piece.
"""
function panel_fraction(st::RDState, s::Real; label = nothing)
    for segment in st.smap
        label === nothing || segment.label == label || continue
        lo, hi = minmax(segment.s0, segment.s1)
        lo - 1e-12 <= s <= hi + 1e-12 || continue
        segment.s1 == segment.s0 && return segment.p0
        return segment.p0 + (s - segment.s0) / (segment.s1 - segment.s0) * (segment.p1 - segment.p0)
    end

    error("Body coordinate s = $s is not on this panel (pieces: " *
          join(["$(seg.label) s ∈ [$(min(seg.s0, seg.s1)), $(max(seg.s0, seg.s1))]" for seg in st.smap], ", ") * ").")
end


# A copy of a core state that shares nothing with the original: the ODE
# right-hand side holds the x vector, which rebase_partition_coordinates!
# changes in place.
function clone_sim(
    sim::C.SimulationState;
    x = copy(sim.x),
    dx = sim.dx,
    y = copy(sim.integrator_ref[].u),
    params = deepcopy(sim.params),
    boundary_condition = sim.boundary_condition,
)
    return C.create_simulation_state_from_data(
        sim.model,
        x,
        dx,
        y,
        params;
        boundary_condition = boundary_condition,
        displayed_time = C.current_display_time(sim),
        dtmax = C.current_dtmax(sim),
    )
end

copy_state(st::RDState; recipe = st.recipe) =
    RDState(clone_sim(st.sim), st.model_key, copy(st.smap), recipe, copy(st.info))


function Base.show(io::IO, st::RDState)
    model = model_of(st)
    @printf(
        io,
        "RDState(%s, N = %d, length = %.6g, pieces = %s)",
        model.id,
        st.sim.N,
        panel_length(st),
        join(["$(segment.label)[s $(round(segment.s0; digits = 4))→$(round(segment.s1; digits = 4))]" for segment in st.smap], " | "),
    )
end


"Print a short description of a state: grid, length, parameters, ρ and heads."
function describe(st::RDState; io::IO = stdout)
    model = model_of(st)
    println(io, st)
    println(io, "  model           ", st.model_key, " (", model.display_name, ")")
    @printf(io, "  grid            N = %d, solver x ∈ [%.6g, %.6g], diffusion scale = %.8g\n",
        st.sim.N, first(st.sim.x), last(st.sim.x), diffusion_scale(st))
    params = C.public_model_parameter_names(model)
    println(io, "  parameters      ", join(["$name = $(st.sim.params[name])" for name in params], ", "))
    rho = rho_values(st)
    isempty(rho) || @printf(io, "  ρ               left %.6g, right %.6g, min %.6g, max %.6g\n",
        first(rho), last(rho), minimum(rho), maximum(rho))

    for (key, value) in sort(collect(st.info); by = first)
        value isa Union{Real, AbstractString, Bool} && println(io, "  ", rpad(key, 16), value)
    end

    return nothing
end


# ============================================================
# make_state
# ============================================================

"""
    make_state(model_id; N = 300, length = nothing, body = nothing, piece = nothing,
               params = (;), rho = nothing, initial = :rest, ...)

A new panel of `model_id`.

- `body`, `piece = (s_a, s_b)`: the panel is the piece [s_a, s_b] of the body
  (default the whole body); its length and ρ(x) follow the piece rule.
- `length`: physical panel length (default 1, or the piece length). The
  solver works on the unit interval with every diffusion coefficient divided
  by length², as the domain slider of the application does.
  `diffusion_scale` sets that divisor (length²) directly instead.
- `params`: model parameters, e.g. `(Du = 0.01, Dv = 1.0)`.
- `rho`: `nothing` (piece rule with a body, else the model's active profile),
  a profile set name of the model (e.g. "FootHead"), `(ρ0 = ..., ρ1 = ...)` for
  ρ0 - ρ1/2 + ρ1 x, a vector of values on the grid, or a function of the
  panel fraction x ∈ [0, 1]. Arrays (and the piece rule) are carried by the
  panel through cut, join and graft.
- `initial`: `:rest` (every variable 0), `:model` (the model's initial
  condition; pass `seed` to make it reproducible), constants such as
  `(u = 0.0, v = 0.0)`, another RDState (interpolated by panel fraction) or
  an N × nvars matrix.
- `label`: name of the piece, reported with the heads.
"""
function make_state(
    model_id;
    N::Integer = 300,
    length::Union{Nothing, Real} = nothing,
    diffusion_scale::Union{Nothing, Real} = nothing,
    body::Union{Nothing, Body} = nothing,
    piece::Union{Nothing, Tuple{Real, Real}, Piece} = nothing,
    params = NamedTuple(),
    rho = nothing,
    initial = :rest,
    boundary_condition::Symbol = :neumann,
    dtmax::Real = 1e-2,
    label::AbstractString = "body",
    seed::Union{Nothing, Integer} = nothing,
)
    key, model = find_model(model_id)
    N >= 3 || error("N must be at least 3.")
    boundary_condition == :neumann || boundary_condition == :periodic ||
        error("boundary_condition must be :neumann or :periodic.")

    # The piece of the body, if any.
    the_piece = if piece isa Piece
        piece
    elseif body !== nothing
        s_a, s_b = piece === nothing ? (0.0, 1.0) : piece
        RDLabAPI.piece(body, s_a, s_b)
    else
        piece === nothing || error("`piece = (s_a, s_b)` needs a `body`.")
        nothing
    end

    # Physical length and diffusion scale (= length²).
    panel_len = if length !== nothing
        Float64(length)
    elseif the_piece !== nothing
        the_piece.length
    elseif diffusion_scale !== nothing
        sqrt(Float64(diffusion_scale))
    else
        1.0
    end
    isfinite(panel_len) && panel_len > 0 || error("Panel length must be positive and finite.")
    if the_piece !== nothing && length !== nothing && !isapprox(panel_len, the_piece.length; rtol = 1e-12)
        error("length = $length disagrees with the piece length $(the_piece.length) (f L).")
    end
    scale = diffusion_scale === nothing ? panel_len^2 : Float64(diffusion_scale)
    isfinite(scale) && scale > 0 || error("Diffusion scale must be positive and finite.")

    # Parameters: the model defaults, the given values, the domain length.
    parameters = Dict{Symbol, Any}(model.default_params)
    given = parameter_dict(params)
    public = Set(C.public_model_parameter_names(model))

    for (name, value) in given
        name in public || error("Model $(model.id) has no parameter $name (it has $(join(sort(collect(public); by = String), ", "))).")
        parameters[name] = value
    end
    parameters[C.DIFFUSION_SCALE_PARAM] = scale

    x, dx = C.make_grid_1d(Int(N); boundary_condition = boundary_condition)
    xfrac = boundary_condition == :neumann ? (x .- first(x)) ./ (last(x) - first(x)) : copy(x)

    # Spatial profile ρ.
    rho_source, rho_recipe = set_rho!(parameters, model, xfrac, rho, the_piece)

    # Initial state.
    U, initial_recipe = initial_matrix(model, x, xfrac, parameters, initial, seed)

    sim = C.create_simulation_state_from_data(
        model,
        x,
        dx,
        vec(U),
        parameters;
        boundary_condition = boundary_condition,
        dtmax = Float64(dtmax),
    )

    # A profile evaluated by the model is stored on the panel, as the
    # application does, so that cut and join carry it.
    rho_source == "model" && C.refresh_partition_spatial_profile_overrides!([sim])

    s_a, s_b = the_piece === nothing ? (0.0, 1.0) : (the_piece.s_a, the_piece.s_b)
    smap = [MapSegment(0.0, 1.0, s_b, s_a, String(label), the_piece === nothing ? nothing : the_piece.body)]

    recipe = Dict{String, Any}(
        "op" => "make_state",
        "model" => key,
        "N" => Int(N),
        "boundary_condition" => String(boundary_condition),
        "params" => Dict{String, Any}(String(name) => value for (name, value) in given),
        "rho" => rho_recipe,
        "initial" => initial_recipe,
        "dtmax" => Float64(dtmax),
        "label" => String(label),
    )
    diffusion_scale === nothing ? (recipe["length"] = panel_len) : (recipe["diffusion_scale"] = scale)
    if the_piece !== nothing
        recipe["body"] = body_entry(the_piece.body)
        recipe["piece"] = [the_piece.s_a, the_piece.s_b]
    end
    seed === nothing || (recipe["seed"] = Int(seed))

    info = Dict{String, Any}("rho_source" => rho_source)
    return RDState(sim, key, smap, recipe, info)
end


function parameter_dict(params)
    params isa NamedTuple && return Dict{Symbol, Float64}(name => Float64(value) for (name, value) in pairs(params))
    params isa AbstractDict && return Dict{Symbol, Float64}(Symbol(name) => Float64(value) for (name, value) in params)
    error("params must be a NamedTuple or a Dict.")
end


function set_rho!(parameters, model, xfrac, rho, the_piece)
    names = active_profile_names(model, parameters)

    if rho isa Union{Symbol, AbstractString}
        set_name = String(rho)
        index = findfirst(set -> first(set) == set_name, model.spatial_profile_sets)
        index === nothing && error("Model $(model.id) has no profile set '$set_name' (it has " *
                                   join(first.(model.spatial_profile_sets), ", ") * ").")
        parameters[C.ACTIVE_SPATIAL_PROFILE_SET_PARAM] = Float64(index)
        return "model", Dict{String, Any}("kind" => "model", "set" => set_name)
    end

    if rho === nothing && the_piece === nothing
        isempty(names) && return "none", Dict{String, Any}("kind" => "none")
        set_name = first(model.spatial_profile_sets[C._active_spatial_profile_set_index(parameters, model.spatial_profile_sets)])
        return "model", Dict{String, Any}("kind" => "model", "set" => set_name)
    end

    isempty(names) && error("Model $(model.id) has no spatial profile to carry ρ.")
    name = first(names)

    values, recipe = if rho === nothing
        [panel_rho(the_piece, xi) for xi in xfrac],
        Dict{String, Any}("kind" => "piece_rule", "rho0" => the_piece.ρ0, "rho1" => the_piece.ρ1)
    elseif rho isa NamedTuple
        haskey(rho, :ρ0) || error("rho = (ρ0 = ..., ρ1 = ...) needs ρ0.")
        linear = Piece(Body(1.0, 1.0, 0.0), 0.0, 1.0, 1.0, Float64(rho.ρ0), Float64(get(rho, :ρ1, 0.0)))
        [panel_rho(linear, xi) for xi in xfrac],
        Dict{String, Any}("kind" => "linear", "rho0" => linear.ρ0, "rho1" => linear.ρ1)
    elseif rho isa AbstractVector
        length(rho) == length(xfrac) || error("rho has $(length(rho)) values for $(length(xfrac)) grid points.")
        v = Float64.(collect(rho))
        v, Dict{String, Any}("kind" => "array", "values" => v)
    elseif rho isa Function
        v = Float64[rho(xi) for xi in xfrac]
        v, Dict{String, Any}("kind" => "array", "values" => v)
    else
        error("rho must be nothing, a profile set name, (ρ0 = ..., ρ1 = ...), a vector or a function.")
    end

    all(isfinite, values) || error("ρ has values that are not finite.")
    parameters[C.spatial_profile_override_key(name)] = values
    return "array", recipe
end


function initial_matrix(model, x, xfrac, parameters, initial, seed)
    N = length(x)
    nvars = model.nvars
    U = zeros(Float64, N, nvars)

    if initial === :rest
        return U, Dict{String, Any}("kind" => "rest")
    elseif initial === :model
        if seed === nothing
            model.initialize!(U, x, parameters)
        else
            # The model initial conditions draw from the global generator;
            # it is seeded for this call and restored afterwards.
            saved = copy(Random.default_rng())
            try
                Random.seed!(seed)
                model.initialize!(U, x, parameters)
            finally
                copy!(Random.default_rng(), saved)
            end
        end
        return U, Dict{String, Any}("kind" => "model")
    elseif initial isa NamedTuple || initial isa AbstractDict
        values = Dict{String, Float64}(String(k) => Float64(v) for (k, v) in pairs(initial))
        for (name, value) in values
            U[:, variable_index(model, name)] .= value
        end
        return U, Dict{String, Any}("kind" => "constant", "values" => values)
    elseif initial isa RDState
        source = initial
        model_of(source).varnames == model.varnames || error("The initial state has other variables.")
        source_p = panel_fractions(source)
        Us = C.solution_matrix(source.sim)
        for variable in 1:nvars
            U[:, variable] = C.interpolate_partition_values(source_p, Us[:, variable], xfrac)
        end
        return U, Dict{String, Any}("kind" => "state", "source" => source.recipe)
    elseif initial isa AbstractMatrix
        size(initial) == (N, nvars) || error("initial must be an N × nvars matrix ($N × $nvars).")
        U .= initial
        return U, Dict{String, Any}("kind" => "array",
            "values" => Dict{String, Any}(model.varnames[j] => U[:, j] for j in 1:nvars))
    end

    error("initial must be :rest, :model, constants such as (u = 0.0, v = 0.0), an RDState or an N × nvars matrix.")
end


# ============================================================
# Steady state
# ============================================================

"""
    series_settings(; kwargs...)

The core SeriesSettings with the defaults of the application's series window
(maximum_time 1e15, check_interval 1e3, tolerance 1e-6, 3 consecutive
checks, dtmax 1e10, reltol 1e-5, abstol 1e-7, seed 12345).
"""
function series_settings(;
    runs::Integer = 1,
    seed::Integer = 12345,
    maximum_time::Real = 1e15,
    check_interval::Real = 1e3,
    tolerance::Real = 1e-6,
    required_consecutive_checks::Integer = 3,
    dtmax::Real = 1e10,
    reltol::Real = 1e-5,
    abstol::Real = 1e-7,
    maximum_steps::Integer = 10_000_000,
    head_variable::Integer = 1,
)
    return C.SeriesSettings(
        run_count = Int(runs),
        maximum_time = Float64(maximum_time),
        maximum_steps_per_panel = Int(maximum_steps),
        check_interval = Float64(check_interval),
        tolerance = Float64(tolerance),
        required_consecutive_checks = Int(required_consecutive_checks),
        dtmax = Float64(dtmax),
        seed = UInt64(seed),
        head_variable = Int(head_variable),
        live_preview = false,
        reltol = Float64(reltol),
        abstol = Float64(abstol),
    )
end

const SETTINGS_KEYS = (
    :maximum_time, :check_interval, :tolerance, :required_consecutive_checks,
    :dtmax, :reltol, :abstol, :maximum_steps,
)

settings_entry(s::C.SeriesSettings) = Dict{String, Any}(
    "maximum_time" => s.maximum_time,
    "check_interval" => s.check_interval,
    "tolerance" => s.tolerance,
    "required_consecutive_checks" => s.required_consecutive_checks,
    "dtmax" => s.dtmax,
    "reltol" => s.reltol,
    "abstol" => s.abstol,
    "maximum_steps" => s.maximum_steps_per_panel,
)

settings_kwargs(entry) = (; (Symbol(k) => v for (k, v) in entry if Symbol(k) in SETTINGS_KEYS)...)


"""
    steady_state(state; maximum_time = 1e15, check_interval = 1e3, tolerance = 1e-6,
                 required_consecutive_checks = 3, dtmax = 1e10, reltol = 1e-5, abstol = 1e-7)

Runs `state` until it is stationary, with the stationarity check of the
series window (scaled max |du/dt| below `tolerance` at
`required_consecutive_checks` consecutive checks). Returns a new state;
`state.info` holds converged, time, steps, residual and the detected heads.
"""
function steady_state(st::RDState; head_variable = 1, kwargs...)
    settings = series_settings(; head_variable = variable_index(model_of(st), head_variable), kwargs...)
    template = C.make_series_template(st.sim)
    sim = C.instantiate_series_template(template, settings)
    outcome = with_solver_threads(() -> C.run_series_panel!(sim, settings, 0))

    outcome.converged ||
        @warn "steady_state: not stationary after t = $(outcome.time) ($(outcome.steps) steps, residual $(outcome.residual))."

    recipe = Dict{String, Any}(
        "op" => "steady_state",
        "source" => st.recipe,
        "settings" => settings_entry(settings),
        "head_variable" => model_of(st).varnames[settings.head_variable],
    )
    info = copy(st.info)
    info["converged"] = outcome.converged
    info["steady_time"] = outcome.time
    info["steady_steps"] = outcome.steps
    info["steady_residual"] = outcome.residual
    info["heads"] = length(outcome.heads)
    info["head_fractions"] = head_fractions(outcome.heads, sim)

    return RDState(sim, st.model_key, copy(st.smap), recipe, info)
end


# ============================================================
# cut, flip, join, graft
# ============================================================

function restrict_map(smap::Vector{MapSegment}, lo::Float64, hi::Float64)
    width = hi - lo
    result = MapSegment[]

    for segment in smap
        a = max(segment.p0, lo)
        b = min(segment.p1, hi)
        b - a > 1e-12 || continue
        push!(
            result,
            MapSegment(
                (a - lo) / width,
                (b - lo) / width,
                body_coordinate([segment], a),
                body_coordinate([segment], b),
                segment.label,
                segment.body,
            ),
        )
    end

    return result
end


# The splits of a cut: split_simulation_state(parent, k) splits at the
# fraction k / N of its panel, so a cut needs one split per end, the second
# on the piece left by the first. Of the two orders, the one whose split
# points come closer to p_lo and p_hi (the right end first on a tie).
function cut_plan(N::Int, p_lo::Float64, p_hi::Float64)
    split_index(fraction) = clamp(round(Int, fraction * N), 2, N - 2)
    cut_lo = p_lo > 1e-12
    cut_hi = p_hi < 1.0 - 1e-12

    # Right end first: split at p_hi, then the left piece at p_lo.
    k_hi = cut_hi ? split_index(p_hi) : 0
    a_hi = cut_hi ? k_hi / N : 1.0
    k_lo = cut_lo ? split_index(p_lo / a_hi) : 0
    a_lo = cut_lo ? (k_lo / N) * a_hi : 0.0
    right_first = (order = :right_first, first = k_hi, second = k_lo, lo = a_lo, hi = a_hi)

    # Left end first: split at p_lo, then the right piece at p_hi.
    k_lo = cut_lo ? split_index(p_lo) : 0
    b_lo = cut_lo ? k_lo / N : 0.0
    k_hi = cut_hi ? split_index((p_hi - b_lo) / (1.0 - b_lo)) : 0
    b_hi = cut_hi ? b_lo + (k_hi / N) * (1.0 - b_lo) : 1.0
    left_first = (order = :left_first, first = k_lo, second = k_hi, lo = b_lo, hi = b_hi)

    error_of(plan) = max(abs(plan.lo - p_lo), abs(plan.hi - p_hi))
    return error_of(left_first) < error_of(right_first) - 1e-15 ? left_first : right_first
end


"""
    cut_fraction(state, p_lo, p_hi)

The piece between panel fractions p_lo and p_hi, cut with
split_simulation_state as the Split button does (once per end) and rebased
to start at x = 0 as Delete does. A split falls on a multiple of 1/N of the
panel it splits, so the cut points are rounded to that grid (the order of
the two splits that comes closer is used); `info["cut"]` holds the fractions
actually used. u, v and ρ are interpolated onto the N points of the piece.
"""
function cut_fraction(st::RDState, p_lo::Real, p_hi::Real; recipe = nothing, rename = nothing)
    0.0 <= p_lo < p_hi <= 1.0 || error("A cut needs 0 ≤ p_lo < p_hi ≤ 1.")
    st.sim.boundary_condition == :neumann || error("Only Neumann panels can be cut.")
    sim = st.sim
    N = sim.N
    C.ensure_partition_spatial_profile_overrides!([sim])
    plan = cut_plan(N, Float64(p_lo), Float64(p_hi))
    piece_sim = sim

    if plan.order == :right_first
        plan.first > 0 && (piece_sim = first(C.split_simulation_state(piece_sim, plan.first)))
        plan.second > 0 && (piece_sim = last(C.split_simulation_state(piece_sim, plan.second)))
    else
        plan.first > 0 && (piece_sim = last(C.split_simulation_state(piece_sim, plan.first)))
        plan.second > 0 && (piece_sim = first(C.split_simulation_state(piece_sim, plan.second)))
    end
    actual_lo = plan.lo
    actual_hi = plan.hi

    piece_sim === sim && (piece_sim = clone_sim(sim))
    C.rebase_partition_coordinates!([piece_sim])

    info = copy(st.info)
    info["rho_source"] = info["rho_source"] == "none" ? "none" : "array"
    info["cut"] = [actual_lo, actual_hi]
    delete!(info, "converged")
    smap = restrict_map(st.smap, actual_lo, actual_hi)
    rename === nothing ||
        (smap = [MapSegment(seg.p0, seg.p1, seg.s0, seg.s1, String(rename), seg.body) for seg in smap])
    recipe = recipe === nothing ?
        Dict{String, Any}("op" => "cut", "source" => st.recipe, "fraction" => [Float64(p_lo), Float64(p_hi)]) :
        recipe
    rename === nothing || (recipe["rename"] = String(rename))

    return RDState(piece_sim, st.model_key, smap, recipe, info)
end


"""
    cut(state, s_a, s_b; rename = nothing)

The piece [s_a, s_b] (body coordinates) of `state`; it keeps u, v and ρ.
`rename` gives the piece a new label (reported with its heads); with several
pieces of the same body in `state`, `label` selects the one to cut from.
See cut_fraction for how the cut points are placed.
"""
function cut(st::RDState, s_a::Real, s_b::Real; label = nothing, rename = nothing)
    p1 = panel_fraction(st, s_a; label = label)
    p2 = panel_fraction(st, s_b; label = label)
    lo, hi = minmax(p1, p2)
    recipe = Dict{String, Any}("op" => "cut", "source" => st.recipe, "s" => [Float64(s_a), Float64(s_b)])
    label === nothing || (recipe["label"] = String(label))
    return cut_fraction(st, clamp(lo, 0.0, 1.0), clamp(hi, 0.0, 1.0); recipe = recipe, rename = rename)
end


"""
    flip(state)

The panel turned around: x → 1 - x for every variable, ρ and the body
coordinates.
"""
function flip(st::RDState)
    sim = st.sim
    U = reverse(copy(C.solution_matrix(sim)); dims = 1)
    params = deepcopy(sim.params)

    for key in collect(keys(params))
        C._is_spatial_profile_override_key(key) && (params[key] = reverse(Float64.(collect(params[key]))))
    end

    flipped = clone_sim(sim; y = vec(U), params = params)
    smap = sort!([
        MapSegment(1.0 - segment.p1, 1.0 - segment.p0, segment.s1, segment.s0, segment.label, segment.body)
        for segment in st.smap
    ]; by = segment -> segment.p0)
    info = copy(st.info)
    st.info["rho_source"] == "none" || (info["rho_source"] = "array")

    return RDState(flipped, st.model_key, smap, Dict{String, Any}("op" => "flip", "source" => st.recipe), info)
end


# The state with its solver x rescaled to diffusion scale `scale`: the same
# physical panel, with x and dx stretched by sqrt(old scale / scale).
function with_diffusion_scale(st::RDState, scale::Float64)
    old = diffusion_scale(st)
    old == scale && return copy_state(st)
    factor = sqrt(old / scale)
    sim = st.sim
    params = deepcopy(sim.params)
    params[C.DIFFUSION_SCALE_PARAM] = scale
    x = first(sim.x) .+ (sim.x .- first(sim.x)) .* factor
    return RDState(
        clone_sim(sim; x = x, dx = sim.dx * factor, params = params),
        st.model_key,
        copy(st.smap),
        st.recipe,
        copy(st.info),
    )
end


const PARAMETER_TOLERANCE = 1e-12

function check_same_parameters(left::RDState, right::RDState)
    model_of(left).id == model_of(right).id ||
        error("Only states of the same model can be joined ($(model_of(left).id) and $(model_of(right).id)).")

    for name in C.public_model_parameter_names(model_of(left))
        a = left.sim.params[name]
        b = right.sim.params[name]
        isapprox(a, b; rtol = PARAMETER_TOLERANCE) ||
            @warn "join: parameter $name differs ($a left, $b right); the doublet uses the left value $a."
    end

    return nothing
end


"""
    join(left, right; flip_left = false, flip_right = false, N = nothing)

The doublet of two panels, `left` then `right`, merged with
merge_simulation_states as the Merge button does. ρ is carried by the pieces.
`flip_left` / `flip_right` turn a piece around first. The doublet has
max(N_left, N_right) grid points unless `N` is given (then it is resampled).
Model parameters are taken from `left`; the right panel is converted to the
diffusion scale of the left one when they differ (same physical length).
"""
function Base.join(
    left::RDState,
    right::RDState;
    flip_left::Bool = false,
    flip_right::Bool = false,
    N::Union{Nothing, Integer} = nothing,
)
    check_same_parameters(left, right)
    left.sim.boundary_condition == :neumann && right.sim.boundary_condition == :neumann ||
        error("Only Neumann panels can be joined.")

    l = flip_left ? flip(left) : copy_state(left)
    r = flip_right ? flip(right) : copy_state(right)
    r = with_diffusion_scale(r, diffusion_scale(l))

    C.ensure_partition_spatial_profile_overrides!([l.sim])
    C.ensure_partition_spatial_profile_overrides!([r.sim])
    C.rebase_partition_coordinates!([l.sim, r.sim])
    merged = C.merge_simulation_states(l.sim, r.sim; boundary_condition = :neumann)

    wl = solver_length(l.sim)
    wr = solver_length(r.sim)
    split = wl / (wl + wr)
    smap = vcat(
        [MapSegment(seg.p0 * split, seg.p1 * split, seg.s0, seg.s1, seg.label, seg.body) for seg in l.smap],
        [MapSegment(split + seg.p0 * (1 - split), split + seg.p1 * (1 - split), seg.s0, seg.s1, seg.label, seg.body) for seg in r.smap],
    )

    info = Dict{String, Any}(
        "rho_source" => (left.info["rho_source"] == "none" ? "none" : "array"),
        "junction" => split,
    )
    recipe = Dict{String, Any}(
        "op" => "join",
        "left" => left.recipe,
        "right" => right.recipe,
        "flip_left" => flip_left,
        "flip_right" => flip_right,
    )
    N === nothing || (recipe["N"] = Int(N))
    doublet = RDState(merged, left.model_key, smap, recipe, info)
    return N === nothing ? doublet : resample(doublet, Int(N); recipe = recipe)
end


"""
    resample(state, N)

The state on N grid points (linear interpolation of every variable and ρ).
"""
function resample(st::RDState, N::Integer; recipe = nothing)
    sim = st.sim
    sim.boundary_condition == :neumann || error("Only Neumann panels can be resampled.")
    x = collect(range(first(sim.x), last(sim.x); length = N))
    dx = (last(x) - first(x)) / (N - 1)
    U = C.solution_matrix(sim)
    y = vcat([C.interpolate_partition_values(sim.x, U[:, j], x) for j in 1:sim.model.nvars]...)
    params = C.resample_partition_params(sim.params, sim.x, x)
    recipe = recipe === nothing ? Dict{String, Any}("op" => "resample", "source" => st.recipe, "N" => Int(N)) : recipe
    return RDState(clone_sim(sim; x = x, dx = dx, y = y, params = params), st.model_key, copy(st.smap), recipe, copy(st.info))
end


"""
    graft(host, donor, s; flip_donor = false, label = nothing, fraction = nothing)

The host split at body coordinate `s` (or at panel fraction `fraction`) with
`donor` inserted there: join(join(host[.., s], donor), host[s, ..]).
"""
function graft(
    host::RDState,
    donor::RDState,
    s::Union{Nothing, Real} = nothing;
    fraction::Union{Nothing, Real} = nothing,
    flip_donor::Bool = false,
    label = nothing,
)
    (s === nothing) != (fraction === nothing) || error("Give the graft position as s or as fraction, not both.")
    p = fraction === nothing ? panel_fraction(host, s; label = label) : Float64(fraction)
    0.0 < p < 1.0 || error("The graft position must lie inside the host.")
    a = cut_fraction(host, 0.0, p)
    b = cut_fraction(host, a.info["cut"][2], 1.0)
    d = flip_donor ? flip(donor) : donor
    result = join(join(a, d), b)
    result.recipe = Dict{String, Any}(
        "op" => "graft",
        "host" => host.recipe,
        "donor" => donor.recipe,
        "flip_donor" => flip_donor,
    )
    s === nothing ? (result.recipe["fraction"] = Float64(fraction)) : (result.recipe["s"] = Float64(s))
    label === nothing || (result.recipe["label"] = String(label))
    result.info["junctions"] = junctions(result)
    return result
end


# ============================================================
# Rebuilding a state from its recipe
# ============================================================

recipe_tuple(entry) = Tuple(Float64.(entry))

"""
    state_from_recipe(recipe)

Builds the state a recipe (as written to spec.toml) describes, running every
step again: make_state, steady_state, cut, flip, join, graft, resample.
"""
function state_from_recipe(recipe::AbstractDict)
    op = recipe["op"]

    if op == "make_state"
        rho_entry = recipe["rho"]
        kind = rho_entry["kind"]
        body = haskey(recipe, "body") ? body_from_entry(recipe["body"]) : nothing
        rho = if kind == "model"
            rho_entry["set"]
        elseif kind == "piece_rule"
            nothing
        elseif kind == "linear"
            (ρ0 = rho_entry["rho0"], ρ1 = rho_entry["rho1"])
        elseif kind == "array"
            Float64.(rho_entry["values"])
        else
            nothing
        end
        initial_entry = recipe["initial"]
        initial_kind = initial_entry["kind"]
        initial = if initial_kind == "rest"
            :rest
        elseif initial_kind == "model"
            :model
        elseif initial_kind == "constant"
            Dict{String, Float64}(k => Float64(v) for (k, v) in initial_entry["values"])
        elseif initial_kind == "state"
            state_from_recipe(initial_entry["source"])
        elseif initial_kind == "array"
            _, model = find_model(recipe["model"])
            hcat([Float64.(initial_entry["values"][name]) for name in model.varnames]...)
        else
            error("Unknown initial condition kind '$initial_kind'.")
        end
        return make_state(
            recipe["model"];
            N = recipe["N"],
            length = get(recipe, "length", nothing),
            diffusion_scale = get(recipe, "diffusion_scale", nothing),
            body = body,
            piece = haskey(recipe, "piece") ? recipe_tuple(recipe["piece"]) : nothing,
            params = Dict{Symbol, Float64}(Symbol(k) => Float64(v) for (k, v) in recipe["params"]),
            rho = rho,
            initial = initial,
            boundary_condition = Symbol(recipe["boundary_condition"]),
            dtmax = recipe["dtmax"],
            label = recipe["label"],
            seed = get(recipe, "seed", nothing),
        )
    elseif op == "steady_state"
        source = state_from_recipe(recipe["source"])
        return steady_state(source; head_variable = recipe["head_variable"], settings_kwargs(recipe["settings"])...)
    elseif op == "cut"
        source = state_from_recipe(recipe["source"])
        rename = get(recipe, "rename", nothing)
        haskey(recipe, "s") &&
            return cut(source, recipe["s"]...; label = get(recipe, "label", nothing), rename = rename)
        return cut_fraction(source, recipe["fraction"]...; rename = rename)
    elseif op == "flip"
        return flip(state_from_recipe(recipe["source"]))
    elseif op == "join"
        return join(
            state_from_recipe(recipe["left"]),
            state_from_recipe(recipe["right"]);
            flip_left = recipe["flip_left"],
            flip_right = recipe["flip_right"],
            N = get(recipe, "N", nothing),
        )
    elseif op == "graft"
        host = state_from_recipe(recipe["host"])
        donor = state_from_recipe(recipe["donor"])
        return graft(
            host,
            donor,
            get(recipe, "s", nothing);
            fraction = get(recipe, "fraction", nothing),
            flip_donor = recipe["flip_donor"],
            label = get(recipe, "label", nothing),
        )
    elseif op == "resample"
        return resample(state_from_recipe(recipe["source"]), recipe["N"])
    end

    error("Unknown recipe step '$op'.")
end


# ============================================================
# Wounds
# ============================================================

"""
    Wound(at; width = (min, max), height = (min, max), variable = :u)
    Wound(; s, width, height, variable = :u)

A perturbation of `variable` drawn in every realization as the series window
draws it: a width uniform in `width`, a height uniform in `height`, and at
every grid point within half the width of the centre an increment
height × uniform(0, 1).

- `at`: a panel fraction in [0, 1], `:left` (0), `:right` (1), `:ends`
  (both ends), or `:junctions` (every junction between joined pieces);
  `s = ...` places it at a body coordinate instead.
- `width`: in absolute length units (converted to the panel fraction
  internally). `width_fraction` gives it as a fraction of the panel length,
  as the series window does.
"""
struct Wound
    at::Any
    s::Union{Nothing, Float64}
    label::Union{Nothing, String}
    width::Union{Nothing, Tuple{Float64, Float64}}
    width_fraction::Union{Nothing, Tuple{Float64, Float64}}
    height::Tuple{Float64, Float64}
    variable::String
end

pair_of(value::Real) = (Float64(value), Float64(value))
pair_of(value) = (Float64(value[1]), Float64(value[2]))

function Wound(
    at = nothing;
    s = nothing,
    label = nothing,
    width = nothing,
    width_fraction = nothing,
    height = (1.0, 2.0),
    variable = :u,
)
    (at === nothing) != (s === nothing) || error("A wound needs either a position `at` or a body coordinate `s`.")
    (width === nothing) != (width_fraction === nothing) ||
        error("A wound needs either `width` (absolute) or `width_fraction`.")
    at isa Union{Nothing, Real, Symbol} || error("Wound position must be a panel fraction or :left, :right, :ends, :junctions.")
    at isa Symbol && !(at in (:left, :right, :ends, :junctions)) &&
        error("Unknown wound position :$at (use :left, :right, :ends or :junctions).")
    return Wound(
        at isa Real ? Float64(at) : at,
        s === nothing ? nothing : Float64(s),
        label === nothing ? nothing : String(label),
        width === nothing ? nothing : pair_of(width),
        width_fraction === nothing ? nothing : pair_of(width_fraction),
        pair_of(height),
        String(variable),
    )
end

function wound_entry(w::Wound)
    entry = Dict{String, Any}("height" => collect(w.height), "variable" => w.variable)
    w.at === nothing || (entry["at"] = w.at isa Symbol ? String(w.at) : w.at)
    w.s === nothing || (entry["s"] = w.s)
    w.label === nothing || (entry["label"] = w.label)
    w.width === nothing || (entry["width"] = collect(w.width))
    w.width_fraction === nothing || (entry["width_fraction"] = collect(w.width_fraction))
    return entry
end

function wound_from_entry(entry)
    at = get(entry, "at", nothing)
    at isa AbstractString && (at = Symbol(at))
    return Wound(
        at;
        s = get(entry, "s", nothing),
        label = get(entry, "label", nothing),
        width = get(entry, "width", nothing),
        width_fraction = get(entry, "width_fraction", nothing),
        height = entry["height"],
        variable = entry["variable"],
    )
end


# Panel fractions of a wound on a state.
function wound_fractions(w::Wound, st::RDState)
    w.s === nothing || return [panel_fraction(st, w.s; label = w.label)]
    w.at isa Real && return [w.at]
    w.at == :left && return [0.0]
    w.at == :right && return [1.0]
    w.at == :ends && return [0.0, 1.0]
    w.at == :junctions && return junctions(st)
    error("Unknown wound position $(w.at).")
end


# The wounds of a state as the series window's perturbations: position and
# widths as fractions of the panel, converted to solver units exactly as
# series_runtime_perturbations does at Start.
function runtime_perturbations(wounds::Vector{Wound}, st::RDState, template)
    model = model_of(st)
    perturbations = C.SeriesPerturbation[]
    rows = Dict{String, Any}[]
    len = panel_length(st)
    solver_len = template.boundary_condition == :periodic ?
        last(template.x) - first(template.x) + template.dx :
        max(last(template.x) - first(template.x), 0.0)

    for (number, wound) in enumerate(wounds)
        width = wound.width_fraction === nothing ?
            (wound.width[1] / len, wound.width[2] / len) :
            wound.width_fraction
        variable = variable_index(model, wound.variable)
        fractions = wound_fractions(wound, st)
        isempty(fractions) && @warn "Wound $number ($(wound.at)) has no position on this panel."

        for fraction in fractions
            0.0 <= fraction <= 1.0 || error("Wound $number lies outside the panel (fraction $fraction).")
            0.0 < width[1] <= width[2] <= 1.0 ||
                error("Wound $number: widths $(width) as fractions of the panel must satisfy 0 < min ≤ max ≤ 1.")
            id = length(perturbations) + 1
            push!(
                perturbations,
                C.SeriesPerturbation(
                    id = id,
                    segment = 1,
                    variable = variable,
                    position = first(template.x) + fraction * solver_len,
                    width_min = width[1] * solver_len,
                    width_max = width[2] * solver_len,
                    height_min = wound.height[1],
                    height_max = wound.height[2],
                ),
            )
            push!(
                rows,
                Dict{String, Any}(
                    "wound" => number,
                    "variable" => model.varnames[variable],
                    "fraction" => fraction,
                    "s" => body_coordinate(st.smap, fraction),
                    "position" => fraction * len,
                    "width_fraction" => collect(width),
                    "width" => collect(width .* len),
                    "height" => collect(wound.height),
                ),
            )
        end
    end

    return perturbations, rows
end


# ============================================================
# Specs
# ============================================================

"""
    SeriesSpec(; experiment, name = "", start, wounds, runs = 100, seed = 12345, ...)

A series: `runs` realizations of `start` with the `wounds` applied, each run
to a stationary state, heads detected. The random stream of realization k is
seeded with seed + k - 1, as in the application. Settings default to those of
the series window. `save_fields` selects runs whose final fields are written
(:none, :all, a vector of run numbers, or n for the first n runs).
`redraw_profiles` redraws random model profiles in every realization (default:
only when ρ comes from the model's own profile).
"""
Base.@kwdef struct SeriesSpec
    experiment::String
    name::String = ""
    start::RDState
    wounds::Vector{Wound} = Wound[]
    runs::Int = 100
    seed::Int = 12345
    maximum_time::Float64 = 1e15
    check_interval::Float64 = 1e3
    tolerance::Float64 = 1e-6
    required_consecutive_checks::Int = 3
    dtmax::Float64 = 1e10
    reltol::Float64 = 1e-5
    abstol::Float64 = 1e-7
    maximum_steps::Int = 10_000_000
    head_variable::String = "u"
    save_fields::Any = :none
    redraw_profiles::Union{Nothing, Bool} = nothing
    notes::String = ""
end


"""
    SingleSpec(; experiment, name = "", start, wounds = Wound[], seed = 12345, run = 1,
               times = Float64[], until_steady = true, ...)

One realization: `start` with the `wounds` drawn from the stream of
realization `run` (seed + run - 1), integrated with profiles of all variables
and ρ recorded at `times` (solver time after the wounds), and run on to a
stationary state when `until_steady`.
"""
Base.@kwdef struct SingleSpec
    experiment::String
    name::String = ""
    start::RDState
    wounds::Vector{Wound} = Wound[]
    seed::Int = 12345
    run::Int = 1
    times::Vector{Float64} = Float64[]
    until_steady::Bool = true
    maximum_time::Float64 = 1e15
    check_interval::Float64 = 1e3
    tolerance::Float64 = 1e-6
    required_consecutive_checks::Int = 3
    dtmax::Float64 = 1e10
    reltol::Float64 = 1e-5
    abstol::Float64 = 1e-7
    maximum_steps::Int = 10_000_000
    head_variable::String = "u"
    redraw_profiles::Union{Nothing, Bool} = nothing
    notes::String = ""
end


function spec_settings(spec; runs = 1)
    return series_settings(
        runs = runs,
        seed = spec.seed,
        maximum_time = spec.maximum_time,
        check_interval = spec.check_interval,
        tolerance = spec.tolerance,
        required_consecutive_checks = spec.required_consecutive_checks,
        dtmax = spec.dtmax,
        reltol = spec.reltol,
        abstol = spec.abstol,
        maximum_steps = spec.maximum_steps,
        head_variable = variable_index(model_of(spec.start), spec.head_variable),
    )
end


function spec_entry(spec)
    kind = spec isa SeriesSpec ? "series" : "single"
    entry = Dict{String, Any}(
        "kind" => kind,
        "experiment" => spec.experiment,
        "name" => spec.name,
        "seed" => spec.seed,
        "head_variable" => spec.head_variable,
        "notes" => spec.notes,
        "settings" => Dict{String, Any}(String(k) => getfield(spec, k) for k in SETTINGS_KEYS),
        "wounds" => [wound_entry(w) for w in spec.wounds],
        "start" => spec.start.recipe,
    )
    spec.redraw_profiles === nothing || (entry["redraw_profiles"] = spec.redraw_profiles)

    if spec isa SeriesSpec
        entry["runs"] = spec.runs
        save = spec.save_fields
        entry["save_fields"] = save isa Symbol ? String(save) : save isa Integer ? Int(save) : collect(Int, save)
    else
        entry["run"] = spec.run
        entry["times"] = spec.times
        entry["until_steady"] = spec.until_steady
    end

    return entry
end


"""
    load_spec(path) -> SeriesSpec or SingleSpec

Reads a spec.toml written by run_series / run_single and builds its start
state again from the recipe.
"""
function load_spec(path::AbstractString)
    entry = TOML.parsefile(path)
    start = state_from_recipe(entry["start"])
    wounds = Wound[wound_from_entry(w) for w in get(entry, "wounds", Any[])]
    settings = settings_kwargs(entry["settings"])
    redraw = get(entry, "redraw_profiles", nothing)
    common = (
        experiment = entry["experiment"],
        name = entry["name"],
        start = start,
        wounds = wounds,
        seed = entry["seed"],
        head_variable = entry["head_variable"],
        redraw_profiles = redraw,
        notes = get(entry, "notes", ""),
    )

    if entry["kind"] == "series"
        save = entry["save_fields"]
        save isa AbstractString && (save = Symbol(save))
        return SeriesSpec(; common..., settings..., runs = entry["runs"], save_fields = save)
    end

    return SingleSpec(
        ; common..., settings...,
        run = entry["run"],
        times = Float64.(entry["times"]),
        until_steady = entry["until_steady"],
    )
end


"""
    rerun(path; out = RESULTS_DIR)

Runs the spec.toml at `path` again (into a new folder).
"""
function rerun(path::AbstractString; out::AbstractString = RESULTS_DIR, kwargs...)
    spec = load_spec(path)
    spec isa SeriesSpec && return run_series(spec; out = out, kwargs...)
    return run_single(spec; out = out, kwargs...)
end


# ============================================================
# Output files
# ============================================================

function new_output_dir(out::AbstractString, experiment::AbstractString, name::AbstractString, time::DateTime)
    directory = joinpath(out, C.sanitized_save_name(experiment))
    stem = C.save_file_stem(time, name)
    path = joinpath(directory, stem)
    number = 2

    while ispath(path)
        path = joinpath(directory, stem * "_$number")
        number += 1
    end

    mkpath(path)
    return path
end


csv_number(value::Real) = isfinite(value) ? string(Float64(value)) : "NaN"
csv_number(value::Integer) = string(value)
csv_number(value::Bool) = value ? "true" : "false"
csv_list(values) = join(csv_number.(values), ";")

function csv_cell(value)
    value isa Real && return csv_number(value)
    text = String(string(value))
    any(character -> character in (',', '"', '\n', '\r'), text) || return text
    return "\"" * replace(text, "\"" => "\"\"") * "\""
end

function write_csv(path::AbstractString, header::Vector{String}, rows)
    open(path, "w") do io
        println(io, join(csv_cell.(header), ","))
        for row in rows
            println(io, join(csv_cell.(row), ","))
        end
    end
    return path
end


function write_fields(path::AbstractString, st::RDState, y::AbstractVector, profiles::AbstractDict)
    model = model_of(st)
    N = st.sim.N
    U = reshape(y, N, model.nvars)
    p = panel_fractions(st)
    pos = positions(st)
    s = body_coordinates(st)
    profile_names = sort(collect(keys(profiles)))
    header = vcat(["x", "position", "s", "piece"], model.varnames, profile_names)
    rows = (
        vcat(
            Any[p[i], pos[i], s[i], piece_label(st.smap, p[i])],
            Any[U[i, j] for j in 1:model.nvars],
            Any[profiles[name][i] for name in profile_names],
        )
        for i in 1:N
    )
    return write_csv(path, header, rows)
end


function jsonify(value)
    value === nothing && return nothing
    value isa Bool && return value
    value isa Real && return isfinite(value) ? value : nothing
    value isa Union{AbstractString, Symbol} && return String(value)
    value isa AbstractDict && return Pair{String, Any}[
        String(k) => jsonify(value[k]) for k in sort(collect(keys(value)); by = string)
    ]
    value isa NamedTuple && return Pair{String, Any}[String(k) => jsonify(v) for (k, v) in pairs(value)]
    value isa Union{AbstractVector, Tuple} && return Any[jsonify(v) for v in value]
    return string(value)
end

write_json(path::AbstractString, value) = write(path, C.json_text(jsonify(value)))


function tomlify(value)
    value isa Symbol && return String(value)
    value isa Unsigned && return Int(value)
    value isa AbstractDict && return Dict{String, Any}(
        String(k) => tomlify(v) for (k, v) in value if v !== nothing
    )
    value isa NamedTuple && return tomlify(Dict(pairs(value)))
    value isa Union{AbstractVector, Tuple} && return Any[tomlify(v) for v in value]
    value isa Real && !isfinite(value) && error("spec.toml cannot hold the value $value.")
    return value
end

function write_spec(path::AbstractString, spec)
    entry = tomlify(spec_entry(spec))
    open(path, "w") do io
        println(io, "# RD Lab spec: run it again with")
        println(io, "#     julia --project -e 'include(\"src/RDLabAPI.jl\"); using .RDLabAPI; rerun(\"$(replace(path, '\\' => '/'))\")'")
        println(io)
        TOML.print(io, entry; sorted = true)
    end
    return path
end


function git_info()
    commit = try
        strip(read(`git -C $REPO_DIR rev-parse HEAD`, String))
    catch
        "unknown"
    end
    dirty = try
        !isempty(strip(read(`git -C $REPO_DIR status --porcelain --untracked-files=no`, String)))
    catch
        nothing
    end
    branch = try
        strip(read(`git -C $REPO_DIR rev-parse --abbrev-ref HEAD`, String))
    catch
        "unknown"
    end
    return Dict{String, Any}("commit" => commit, "dirty" => dirty, "branch" => branch)
end


"""
    panel_parameters(state)

The parameters a panel actually uses: length, grid, diffusion scale, model
parameters, the diffusion coefficients after rescaling (D / length², the
coefficient on the unit panel) and the pieces with their piece-rule ρ0, ρ1.
"""
function panel_parameters(st::RDState)
    model = model_of(st)
    sim = st.sim
    len = panel_length(st)
    scale = diffusion_scale(st)
    params = Dict{String, Any}(String(name) => sim.params[name] for name in C.public_model_parameter_names(model))
    visible = String.(C.visible_model_parameter_names(model, sim.params))
    diffusion = Dict{String, Any}()

    for var in model.varnames
        name = Symbol("D", var)
        haskey(sim.params, name) || continue
        D = Float64(sim.params[name])
        diffusion[String(name)] = Dict{String, Any}(
            "D" => D,
            "D_over_length2" => D / len^2,
            "D_solver" => D / scale,
        )
    end

    pieces = Any[]
    for segment in st.smap
        entry = Dict{String, Any}(
            "label" => segment.label,
            "panel_fraction" => [segment.p0, segment.p1],
            "s" => [segment.s0, segment.s1],
            "length" => (segment.p1 - segment.p0) * len,
        )
        if segment.body !== nothing
            pc = piece(segment.body, min(segment.s0, segment.s1), max(segment.s0, segment.s1))
            entry["body"] = body_entry(segment.body)
            entry["piece_rule"] = piece_entry(pc)
            entry["head_side"] = segment.s1 < segment.s0 ? "right" : "left"
        end
        push!(pieces, entry)
    end

    rho = rho_values(st)
    profile_set = isempty(model.spatial_profile_sets) ? nothing :
        first(model.spatial_profile_sets[C._active_spatial_profile_set_index(sim.params, model.spatial_profile_sets)])

    return Dict{String, Any}(
        "model_key" => st.model_key,
        "model_id" => String(model.id),
        "model_name" => model.display_name,
        "variables" => model.varnames,
        "N" => sim.N,
        "boundary_condition" => String(sim.boundary_condition),
        "length" => len,
        "dx" => len / (sim.boundary_condition == :periodic ? sim.N : sim.N - 1),
        "diffusion_scale" => scale,
        "solver_x" => [first(sim.x), last(sim.x)],
        "parameters" => params,
        "parameters_in_use" => visible,
        "diffusion" => diffusion,
        "profile_set" => profile_set,
        "rho_source" => get(st.info, "rho_source", "none"),
        "rho" => isempty(rho) ? nothing : Dict{String, Any}(
            "left" => first(rho), "right" => last(rho), "min" => minimum(rho),
            "max" => maximum(rho), "mean" => mean(rho),
        ),
        "pieces" => pieces,
        "junctions" => junctions(st),
    )
end


function meta_entry(spec, st::RDState, settings, kind::String, started::DateTime)
    return Dict{String, Any}(
        "kind" => kind,
        "experiment" => spec.experiment,
        "name" => spec.name,
        "date" => Dates.format(started, "yyyy-mm-ddTHH:MM:SS"),
        "git" => git_info(),
        "julia_version" => string(VERSION),
        "threads" => Threads.nthreads(),
        "solver_threads" => solver_thread_entry(),
        "jacobian" => C.jacobian_setting(),
        "seed" => spec.seed,
        "model_id" => String(model_of(st).id),
        "model_key" => st.model_key,
        "panel" => panel_parameters(st),
        "start_info" => st.info,
        "settings" => merge(settings_entry(settings), Dict{String, Any}(
            "head_variable" => model_of(st).varnames[settings.head_variable],
        )),
        "head_detection" => Dict{String, Any}(
            "minimum_prominence_fraction" => C.HEAD_MINIMUM_PROMINENCE_FRACTION,
            "minimum_absolute_prominence" => C.HEAD_MINIMUM_ABSOLUTE_PROMINENCE,
            "minimum_distance_fraction" => C.HEAD_MINIMUM_DISTANCE_FRACTION,
            "configuration_tolerance" => C.HEAD_CONFIGURATION_TOLERANCE,
        ),
    )
end


# ============================================================
# Outcomes
# ============================================================

function head_fractions(heads, sim::C.SimulationState)
    x0 = first(sim.x)
    len = solver_length(sim)
    return [clamp((head.position - x0) / len, 0.0, 1.0) for head in heads]
end


function outcome_row(run::Integer, seed::Integer, outcome, st::RDState, wall::Float64)
    fractions = head_fractions(outcome.heads, st.sim)
    return Any[
        run,
        seed + run - 1,
        outcome.converged,
        outcome.time,
        outcome.steps,
        outcome.residual,
        length(outcome.heads),
        csv_list(fractions),
        csv_list([body_coordinate(st.smap, p) for p in fractions]),
        join([piece_label(st.smap, p) for p in fractions], ";"),
        csv_list([head.value for head in outcome.heads]),
        csv_list([head.prominence for head in outcome.heads]),
        wall,
    ]
end

const OUTCOME_HEADER = [
    "run", "seed", "converged", "final_time", "steps", "residual", "n_heads",
    "head_x", "head_s", "head_piece", "head_amplitude", "head_prominence", "wall_time_s",
]


function save_field_runs(save, runs::Int)
    save === :none && return Int[]
    save === :all && return collect(1:runs)
    save isa Integer && return collect(1:min(Int(save), runs))
    save isa AbstractVector && return sort!(unique(Int[run for run in save if 1 <= run <= runs]))
    error("save_fields must be :none, :all, a number of runs or a vector of run numbers.")
end


function series_summary(outcomes, st::RDState)
    converged = [o for o in outcomes if o.converged]
    counts = Dict{Int, Int}()
    groups = C.HeadConfigurationGroup[]
    periodic = st.sim.boundary_condition == :periodic

    for o in converged
        counts[length(o.heads)] = get(counts, length(o.heads), 0) + 1
        C.assign_head_configuration!(
            groups,
            C.normalized_head_positions(o.heads, st.sim.x, st.sim.boundary_condition),
            periodic,
        )
    end

    labels = C.head_configuration_labels(groups, periodic)
    order = C.head_configuration_order(groups)
    max_heads = isempty(counts) ? 0 : maximum(keys(counts))

    return Dict{String, Any}(
        "runs" => length(outcomes),
        "converged" => length(converged),
        "not_converged" => length(outcomes) - length(converged),
        "head_counts" => Dict{String, Any}(string(k) => get(counts, k, 0) for k in 0:max_heads),
        "configurations" => Any[
            Dict{String, Any}(
                "label" => labels[i],
                "heads" => length(groups[i].reference),
                "count" => groups[i].count,
                "reference_x" => groups[i].reference,
                "reference_s" => [body_coordinate(st.smap, p) for p in groups[i].reference],
            )
            for i in order
        ],
    )
end


# ============================================================
# run_series
# ============================================================

"""
    run_series(spec::SeriesSpec; out = RESULTS_DIR, threads = Threads.nthreads(),
               mkl_threads = solver_threads(), verbose = true) -> NamedTuple

Runs the series in parallel over realizations, `threads` at a time on Julia
threads, and writes out/<experiment>/<time>_<name>/ with spec.toml,
meta.json, outcomes.csv, summary.json and fields/ (initial.csv and the
selected runs). Every realization is the one the series window computes for
the same run number. `mkl_threads` sets the threads of the dense
factorization (default 1, see set_solver_threads!); `threads = 1,
mkl_threads = :default` computes exactly as the application. Returns
(dir, outcomes, summary, wall_time, profiles).
"""
function run_series(
    spec::SeriesSpec;
    out::AbstractString = RESULTS_DIR,
    threads::Integer = Threads.nthreads(),
    mkl_threads = solver_threads(),
    verbose::Bool = true,
)
    return with_solver_threads(mkl_threads) do
        run_series_inner(spec, out, clamp(Int(threads), 1, max(1, Threads.nthreads())), verbose)
    end
end

function run_series_inner(spec::SeriesSpec, out::AbstractString, threads::Int, verbose::Bool)
    started = Dates.now()
    st = spec.start
    model = model_of(st)
    spec.runs >= 1 || error("A series needs at least one run.")
    isempty(spec.wounds) && error("A series needs at least one wound (use steady_state or run_single without wounds).")
    settings = spec_settings(spec; runs = spec.runs)
    C.validate_series_settings(settings, model.nvars)

    C.ensure_partition_spatial_profile_overrides!([st.sim])
    templates = [C.make_series_template(st.sim)]
    perturbations, wound_rows = runtime_perturbations(spec.wounds, st, first(templates))
    check = C.instantiate_series_template(first(templates), settings)
    foreach(p -> C.validate_series_perturbation!(p, [check]), perturbations)
    redraw = spec.redraw_profiles === nothing ? get(st.info, "rho_source", "none") == "model" : spec.redraw_profiles

    dir = new_output_dir(out, spec.experiment, spec.name, started)
    write_spec(joinpath(dir, "spec.toml"), spec)
    meta = meta_entry(spec, st, settings, "series", started)
    meta["runs"] = spec.runs
    meta["wounds"] = wound_rows
    meta["redraw_profiles"] = redraw
    write_json(joinpath(dir, "meta.json"), meta)
    mkpath(joinpath(dir, "fields"))
    write_fields(joinpath(dir, "fields", "initial.csv"), st, copy(st.sim.integrator_ref[].u), profile_values(st.sim))

    field_runs = Set(save_field_runs(spec.save_fields, spec.runs))
    outcomes = Vector{Any}(undef, spec.runs)
    walls = zeros(spec.runs)
    profiles = Vector{Any}(undef, spec.runs)
    done = Threads.Atomic{Int}(0)
    print_lock = ReentrantLock()
    t0 = time()

    verbose && @printf("[%s] %s: %d runs, %d at a time → %s\n", spec.experiment, spec.name, spec.runs, threads, dir)

    function realization(run)
        run_started = time()
        captured = Ref{Any}(nothing)
        panel_outcomes = C.run_series_realization!(
            templates,
            perturbations,
            settings,
            0,
            run;
            redraw_profiles = redraw,
            on_profiles = values -> (captured[] = values),
        )
        outcome = only(panel_outcomes)
        outcomes[run] = outcome
        walls[run] = time() - run_started
        profiles[run] = captured[] === nothing ? profile_values(st.sim) : only(captured[])

        if run in field_runs
            write_fields(
                joinpath(dir, "fields", @sprintf("run_%03d.csv", run)),
                st,
                outcome.final_snapshot.y,
                profiles[run],
            )
        end

        count = Threads.atomic_add!(done, 1) + 1
        if verbose
            lock(print_lock) do
                @printf(
                    "  run %3d  %s  heads %d  t = %.3g  steps %d  %.1f s   (%d/%d)\n",
                    run,
                    outcome.converged ? "stationary" : "NOT stationary",
                    length(outcome.heads),
                    outcome.time,
                    outcome.steps,
                    walls[run],
                    count,
                    spec.runs,
                )
                flush(stdout)
            end
        end
        return nothing
    end

    # A pool of `threads` workers, each taking the next run number.
    next_run = Threads.Atomic{Int}(1)
    workers = [
        Threads.@spawn begin
            while true
                run = Threads.atomic_add!(next_run, 1)
                run > spec.runs && break
                realization(run)
            end
        end
        for _ in 1:min(threads, spec.runs)
    ]
    foreach(wait, workers)

    wall = time() - t0
    write_csv(
        joinpath(dir, "outcomes.csv"),
        OUTCOME_HEADER,
        (outcome_row(run, spec.seed, outcomes[run], st, walls[run]) for run in 1:spec.runs),
    )
    summary = series_summary(outcomes, st)
    summary["wall_time_s"] = wall
    summary["mean_run_time_s"] = mean(walls)
    write_json(joinpath(dir, "summary.json"), summary)

    if verbose
        @printf("[%s] %s done in %.1f s: %d/%d stationary; heads %s\n", spec.experiment, spec.name, wall,
            summary["converged"], spec.runs,
            join(["$k: $v" for (k, v) in sort(collect(summary["head_counts"]); by = first)], ", "))
        for c in summary["configurations"]
            @printf("    %-24s %4d\n", c["label"], c["count"])
        end
    end

    return (dir = dir, outcomes = outcomes, summary = summary, wall_time = wall, profiles = profiles)
end


# ============================================================
# run_single
# ============================================================

"""
    run_single(spec::SingleSpec; times = spec.times, out = RESULTS_DIR) -> NamedTuple

One realization with the profiles of all variables and ρ written at the
requested `times` (solver time since the wounds; 0 is right after them) to
profiles.csv and fields/t_XXX.csv; with `until_steady`, run on to a
stationary state (outcomes.csv, fields/final.csv). The solver stops exactly
at each requested time, so its steps differ from those of a series run.
"""
function run_single(
    spec::SingleSpec;
    times = spec.times,
    out::AbstractString = RESULTS_DIR,
    mkl_threads = solver_threads(),
    verbose::Bool = true,
)
    return with_solver_threads(() -> run_single_inner(spec, times, out, verbose), mkl_threads)
end

function run_single_inner(spec::SingleSpec, times, out::AbstractString, verbose::Bool)
    started = Dates.now()
    st = spec.start
    model = model_of(st)
    settings = spec_settings(spec)
    C.validate_series_settings(settings, model.nvars)
    record_times = sort!(unique(Float64.(collect(times))))
    all(t -> isfinite(t) && t >= 0, record_times) || error("Times must be finite and non-negative.")

    C.ensure_partition_spatial_profile_overrides!([st.sim])
    template = C.make_series_template(st.sim)
    perturbations, wound_rows = runtime_perturbations(spec.wounds, st, template)
    redraw = spec.redraw_profiles === nothing ? get(st.info, "rho_source", "none") == "model" : spec.redraw_profiles

    # The realization `run` of a series, step by step.
    run_rng = Xoshiro(settings.seed + UInt64(spec.run - 1))
    sim = C.instantiate_series_template(template, settings)
    if redraw
        profile_rng = Xoshiro(settings.seed + UInt64(spec.run - 1) + C.SERIES_PROFILE_SEED_OFFSET)
        C.randomize_partition_spatial_profiles!([sim], profile_rng)
    end
    if isempty(perturbations)
        C.restart_after_manual_change!(sim, copy(sim.integrator_ref[].u); reltol = settings.reltol, abstol = settings.abstol)
        sim.step_counter[] = 0
    else
        C.apply_series_perturbations!([sim], perturbations, run_rng, settings)
    end

    dir = new_output_dir(out, spec.experiment, spec.name, started)
    write_spec(joinpath(dir, "spec.toml"), spec)
    meta = meta_entry(spec, st, settings, "single", started)
    meta["run"] = spec.run
    meta["times"] = record_times
    meta["wounds"] = wound_rows
    meta["redraw_profiles"] = redraw
    write_json(joinpath(dir, "meta.json"), meta)
    mkpath(joinpath(dir, "fields"))
    write_fields(joinpath(dir, "fields", "initial.csv"), st, copy(st.sim.integrator_ref[].u), profile_values(st.sim))

    run_state = RDState(sim, st.model_key, st.smap, st.recipe, st.info)
    profiles = profile_values(sim)
    integrator = sim.integrator_ref[]
    foreach(t -> t > integrator.t && C.add_tstop!(integrator, t), record_times)
    snapshots = Tuple{Float64, Vector{Float64}}[]
    t0 = time()

    for t in record_times
        while integrator.t < t
            sim.step_counter[] >= settings.maximum_steps_per_panel && error("Step limit reached before t = $t.")
            C.step_series_panel!(sim)
        end
        push!(snapshots, (integrator.t, copy(integrator.u)))
        verbose && @printf("  t = %.6g recorded (%d steps)\n", integrator.t, sim.step_counter[])
    end

    var_names = model.varnames
    profile_names = sort(collect(keys(profiles)))
    p = panel_fractions(run_state)
    pos = positions(run_state)
    s = body_coordinates(run_state)
    write_csv(
        joinpath(dir, "profiles.csv"),
        vcat(["time", "x", "position", "s"], var_names, profile_names),
        (
            vcat(Any[t, p[i], pos[i], s[i]],
                 Any[reshape(y, sim.N, model.nvars)[i, j] for j in 1:model.nvars],
                 Any[profiles[name][i] for name in profile_names])
            for (t, y) in snapshots for i in 1:sim.N
        ),
    )
    for (index, (t, y)) in enumerate(snapshots)
        write_fields(joinpath(dir, "fields", @sprintf("t_%03d.csv", index)), run_state, y, profiles)
    end

    outcome = nothing
    if spec.until_steady
        outcome = C.run_series_panel!(sim, settings, 0)
        write_fields(joinpath(dir, "fields", "final.csv"), run_state, outcome.final_snapshot.y, profiles)
        write_csv(
            joinpath(dir, "outcomes.csv"),
            OUTCOME_HEADER,
            [outcome_row(spec.run, spec.seed, outcome, run_state, time() - t0)],
        )
        verbose && @printf("  %s at t = %.6g, %d heads\n", outcome.converged ? "stationary" : "NOT stationary",
            outcome.time, length(outcome.heads))
    end

    return (dir = dir, snapshots = snapshots, outcome = outcome, state = run_state, wall_time = time() - t0)
end


end
