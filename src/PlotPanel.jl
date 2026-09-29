# src/PlotPanel.jl

# ============================================================
# Plot panel
# ============================================================
#
# Left application area.
#
# Contains:
#
#     - one plot for every model variable,
#     - gray dashed preview curves for local perturbations,
#     - optional spatial profile plots with a Previous/Next selector for
#       the active profile set.
#
# ============================================================


# ============================================================
# Empty panel
# ============================================================

function empty_plot_panel()
    return PlotPanel(
        Axis[],
        Any[],
        1.0,
        Any[],
        Vector{Axis}[],
        Observable{Vector{Float64}}[],
        Vector{Observable{Vector{Float64}}}[],
        Vector{Observable{Vector{Float64}}}[],
        Vector{Axis}[],
        Vector{Observable{Vector{Float64}}}[],
        Observable{Vector{Float64}}[],
        Observable{Symbol}[],
        Observable{Float64}[],
        Base.RefValue{Int}[],
        Observable{String}[],
        () -> nothing,
    )
end


function compact_segment_status(sim::SimulationState)
    return @sprintf(
        "t=%.2e  steps=%d\ndt=%.1e",
        current_display_time(sim),
        sim.step_counter[],
        current_internal_dt(sim),
    )
end


function compact_segment_status(snapshot::SimulationSnapshot)
    return @sprintf(
        "t=%.2e  steps=%d\ndt=%.1e",
        snapshot.t,
        snapshot.steps,
        snapshot.dt,
    )
end


function set_plot_domain_scale!(
    panel::PlotPanel,
    app::AppState,
    diffusion_scale::Real,
)
    scale = Float64(diffusion_scale)

    isfinite(scale) && scale > 0 ||
        error("Domain scale must be positive and finite.")

    domain_length_scale = sqrt(scale)
    panel.domain_length_scale = domain_length_scale

    for segment in eachindex(app.simulations)
        displayed_x = segment_display_coordinates(
            app,
            segment,
            domain_length_scale,
        )
        panel.segment_x_observables[segment][] = displayed_x
        xmax = segment_base_length(app, segment) * domain_length_scale

        for axis in panel.segment_axes[segment]
            xlims!(axis, 0.0, xmax)
        end

        for axis in panel.segment_profile_axes[segment]
            xlims!(axis, 0.0, xmax)
        end
    end

    clear_perturbation_previews!(panel)

    return nothing
end


# ============================================================
# Axis scaling
# ============================================================

function fallback_finite_ticks(left::Float64, right::Float64)
    isfinite(left) && isfinite(right) || return Float64[]
    left == right && return [left]

    low, high = minmax(left, right)
    span = high - low
    ticks = unique([
        low + span * fraction
        for fraction in range(0.0, 1.0; length = 5)
        if isfinite(low + span * fraction)
    ])

    if length(ticks) < 2
        ticks = [low, high]
    end

    return ticks
end


function non_strict_wilkinson_ticks(
    vmin::Real,
    vmax::Real;
    k_ideal::Int = 5,
    k_min::Int = 3,
)
    left = Float64(vmin)
    right = Float64(vmax)
    isfinite(left) && isfinite(right) || return Float64[]
    left == right && return [left]

    low, high = minmax(left, right)
    locator = WilkinsonTicks(k_ideal; k_min = k_min)
    ticks = try
        values, _, _ = GLMakie.Makie.PlotUtils.optimize_ticks(
            low,
            high;
            extend_ticks = false,
            strict_span = false,
            span_buffer = nothing,
            k_min = k_min,
            k_max = locator.k_max,
            k_ideal = k_ideal,
            Q = locator.Q,
            granularity_weight = locator.granularity_weight,
            simplicity_weight = locator.simplicity_weight,
            coverage_weight = locator.coverage_weight,
            niceness_weight = locator.niceness_weight,
        )
        Float64.(collect(values))
    catch
        Float64[]
    end

    filter!(isfinite, ticks)
    filter!(tick -> low <= tick <= high, ticks)
    sort!(ticks)
    unique!(ticks)

    if length(ticks) < 2 || any(diff(ticks) .<= 0.0)
        return fallback_finite_ticks(low, high)
    end

    return ticks
end


function automatic_safe_y_ticks(ymin::Real, ymax::Real)
    return non_strict_wilkinson_ticks(ymin, ymax)
end


