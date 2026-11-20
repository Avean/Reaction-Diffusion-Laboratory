# src/DoubletApp.jl

# ============================================================
# Source tools of the application window
# ============================================================
#
# The AppState-level Freeze SD, half operations, Cut and the installation of
# a Cut and run result. The operations on simulation states they build on
# (apply_half_operation, cut_simulation_state, cut_and_run) are in the core
# file Doublet.jl. They work on a single panel.


function require_single_panel(app::AppState)
    length(app.simulations) == 1 ||
        error("Merge the panels first: this works on a single panel.")
    return nothing
end


function any_worker_running(app::AppState)
    return app.worker_running[] ||
           any(runtime.running[] for runtime in app.segment_runtimes)
end


# Replaces every panel by `sim` and rebuilds the plots for the domain length
# `domain_length_scale`, with the workers stopped as for Split or Delete.
# Restarts the live run if it was running and `restart` is set.
function install_single_panel_app!(
    app::AppState,
    plot_grid::GridLayout,
    sim::SimulationState;
    title_obs,
    domain_length_scale::Float64,
    restart::Bool = true,
    steps_per_frame::Int = 5,
    worker_sleep_time::Float64 = 0.001,
)
    was_running = any_worker_running(app)

    lock(app.simlock)

    try
        app.generation[] += 1
        stop_and_settle_partition_workers!(app)
        app.sim = sim
        app.simulations = SimulationState[sim]
        app.segment_runtimes = SegmentRuntime[empty_segment_runtime()]
        finalize_partition_topology_change!(
            app,
            plot_grid;
            title_obs = title_obs,
            domain_length_scale = domain_length_scale,
        )
    finally
        unlock(app.simlock)
    end

    if was_running && restart
        start_worker!(
            app;
            steps_per_frame = steps_per_frame,
            sleep_time = worker_sleep_time,
        )
    end

    return nothing
end


# Rebuilds the plots of the current panels, e.g. after Freeze SD, which draws
# the frozen variables like fixed profiles.
function rebuild_plots_app!(
    app::AppState,
    plot_grid::GridLayout;
    title_obs,
    steps_per_frame::Int = 5,
    worker_sleep_time::Float64 = 0.001,
)
    was_running = any_worker_running(app)

    lock(app.simlock)

    try
        app.generation[] += 1
        stop_and_settle_partition_workers!(app)
        finalize_partition_topology_change!(
            app,
            plot_grid;
            title_obs = title_obs,
            domain_length_scale = app.plot_panel.domain_length_scale,
        )
    finally
        unlock(app.simlock)
    end

    if was_running
        start_worker!(
            app;
            steps_per_frame = steps_per_frame,
            sleep_time = worker_sleep_time,
        )
    end

    return nothing
end


"""
    set_variables_frozen_app!(app, plot_grid, frozen; title_obs, ...)

Freeze SD: sets the parameter `frozen` of a model with freezable variables
and redraws the plots, where frozen variables appear red and dashed.
"""
function set_variables_frozen_app!(
    app::AppState,
    plot_grid::GridLayout,
    frozen::Bool;
    title_obs,
    steps_per_frame::Int = 5,
    worker_sleep_time::Float64 = 0.001,
)
    isempty(app.sim.model.freezable_variables) &&
        error("The model $(app.sim.model.display_name) has no variable to freeze.")

    set_model_parameter_app!(
        app,
        FROZEN_PARAM,
        frozen ? 1.0 : 0.0;
        steps_per_frame = steps_per_frame,
        worker_sleep_time = worker_sleep_time,
    )
    rebuild_plots_app!(
        app,
        plot_grid;
        title_obs = title_obs,
        steps_per_frame = steps_per_frame,
        worker_sleep_time = worker_sleep_time,
    )

    return nothing
end


"""
    apply_half_operation_app!(app, operation; ...)

Rearranges the halves of the single panel (see apply_half_operation): all
variables move together and the solver restarts from the new state.
"""
function apply_half_operation_app!(
    app::AppState,
    operation::Symbol;
    steps_per_frame::Int = 5,
    worker_sleep_time::Float64 = 0.001,
)
    require_single_panel(app)
    operation in HALF_OPERATIONS || error("Unknown half operation :$operation.")

    with_worker_paused!(
        app,
        () -> begin
            sim = app.sim
            U = apply_half_operation(solution_matrix(sim), operation)
            restart_after_manual_change!(sim, vec(U))
            refresh_app_from_live_state!(app)
        end;
        restart_if_was_running = true,
        steps_per_frame = steps_per_frame,
        worker_sleep_time = worker_sleep_time,
    )

    return nothing
end


"""
    cut_center_app!(app, plot_grid, cut_length; ...) -> (length, points)

Cut: keeps the centred piece of the single panel closest to the physical
length `cut_length`; the domain becomes [0, length]. Returns the length and
the number of grid points of the piece.
"""
function cut_center_app!(
    app::AppState,
    plot_grid::GridLayout,
    cut_length::Real;
    title_obs,
    steps_per_frame::Int = 5,
    worker_sleep_time::Float64 = 0.001,
    reltol::Float64 = 1e-5,
    abstol::Float64 = 1e-7,
)
    require_single_panel(app)
    # Validates the length before anything stops.
    range, _ = cut_plan(app.sim, cut_length)

    was_running = any_worker_running(app)
    piece = nothing
    actual_length = 0.0

    lock(app.simlock)

    try
        app.generation[] += 1
        stop_and_settle_partition_workers!(app)
        piece, actual_length = cut_simulation_state(
            app.sim,
            cut_length;
            reltol = reltol,
            abstol = abstol,
        )
        app.sim = piece
        app.simulations = SimulationState[piece]
        app.segment_runtimes = SegmentRuntime[empty_segment_runtime()]
        finalize_partition_topology_change!(
            app,
            plot_grid;
            title_obs = title_obs,
            domain_length_scale = actual_length,
        )
    finally
        unlock(app.simlock)
    end

    if was_running
        start_worker!(
            app;
            steps_per_frame = steps_per_frame,
            sleep_time = worker_sleep_time,
        )
    end

    return (length = actual_length, points = length(range))
end
