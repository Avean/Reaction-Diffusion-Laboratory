# src/GraphExport.jl

# ============================================================
# Save graph: the current plots as PNG and PDF, their data as CSV and a
# Jupyter notebook that draws them again
# ============================================================
#
# Every save creates its own folder saved_graphs/<date>_<time>. The plots are
# drawn again with CairoMakie from the data shown in the window, so they do
# not depend on the window size. In series mode the series results of every
# panel are saved as well. The notebook (notebooks/graphs.ipynb) is copied
# next to the data and reads it with pandas.

const SAVED_GRAPHS_DIR = normpath(joinpath(@__DIR__, "..", "saved_graphs"))
const GRAPHS_NOTEBOOK_TEMPLATE = normpath(joinpath(@__DIR__, "..", "notebooks", "graphs.ipynb"))
const GRAPH_PNG_PIXELS_PER_UNIT = 2
const HEAD_CONFIGURATION_PALETTE = ["#64748b", "#2563eb", "#7c3aed", "#db2777", "#ea580c", "#16a34a", "#0891b2"]


# ------------------------------------------------------------
# Data shown in the window
# ------------------------------------------------------------

function active_spatial_profile_names(app::RD.AppState)
    profile_sets = app.sim.model.spatial_profile_sets
    isempty(profile_sets) && return String[]
    set_index = RD._active_spatial_profile_set_index(app.sim.params, profile_sets)
    _, profiles = profile_sets[set_index]
    return [String(first(profile)) for profile in profiles]
end


function simulation_graph_data(controller::QMLController)
    app = controller.app
    panel = app.plot_panel
    model = app.sim.model
    profile_names = active_spatial_profile_names(app)

    panels = [
        (
            x = copy(panel.segment_x_observables[segment][]),
            length = series_display_length(app, segment),
            status = panel.segment_status_observables[segment][],
            values = [copy(panel.segment_observables[segment][variable][]) for variable in 1:model.nvars],
            profiles = [copy(panel.segment_profile_observables[segment][k][]) for k in eachindex(profile_names)],
        )
        for segment in eachindex(app.simulations)
    ]

    return (variables = String.(model.varnames), profile_names = profile_names, panels = panels)
end


function series_graph_data(controller::QMLController)
    series = controller.series
    app = controller.app
    panel = app.plot_panel
    model = app.sim.model
    head_variable = model.varnames[clamp(series.settings.head_variable, 1, model.nvars)]

    lock(series.lock)

    try
        panels = [
            begin
                count_map = series.head_count_counts[segment]
                maximum_heads = isempty(count_map) ? 0 : maximum(keys(count_map))
                groups = series.configuration_groups[segment]
                periodic = segment <= length(series.templates) &&
                           series.templates[segment].boundary_condition == :periodic
                order = RD.head_configuration_order(groups)

                (
                    x = segment <= length(panel.segment_x_observables) ?
                        copy(panel.segment_x_observables[segment][]) :
                        Float64[],
                    length = segment <= length(app.simulations) ?
                        series_display_length(app, segment) :
                        1.0,
                    location_counts = copy(series.location_counts[segment]),
                    head_counts = [get(count_map, count, 0) for count in 0:maximum_heads],
                    not_converged = series.not_converged_counts[segment],
                    config_labels = RD.head_configuration_labels(groups, periodic)[order],
                    config_counts = [groups[index].count for index in order],
                    config_positions = [copy(groups[index].reference) for index in order],
                    patterns = deepcopy(series.patterns[segment]),
                    converged = copy(series.pattern_converged[segment]),
                )
            end
            for segment in eachindex(series.location_counts)
        ]
        return (panels = panels, head_variable = head_variable, completed_runs = series.completed_runs)
    finally
        unlock(series.lock)
    end
end


# ------------------------------------------------------------
# CSV and JSON files
# ------------------------------------------------------------

csv_number(value::Real) = isfinite(value) ? string(Float64(value)) : "NaN"