function automatic_x_ticks_with_right_endpoint(
    xmin::Real,
    xmax::Real,
)
    left = Float64(xmin)
    right = Float64(xmax)
    ticks = non_strict_wilkinson_ticks(left, right)

    tolerance = max(abs(left), abs(right), 1.0) * 1e-9
    filter!(tick -> left - tolerance <= tick <= right + tolerance, ticks)

    endpoint_index = findfirst(
        tick -> isapprox(tick, right; atol = tolerance, rtol = 0.0),
        ticks,
    )

    if endpoint_index === nothing
        push!(ticks, right)
        sort!(ticks)
    else
        ticks[endpoint_index] = right
    end

    # The forced endpoint can land very close to the last automatically chosen
    # tick. In that case keep the endpoint label and remove its neighbour so the
    # two labels do not overlap, especially in narrow partition columns.
    endpoint_index = findfirst(==(right), ticks)
    if endpoint_index !== nothing && endpoint_index >= 3
        previous_tick_index = endpoint_index - 1
        previous_spacing = ticks[previous_tick_index] - ticks[previous_tick_index - 1]
        endpoint_spacing = right - ticks[previous_tick_index]

        if previous_spacing > tolerance &&
           endpoint_spacing > tolerance &&
           endpoint_spacing < 0.3 * previous_spacing
            deleteat!(ticks, previous_tick_index)
        end
    end

    precision_index = findfirst(
        digits -> all(
            tick -> isapprox(
                tick,
                round(tick; digits = digits);
                atol = tolerance,
                rtol = 0.0,
            ),
            ticks,
        ),
        0:2,
    )
    decimal_places = precision_index === nothing ? 2 : precision_index - 1
    tick_format = Printf.Format("%.$(decimal_places)f")
    labels = [Printf.format(tick_format, tick) for tick in ticks]

    return ticks, labels
end


function finite_values(v::AbstractVector)
    return collect(filter(isfinite, v))
end


function set_axis_y_limits_from_values!(
    ax::Axis,
    values::AbstractVector,
)
    finite = finite_values(values)

    isempty(finite) &&
        return nothing

    ymin, ymax = extrema(finite)
    ymin = 0.0
    ymean = mean(finite)

    # Minimal allowed y-range.
    # This prevents degenerate or almost-degenerate axis limits.
    min_range = 1e-3

    yrange = ymax - ymin

    if yrange < min_range
        center = 0.5 * (ymin + ymax)
        ymin = center - 0.5 * min_range
        ymax = center + 0.5 * min_range
    else
        pad = 0.05 * yrange
        ymin -= pad
        ymax += pad
    end

    ylims!(ax, ymin, max(ymax, 2*ymean))

    return nothing
end


# ============================================================
# Spatial profile plots
# ============================================================

