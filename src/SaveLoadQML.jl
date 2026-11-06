# src/SaveLoadQML.jl

# ============================================================
# Save, Load and Save series: the window actions
# ============================================================
#
# The QMLController side of the saves: the Load window, Save, Load and Save
# series. File names, the JSON writer and the conversion between simulation
# states and save documents are in the core file SaveLoad.jl.

const SAVE_PREVIEW_MAX_POINTS = 500


# ------------------------------------------------------------
# Load window
# ------------------------------------------------------------

function last_saved_time(panels)
    return maximum(save_number(save_field(panel, "t", "A panel"), "Panel t") for panel in panels)
end


function simulation_saves_listing(model; root::AbstractString = SAVES_DIR)
    # The saves of this model, newest first; what cannot be read is reported
    # by name and skipped.
    directory = simulation_saves_dir(model.id; root = root)
    summaries = NamedTuple[]
    skipped = String[]

    for file in (isdir(directory) ? readdir(directory) : String[])
        endswith(file, ".json") || continue

        try
            document = read_save_document(joinpath(directory, file))
            save_field(document, "kind", "The file") == "simulation" || error("It is not a simulation save.")
            save_field(document, "model_id", "The file") == String(model.id) || error("It belongs to another model.")
            panels = save_field(document, "panels", "The file")
            panels isa AbstractVector && !isempty(panels) || error("It has no panels.")
            push!(
                summaries,
                (
                    file = file,
                    name = String(get(document, "name", "")),
                    saved_at = String(save_field(document, "saved_at", "The file")),
                    time = display_number(last_saved_time(panels)),
                    panels = length(panels),
                ),
            )
        catch error
            @warn "Skipping a save that cannot be read." file exception = error
            push!(skipped, file)
        end
    end

    sort!(summaries; by = summary -> (summary.saved_at, summary.file), rev = true)
    saves = Any[
        json_object(
            "file" => summary.file,
            "name" => summary.name,
            "savedAt" => replace(summary.saved_at, 'T' => ' '),
            "time" => summary.time,
            "panels" => summary.panels,
        )
        for summary in summaries
    ]

    return json_object("saves" => saves, "skipped" => sort(skipped))
end


function save_preview_charts(saved::RD.SavedSimulationState, model)
    # One chart per variable: the panels side by side in axis units.
    charts = Any[]
    scale = saved.domain_length_scale

    for (variable, variable_name) in enumerate(model.varnames)
        panels = Any[]
        offset = 0.0

        for segment in saved.segments
            N = length(segment.x)
            U = reshape(segment.y, N, length(model.varnames))
            indices = N <= SAVE_PREVIEW_MAX_POINTS ?
                collect(1:N) :
                unique(round.(Int, range(1, N; length = SAVE_PREVIEW_MAX_POINTS)))
            push!(
                panels,
                json_object(
                    "x" => (segment.x[indices] .- first(segment.x)) .* scale .+ offset,
                    "y" => U[indices, variable],
                ),
            )
            offset += (last(segment.x) - first(segment.x) + segment.dx) * scale
        end

        push!(charts, json_object("variable" => variable_name, "panels" => panels))
    end

    return charts
end


function simulation_save_details(model, file::AbstractString; root::AbstractString = SAVES_DIR)
    # What the Load window shows for one save. "error" says why it cannot be
    # loaded; the window then keeps the Load button disabled.
    try
        document = read_save_document(simulation_save_path(model.id, file; root = root))
        saved, warnings = parse_simulation_save(document, model)
        params = first(saved.segments).params
        parameters = Any[
            json_object("key" => String(name), "value" => display_number(params[name]))
            for name in RD.visible_model_parameter_names(model, params)
        ]
        panel_lengths = [
            (last(segment.x) - first(segment.x) + (segment.boundary_condition == :periodic ? segment.dx : 0.0)) *
            saved.domain_length_scale
            for segment in saved.segments
        ]
        profile_set = get(document, "active_profile_set", nothing)

        return json_object(
            "file" => file,
            "name" => String(get(document, "name", "")),
            "savedAt" => replace(String(save_field(document, "saved_at", "The file")), 'T' => ' '),
            "time" => display_number(maximum(segment.t for segment in saved.segments)),
            "panels" => length(saved.segments),
            "gridPoints" => join(string.(length.(getfield.(saved.segments, :x))), " | "),
            "boundary" => RD.boundary_condition_label(saved.initial_boundary_condition),
            "domainLength" => display_number(sum(panel_lengths)),
            "domainScale" => display_number(saved.domain_length_scale),
            "profileSet" => profile_set === nothing ? "" : String(save_field(profile_set, "name", "active_profile_set")),
            "parameters" => parameters,
            "charts" => save_preview_charts(saved, model),
            "warnings" => warnings,
            "error" => "",
        )
    catch error
        return json_object(
            "file" => file,
            "error" => sprint(showerror, error),
        )
    end
