# src/SeriesPresets.jl

# ============================================================
# File-backed presets for Series perturbations
# ============================================================
#
# A preset is a TOML file beside the model.jl of its model, see
# Models/GiererMeinhardt/rho/three_wounds_narrow.toml: a name, an optional
# description and [initial_values], and one [[perturbations]] entry per bump.
# The series window loads every preset at startup, and its Save preset and
# Delete preset buttons write and remove these files. Part of the headless
# core, so the files can be written and read without a window.

struct SeriesPresetPerturbation
    variable_name::String
    position_fraction::Float64
    # Perturbation centre as a fraction of the panel length, from 0 to 1.
    width_min_fraction::Float64
    width_max_fraction::Float64
    height_min::Float64
    height_max::Float64
end


struct SeriesPresetDefinition
    key::String
    name::String
    # Short text shown under the preset selector; empty when the file has none.
    description::String
    model_key::String
    initial_values::Dict{String, Float64}
    perturbations::Vector{SeriesPresetPerturbation}
    path::String
    # The file it was read from; Delete preset removes it.
end


function _series_preset_string(table, field::String, path::AbstractString)
    value = get(table, field, nothing)
    value isa AbstractString || error("Preset $path must define string field '$field'.")
    return String(value)
end


function _series_preset_number(table, field::String, path::AbstractString)
    value = get(table, field, nothing)
    value isa Real || error("Preset $path must define numeric field '$field'.")
    number = Float64(value)
    isfinite(number) || error("Preset $path field '$field' must be finite.")
    return number
end


function _series_preset_position(table, path::AbstractString)
    position = _series_preset_number(table, "position", path)
    0.0 <= position <= 1.0 ||
        error("Preset $path position must be a fraction of the panel length between 0 and 1, got $position.")
    return position
end


function load_series_preset(path::AbstractString, model_key::AbstractString)
    data = TOML.parsefile(path)
    name = _series_preset_string(data, "name", path)
    description = haskey(data, "description") ?
        _series_preset_string(data, "description", path) : ""
    raw_initial_values = get(data, "initial_values", Dict{String, Any}())
    raw_initial_values isa AbstractDict ||
        error("Preset $path initial_values must be a table.")
    initial_values = Dict{String, Float64}()
    for (variable, value) in raw_initial_values
        value isa Real || error("Preset $path initial value for $variable must be numeric.")
        number = Float64(value)
        isfinite(number) || error("Preset $path initial value for $variable must be finite.")
        initial_values[String(variable)] = number
    end
    raw_perturbations = get(data, "perturbations", nothing)
    raw_perturbations isa AbstractVector ||
        error("Preset $path must define at least one [[perturbations]] entry.")
    isempty(raw_perturbations) && error("Preset $path has no perturbations.")

    perturbations = SeriesPresetPerturbation[]
    for entry in raw_perturbations
        entry isa AbstractDict || error("Preset $path contains an invalid perturbation.")
        variable_name = _series_preset_string(entry, "variable", path)
        position = _series_preset_position(entry, path)
        width_min = _series_preset_number(entry, "width_min_fraction", path)
        width_max = _series_preset_number(entry, "width_max_fraction", path)
        height_min = _series_preset_number(entry, "height_min", path)
        height_max = _series_preset_number(entry, "height_max", path)
        0.0 < width_min <= width_max ||
            error("Preset $path has invalid width bounds.")
        height_min <= height_max || error("Preset $path has invalid height bounds.")
        push!(
            perturbations,
            SeriesPresetPerturbation(
                variable_name,
                position,
                width_min,
                width_max,
                height_min,
                height_max,
            ),
        )
    end

    key = basename(path)
    return SeriesPresetDefinition(
        key,
        name,
        description,
        String(model_key),
        initial_values,
        perturbations,
        String(path),
    )
end


function load_series_presets(root::AbstractString)
    isdir(root) || return SeriesPresetDefinition[]
    presets = SeriesPresetDefinition[]

    for model_path in model_files(root)
        directory = dirname(model_path)
        model_key = model_registry_key(root, model_path)
        for name in sort(readdir(directory))
            endswith(lowercase(name), ".toml") || continue
            path = joinpath(directory, name)
            try
                push!(presets, load_series_preset(path, model_key))
            catch error
                @warn "Ignoring invalid Series preset" path exception = (error, catch_backtrace())
            end
        end
    end

    return sort_series_presets!(presets)
end


sort_series_presets!(presets::Vector{SeriesPresetDefinition}) =
    sort!(presets; by = preset -> (preset.model_key, preset.name, preset.key))


function series_presets_json(
    presets::Vector{SeriesPresetDefinition},
    model_key::AbstractString;
    include_custom::Bool = false,
)
    entries = ["{\"key\":\"none\",\"name\":\"None\"}"]
    include_custom && push!(entries, "{\"key\":\"custom\",\"name\":\"Custom\"}")

    for preset in presets
        preset.model_key == model_key || continue
        push!(
            entries,
            "{\"key\":" * json_string(preset.key) *
            ",\"name\":" * json_string(preset.name) *
            ",\"description\":" * json_string(preset.description) *
            ",\"file\":" * json_string(series_preset_display_path(preset.path)) * "}",
        )
    end

    return "[" * join(entries, ",") * "]"
end


# ------------------------------------------------------------
# Writing and deleting presets
# ------------------------------------------------------------

const SERIES_PRESET_NAME_MAX_LENGTH = 100
const SERIES_PRESET_FILE_STEM_MAX_LENGTH = 60


series_preset_directory(model_key::AbstractString; root::AbstractString = MODEL_DIR) =
    joinpath(root, split(String(model_key), '/')...)