function csv_text(value::AbstractString)
    any(character -> character in (',', '"', '\n', '\r'), value) || return String(value)
    return "\"" * replace(value, "\"" => "\"\"") * "\""
end


function write_csv(path::AbstractString, header::Vector{String}, rows)
    open(path, "w") do io
        println(io, join(csv_text.(header), ","))
        for row in rows
            println(io, join(row, ","))
        end
    end
    return nothing
end


function write_simulation_csv!(folder::AbstractString, data)
    write_csv(
        joinpath(folder, "solution.csv"),
        ["panel"; "x"; data.variables],
        (
            [string(segment); csv_number(panel.x[index]); [csv_number(values[index]) for values in panel.values]]
            for (segment, panel) in enumerate(data.panels) for index in eachindex(panel.x)
        ),
    )

    isempty(data.profile_names) && return nothing

    write_csv(
        joinpath(folder, "spatial_profiles.csv"),
        ["panel"; "x"; data.profile_names],
        (
            [string(segment); csv_number(panel.x[index]); [csv_number(values[index]) for values in panel.profiles]]
            for (segment, panel) in enumerate(data.panels) for index in eachindex(panel.x)
        ),
    )

    return nothing
end


function write_series_csv!(folder::AbstractString, panels)
    write_csv(
        joinpath(folder, "series_head_locations.csv"),
        ["panel", "x", "count"],
        (
            [string(segment), csv_number(panel.x[index]), string(panel.location_counts[index])]
            for (segment, panel) in enumerate(panels)
            for index in 1:min(length(panel.x), length(panel.location_counts))
        ),
    )
    write_csv(
        joinpath(folder, "series_head_counts.csv"),
        ["panel", "heads", "count"],
        (
            [string(segment), string(heads - 1), string(count)]
            for (segment, panel) in enumerate(panels)
            for (heads, count) in enumerate(panel.head_counts)
        ),
    )
    # Positions are the normalised head positions (0 to 1) of the group's
    # reference configuration, separated by spaces.
    write_csv(
        joinpath(folder, "series_configurations.csv"),
        ["panel", "label", "heads", "count", "positions"],
        (
            [
                string(segment),
                csv_text(panel.config_labels[index]),
                string(length(panel.config_positions[index])),
                string(panel.config_counts[index]),
                join(csv_number.(panel.config_positions[index]), " "),
            ]
            for (segment, panel) in enumerate(panels)
            for index in eachindex(panel.config_labels)
        ),
    )
    write_csv(
        joinpath(folder, "series_patterns.csv"),
        ["panel", "run", "converged", "x", "value"],
        (
            [string(segment), string(run), string(panel.converged[run]), csv_number(panel.x[index]), csv_number(profile[index])]
            for (segment, panel) in enumerate(panels)
            for (run, profile) in enumerate(panel.patterns)
            for index in 1:min(length(panel.x), length(profile))
        ),
    )

    return nothing
end


function graph_metadata_json(controller::QMLController, time::DateTime, data, series_data)
    app = controller.app

    panel_entries = String[]
    for (segment, panel) in enumerate(data.panels)
        fields = [
            "\"panel\":" * string(segment),
            "\"length\":" * json_number(panel.length),
            "\"status\":" * json_string(panel.status),
        ]
        if series_data !== nothing && segment <= length(series_data.panels)
            push!(fields, "\"not_converged\":" * string(series_data.panels[segment].not_converged))
        end
        push!(panel_entries, "{" * join(fields, ",") * "}")
    end

    fields = [
        "\"model\":" * json_string(active_model_menu_name(controller.bindings.active_model_key[])),
        "\"saved\":" * json_string(Dates.format(time, "yyyy-mm-dd HH:MM:SS")),
        "\"mode\":" * json_string(series_data === nothing ? "simulation" : "series"),
        "\"boundary\":" * json_string(RD.boundary_condition_label(app.initial_boundary_condition)),
        "\"time\":" * json_number(app.time_obs[]),
        "\"steps\":" * string(app.step_counter_obs[]),
        "\"variables\":" * json_string_array(data.variables),
        "\"spatial_profiles\":" * json_string_array(data.profile_names),
        "\"panels\":[" * join(panel_entries, ",") * "]",
    ]

    if series_data !== nothing
        push!(fields, "\"head_variable\":" * json_string(series_data.head_variable))
        push!(fields, "\"completed_runs\":" * string(series_data.completed_runs))
    end

    return "{\n  " * join(fields, ",\n  ") * "\n}\n"