end


function refresh_simulation_saves!(controller::QMLController; root::AbstractString = SAVES_DIR)
    return guarded_action(controller, "Reading the saves failed") do
        controller.bindings.simulation_saves_json[] =
            json_text(simulation_saves_listing(controller.app.sim.model; root = root))
    end
end


function select_simulation_save!(
    controller::QMLController,
    file::AbstractString;
    root::AbstractString = SAVES_DIR,
)
    return guarded_action(controller, "Reading the save failed") do
        controller.bindings.simulation_save_details_json[] =
            json_text(simulation_save_details(controller.app.sim.model, file; root = root))
    end
end


# ------------------------------------------------------------
# Save and Load
# ------------------------------------------------------------

function save_simulation!(
    controller::QMLController,
    name::AbstractString;
    root::AbstractString = SAVES_DIR,
    time::DateTime = Dates.now(),
)
    return guarded_action(controller, "Saving the simulation failed") do
        controller.series.running[] && error("Stop the series before saving the simulation.")
        model = controller.app.sim.model
        saved = RD.capture_simulation_state(controller.app)
        text = json_text(simulation_save_document(saved, model, name, time))
        path = write_save_file(simulation_saves_dir(model.id; root = root), time, name, text)
        controller.bindings.notice[] = "Saved to " * save_display_path(path, root)
    end
end


function load_simulation_save!(
    controller::QMLController,
    file::AbstractString;
    root::AbstractString = SAVES_DIR,
)
    warnings = String[]
    loaded = guarded_action(controller, "Loading the save failed") do
        controller.series.running[] && error("Stop the series before loading a save.")
        app = controller.app
        document = read_save_document(simulation_save_path(app.sim.model.id, file; root = root))
        saved, parse_warnings = parse_simulation_save(document, app.sim.model)
        append!(warnings, parse_warnings)
        RD.restore_simulation_state_app!(
            app,
            saved;
            plot_grid = controller.plot_grid,
            title_obs = controller.title_obs,
            reltol = controller.reltol,
            abstol = controller.abstol,
        )
        controller.diffusion_scale = app.plot_panel.domain_length_scale^2
        controller.boundary_name_obs[] = RD.boundary_condition_label(app.initial_boundary_condition)
        controller.selected_segment = 1
        update_model_bindings!(controller)
        refresh_current_equation_image!(controller)
        update_partition_bindings!(controller; reset_index = true)
        # A save holds nothing of the series: its setup stays for the panels
        # that still exist, but results of another state would mislead.
        keep_series_setup_of_remaining_panels!(controller)
        controller.bindings.notice[] = "Loaded " * file
    end

    if loaded && !isempty(warnings)
        foreach(warning -> @warn(warning), warnings)
        # After guarded_action, which clears the message on success.
        controller.bindings.message[] = "Loaded with changes: " * join(warnings, " ")
    end

    return loaded
end


# ------------------------------------------------------------
# Save series
# ------------------------------------------------------------


function panel_preset_name(controller::QMLController, segment::Int)
    key = controller.series.panel_presets[segment]
    key == "none" && return "None"
    key == "custom" && return "Custom"
    preset = series_preset_by_key(controller.bindings.active_model_key[], key)
    return preset === nothing ? key : preset.name
end


