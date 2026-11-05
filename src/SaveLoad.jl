# src/SaveLoad.jl

# ============================================================
# Save, Load and Save series
# ============================================================
#
# Every save is one JSON file, kept per model id:
#
#     saves/simulation/<model id>/<date>_<time>[_<name>].json
#     saves/series/<model id>/<date>_<time>[_<name>].json
#
# A simulation save holds the complete state of the panels and can be loaded
# again by the same model; it holds nothing of the series. A series save holds
# what a series used and its results, for processing outside this application;
# it is never read back.
#
# Metadata take one line per value and every list of numbers one line, so a
# file can be looked through in a text editor. Numbers use the shortest decimal
# form that reads back as exactly the same Float64.

const SAVES_DIR = normpath(joinpath(@__DIR__, "..", "saves"))
const SAVE_FORMAT_VERSION = 1
const SAVE_NAME_MAX_LENGTH = 100
const SAVE_PREVIEW_MAX_POINTS = 500
const SAVE_RESERVED_PANEL_FIELDS = (
    "x0", "dx", "N", "x", "t", "dt", "dtmax", "steps",
    "boundary_condition", "parameters", "profiles",
)
const WINDOWS_RESERVED_FILE_NAMES = Set([
    "CON", "PRN", "AUX", "NUL",
    ("COM$number" for number in 1:9)...,
    ("LPT$number" for number in 1:9)...,
])


simulation_saves_dir(model_id; root::AbstractString = SAVES_DIR) =
    joinpath(root, "simulation", String(model_id))

series_saves_dir(model_id; root::AbstractString = SAVES_DIR) =
    joinpath(root, "series", String(model_id))


# ------------------------------------------------------------
# File names
# ------------------------------------------------------------

function sanitized_save_name(name::AbstractString)
    # The name as far as a file name allows it, on every platform. The file
    # itself keeps the name as typed.
    cleaned = map(
        character -> character in "<>:\"/\\|?*" || iscntrl(character) ? '_' : character,
        String(name),
    )
    cleaned = String(strip(cleaned))
    cleaned = first(cleaned, SAVE_NAME_MAX_LENGTH)
    cleaned = String(rstrip(character -> character == '.' || isspace(character), cleaned))

    if uppercase(first(split(cleaned, '.'))) in WINDOWS_RESERVED_FILE_NAMES
        cleaned = "_" * cleaned
    end

    return cleaned
end


function save_file_stem(time::DateTime, name::AbstractString)
    date = Dates.format(time, "yyyy-mm-dd_HH-MM-SS")
    cleaned = sanitized_save_name(name)
    return isempty(cleaned) ? date : date * "_" * cleaned
end


function new_save_path(directory::AbstractString, time::DateTime, name::AbstractString)
    # An existing file is never replaced, also within the same second.
    stem = save_file_stem(time, name)
    path = joinpath(directory, stem * ".json")
    number = 2

    while ispath(path)
        path = joinpath(directory, stem * "_$number.json")
        number += 1
    end

    return path
end


function write_save_file(
    directory::AbstractString,
    time::DateTime,
    name::AbstractString,
    text::AbstractString,
)
    mkpath(directory)
    path = new_save_path(directory, time, name)
    # Through a temporary file, so a failed write leaves no broken save.
    temporary = path * ".tmp"

    try
        write(temporary, text)
        mv(temporary, path)
    finally
        rm(temporary; force = true)
    end

    return path
end


function save_display_path(path::AbstractString, root::AbstractString)
    return replace(joinpath(basename(root), relpath(path, root)), '\\' => '/')
end


# ------------------------------------------------------------
# JSON text
# ------------------------------------------------------------

const JsonObject = Vector{Pair{String, Any}}

json_object(entries::Pair...) = Pair{String, Any}[String(first(entry)) => last(entry) for entry in entries]

sorted_json_object(values::AbstractDict) = Pair{String, Any}[
    String(key) => values[key]
    for key in sort(collect(keys(values)); by = String)
]


function write_json_number(io::IO, value::Real, path::AbstractString)
    if value isa Integer
        print(io, value)
        return nothing
    end

    number = Float64(value)
    isfinite(number) || error("$path holds a value that is not finite ($number).")
    # print gives the shortest decimal form that reads back identically.
    print(io, number)
    return nothing
end


is_json_scalar(value) =
    value === nothing || value isa Real || value isa AbstractString || value isa Symbol


