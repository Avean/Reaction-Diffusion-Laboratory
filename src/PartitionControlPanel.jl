# src/PartitionControlPanel.jl

# ============================================================
# Domain split / merge controls
# ============================================================

const PARTITION_WORKER_SETTLE_TIME = 0.05


function stop_and_settle_partition_workers!(app::AppState)
    stop_worker!(app; wait = true)

    # Give the UI/render tasks one short scheduling window after every solver
    # task has finished before replacing simulations and plot observables.
    yield()
    sleep(PARTITION_WORKER_SETTLE_TIME)

    return nothing
end


function update_split_marker!(
    app::AppState,
    segment::Int,
    left_count::Int,
)
    for index in eachindex(app.plot_panel.split_marker_observables)
        app.plot_panel.split_marker_fade_tokens[index][] += 1
        app.plot_panel.split_marker_observables[index][] = [NaN]
        app.plot_panel.split_marker_color_observables[index][] = :red
        app.plot_panel.split_marker_alpha_observables[index][] = 0.0
    end

    1 <= segment <= length(app.simulations) || return nothing
    sim = app.simulations[segment]
    2 <= left_count <= sim.N - 2 || return nothing

    displayed_length =
        segment_base_length(app, segment) *
        app.plot_panel.domain_length_scale
    split_position = displayed_length * left_count / sim.N
    marker = app.plot_panel.split_marker_observables[segment]
    alpha = app.plot_panel.split_marker_alpha_observables[segment]
    token_ref = app.plot_panel.split_marker_fade_tokens[segment]
    marker[] = [split_position]
    alpha[] = 1.0
    token = token_ref[]

    @async begin
        sleep(5.0)
        fade_duration = 0.5
        fade_started_at = time_ns()

        while true
            token_ref[] == token || return nothing
            elapsed = (time_ns() - fade_started_at) / 1e9
            elapsed >= fade_duration && break
            alpha[] = max(0.0, 1.0 - elapsed / fade_duration)
            sleep(1 / 60)
        end

        token_ref[] == token || return nothing
        marker[] = [NaN]
        alpha[] = 0.0
        return nothing
    end

    return nothing
end


function rebuild_plot_panel_for_partition!(
    app::AppState,
    plot_grid::GridLayout;
    title_obs,
    domain_length_scale::Float64,
)
    clear_plot_panel!(app.plot_panel)
    reset_plot_grid_layout!(plot_grid)

    app.plot_panel = build_plot_panel!(
        plot_grid,
        app;
        title_obs = title_obs,
    )

    set_plot_domain_scale!(
        app.plot_panel,
        app,
        domain_length_scale^2,
    )

    refresh_app_from_live_state!(app)

    return nothing
end


function split_domain_segment_app!(
    app::AppState,
    plot_grid::GridLayout,
    segment::Int,
    left_count::Int;
    title_obs,
)
    lock(app.simlock)

    try
        1 <= segment <= length(app.simulations) || return false
        2 <= left_count <= app.simulations[segment].N - 2 || return false

        # Increment before the first yielding operation. Every callback from
        # the panel being replaced can then recognize that it is stale.
        app.generation[] += 1
        stop_and_settle_partition_workers!(app)
        domain_length_scale = app.plot_panel.domain_length_scale
        split_domain_segment!(app, segment, left_count)

        rebuild_plot_panel_for_partition!(
            app,
            plot_grid;
            title_obs = title_obs,
            domain_length_scale = domain_length_scale,
        )
    finally
        unlock(app.simlock)
    end

    return true
end


function merge_domain_segments_app!(
    app::AppState,
    plot_grid::GridLayout,
    left_segment::Int;
    title_obs,
)
    lock(app.simlock)

    try
        1 <= left_segment < length(app.simulations) || return false

        # Invalidate the current control panel before waiting for workers.
        # This prevents a queued second click on the old Merge button from
        # starting another merge with obsolete segment indices.
        app.generation[] += 1
        stop_and_settle_partition_workers!(app)
        domain_length_scale = app.plot_panel.domain_length_scale

        synchronize_segment_indices_blocking!(
            app,
            [left_segment, left_segment + 1];
            allow_cancel = false,
        )

        merge_domain_segments!(app, left_segment)

        rebuild_plot_panel_for_partition!(
            app,
            plot_grid;
            title_obs = title_obs,
            domain_length_scale = domain_length_scale,
        )
    finally
        unlock(app.simlock)
    end

    return true
end


function finalize_partition_topology_change!(
    app::AppState,
    plot_grid::GridLayout;
    title_obs,
    domain_length_scale::Float64,
)
    rebuild_plot_panel_for_partition!(
        app,
        plot_grid;
        title_obs = title_obs,
        domain_length_scale = domain_length_scale,
    )

    snapshot = make_partition_snapshot(app.simulations, app.generation[])
    store_runtime_snapshots!(app, snapshot.segments)
    refresh_app_from_snapshot!(app, snapshot)

    return nothing
end


function swap_adjacent_domain_segments_app!(
    app::AppState,
    plot_grid::GridLayout,
    left_segment::Int;
    title_obs,
    steps_per_frame::Int = 5,
    worker_sleep_time::Float64 = 0.001,
)
    1 <= left_segment < length(app.simulations) || return false
    was_running = app.worker_running[] ||
        any(runtime.running[] for runtime in app.segment_runtimes)

    lock(app.simlock)

    try
        app.generation[] += 1
        stop_and_settle_partition_workers!(app)
        domain_length_scale = app.plot_panel.domain_length_scale
        swap_adjacent_domain_segments!(app, left_segment)
        finalize_partition_topology_change!(
            app,
            plot_grid;
            title_obs = title_obs,
            domain_length_scale = domain_length_scale,
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

    return true
end


function delete_domain_segment_app!(
    app::AppState,
    plot_grid::GridLayout,
    segment::Int;
    title_obs,
    steps_per_frame::Int = 5,
    worker_sleep_time::Float64 = 0.001,
)
    length(app.simulations) > 1 || return false
    1 <= segment <= length(app.simulations) || return false
    was_running = app.worker_running[] ||
        any(runtime.running[] for runtime in app.segment_runtimes)

    lock(app.simlock)

    try
        app.generation[] += 1
        stop_and_settle_partition_workers!(app)
        domain_length_scale = app.plot_panel.domain_length_scale
        delete_domain_segment!(app, segment)
        finalize_partition_topology_change!(
            app,
            plot_grid;
            title_obs = title_obs,
            domain_length_scale = domain_length_scale,
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

    return true
end
