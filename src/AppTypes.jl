# src/AppTypes.jl

# ============================================================
# Types of the interactive application
# ============================================================
#
# These types hold Makie axes and Observables, so they belong to the GUI
# module ReactionDiffusionApp, not to the headless core (Types.jl).


# ============================================================
# Worker runtime of one domain segment
# ============================================================

mutable struct SegmentRuntime
    running::Threads.Atomic{Bool}
    task_ref::Base.RefValue{Union{Nothing, Task}}
    lock::ReentrantLock
    latest_snapshot::Base.RefValue{Union{Nothing, SimulationSnapshot}}
    snapshot_lock::ReentrantLock
end


function empty_segment_runtime()
    return SegmentRuntime(
        Threads.Atomic{Bool}(false),
        Ref{Union{Nothing, Task}}(nothing),
        ReentrantLock(),
        Ref{Union{Nothing, SimulationSnapshot}}(nothing),
        ReentrantLock(),
    )
end


# ============================================================
# Plot panel
# ============================================================

mutable struct PlotPanel
    axes::Vector{Axis}
    ui_items::Vector{Any}
    # Makie controls in the plot layout (the spatial profile selector).
    domain_length_scale::Float64
    perturbation_controls::Vector{Any}

    segment_axes::Vector{Vector{Axis}}
    segment_x_observables::Vector{Observable{Vector{Float64}}}
    segment_observables::Vector{Vector{Observable{Vector{Float64}}}}
    segment_preview_observables::Vector{Vector{Observable{Vector{Float64}}}}
    segment_profile_axes::Vector{Vector{Axis}}
    segment_profile_observables::Vector{Vector{Observable{Vector{Float64}}}}
    split_marker_observables::Vector{Observable{Vector{Float64}}}
    split_marker_color_observables::Vector{Observable{Symbol}}
    split_marker_alpha_observables::Vector{Observable{Float64}}
    split_marker_fade_tokens::Vector{Base.RefValue{Int}}
    segment_status_observables::Vector{Observable{String}}
    refresh_spatial_profiles::Function
    # Redraws the spatial profile plots for the active profile set.
end

# ============================================================
# Application state
# ============================================================

mutable struct AppState
    sim::SimulationState
    # Current simulation state.

    simulations::Vector{SimulationState}
    # Ordered independent domain segments. app.sim always points to the
    # first segment for shared model and parameter metadata.

    initial_N::Int
    # Number of grid points in the original, unsplit domain.

    initial_boundary_condition::Symbol
    # Boundary condition restored by Reset on the unsplit domain.

    plot_panel::PlotPanel
    # Current collection of plots displaying the solution.

    running::Observable{Bool}
    # Whether the simulation is currently running from the UI perspective.
    # This observable should be updated only from the UI thread.

    dtmax_obs::Observable{Float64}
    # Observable storing the current maximum allowed time step.

    dt_obs::Observable{Float64}
    # Observable storing the currently proposed/internal solver time step.

    time_obs::Observable{Float64}
    # Observable storing the displayed physical simulation time.

    step_counter_obs::Observable{Int}
    # Observable storing the number of solver steps shown in the UI.

    worker_running::Threads.Atomic{Bool}
    # Thread-safe flag used by the simulation worker.

    worker_task_ref::Base.RefValue{Union{Nothing, Task}}
    # Reference to the threaded simulation worker task.

    generation::Threads.Atomic{Int}
    # Incremented whenever the model is switched.
    # Old snapshots with older generations are ignored.

    simlock::ReentrantLock
    # Lock protecting the live solver state.

    segment_runtimes::Vector{SegmentRuntime}
    # One independently scheduled worker runtime per domain segment.

    synchronization_running::Threads.Atomic{Bool}
    synchronization_task_ref::Base.RefValue{Union{Nothing, Task}}
    synchronization_status::Observable{String}

    mouse_perturbations_enabled::Threads.Atomic{Bool}
    # Cleared while a series runs, so the plots then react neither to mouse
    # perturbation input nor to the buttons of the profile sets.

    parameter_overrides::Dict{Symbol, Float64}
    # Parameter values set by the user for the current model, kept by Reset
    # and boundary-condition changes and cleared by a model change. They are
    # the model's own values: the domain length never changes a parameter,
    # it only rescales diffusion inside the right-hand side.

    spatial_profile_set_revision::Observable{Int}
    # Incremented when the Previous / Next buttons under the profile plots
    # change the active profile set, so the interface can show the set's
    # parameters and formula.
end