function write_json_value(io::IO, value, path::AbstractString, indent::Int)
    if value === nothing
        print(io, "null")
    elseif value isa Bool
        print(io, value ? "true" : "false")
    elseif value isa Real
        write_json_number(io, value, path)
    elseif value isa AbstractString || value isa Symbol
        print(io, json_string(String(value)))
    elseif value isa JsonObject
        if isempty(value)
            print(io, "{}")
            return nothing
        end
        println(io, "{")
        for (index, (key, item)) in enumerate(value)
            print(io, " "^(indent + 2), json_string(key), ": ")
            write_json_value(io, item, path * "." * key, indent + 2)
            println(io, index < length(value) ? "," : "")
        end
        print(io, " "^indent, "}")
    elseif value isa AbstractVector
        if all(is_json_scalar, value)
            print(io, "[")
            for (index, item) in enumerate(value)
                index > 1 && print(io, ",")
                write_json_value(io, item, path * "[$index]", indent)
            end
            print(io, "]")
            return nothing
        end
        println(io, "[")
        for (index, item) in enumerate(value)
            print(io, " "^(indent + 2))
            write_json_value(io, item, path * "[$index]", indent + 2)
            println(io, index < length(value) ? "," : "")
        end
        print(io, " "^indent, "]")
    else
        error("$path cannot be saved: unsupported value of type $(typeof(value)).")
    end

    return nothing
end


function json_text(document)
    io = IOBuffer()
    write_json_value(io, document, "save", 0)
    println(io)
    return String(take!(io))
end


# ------------------------------------------------------------
# Simulation save: state -> document
# ------------------------------------------------------------

function saved_time_text(time::DateTime)
    return Dates.format(time, "yyyy-mm-ddTHH:MM:SS")
end


function active_profile_set_entry(model, params::AbstractDict{Symbol})
    isempty(model.spatial_profile_sets) && return nothing
    index = RD._active_spatial_profile_set_index(params, model.spatial_profile_sets)
    return json_object(
        "name" => first(model.spatial_profile_sets[index]),
        "index" => index,
    )
end


function split_saved_parameters(params::AbstractDict{Symbol})
    # Scalars, and the profile vectors under the names of their profiles.
    scalars = JsonObject()
    profiles = JsonObject()

    for key in sort(collect(keys(params)); by = String)
        name = String(key)
        value = params[key]

        if startswith(name, RD.SPATIAL_PROFILE_OVERRIDE_PREFIX)
            push!(profiles, chopprefix(name, RD.SPATIAL_PROFILE_OVERRIDE_PREFIX) => Float64.(value))
        elseif value isa Real
            push!(scalars, name => Float64(value))
        else
            error("Parameter $name cannot be saved: unsupported value of type $(typeof(value)).")
        end
    end

    return scalars, profiles
end


function grid_is_reproducible(x::AbstractVector{<:Real}, dx::Real)
    x0 = first(x)
    tolerance = 1e-12 * max(abs(x0), abs(last(x)), abs(dx))
    return all(
        abs(x[index] - (x0 + (index - 1) * dx)) <= tolerance
        for index in eachindex(x)
    )
end


function simulation_save_document(
    saved::RD.SavedSimulationState,
    model,
    name::AbstractString,
    time::DateTime,
)
    isempty(saved.segments) && error("There is no panel to save.")

    for variable in model.varnames
        variable in SAVE_RESERVED_PANEL_FIELDS &&
            error("Variable '$variable' has a name a save file uses for something else.")
    end

    panels = Any[]

    for segment in saved.segments
        N = length(segment.x)
        U = reshape(segment.y, N, length(model.varnames))
        scalars, profiles = split_saved_parameters(segment.params)
        panel = json_object(
            "x0" => first(segment.x),
            "dx" => segment.dx,
            "N" => N,
        )
        grid_is_reproducible(segment.x, segment.dx) || push!(panel, "x" => segment.x)
        append!(
            panel,
            json_object(
                "t" => segment.t,
                "dt" => isfinite(segment.dt) ? segment.dt : nothing,
                "dtmax" => segment.dtmax,
                "steps" => segment.steps,
                "boundary_condition" => segment.boundary_condition,
            ),
        )

        for (variable, variable_name) in enumerate(model.varnames)
            push!(panel, variable_name => U[:, variable])
        end

        append!(panel, json_object("parameters" => scalars, "profiles" => profiles))
        push!(panels, panel)
    end

    return json_object(
        "format_version" => SAVE_FORMAT_VERSION,
        "kind" => "simulation",
        "name" => String(name),
        "saved_at" => saved_time_text(time),
        "model_id" => model.id,
        "model_name" => model.display_name,
        "variables" => copy(model.varnames),
        "domain_length_scale" => saved.domain_length_scale,
        "requested_dtmax" => saved.requested_dtmax,
        "initial_N" => saved.initial_N,
        "boundary_condition" => saved.initial_boundary_condition,
        "parameter_overrides" => sorted_json_object(saved.parameter_overrides),
        "active_profile_set" => active_profile_set_entry(model, first(saved.segments).params),
        "panels" => panels,
    )
end


# ------------------------------------------------------------
# Simulation save: file -> state
# ------------------------------------------------------------