function series_run_setup(
    controller::QMLController,
    templates::Vector{RD.SeriesSegmentTemplate},
)
    # Everything but the results, as a Start uses it. The caller has clamped
    # the perturbations and captured the templates.
    app = controller.app
    series = controller.series
    ensure_panel_preset_state!(controller)
    model = first(templates).model
    params = first(templates).params
    panels = Any[]

    for (segment, template) in enumerate(templates)
        perturbations = Any[
            json_object(
                "variable" => model.varnames[perturbation.variable],
                "position" => perturbation.position,
                "width_min" => perturbation.width_min,
                "width_max" => perturbation.width_max,
                "height_min" => perturbation.height_min,
                "height_max" => perturbation.height_max,
            )
            for perturbation in series.perturbations
            if perturbation.segment == segment
        ]
        push!(
            panels,
            json_object(
                "panel" => segment,
                "preset" => panel_preset_name(controller, segment),
                "initial_condition" => isempty(applied_panel_initial_values(series, segment)) ?
                                       "current_state" : "preset",
                "preset_initial_values" => sorted_json_object(series.panel_initial_values[segment]),
                "perturbations" => perturbations,
                "x0" => first(template.x),
                "dx" => template.dx,
                "N" => length(template.x),
                "length" => series_display_length(app, segment),
                "boundary_condition" => template.boundary_condition,
            ),
        )
    end

    panel_lengths = [series_display_length(app, segment) for segment in eachindex(templates)]

    return (
        model = model,
        run_count = series.settings.run_count,
        settings = series_settings_entry(series.settings, model.varnames),
        parameters = Pair{String, Any}[
            String(name) => Float64(get(params, name, model.default_params[name]))
            for name in RD.public_model_parameter_names(model)
        ],
        active_profile_set = active_profile_set_entry(model, params),
        domain_length = sum(panel_lengths),
        domain_length_scale = app.plot_panel.domain_length_scale,
        diffusion_scale = controller.diffusion_scale,
        boundary_condition = app.initial_boundary_condition,
        panels = panels,
    )
end


function series_panel_results(series::SeriesController, segment::Int)
    # The caller holds series.lock. head_counts[k + 1] realizations ended with
    # k heads; location_counts follows the grid given by x0, dx and N.
    count_map = series.head_count_counts[segment]
    maximum_heads = isempty(count_map) ? 0 : maximum(keys(count_map))
    groups = series.configuration_groups[segment]

    return json_object(
        "location_counts" => copy(series.location_counts[segment]),
        "head_counts" => [get(count_map, count, 0) for count in 0:maximum_heads],
        "not_converged" => series.not_converged_counts[segment],
        "configurations" => Any[
            json_object("reference" => copy(groups[index].reference), "count" => groups[index].count)
            for index in RD.head_configuration_order(groups)
        ],
    )
end


function series_save_document(
    series::SeriesController,
    name::AbstractString,
    time::DateTime,
)
    lock(series.lock)

    try
        setup = series.run_setup
        setup === nothing && error("No series has run yet.")
        series.completed_runs >= 1 || error("The series has no completed realization yet.")
        length(series.location_counts) == length(setup.panels) ||
            error("The results do not belong to the last series.")

        return json_object(
            "format_version" => SAVE_FORMAT_VERSION,
            "kind" => "series",
            "name" => String(name),
            "saved_at" => saved_time_text(time),
            "model_id" => setup.model.id,
            "model_name" => setup.model.display_name,
            "completed_runs" => series.completed_runs,
            "run_count" => setup.run_count,
            "settings" => setup.settings,
            "parameters" => setup.parameters,
            "active_profile_set" => setup.active_profile_set,
            "domain_length" => setup.domain_length,
            "domain_length_scale" => setup.domain_length_scale,
            "diffusion_scale" => setup.diffusion_scale,
            "boundary_condition" => setup.boundary_condition,
            "panels" => Any[
                vcat(panel, series_panel_results(series, segment))
                for (segment, panel) in enumerate(setup.panels)
            ],
        )
    finally
        unlock(series.lock)
    end
end


function save_series!(
    controller::QMLController,
    name::AbstractString;
    root::AbstractString = SAVES_DIR,
    time::DateTime = Dates.now(),
)
    return guarded_action(controller, "Saving the series failed") do
        series = controller.series
        text = json_text(series_save_document(series, name, time))
        path = write_save_file(
            series_saves_dir(series.run_setup.model.id; root = root),
            time,
            name,
            text,
        )
        controller.bindings.notice[] = "Saved to " * save_display_path(path, root)
    end
end
