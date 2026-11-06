# src/Types.jl
#
# Core types: models, simulation states, snapshots and saved states. They do
# not depend on any GUI package; the types of the application window
# (PlotPanel, AppState, SegmentRuntime) live in AppTypes.jl.

# ============================================================
# Model specification
# ============================================================

Base.@kwdef struct ModelSpec
    id::Symbol
    # Short internal model identifier, for example :fisher_kpp or :schnakenberg.
    # Unique among the models and permanent: the save files of a model are
    # stored under it, so changing it orphans them.

    display_name::String
    # Human-readable model name displayed in the user interface.

    description::String = ""
    # Optional short description displayed above the equations in the model drawer.

    nvars::Int
    # Number of dependent variables/equations in the model.

    varnames::Vector{String}
    # Names of dependent variables, for example ["u"] or ["u", "v"].

    default_params::Dict{Symbol, Float64}
    # Default numerical parameters of the model, for example diffusion constants.

    initialize!::Function
    # Function initializing the solution matrix U at t = 0.
    #
    # Signature:
    #
    #     initialize!(U, x, p)
    #
    # where U has size N × nvars.

    rhs!::Function
    # Right-hand side of the semi-discrete ODE system.
    #
    # Signature:
    #
    #     rhs!(dU, U, Lap, x, p, t)
    #
    # where U and dU have size N × nvars.

    default_boundary_condition::Union{Nothing, Symbol} = nothing
    # Optional boundary condition selected automatically when the model is
    # chosen. A value of `nothing` preserves the currently selected condition.

    spatial_profile_sets::Vector{Tuple{String, Vector{Tuple{String, Function}}}} =
    Tuple{String, Vector{Tuple{String, Function}}}[]
    # Optional spatial profiles that can be displayed in the UI.

    spatial_profile_formulas::Vector{Any} = Any[]
    # Optional LaTeX formula of every profile set, in the order of
    # spatial_profile_sets: a String, a PiecewiseFormula or nothing.

    spatial_profile_notes::Vector{String} = String[]
    # Optional short note shown under the formula of every profile set.

    spatial_profile_hidden_parameters::Vector{Vector{Symbol}} = Vector{Symbol}[]
    # For every profile set, the parameters that only other profile sets
    # use; they are hidden from the parameter fields while it is active.

    latex_equations::Vector{String} = String[]
    # Optional LaTeX strings describing the equations, for display in the UI.
end


function validate_model(model::ModelSpec)
    model.nvars >= 1 ||
        error("Model must have at least one variable.")

    length(model.varnames) == model.nvars ||
        error("Length of varnames must be equal to nvars.")

    length(unique(model.varnames)) == length(model.varnames) ||
        error("Variable names must be unique.")

    if !isnothing(model.default_boundary_condition)
        validate_boundary_condition(model.default_boundary_condition)
    end

    return true
end


# ============================================================
# Simulation state
# ============================================================

mutable struct SimulationState
    model::ModelSpec
    # Currently selected mathematical model.

    N::Int
    # Number of spatial grid points.

    x::Vector{Float64}
    # Spatial grid points.

    dx::Float64
    # Spatial mesh size.

    Lap::SparseMatrixCSC{Float64, Int}
    # Sparse matrix representing the 1D Laplacian.

    boundary_condition::Symbol
    # Boundary condition used by the current simulation.
    # Supported values are currently:
    #
    #     :neumann
    #     :periodic

    params::Dict{Symbol, Any}
    # Current parameter values used by the model.

    prob::ODEProblem
    # DifferentialEquations.jl ODE problem built from the selected model.

    integrator_ref::Ref{Any}
    # Reference to the current time integrator.
    # A Ref is used because we sometimes replace the integrator after restarting.

    time_offset::Base.RefValue{Float64}
    # Accumulated physical time after internal solver time resets.
    # This avoids loss of floating-point precision for very large times.

    step_counter::Base.RefValue{Int}
    # Number of accepted solver steps since the last full restart.
end


# ============================================================
# Snapshot passed from worker thread to UI
# ============================================================

mutable struct SimulationSnapshot
    y::Vector{Float64}
    # Copy of the current solver state.
    # This is safe to read from the UI thread because it is independent
    # of the live integrator.

    N::Int
    # Number of spatial grid points used when the snapshot was created.

    nvars::Int
    # Number of variables in the model used when the snapshot was created.

    model_id::Symbol
    # Identifier of the model used when the snapshot was created.

    generation::Int
    # Application generation number.
    # This prevents old snapshots from a previous model from being drawn
    # after switching models.

    t::Float64
    # Displayed physical simulation time.

    dt::Float64
    # Current internal/proposed solver time step.

    dtmax::Float64
    # Current maximum allowed solver time step.

    steps::Int
    # Number of accepted solver steps since the last full restart.
end


mutable struct PartitionSnapshot
    segments::Vector{SimulationSnapshot}
    generation::Int
    t::Float64
    dt::Float64
    dtmax::Float64
    steps::Int
end


# ============================================================
# Complete state of the panels, as written to and read from a save file
# ============================================================

struct SavedSegmentState
    model_id::Symbol
    x::Vector{Float64}
    dx::Float64
    y::Vector{Float64}
    params::Dict{Symbol, Any}
    boundary_condition::Symbol
    t::Float64
    dt::Float64
    dtmax::Float64
    steps::Int
end


struct SavedSimulationState
    model_id::Symbol
    segments::Vector{SavedSegmentState}
    domain_length_scale::Float64
    requested_dtmax::Float64
    initial_N::Int
    initial_boundary_condition::Symbol
    parameter_overrides::Dict{Symbol, Float64}
end