function save_field(table, key::AbstractString, context::AbstractString)
    table isa AbstractDict || error("$context is not a table.")
    haskey(table, key) || error("$context has no field '$key'.")
    return table[key]
end


function save_number(value, label::AbstractString)
    value isa Real && !(value isa Bool) || error("$label is not a number.")
    number = Float64(value)
    isfinite(number) || error("$label is not finite.")
    return number
end


function save_integer(value, label::AbstractString)
    number = save_number(value, label)
    isinteger(number) || error("$label is not an integer.")
    return Int(number)
end


function save_number_vector(value, label::AbstractString, expected_length::Int)
    value isa AbstractVector || error("$label is not a list of numbers.")
    length(value) == expected_length ||
        error("$label has $(length(value)) values instead of $expected_length.")
    return Float64[save_number(item, label) for item in value]
end


function save_boundary_condition(value, label::AbstractString)
    value isa AbstractString || error("$label is not text.")
    boundary_condition = Symbol(value)
    RD.validate_boundary_condition(boundary_condition)
    return boundary_condition
end


function read_save_document(path::AbstractString)
    document = JSON.parsefile(path)
    document isa AbstractDict || error("It is not a save file.")
    version = save_integer(save_field(document, "format_version", "The file"), "format_version")
    version <= SAVE_FORMAT_VERSION ||
        error("It was written by a newer version of this application (format $version).")
    return document
end


function resolve_saved_profile_set!(warnings::Vector{String}, model, saved_set)
    # The set is found by name: its number changes when the model file gains
    # or reorders sets. Returns its number and whether the saved profiles fit.
    sets = model.spatial_profile_sets

    if isempty(sets)
        saved_set === nothing ||
            push!(warnings, "The model no longer has spatial profile sets; the saved profiles were ignored.")
        return 0, false
    end

    if saved_set === nothing
        push!(warnings, "The save has no spatial profile set; the first one of the model is used.")
        return 1, false
    end

    set_name = save_field(saved_set, "name", "active_profile_set")
    index = findfirst(set -> first(set) == set_name, sets)

    if index === nothing
        push!(
            warnings,
            "Spatial profile set '$set_name' no longer exists; '$(first(first(sets)))' is used and evaluated anew.",
        )
        return 1, false
    end

    return index, true
end


function restored_panel_parameters!(
    removed::Set{String},
    added::Set{String},
    dropped_profiles::Set{String},
    panel,
    model,
    label::AbstractString,
    N::Int,
    set_index::Int,
    keep_profiles::Bool,
)
    params = Dict{Symbol, Any}(model.default_params)
    saved_parameters = save_field(panel, "parameters", label)

    for (name, value) in saved_parameters
        key = Symbol(name)

        if key == RD.DIFFUSION_SCALE_PARAM
            params[key] = save_number(value, "$label parameter $name")
        elseif startswith(String(name), "__")
            # The active profile set is resolved by name.
            continue
        elseif haskey(model.default_params, key)
            params[key] = save_number(value, "$label parameter $name")
        else
            push!(removed, String(name))
        end
    end

    for key in RD.public_model_parameter_names(model)
        haskey(saved_parameters, String(key)) || push!(added, String(key))
    end

    if set_index > 0
        params[RD.ACTIVE_SPATIAL_PROFILE_SET_PARAM] = Float64(set_index)
    end

    keep_profiles || return params
    set_profile_names = first.(last(model.spatial_profile_sets[set_index]))

    for (name, values) in get(panel, "profiles", Dict{String, Any}())
        if name in set_profile_names
            params[RD.spatial_profile_override_key(name)] =
                save_number_vector(values, "$label profile $name", N)
        else
            push!(dropped_profiles, String(name))
        end
    end

    return params
end