end


# ------------------------------------------------------------
# Figures
# ------------------------------------------------------------

function simulation_graph_figure(data, title::AbstractString)
    rows = length(data.variables) + length(data.profile_names)
    panel_count = length(data.panels)
    total_length = sum(panel.length for panel in data.panels)

    figure = Figure(size = (max(800, 450 * panel_count), 70 + 230 * rows), backgroundcolor = :white)
    Label(figure[1, 1], title; fontsize = 18, font = :bold, tellwidth = false)
    grid = figure[2, 1] = GridLayout()
    row_axes = [Axis[] for _ in 1:rows]
    row_values = [Float64[] for _ in 1:rows]

    for (segment, panel) in enumerate(data.panels)
        status = replace(panel.status, '\n' => "   ")
        curves = [
            [(name, values, (linewidth = 2,)) for (name, values) in zip(data.variables, panel.values)];
            [
                (name, values, (linewidth = 3, color = :red, linestyle = :dash))
                for (name, values) in zip(data.profile_names, panel.profiles)
            ]
        ]

        for (row, (name, values, style)) in enumerate(curves)
            axis = Axis(
                grid[row, segment];
                title = row > 1 ? name : panel_count > 1 ? "Panel $segment   $status" : status,
                titlesize = row == 1 ? 12 : 15,
                xlabel = row == rows ? "x" : "",
                ylabel = segment == 1 ? name : "",
                xticks = RD.automatic_x_ticks_with_right_endpoint,
                yticks = RD.automatic_safe_y_ticks,
            )
            any(isfinite, values) && lines!(axis, panel.x, values; style...)
            xlims!(axis, 0.0, panel.length)
            push!(row_axes[row], axis)
            append!(row_values[row], RD.finite_values(values))
        end

        colsize!(grid, segment, Auto(false, total_length > 0 ? panel.length / total_length : 1.0))
    end

    # As in the window, the panels of one row share their y range.
    for row in 1:rows
        RD.set_axes_y_limits_from_values!(row_axes[row], row_values[row])
    end

    return figure
end


function nan_separated_curves(x::Vector{Float64}, profiles)
    xs = Float64[]
    ys = Float64[]

    for profile in profiles
        count = min(length(x), length(profile))
        append!(xs, view(x, 1:count))
        append!(ys, view(profile, 1:count))
        push!(xs, NaN)
        push!(ys, NaN)
    end

    return xs, ys
end