function series_preset_display_path(path::AbstractString)
    # Relative to the repository for a file under Models/, in full otherwise.
    full = normpath(abspath(path))
    startswith(full, joinpath(MODEL_DIR, "")) || return replace(full, '\\' => '/')
    return replace(joinpath(basename(MODEL_DIR), relpath(full, MODEL_DIR)), '\\' => '/')
end


function series_preset_name(name::AbstractString)
    # The name as stored: on one line, without surrounding spaces.
    cleaned = String(strip(replace(String(name), r"[\r\n\t]+" => " ")))
    isempty(cleaned) && error("Enter a name for the preset.")
    length(cleaned) <= SERIES_PRESET_NAME_MAX_LENGTH ||
        error("A preset name can have at most $SERIES_PRESET_NAME_MAX_LENGTH characters.")
    return cleaned
end


function series_preset_file_name(name::AbstractString)
    # Lower-case ASCII letters, digits and underscores taken from the name, so
    # that "Ends 1.6–2.6 (narrow)" becomes ends_1_6_2_6_narrow.toml.
    folded = Base.Unicode.normalize(String(strip(name)); stripmark = true, casefold = true)
    stem = strip(replace(folded, r"[^a-z0-9]+" => "_"), '_')
    stem = rstrip(first(stem, SERIES_PRESET_FILE_STEM_MAX_LENGTH), '_')
    isempty(stem) && (stem = "preset")
    uppercase(stem) in WINDOWS_RESERVED_FILE_NAMES && (stem *= "_preset")
    return stem * ".toml"
end


function _toml_string(value::AbstractString)
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
        elseif iscntrl(character)
            @printf(io, "\\u%04X", Int(character))
        else
            print(io, character)
        end
    end

    print(io, '"')
    return String(take!(io))
end


_toml_key(key::AbstractString) =
    occursin(r"^[A-Za-z0-9_-]+$", key) ? String(key) : _toml_string(key)


function _toml_number(value::Real, field::AbstractString)
    number = Float64(value)
    isfinite(number) || error("The preset field '$field' must be finite, got $number.")
    # print gives the shortest decimal form that reads back identically.
    return string(number)
end


function series_preset_toml(
    name::AbstractString,
    description::AbstractString,
    initial_values::AbstractDict,
    perturbations::AbstractVector{SeriesPresetPerturbation},
)
    # The layout of the hand-written presets in Models/.
    io = IOBuffer()
    println(io, "name = ", _toml_string(name))
    isempty(description) || println(io, "description = ", _toml_string(description))

    if !isempty(initial_values)
        print(io, "\n[initial_values]\n")
        for variable in sort(collect(keys(initial_values)); by = String)
            println(
                io,
                _toml_key(String(variable)),
                " = ",
                _toml_number(initial_values[variable], "initial_values.$variable"),
            )
        end
    end

    for perturbation in perturbations
        print(io, "\n[[perturbations]]\n")
        println(io, "variable = ", _toml_string(perturbation.variable_name))
        println(io, "position = ", _toml_number(perturbation.position_fraction, "position"))
        println(
            io,
            "width_min_fraction = ",
            _toml_number(perturbation.width_min_fraction, "width_min_fraction"),
        )
        println(
            io,
            "width_max_fraction = ",
            _toml_number(perturbation.width_max_fraction, "width_max_fraction"),
        )
        println(io, "height_min = ", _toml_number(perturbation.height_min, "height_min"))
        println(io, "height_max = ", _toml_number(perturbation.height_max, "height_max"))
    end

    return String(take!(io))
end


function write_series_preset(
    directory::AbstractString,
    model_key::AbstractString,
    name::AbstractString,
    description::AbstractString,
    initial_values::AbstractDict,
    perturbations::AbstractVector{SeriesPresetPerturbation};
    overwrite::Bool = false,
)
    # Writes <directory>/<file name from the name>.toml and returns the preset
    # as read back from it. An existing file is replaced only with overwrite.
    isdir(directory) || error("The model folder $directory does not exist.")
    cleaned_name = series_preset_name(name)
    isempty(perturbations) && error("A preset needs at least one perturbation.")
    path = joinpath(directory, series_preset_file_name(cleaned_name))
    !overwrite && ispath(path) &&
        error("The preset file $(series_preset_display_path(path)) already exists.")
    text = series_preset_toml(
        cleaned_name,
        String(strip(description)),
        initial_values,
        perturbations,
    )
    # Through a temporary file, checked as a preset before it replaces
    # anything, so a failed write leaves no broken preset.
    temporary = path * ".tmp"

    try
        write(temporary, text)
        load_series_preset(temporary, model_key)
        mv(temporary, path; force = true)
    finally
        rm(temporary; force = true)
    end

    return load_series_preset(path, model_key)
end


function delete_series_preset_file(preset::SeriesPresetDefinition)
    # A file that is already gone is not an error; one that cannot be removed is.
    rm(preset.path; force = true)
    return nothing
end


same_series_preset(a::SeriesPresetDefinition, b::SeriesPresetDefinition) =
    a.model_key == b.model_key && a.key == b.key


function register_series_preset!(
    presets::Vector{SeriesPresetDefinition},
    preset::SeriesPresetDefinition,
)
    # Adds a written preset, or replaces the one read from the same file.
    filter!(other -> !same_series_preset(other, preset), presets)
    push!(presets, preset)
    return sort_series_presets!(presets)
end


function unregister_series_preset!(
    presets::Vector{SeriesPresetDefinition},
    preset::SeriesPresetDefinition,
)
    return filter!(other -> !same_series_preset(other, preset), presets)
end