function build_spatial_profile_panel!(
    grid::GridLayout,
    app::AppState,
    segment_x_observables::Vector{Observable{Vector{Float64}}},
    split_marker_observables::Vector{Observable{Vector{Float64}}},
    split_marker_alpha_observables::Vector{Observable{Float64}},
    all_axes::Vector{Axis};
    start_row::Int,
)
    profile_sets = app.sim.model.spatial_profile_sets
    nsegments = length(app.simulations)

    if isempty(profile_sets)
        return (
            axes = [Axis[] for _ in 1:nsegments],
            observables = [Observable{Vector{Float64}}[] for _ in 1:nsegments],
            items = Any[],
            refresh = () -> nothing,
        )
    end

    max_profiles = maximum(length(profile_set) for (_, profile_set) in profile_sets)
    profile_axes = [Axis[] for _ in 1:nsegments]
    profile_observables = [Observable{Vector{Float64}}[] for _ in 1:nsegments]
    profile_name_observables = [Observable("") for _ in 1:max_profiles]

    for k in 1:max_profiles
        row = start_row + k - 1

        for segment in 1:nsegments
            sim = app.simulations[segment]
            ax = Axis(
                grid[row, segment],
                xlabel = k == max_profiles ? "x" : "",
                ylabel = segment == 1 ? profile_name_observables[k] : "",
                title = profile_name_observables[k],
                xticks = automatic_x_ticks_with_right_endpoint,
                yticks = automatic_safe_y_ticks,
            )
            deactivate_interaction!(ax, :scrollzoom)

            y_obs = Observable(fill(NaN, sim.N))
            lines!(
                ax,
                segment_x_observables[segment],
                y_obs;
                linewidth = 4,
                color = :red,
                linestyle = :dash,
            )
            vlines!(
                ax,
                split_marker_observables[segment];
                color = lift(
                    alpha -> (:red, alpha),
                    split_marker_alpha_observables[segment],
                ),
                linewidth = 2,
            )

            push!(profile_axes[segment], ax)
            push!(profile_observables[segment], y_obs)
            push!(all_axes, ax)
        end

        rowsize!(grid, row, Fixed(120))
    end

    # Previous / set name / Next under the profile plots, styled like the
    # light tiles of the QML interface (qml/Theme.qml).
    nav_row = start_row + max_profiles
    nav_grid = GridLayout(tellwidth = false, tellheight = true)
    grid[nav_row, 1:nsegments] = nav_grid
    tile_style = (
        buttoncolor = "#e7ebf0",
        buttoncolor_hover = "#dde3ea",
        buttoncolor_active = "#dbeafe",
        strokecolor = "#c3cad4",
        strokewidth = 1,
        cornerradius = 4,
        labelcolor = "#20252d",
        font = :bold,
        height = 28,
        tellwidth = false,
    )
    previous_button = Button(nav_grid[1, 1]; label = "Previous", tile_style...)
    set_label_obs = Observable("")
    set_label = Label(nav_grid[1, 2], set_label_obs; font = :bold, tellwidth = false)
    next_button = Button(nav_grid[1, 3]; label = "Next", tile_style...)
    colsize!(nav_grid, 1, Fixed(90))
    colsize!(nav_grid, 2, Fixed(200))
    colsize!(nav_grid, 3, Fixed(90))
    colgap!(nav_grid, 8)
    rowsize!(grid, nav_row, Fixed(36))
    items = Any[previous_button, set_label, next_button, nav_grid]

    function refresh_profile_set!()
        current_profile_sets = app.sim.model.spatial_profile_sets
        isempty(current_profile_sets) && return nothing

        set_index = _active_spatial_profile_set_index(app.sim.params, current_profile_sets)
        set_name, profiles = current_profile_sets[set_index]
        set_label_obs[] = "Spatial profile: $(set_name)"
        # A layout rebuild after Split, Swap, Delete, Merge, or Restore must
        # display the profile arrays carried by the segments, not regenerate
        # them on the possibly shortened/reordered global domain.
        ensure_partition_spatial_profile_overrides!(app.simulations)

        for k in 1:max_profiles
            row = start_row + k - 1

            if k <= length(profiles)
                profile_name, _ = profiles[k]
                profile_name_observables[k][] = profile_name
                override_key = spatial_profile_override_key(profile_name)
                row_values = Float64[]

                for segment in 1:nsegments
                    y = copy(app.simulations[segment].params[override_key])
                    profile_observables[segment][k][] = y
                    append!(row_values, finite_values(y))
                end

                set_axes_y_limits_from_values!(
                    [profile_axes[segment][k] for segment in 1:nsegments],
                    row_values,
                )

                rowsize!(grid, row, Fixed(120))
            else
                profile_name_observables[k][] = ""

                for segment in 1:nsegments
                    N = app.simulations[segment].N
                    profile_observables[segment][k][] = fill(NaN, N)
                end

                rowsize!(grid, row, Fixed(0))
            end
        end

        return nothing
    end

    function step_profile_set!(step::Int)
        nsets = length(app.sim.model.spatial_profile_sets)
        nsets == 0 && return nothing
        current = _active_spatial_profile_set_index(app.sim.params, app.sim.model.spatial_profile_sets)
        set_active_spatial_profile_set_app!(app, mod1(current + step, nsets))
        return nothing
    end

    on(_ -> step_profile_set!(-1), previous_button.clicks)
    on(_ -> step_profile_set!(1), next_button.clicks)

    refresh_profile_set!()

    return (
        axes = profile_axes,
        observables = profile_observables,
        items = items,
        refresh = refresh_profile_set!,
    )
end


function rescale_solution_axes!(
    panel::PlotPanel,
    simulations::Vector{SimulationState},
    ;
    include_previews::Bool = true,
)
    length(panel.segment_axes) == length(simulations) ||
        error("Plot panel does not match the number of domain segments.")

    isempty(simulations) && return nothing

    for variable in 1:first(simulations).model.nvars
        rescale_solution_variable_axes!(
            panel,
            variable;
            include_previews = include_previews,
        )
    end

    return nothing
end


function set_axes_y_limits_from_values!(
    axes::AbstractVector{<:Axis},
    values::AbstractVector,
)
    for axis in axes
        set_axis_y_limits_from_values!(axis, values)
    end

    return nothing
end


function rescale_solution_variable_axes!(
    panel::PlotPanel,
    variable::Int,
    ;
    include_previews::Bool = true,
)
    nsegments = length(panel.segment_axes)
    nsegments > 0 || return nothing

    row_values = Float64[]
    row_axes = Axis[]

    for segment in 1:nsegments
        variable <= length(panel.segment_axes[segment]) ||
            error("Plot panel does not contain variable $(variable) in every segment.")

        append!(
            row_values,
            finite_values(panel.segment_observables[segment][variable][]),
        )
        if include_previews
            append!(
                row_values,
                finite_values(panel.segment_preview_observables[segment][variable][]),
            )
        end
        push!(row_axes, panel.segment_axes[segment][variable])
    end

    set_axes_y_limits_from_values!(row_axes, row_values)

    return nothing