function parse_simulation_save(document, model)
    # The state a save describes for this model, and what had to be adapted
    # because the model changed since. Anything that cannot be adapted is an
    # error, which leaves the running simulation untouched.
    save_field(document, "kind", "The file") == "simulation" || error("It is not a simulation save.")
    saved_id = save_field(document, "model_id", "The file")
    saved_id == String(model.id) || error("It belongs to model '$saved_id', not to '$(model.id)'.")
    variables = save_field(document, "variables", "The file")
    variables == model.varnames ||
        error("It has the variables $(join(variables, ", ")), the model has $(join(model.varnames, ", ")).")
    panels = save_field(document, "panels", "The file")
    panels isa AbstractVector && !isempty(panels) || error("It has no panels.")

    warnings = String[]
    set_index, keep_profiles = resolve_saved_profile_set!(
        warnings,
        model,
        get(document, "active_profile_set", nothing),
    )
    removed = Set{String}()
    added = Set{String}()
    dropped_profiles = Set{String}()
    segments = RD.SavedSegmentState[]

    for (panel_index, panel) in enumerate(panels)
        label = "Panel $panel_index"
        N = save_integer(save_field(panel, "N", label), "$label N")
        N >= 2 || error("$label has fewer than two grid points.")
        dx = save_number(save_field(panel, "dx", label), "$label dx")
        dx > 0.0 || error("$label has a grid spacing that is not positive.")
        x = haskey(panel, "x") ?
            save_number_vector(panel["x"], "$label x", N) :
            begin
                x0 = save_number(save_field(panel, "x0", label), "$label x0")
                Float64[x0 + (index - 1) * dx for index in 1:N]
            end
        y = Float64[]
        sizehint!(y, N * length(model.varnames))

        for variable in model.varnames
            append!(y, save_number_vector(save_field(panel, variable, label), "$label $variable", N))
        end

        dt_value = save_field(panel, "dt", label)
        dtmax = save_number(save_field(panel, "dtmax", label), "$label dtmax")
        dtmax > 0.0 || error("$label has a maximum time step that is not positive.")
        params = restored_panel_parameters!(
            removed,
            added,
            dropped_profiles,
            panel,
            model,
            label,
            N,
            set_index,
            keep_profiles,
        )
        push!(
            segments,
            RD.SavedSegmentState(
                model.id,
                x,
                dx,
                y,
                params,
                save_boundary_condition(save_field(panel, "boundary_condition", label), "$label boundary_condition"),
                save_number(save_field(panel, "t", label), "$label t"),
                dt_value === nothing ? NaN : save_number(dt_value, "$label dt"),
                dtmax,
                save_integer(save_field(panel, "steps", label), "$label steps"),
            ),
        )
    end

    foreach(name -> push!(warnings, "Saved parameter '$name' no longer exists in the model and was ignored."), sort(collect(removed)))
    foreach(name -> push!(warnings, "Parameter '$name' is newer than the save and keeps its default value."), sort(collect(added)))
    foreach(name -> push!(warnings, "Saved profile '$name' is not part of the active set and was ignored."), sort(collect(dropped_profiles)))

    overrides = Dict{Symbol, Float64}()

    for (name, value) in get(document, "parameter_overrides", Dict{String, Any}())
        key = Symbol(name)
        haskey(model.default_params, key) || continue
        overrides[key] = save_number(value, "Parameter override $name")
    end

    # The panels found their profile set by name, so its number may differ
    # from the saved one if the model changed. Reset must use the same set.
    if haskey(overrides, RD.ACTIVE_SPATIAL_PROFILE_SET_PARAM)
        if set_index > 0
            overrides[RD.ACTIVE_SPATIAL_PROFILE_SET_PARAM] = Float64(set_index)
        else
            delete!(overrides, RD.ACTIVE_SPATIAL_PROFILE_SET_PARAM)
        end
    end

    domain_length_scale = save_number(save_field(document, "domain_length_scale", "The file"), "domain_length_scale")
    domain_length_scale > 0.0 || error("Its domain scale is not positive.")
    requested_dtmax = save_number(save_field(document, "requested_dtmax", "The file"), "requested_dtmax")
    requested_dtmax > 0.0 || error("Its maximum time step is not positive.")
    initial_N = save_integer(save_field(document, "initial_N", "The file"), "initial_N")
    initial_N >= 2 || error("Its grid has fewer than two points.")

    saved = RD.SavedSimulationState(
        model.id,
        segments,
        domain_length_scale,
        requested_dtmax,
        initial_N,
        save_boundary_condition(save_field(document, "boundary_condition", "The file"), "boundary_condition"),
        overrides,
    )

    return saved, warnings
end


# ------------------------------------------------------------
# Load window
# ------------------------------------------------------------

function simulation_save_path(model_id, file::AbstractString; root::AbstractString = SAVES_DIR)
    # Only a file of this model's folder, whatever the interface passes.
    file == basename(file) && endswith(file, ".json") || error("Not a save file: $file")
    return joinpath(simulation_saves_dir(model_id; root = root), file)
end


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

function series_settings_entry(settings::RD.SeriesSettings, varnames::Vector{String})
    head_variable = clamp(settings.head_variable, 1, length(varnames))
    return json_object(
        "run_count" => settings.run_count,
        "maximum_time" => settings.maximum_time,
        "maximum_steps_per_panel" => settings.maximum_steps_per_panel,
        "check_interval" => settings.check_interval,
        "tolerance" => settings.tolerance,
        "required_consecutive_checks" => settings.required_consecutive_checks,
        "dtmax" => settings.dtmax,
        "seed" => settings.seed,
        "head_variable" => varnames[head_variable],
        "live_preview" => settings.live_preview,
        "reltol" => settings.reltol,
        "abstol" => settings.abstol,
    )
end


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
