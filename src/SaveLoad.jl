# src/SaveLoad.jl

# ============================================================
# Save files: names, JSON text, simulation saves
# ============================================================
#
# This is the part of Save, Load and Save series that needs no window: file
# names, the JSON writer, and the conversion of a simulation state to a save
# document and back. The QMLController actions (Save, Load window, Save
# series) are in SaveLoadQML.jl.
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

function json_string(value::AbstractString)
    io = IOBuffer()
    print(io, '"')

    for character in String(value)
        if character == '"'
            print(io, "\\\"")
        elseif character == '\\'
            print(io, "\\\\")
        elseif character == '\n'
            print(io, "\\n")
        elseif character == '\r'
            print(io, "\\r")
        elseif character == '\t'
            print(io, "\\t")
        elseif Int(character) < 0x20
            @printf(io, "\\u%04x", Int(character))
        else
            print(io, character)
        end
    end

    print(io, '"')
    return String(take!(io))
end


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
    index = _active_spatial_profile_set_index(params, model.spatial_profile_sets)
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

        if startswith(name, SPATIAL_PROFILE_OVERRIDE_PREFIX)
            push!(profiles, chopprefix(name, SPATIAL_PROFILE_OVERRIDE_PREFIX) => Float64.(value))
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
    saved::SavedSimulationState,
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
    validate_boundary_condition(boundary_condition)
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

        if key == DIFFUSION_SCALE_PARAM
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

    for key in public_model_parameter_names(model)
        haskey(saved_parameters, String(key)) || push!(added, String(key))
    end

    if set_index > 0
        params[ACTIVE_SPATIAL_PROFILE_SET_PARAM] = Float64(set_index)
    end

    keep_profiles || return params
    set_profile_names = first.(last(model.spatial_profile_sets[set_index]))

    for (name, values) in get(panel, "profiles", Dict{String, Any}())
        if name in set_profile_names
            params[spatial_profile_override_key(name)] =
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
    segments = SavedSegmentState[]

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
            SavedSegmentState(
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
    if haskey(overrides, ACTIVE_SPATIAL_PROFILE_SET_PARAM)
        if set_index > 0
            overrides[ACTIVE_SPATIAL_PROFILE_SET_PARAM] = Float64(set_index)
        else
            delete!(overrides, ACTIVE_SPATIAL_PROFILE_SET_PARAM)
        end
    end

    domain_length_scale = save_number(save_field(document, "domain_length_scale", "The file"), "domain_length_scale")
    domain_length_scale > 0.0 || error("Its domain scale is not positive.")
    requested_dtmax = save_number(save_field(document, "requested_dtmax", "The file"), "requested_dtmax")
    requested_dtmax > 0.0 || error("Its maximum time step is not positive.")
    initial_N = save_integer(save_field(document, "initial_N", "The file"), "initial_N")
    initial_N >= 2 || error("Its grid has fewer than two points.")

    saved = SavedSimulationState(
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


function simulation_save_path(model_id, file::AbstractString; root::AbstractString = SAVES_DIR)
    # Only a file of this model's folder, whatever the interface passes.
    file == basename(file) && endswith(file, ".json") || error("Not a save file: $file")
    return joinpath(simulation_saves_dir(model_id; root = root), file)
end


# ------------------------------------------------------------
# Series settings, as a series save writes them
# ------------------------------------------------------------

function series_settings_entry(settings::SeriesSettings, varnames::Vector{String})
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