end


function build_plot_panel!(
    grid::GridLayout,
    app::AppState;
    title_obs = nothing,
)
    model = app.sim.model
    nsegments = length(app.simulations)
    total_length = sum(
        segment_base_length(app, segment)
        for segment in eachindex(app.simulations)
    )

    all_axes = Axis[]
    segment_axes = [Axis[] for _ in 1:nsegments]
    segment_x_observables = Observable{Vector{Float64}}[]
    segment_observables = [Observable{Vector{Float64}}[] for _ in 1:nsegments]
    segment_preview_observables = [Observable{Vector{Float64}}[] for _ in 1:nsegments]
    split_marker_observables = [Observable([NaN]) for _ in 1:nsegments]
    split_marker_color_observables = [Observable(:red) for _ in 1:nsegments]
    split_marker_alpha_observables = [Observable(0.0) for _ in 1:nsegments]
    split_marker_fade_tokens = [Ref(0) for _ in 1:nsegments]
    segment_status_observables = [
        Observable(compact_segment_status(app.simulations[segment]))
        for segment in 1:nsegments
    ]

    rowgap!(grid, 0)

    for segment in 1:nsegments
        sim = app.simulations[segment]
        U = solution_matrix(sim)
        x_observable = Observable(segment_display_coordinates(app, segment, 1.0))
        push!(segment_x_observables, x_observable)

        for variable in 1:model.nvars
            axis_title = if variable == 1
                segment_status_observables[segment]
            else
                model.varnames[variable]
            end

            ax = Axis(
                grid[variable, segment],
                xlabel = variable == model.nvars ? "x" : "",
                ylabel = segment == 1 ? model.varnames[variable] : "",
                title = axis_title,
                titlesize = variable == 1 ? 10 : 16,
                xticks = automatic_x_ticks_with_right_endpoint,
                yticks = automatic_safe_y_ticks,
            )
            deactivate_interaction!(ax, :scrollzoom)

            y_obs = Observable(copy(U[:, variable]))
            preview_obs = Observable(fill(NaN, sim.N))

            lines!(ax, x_observable, y_obs; linewidth = 2)
            lines!(
                ax,
                x_observable,
                preview_obs;
                color = (:gray, 0.45),
                linewidth = 2,
                linestyle = :dash,
            )
            vlines!(
                ax,
                split_marker_observables[segment];
                color = lift(
                    (color, alpha) -> (color, alpha),
                    split_marker_color_observables[segment],
                    split_marker_alpha_observables[segment],
                ),
                linewidth = 2,
            )
            push!(segment_axes[segment], ax)
            push!(segment_observables[segment], y_obs)
            push!(segment_preview_observables[segment], preview_obs)
            push!(all_axes, ax)
            rowsize!(grid, variable, Auto(false, 1.0))
        end

        column_weight = total_length > 0 ?
            segment_base_length(app, segment) / total_length :
            1.0 / nsegments
        colsize!(grid, segment, Relative(column_weight))
    end

    perturbation_state = create_perturbation_state!(app, segment_axes)

    profile_panel = build_spatial_profile_panel!(
        grid,
        app,
        segment_x_observables,
        split_marker_observables,
        split_marker_alpha_observables,
        all_axes;
        start_row = model.nvars + 1,
    )

    panel = PlotPanel(
        all_axes,
        profile_panel.items,
        1.0,
        Any[perturbation_state],
        segment_axes,
        segment_x_observables,
        segment_observables,
        segment_preview_observables,
        profile_panel.axes,
        profile_panel.observables,
        split_marker_observables,
        split_marker_color_observables,
        split_marker_alpha_observables,
        split_marker_fade_tokens,
        segment_status_observables,
        profile_panel.refresh,
    )

    set_plot_domain_scale!(panel, app, 1.0)
    rescale_solution_axes!(panel, app.simulations)

    return panel
end


# ============================================================
# Refresh
# ============================================================

function solution_matrix_from_snapshot(snapshot::SimulationSnapshot)
    return reshape(snapshot.y, snapshot.N, snapshot.nvars)
end


# ============================================================
# Perturbation previews
# ============================================================