function series_graph_figure(panels, title::AbstractString, head_variable::AbstractString)
    panel_count = length(panels)
    figure = Figure(size = (max(800, 560 * panel_count), 1350), backgroundcolor = :white)
    Label(figure[1, 1], title; fontsize = 18, font = :bold, tellwidth = false)
    grid = figure[2, 1] = GridLayout()

    for (segment, panel) in enumerate(panels)
        prefix = panel_count > 1 ? "Panel $segment: " : ""

        # Head locations: one bar per grid node.
        axis = Axis(grid[1, segment]; title = prefix * "Head locations", xlabel = "x", ylabel = segment == 1 ? "heads" : "")
        count = min(length(panel.x), length(panel.location_counts))
        if count > 0
            bar_width = count > 1 ? panel.x[2] - panel.x[1] : panel.length
            barplot!(axis, panel.x[1:count], panel.location_counts[1:count]; width = bar_width, gap = 0, color = "#2563eb")
        end
        xlims!(axis, 0.0, panel.length)
        ylims!(axis, 0.0, 1.08 * max(1, maximum(panel.location_counts; init = 0)))

        # Number of heads, with the not converged runs last.
        labels = [string.(0:length(panel.head_counts) - 1); "Not converged"]
        values = [panel.head_counts; panel.not_converged]
        axis = Axis(
            grid[2, segment];
            title = prefix * "Number of heads",
            ylabel = segment == 1 ? "runs" : "",
            xticks = (1:length(labels), labels),
        )
        barplot!(axis, 1:length(values), values; color = [fill("#7c3aed", length(values) - 1); "#dc2626"])
        ylims!(axis, 0.0, 1.08 * max(1, maximum(values)))

        # Head configurations, coloured by the number of heads.
        labels = [panel.config_labels; "Not converged"]
        values = [panel.config_counts; panel.not_converged]
        colors = [
            [
                HEAD_CONFIGURATION_PALETTE[min(length(positions), length(HEAD_CONFIGURATION_PALETTE) - 1) + 1]
                for positions in panel.config_positions
            ];
            "#dc2626"
        ]
        axis = Axis(
            grid[3, segment];
            title = prefix * "Head configurations",
            xlabel = "runs",
            yticks = (1:length(labels), labels),
            yreversed = true,
        )
        barplot!(axis, 1:length(values), values; direction = :x, color = colors)
        xlims!(axis, 0.0, 1.12 * max(1, maximum(values)))

        # Final profiles: converged runs in blue, not converged ones in red.
        axis = Axis(grid[4, segment]; title = prefix * "Patterns ($head_variable)", xlabel = "x")
        for (converged, color) in ((true, ("#2563eb", 0.28)), (false, ("#dc2626", 0.55)))
            selected = [profile for (profile, ok) in zip(panel.patterns, panel.converged) if ok == converged]
            isempty(selected) && continue
            xs, ys = nan_separated_curves(panel.x, selected)
            lines!(axis, xs, ys; color = color, linewidth = 1)
        end
        xlims!(axis, 0.0, panel.length)
    end

    rowsize!(grid, 3, Auto(false, 1.4))
    return figure
end


function save_graph_figure(folder::AbstractString, name::AbstractString, figure)
    save(joinpath(folder, name * ".png"), figure; backend = CairoMakie, px_per_unit = GRAPH_PNG_PIXELS_PER_UNIT)
    save(joinpath(folder, name * ".pdf"), figure; backend = CairoMakie)
    return nothing
end


# ------------------------------------------------------------
# Save graph
# ------------------------------------------------------------

function new_graph_folder(time::DateTime)
    base = joinpath(SAVED_GRAPHS_DIR, Dates.format(time, "yyyy-mm-dd_HH-MM-SS"))
    folder = base
    suffix = 1

    # Two saves within one second get separate folders.
    while ispath(folder)
        suffix += 1
        folder = base * "_" * string(suffix)
    end

    mkpath(folder)
    return folder
end


function save_graphs!(controller::QMLController)
    return guarded_action(controller, "Saving the graphs failed") do
        time = Dates.now()
        data = simulation_graph_data(controller)
        series_data = controller.bindings.series_mode[] ? series_graph_data(controller) : nothing
        model_name = active_model_menu_name(controller.bindings.active_model_key[])
        boundary = RD.boundary_condition_label(controller.app.initial_boundary_condition)

        folder = new_graph_folder(time)
        write(joinpath(folder, "parameters.txt"), parameter_history_entry(controller, time))
        write(joinpath(folder, "metadata.json"), graph_metadata_json(controller, time, data, series_data))
        write_simulation_csv!(folder, data)
        save_graph_figure(folder, "simulation", simulation_graph_figure(data, "$model_name   ($boundary)"))

        if series_data !== nothing
            write_series_csv!(folder, series_data.panels)
            save_graph_figure(
                folder,
                "series",
                series_graph_figure(
                    series_data.panels,
                    "$model_name   series, $(series_data.completed_runs) runs",
                    series_data.head_variable,
                ),
            )
        end

        cp(GRAPHS_NOTEBOOK_TEMPLATE, joinpath(folder, "graphs.ipynb"))
        controller.bindings.notice[] = "Graphs saved to saved_graphs/$(basename(folder))"
    end
end