function clear_perturbation_preview!(
    panel::PlotPanel,
    segment::Int,
    variable::Int,
)
    if segment >= 1 && segment <= length(panel.segment_preview_observables) &&
       variable >= 1 && variable <= length(panel.segment_preview_observables[segment])
        preview = panel.segment_preview_observables[segment][variable]
        N = length(preview[])
        preview[] = fill(NaN, N)

        if !isempty(panel.perturbation_controls)
            state = first(panel.perturbation_controls)

            if state.active_segment != segment ||
               state.active_variable != variable
                return nothing
            end

            state.active_variable = 0
            state.active_segment = 0
            state.center = NaN
            state.mouse_height = NaN
            state.increment = zeros(Float64, N)
            state.has_valid_preview = false
        end
    end

    return nothing
end


function clear_perturbation_previews!(panel::PlotPanel)
    for segment_previews in panel.segment_preview_observables
        for preview_obs in segment_previews
            N = length(preview_obs[])
            preview_obs[] = fill(NaN, N)
        end
    end

    if !isempty(panel.perturbation_controls)
        state = first(panel.perturbation_controls)
        N = isempty(panel.segment_preview_observables) ?
            0 :
            length(first(first(panel.segment_preview_observables))[])

        state.active_variable = 0
        state.active_segment = 0
        state.center = NaN
        state.mouse_height = NaN
        state.increment = zeros(Float64, N)
        state.has_valid_preview = false
    end

    return nothing
end


# ============================================================
# Clearing / rebuilding
# ============================================================

function delete_plot_panel_item!(item)
    if item isa GridLayout
        try
            grid_content = Makie.gridcontent(item)
            grid_content === nothing ||
                Makie.GridLayoutBase.remove_from_gridlayout!(grid_content)
        catch
        end

        return nothing
    end

    try
        delete!(item)
    catch
        try
            item.visible = false
        catch
        end
    end

    return nothing
end


function reset_plot_grid_layout!(grid::GridLayout)
    # Blocks such as Axis remove themselves from their GridLayout when they
    # are deleted. Nested GridLayouts do not implement delete!, however, and
    # older panel versions could therefore leave empty layout content behind.
    # Detach everything that remains before trimming so old row/column sizes
    # cannot influence the next model or partition layout.
    for grid_content in copy(grid.content)
        try
            Makie.GridLayoutBase.remove_from_gridlayout!(grid_content)
        catch
        end
    end

    trim!(grid)
    return nothing
end


function clear_plot_panel!(panel::PlotPanel)
    for ax in panel.axes
        delete_plot_panel_item!(ax)
    end

    for item in panel.ui_items
        delete_plot_panel_item!(item)
    end

    empty!(panel.axes)
    empty!(panel.ui_items)
    panel.domain_length_scale = 1.0
    empty!(panel.perturbation_controls)
    empty!(panel.segment_axes)
    empty!(panel.segment_x_observables)
    empty!(panel.segment_observables)
    empty!(panel.segment_preview_observables)
    empty!(panel.segment_profile_axes)
    empty!(panel.segment_profile_observables)
    empty!(panel.split_marker_observables)
    empty!(panel.split_marker_color_observables)
    empty!(panel.split_marker_alpha_observables)
    empty!(panel.split_marker_fade_tokens)
    empty!(panel.segment_status_observables)
    panel.refresh_spatial_profiles = () -> nothing

    return nothing
end


function refresh_plot_panel_from_snapshots!(
    panel::PlotPanel,
    snapshots::Vector{SimulationSnapshot},
)
    length(panel.segment_observables) == length(snapshots) ||
        error("Plot panel does not match the number of snapshot segments.")

    for segment in eachindex(snapshots)
        snapshot = snapshots[segment]
        U = solution_matrix_from_snapshot(snapshot)
        panel.segment_status_observables[segment][] =
            compact_segment_status(snapshot)

        for variable in 1:snapshot.nvars
            panel.segment_observables[segment][variable][] =
                copy(U[:, variable])
        end
    end

    if !isempty(snapshots)
        for variable in 1:first(snapshots).nvars
            rescale_solution_variable_axes!(panel, variable)
        end
    end

    return nothing
end


function refresh_plot_panel!(
    panel::PlotPanel,
    simulations::Vector{SimulationState},
)
    length(panel.segment_observables) == length(simulations) ||
        error("Plot panel does not match the number of domain segments.")

    for segment in eachindex(simulations)
        sim = simulations[segment]
        U = solution_matrix(sim)
        panel.segment_status_observables[segment][] = compact_segment_status(sim)

        for variable in 1:sim.model.nvars
            panel.segment_observables[segment][variable][] =
                copy(U[:, variable])
        end
    end

    rescale_solution_axes!(panel, simulations)

    return nothing
end
