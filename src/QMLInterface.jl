# app.jl loads the startup splash before any heavy package; load it here
# when this file is included on its own.
isdefined(@__MODULE__, :StartupSplash) || include(joinpath(@__DIR__, "StartupSplash.jl"))

module ReactionDiffusionQML

using GLMakie
import CairoMakie
using CxxWrap
using Base64
using Dates
import JSON
using LaTeXStrings
using Logging
using QML
using QMLMakie
using Printf
using TOML

# Qt settings, applied before the first window exists. On Windows Qt keeps its
# own copy of the environment from the moment it starts, and QML is loaded
# before this module, so ENV alone would not reach it; qputenv does, on every
# platform. The basic render loop keeps rendering, and so Makie's Julia
# callbacks, on the main thread; Qt's threaded default on Windows hung the
# first frame.
QML.qputenv("QSG_RENDER_LOOP", QML.QByteArray(get!(ENV, "QSG_RENDER_LOOP", "basic")))
# Effective on Linux only; on Windows the controls keep the native style.
get!(ENV, "QT_QUICK_CONTROLS_STYLE", "Basic")

import ..ReactionDiffusionApp
import ..StartupSplash
const RD = ReactionDiffusionApp

# The save files and the JSON writer live in the core (SaveLoad.jl); the
# window actions in SaveLoadQML.jl and the bindings here use them directly.
import ..ReactionDiffusionApp:
    SAVES_DIR,
    SAVE_FORMAT_VERSION,
    active_profile_set_entry,
    json_object,
    json_string,
    json_text,
    parse_simulation_save,
    read_save_document,
    save_display_path,
    save_field,
    save_number,
    saved_time_text,
    series_saves_dir,
    series_settings_entry,
    simulation_save_document,
    simulation_save_path,
    simulation_saves_dir,
    sorted_json_object,
    write_save_file

include("SeriesPresets.jl")

const QML_FILE = normpath(joinpath(@__DIR__, "..", "qml", "Main.qml"))
const SERIES_PRESETS = load_series_presets(RD.MODEL_DIR)


mutable struct QMLBindings
    active_model_key::Observable{String}
    active_model_name::Observable{String}
    domain_length::Observable{Float64}
    random_mode::Observable{Bool}
    absolute_mode::Observable{Bool}
    selected_segment::Observable{Int}
    segment_count::Observable{Int}
    split_index::Observable{Int}
    split_maximum::Observable{Int}
    variables_json::Observable{String}
    equation_images_json::Observable{String}
    equation_preferred_width::Observable{Float64}
    perturbation_width::Observable{Float64}
    perturbation_height::Observable{Float64}
    message::Observable{String}
    series_running::Observable{Bool}
    series_completed_runs::Observable{Int}
    series_total_runs::Observable{Int}
    series_status::Observable{String}
    series_run_count::Observable{Int}
    series_maximum_time::Observable{Float64}
    series_maximum_steps::Observable{Int}
    series_check_interval::Observable{Float64}
    series_tolerance::Observable{Float64}
    series_required_checks::Observable{Int}
    series_dtmax::Observable{Float64}
    series_seed::Observable{String}
    series_head_variable::Observable{Int}
    series_live_preview::Observable{Bool}
    series_selected_segment::Observable{Int}
    series_selected_variable::Observable{Int}
    series_position::Observable{Float64}
    series_perturbations_json::Observable{String}
    series_presets_json::Observable{String}
    series_selected_preset::Observable{String}
    series_results_json::Observable{String}
    series_mode::Observable{Bool}
    series_preset_initial_available::Observable{Bool}
    series_use_preset_initial::Observable{Bool}
    model_description::Observable{String}
    model_parameters_json::Observable{String}
    equation_values_visible::Observable{Bool}
    domain_resolution::Observable{Int}
    main_window_visible::Observable{Bool}
    notice::Observable{String}
    # Short confirmation shown by the windows, e.g. after Save.
    profile_formula_image::Observable{String}
    profile_formula_width::Observable{Float64}
    profile_formula_note::Observable{String}
    # Formula of the active spatial profile set, shown under Model
    # parameters: an SVG data URI ("" for none), its width and a note.
    active_profile_set::Observable{Int}
    simulation_saves_json::Observable{String}
    simulation_save_details_json::Observable{String}
    # The Load window: the saves of the active model and the selected one.
end


struct CustomPanelSet
    # The perturbations and initial values of one panel after its last manual
    # change, restored by choosing "Custom" in the preset selector.
    perturbations::Vector{RD.SeriesPerturbation}
    initial_values::Dict{String, Float64}
    apply_initial_values::Bool
end


mutable struct SeriesController
    settings::RD.SeriesSettings
    perturbations::Vector{RD.SeriesPerturbation}
    next_perturbation_id::Int
    selected_perturbation_id::Int
    selected_segment::Int
    selected_variable::Int
    selected_position::Float64
    editor_open::Bool
    preview_items::Vector{Any}
    preview_geometry::Vector{Float64}
    # What the preview boxes on the plots were drawn from.
    running::Threads.Atomic{Bool}
    stop_requested::Threads.Atomic{Bool}
    task_ref::Base.RefValue{Union{Nothing, Task}}
    lock::ReentrantLock
    base_snapshots::Vector{RD.SimulationSnapshot}
    # The live state captured by the last Start; a run never replaces it.
    latest_snapshots::Vector{Union{Nothing, RD.SimulationSnapshot}}
    snapshot_revision::Int
    published_snapshot_revision::Int
    generation::Int
    completed_runs::Int
    status::String
    location_counts::Vector{Vector{Int}}
    head_count_counts::Vector{Dict{Int, Int}}
    not_converged_counts::Vector{Int}
    results_revision::Int
    published_results_revision::Int
    pending_preview_update::Symbol
    # :none, :show or :clear. Series preview boxes are Makie plots, so they
    # may only be created or deleted inside the Makie window's render function,
    # where its OpenGL context is current (the series window has its own).
    patterns::Vector{Vector{Vector{Float64}}}
    # Final head-variable profile of every realization, per panel.
    pattern_converged::Vector{Vector{Bool}}
    published_results_segment::Int
    # The results JSON carries the patterns of the selected panel only, so it
    # is published again when the selection changes.
    configuration_groups::Vector{Vector{RD.HeadConfigurationGroup}}
    # Head configurations of the converged realizations, per panel.
    latest_residuals::Vector{Float64}
    residual_revision::Int
    published_residual_revision::Int
    panel_presets::Vector{String}
    # Per panel: a preset key, "none" or "custom".
    panel_initial_values::Vector{Dict{String, Float64}}
    # Per panel: the initial values of its preset, remembered in both positions
    # of the initial-condition switch.
    panel_apply_initial_values::Vector{Bool}
    # Per panel: whether a Start applies them ("Preset") or keeps the live
    # state ("Current state").
    custom_sets::Vector{Union{Nothing, CustomPanelSet}}
    # Per panel: the remembered "Custom" perturbation set, if any.
    latest_profiles::Union{Nothing, Vector{Dict{String, Vector{Float64}}}}
    # Spatial profiles of the running realization for the live preview;
    # nothing shows the nominal profiles of the live panels.
    profile_revision::Int
    published_profile_revision::Int
    run_setup::Any
    # What the last Start used, for Save series; later edits do not change it,
    # so a save always describes the run that produced its results.
end


mutable struct QMLController
    app::RD.AppState
    plot_grid::GridLayout
    title_obs
    model_name_obs::Observable{String}
    boundary_name_obs::Observable{String}
    registry::Dict{String, RD.ModelSpec}
    equation_images_by_model::Dict{String, Vector{String}}
    equation_widths_by_model::Dict{String, Float64}
    bindings::QMLBindings
    series::SeriesController
    diffusion_scale::Float64
    selected_segment::Int
    split_index::Int
    steps_per_frame::Int
    worker_sleep_time::Float64
    reltol::Float64
    abstol::Float64
    graphics_actions::Vector{Function}
    graphics_actions_lock::ReentrantLock
    graphics_busy::Observable{Bool}
    close_requested::Threads.Atomic{Bool}
    first_workspace_frame_rendered::Threads.Atomic{Bool}
end


const ACTIVE_QML_CONTROLLER = Ref{Union{Nothing, QMLController}}(nothing)
const QML_RENDER_CFUNCTION = Ref{Any}(nothing)


function report_startup_stage(label::AbstractString, started_ns::UInt64)
    elapsed = (time_ns() - started_ns) / 1.0e9
    @printf("[startup] %s %8.3f s\n", rpad(label, 36, '.'), elapsed)
    flush(stdout)
    return nothing
end


function set_if_changed!(observable::Observable, value)
    observable[] == value || (observable[] = value)
    return nothing
end


function json_string_array(values)
    return "[" * join(json_string.(String.(collect(values))), ",") * "]"
end


function json_number(value::Real)
    number = Float64(value)
    return isfinite(number) ? @sprintf("%.17g", number) : "null"
end


function model_parameters_json(model::RD.ModelSpec, params::AbstractDict{Symbol})
    entries = String[]
    for name in RD.visible_model_parameter_names(model, params)
        value = get(params, name, model.default_params[name])
        value isa Real || continue
        push!(
            entries,
            "{\"key\":" * json_string(String(name)) *
            ",\"label\":" * json_string(String(name)) *
            ",\"value\":" * json_number(value) *
            ",\"display\":" * json_string(display_number(value)) * "}",
        )
    end
    return "[" * join(entries, ",") * "]"
end


function empty_series_controller()
    return SeriesController(
        RD.SeriesSettings(),
        RD.SeriesPerturbation[],
        1,
        0,
        1,
        1,
        0.5,
        false,
        Any[],
        Float64[],
        Threads.Atomic{Bool}(false),
        Threads.Atomic{Bool}(false),
        Ref{Union{Nothing, Task}}(nothing),
        ReentrantLock(),
        RD.SimulationSnapshot[],
        Union{Nothing, RD.SimulationSnapshot}[],
        0,
        -1,
        0,
        0,
        "Configure perturbations",
        Vector{Int}[],
        Vector{Dict{Int, Int}}[],
        Int[],
        0,
        -1,
        :none,
        Vector{Vector{Float64}}[],
        Vector{Bool}[],
        0,
        Vector{RD.HeadConfigurationGroup}[],
        Float64[],
        0,
        -1,
        String[],
        Dict{String, Float64}[],
        Bool[],
        Union{Nothing, CustomPanelSet}[],
        nothing,
        0,
        0,
        nothing,
    )
end


function series_perturbations_json(controller)
    # Position and widths are fractions of the panel length.
    series = controller.series
    entries = String[]

    for perturbation in series.perturbations
        push!(
            entries,
            "{" *
            "\"id\":" * string(perturbation.id) * "," *
            "\"panel\":" * string(perturbation.segment) * "," *
            "\"variable\":" * string(perturbation.variable) * "," *
            "\"position\":" * json_number(perturbation.position) * "," *
            "\"widthMin\":" * json_number(perturbation.width_min) * "," *
            "\"widthMax\":" * json_number(perturbation.width_max) * "," *
            "\"heightMin\":" * json_number(perturbation.height_min) * "," *
            "\"heightMax\":" * json_number(perturbation.height_max) *
            "}",
        )
    end

    return "[" * join(entries, ",") * "]"
end


function series_preset_by_key(model_key::AbstractString, preset_key::AbstractString)
    index = findfirst(
        preset -> preset.model_key == model_key && preset.key == preset_key,
        SERIES_PRESETS,
    )
    return index === nothing ? nothing : SERIES_PRESETS[index]
end


function apply_series_initial_values!(
    templates::Vector{RD.SeriesSegmentTemplate},
    initial_values::Dict{String, Float64},
)
    isempty(initial_values) && return nothing

    for template in templates
        U = reshape(template.y, length(template.x), template.model.nvars)
        for (variable_name, value) in initial_values
            variable = findfirst(==(variable_name), template.model.varnames)
            variable === nothing &&
                error("Series preset requires variable '$variable_name', which is unavailable in this model.")
            U[:, variable] .= value
        end
    end

    return nothing
end


function applied_panel_initial_values(series::SeriesController, segment::Int)
    # What a realization of this panel really starts from. An empty result
    # means the live state of every variable; a variable the preset does not
    # list keeps its live state in any case.
    segment <= length(series.panel_apply_initial_values) &&
        series.panel_apply_initial_values[segment] ||
        return Dict{String, Float64}()
    return series.panel_initial_values[segment]
end


function resize_panel_vector!(values::Vector, count::Int, default::Function)
    while length(values) < count
        push!(values, default())
    end
    length(values) > count && resize!(values, count)
    return values
end


function ensure_panel_preset_state!(
    controller::QMLController,
    count::Int = length(controller.app.simulations),
)
    # The remap functions pass the panel count from before the topology change.
    series = controller.series
    resize_panel_vector!(series.panel_presets, count, () -> "none")
    resize_panel_vector!(series.panel_initial_values, count, () -> Dict{String, Float64}())
    resize_panel_vector!(series.panel_apply_initial_values, count, () -> false)
    resize_panel_vector!(series.custom_sets, count, () -> nothing)
    return nothing
end


function clear_panel_preset_state!(controller::QMLController)
    series = controller.series
    empty!(series.panel_presets)
    empty!(series.panel_initial_values)
    empty!(series.panel_apply_initial_values)
    empty!(series.custom_sets)
    ensure_panel_preset_state!(controller)
    return nothing
end


function mark_panel_custom!(controller::QMLController, segment::Int)
    series = controller.series
    ensure_panel_preset_state!(controller)
    1 <= segment <= length(series.panel_presets) || return nothing

    series.panel_presets[segment] = "custom"
    series.custom_sets[segment] = CustomPanelSet(
        deepcopy(filter(perturbation -> perturbation.segment == segment, series.perturbations)),
        copy(series.panel_initial_values[segment]),
        series.panel_apply_initial_values[segment],
    )
    return nothing
end


const SERIES_PATTERN_DISPLAY_LIMIT = 300


compact_json_number(value::Real) =
    isfinite(value) ? @sprintf("%.6g", Float64(value)) : "null"


function series_patterns_json(controller, segment::Int)
    # The caller holds series.lock.
    series = controller.series
    panel = controller.app.plot_panel
    segment <= length(series.patterns) || return "\"patternX\":[],\"patterns\":[],\"patternConverged\":[]"
    x = segment <= length(panel.segment_x_observables) ?
        panel.segment_x_observables[segment][] :
        Float64[]
    profiles = series.patterns[segment]
    converged = series.pattern_converged[segment]
    shown = max(1, length(profiles) - SERIES_PATTERN_DISPLAY_LIMIT + 1):length(profiles)

    return "\"patternX\":[" * join(compact_json_number.(x), ",") * "]," *
           "\"patterns\":[" *
           join(("[" * join(compact_json_number.(profiles[index]), ",") * "]" for index in shown), ",") *
           "]," *
           "\"patternConverged\":[" * join(string.(converged[shown]), ",") * "]"
end


function series_results_json(controller)
    series = controller.series
    app = controller.app
    entries = String[]

    lock(series.lock)

    try
        for segment in eachindex(series.location_counts)
            location_counts = series.location_counts[segment]
            count_map = series.head_count_counts[segment]
            maximum_heads = isempty(count_map) ? 0 : maximum(keys(count_map))
            head_labels = [json_string(string(count)) for count in 0:maximum_heads]
            head_values = [string(get(count_map, count, 0)) for count in 0:maximum_heads]
            push!(head_labels, json_string("Not converged"))
            push!(head_values, string(series.not_converged_counts[segment]))
            # Every partition panel displays local coordinates.  Keep the
            # histogram axis consistent with that convention, including the
            # right endpoint of a periodic panel (which is not itself a node).
            xmin = 0.0
            xmax = segment <= length(app.simulations) ?
                series_display_length(app, segment) :
                1.0

            groups = series.configuration_groups[segment]
            periodic = segment <= length(app.simulations) &&
                       app.simulations[segment].boundary_condition == :periodic
            order = RD.head_configuration_order(groups)
            config_labels = RD.head_configuration_labels(groups, periodic)[order]
            config_counts = [groups[index].count for index in order]
            config_heads = [length(groups[index].reference) for index in order]

            # Only the displayed panel carries its (large) pattern data.
            patterns_json = segment == series.selected_segment ?
                series_patterns_json(controller, segment) :
                "\"patternX\":[],\"patterns\":[],\"patternConverged\":[]"

            push!(
                entries,
                "{" *
                "\"panel\":" * string(segment) * "," *
                "\"locationCounts\":[" * join(string.(location_counts), ",") * "]," *
                "\"xMin\":" * json_number(xmin) * "," *
                "\"xMax\":" * json_number(xmax) * "," *
                "\"headLabels\":[" * join(head_labels, ",") * "]," *
                "\"headCounts\":[" * join(head_values, ",") * "]," *
                "\"configLabels\":[" * join(json_string.(config_labels), ",") * "]," *
                "\"configCounts\":[" * join(string.(config_counts), ",") * "]," *
                "\"configHeads\":[" * join(string.(config_heads), ",") * "]," *
                "\"notConverged\":" * string(series.not_converged_counts[segment]) * "," *
                patterns_json *
                "}",
            )
        end
    finally
        unlock(series.lock)
    end

    return "[" * join(entries, ",") * "]"
end


function series_perturbation_by_id(series::SeriesController, id::Int)
    index = findfirst(perturbation -> perturbation.id == id, series.perturbations)
    return index === nothing ? nothing : series.perturbations[index]
end


function series_display_length(app::RD.AppState, segment::Int)
    return RD.segment_base_length(app, segment) * app.plot_panel.domain_length_scale
end


# Series perturbations store and show their position and widths as fractions
# of the panel length (0 to 1). They are converted to axis units for the
# previews and to solver units when a series starts, so changing the domain
# length never changes them.
const SERIES_POSITION_DIGITS = 3
const SERIES_WIDTH_DIGITS = 2
const SERIES_WIDTH_STEP = 0.01
const SERIES_HEIGHT_DIGITS = 1
# A width converted between panels stays positive however small it gets.
const SERIES_SMALLEST_WIDTH = 1e-12


function clamp_series_perturbation!(app::RD.AppState, perturbation::RD.SeriesPerturbation)
    1 <= perturbation.segment <= length(app.simulations) || return false
    # Limits only. Panel operations convert these fractions exactly, so that a
    # perturbation keeps its physical size; values are rounded where they are
    # typed, in update_series_perturbation!.
    perturbation.position = clamp(perturbation.position, 0.0, 1.0)
    perturbation.width_max = clamp(perturbation.width_max, SERIES_SMALLEST_WIDTH, 1.0)
    perturbation.width_min = clamp(
        perturbation.width_min,
        SERIES_SMALLEST_WIDTH,
        perturbation.width_max,
    )
    perturbation.variable = clamp(
        perturbation.variable,
        1,
        app.simulations[perturbation.segment].model.nvars,
    )
    return true
end

const LATEX_GREEK_LETTERS = Dict(zip(
    "αβγδεζηθικλμνξπρστυφχψω",
    (
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
        "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau",
        "upsilon", "phi", "chi", "psi", "omega",
    ),
))


function latex_subscript(text::AbstractString)
    # One character as it is, a longer subscript in braces; underscores in
    # parameter names are escaped: 0 -> _0, split -> _{split},
    # peak_pos -> _{peak\_pos}.
    escaped = replace(String(text), "_" => raw"\_")
    return length(text) == 1 ? "_" * escaped : "_{" * escaped * "}"
end


function latex_parameter_token(parameter::Symbol)
    # Greek-letter parameters appear as LaTeX commands in the equations,
    # whether the name uses the letter or spells it out: μu -> \mu_u,
    # τ -> \tau, kappa -> \kappa, ρsplit -> \rho_{split}.
    name = String(parameter)
    letter = get(LATEX_GREEK_LETTERS, first(name), nothing)
    if letter !== nothing
        rest = name[nextind(name, 1):end]
        return "\\" * letter * (isempty(rest) ? "" : latex_subscript(rest))
    end
    name in values(LATEX_GREEK_LETTERS) && return "\\" * name
    if startswith(name, "D") && length(name) == 2
        return "D_" * name[2:end]
    end
    return name
end


# Displayed form of a model parameter, shared by the parameter fields and the
# equations: at most three significant digits without trailing zeros, in
# positional notation unless that needs more than three digits (the leading
# "0." does not count), e.g. 1, 0.5, 123, 0.015, 1.23e+3, 1.23e-2. Only the
# display is rounded; the solver keeps the full value.
function display_number_parts(value::Real)
    number = Float64(value)
    number == 0.0 && return ("0", nothing)
    isfinite(number) || return (string(number), nothing)
    mantissa, exponent_text = split(@sprintf("%.2e", number), 'e')
    exponent = parse(Int, exponent_text)
    sign = startswith(mantissa, '-') ? "-" : ""
    mantissa = rstrip(rstrip(lstrip(mantissa, '-'), '0'), '.')
    significant = replace(mantissa, "." => "")
    positional_digits = exponent >= 0 ?
        max(exponent + 1, length(significant)) :
        length(significant) - exponent - 1
    positional_digits <= 3 || return (sign * mantissa, exponent)
    exponent < 0 && return (sign * "0." * "0"^(-exponent - 1) * significant, nothing)
    whole = rpad(significant[1:min(end, exponent + 1)], exponent + 1, '0')
    fraction = length(significant) > exponent + 1 ? "." * significant[(exponent + 2):end] : ""
    return (sign * whole * fraction, nothing)
end


function display_number(value::Real)
    mantissa, exponent = display_number_parts(value)
    exponent === nothing && return mantissa
    return mantissa * (exponent < 0 ? "e-" : "e+") * string(abs(exponent))
end


function latex_number(value::Real)
    mantissa, exponent = display_number_parts(value)
    exponent === nothing && return mantissa
    power = "10^{" * string(exponent) * "}"
    mantissa == "1" && return power
    mantissa == "-1" && return "-" * power
    return mantissa * raw"\times " * power
end


regex_escape(text::AbstractString) =
    replace(String(text), r"[\\^$.|?*+()\[\]{}]" => character -> "\\" * character)


function equations_with_parameter_values(
    equations::AbstractVector{<:AbstractString},
    model::RD.ModelSpec,
    params::AbstractDict{Symbol},
)
    rendered = String.(equations)
    for parameter in RD.public_model_parameter_names(model)
        token = latex_parameter_token(parameter)
        value = get(params, parameter, model.default_params[parameter])
        value isa Real || continue
        # Never match right after a backslash, i.e. inside a LaTeX command.
        pattern = Regex("(?<![A-Za-z\\\\])" * regex_escape(token) * "(?![A-Za-z])")
        replacement = latex_number(value)
        rendered = replace.(rendered, pattern => replacement)
    end
    return rendered
end


function render_model_equations_svg_uri(equations::AbstractVector{<:AbstractString})
    equation_lines = [
        filter(!isempty, strip.(split(String(equation), '\n')))
        for equation in equations
    ]
    filter!(!isempty, equation_lines)
    isempty(equation_lines) && return (uri = "", width = 0.0)

    figure = CairoMakie.Figure(
        figure_padding = (18, 18, 14, 14),
        backgroundcolor = :transparent,
    )
    row = 1

    for lines in equation_lines
        for (line_index, line) in enumerate(lines)
            parts = split(line, '='; limit = 2)
            has_equals = line_index == 1 && length(parts) == 2
            left_side = has_equals ? strip(parts[1]) : ""
            right_side = has_equals ? strip(parts[2]) : line

            if !isempty(left_side)
                CairoMakie.Label(
                    figure[row, 1],
                    LaTeXStrings.latexstring(left_side);
                    fontsize = 24,
                    color = :black,
                    halign = :right,
                    tellwidth = true,
                    tellheight = true,
                )
                CairoMakie.Label(
                    figure[row, 2],
                    LaTeXStrings.latexstring("=");
                    fontsize = 24,
                    color = :black,
                    halign = :center,
                    tellwidth = false,
                    tellheight = true,
                )
            end

            CairoMakie.Label(
                figure[row, 3],
                LaTeXStrings.latexstring(right_side);
                fontsize = 24,
                color = :black,
                halign = :left,
                tellwidth = true,
                tellheight = true,
            )
            row += 1
        end
    end

    colsize!(figure.layout, 1, Auto())
    colsize!(figure.layout, 2, Fixed(58))
    colsize!(figure.layout, 3, Auto())
    colgap!(figure.layout, 10)
    rowgap!(figure.layout, 18)
    CairoMakie.resize_to_layout!(figure)

    rendered_width = Float64(figure.scene.viewport[].widths[1])
    svg = sprint(show, MIME"image/svg+xml"(), figure)
    return (
        uri = "data:image/svg+xml;base64," * base64encode(svg),
        width = rendered_width,
    )
end


function refresh_current_equation_image!(controller::QMLController)
    bindings = controller.bindings
    key = bindings.active_model_key[]
    model = controller.app.sim.model
    rendered = if bindings.equation_values_visible[]
        CairoMakie.activate!(type = "svg")
        try
            render_model_equations_svg_uri(
                equations_with_parameter_values(model.latex_equations, model, controller.app.sim.params),
            )
        finally
            GLMakie.activate!()
        end
    else
        (
            uri = isempty(get(controller.equation_images_by_model, key, String[])) ? "" :
                  first(controller.equation_images_by_model[key]),
            width = get(controller.equation_widths_by_model, key, 0.0),
        )
    end
    set_if_changed!(
        bindings.equation_images_json,
        isempty(rendered.uri) ? "[]" : json_string_array([rendered.uri]),
    )
    set_if_changed!(bindings.equation_preferred_width, rendered.width)
    return nothing
end


# ============================================================
# Formula of the active spatial profile set
# ============================================================

function formula_with_parameter_values(
    formula,
    model::RD.ModelSpec,
    params::AbstractDict{Symbol},
)
    substitute(text) = only(equations_with_parameter_values([text], model, params))
    formula isa RD.PiecewiseFormula || return substitute(formula)

    return RD.PiecewiseFormula(
        substitute(formula.lhs),
        [substitute(first(piece)) => substitute(last(piece)) for piece in formula.pieces],
    )
end


function svg_data_uri(figure)
    rendered_width = Float64(figure.scene.viewport[].widths[1])
    svg = sprint(show, MIME"image/svg+xml"(), figure)
    return (
        uri = "data:image/svg+xml;base64," * base64encode(svg),
        width = rendered_width,
    )
end


function render_piecewise_formula_svg_uri(formula::RD.PiecewiseFormula)
    # lhs = { expression_1   condition_1
    #         expression_2   condition_2
    # MathTeXEngine has no cases environment, so the brace is a single
    # glyph scaled to the height of the parts.
    figure = CairoMakie.Figure(
        figure_padding = (18, 18, 14, 14),
        backgroundcolor = :transparent,
    )
    rows = length(formula.pieces)

    latex_label(position, text; halign) = CairoMakie.Label(
        position,
        LaTeXStrings.latexstring(text);
        fontsize = 24,
        color = :black,
        halign = halign,
        tellwidth = true,
        tellheight = true,
    )

    latex_label(figure[1:rows, 1], formula.lhs; halign = :right)
    latex_label(figure[1:rows, 2], "="; halign = :center)
    CairoMakie.Label(
        figure[1:rows, 3],
        LaTeXStrings.latexstring(raw"\{");
        fontsize = 34 * rows + 10 * (rows - 1),
        color = :black,
        halign = :right,
        valign = :center,
        tellwidth = true,
        tellheight = false,
    )

    for (row, (expression, condition)) in enumerate(formula.pieces)
        latex_label(figure[row, 4], expression; halign = :left)
        latex_label(figure[row, 5], condition; halign = :left)
    end

    colgap!(figure.layout, 10)
    colgap!(figure.layout, 3, 4)
    colgap!(figure.layout, 4, 28)
    rowgap!(figure.layout, 10)
    CairoMakie.resize_to_layout!(figure)

    return svg_data_uri(figure)
end


function render_profile_formula_svg_uri(formula)
    formula isa RD.PiecewiseFormula ||
        return render_model_equations_svg_uri([formula])

    try
        return render_piecewise_formula_svg_uri(formula)
    catch error
        @warn "The profile formula could not be drawn with a brace; it is shown line by line." exception =
            (error, catch_backtrace())
        lines = [
            (index == 1 ? formula.lhs * " = " : "") * expression * raw", \quad " * condition
            for (index, (expression, condition)) in enumerate(formula.pieces)
        ]
        return render_model_equations_svg_uri([join(lines, "\n")])
    end
end


const PROFILE_FORMULA_CACHE = Dict{String, NamedTuple{(:uri, :width), Tuple{String, Float64}}}()

profile_formula_cache_key(formula::AbstractString) = "S\0" * formula
profile_formula_cache_key(formula::RD.PiecewiseFormula) =
    "P\0" * formula.lhs * "\0" *
    join((first(piece) * "\0" * last(piece) for piece in formula.pieces), "\0")


function refresh_profile_formula!(controller::QMLController)
    bindings = controller.bindings
    app = controller.app
    formula, note = RD.active_spatial_profile_formula(app.sim.model, app.sim.params)
    rendered = (uri = "", width = 0.0)

    if formula !== nothing
        if bindings.equation_values_visible[]
            formula = formula_with_parameter_values(formula, app.sim.model, app.sim.params)
        end

        key = profile_formula_cache_key(formula)
        cached = get(PROFILE_FORMULA_CACHE, key, nothing)

        if cached === nothing
            CairoMakie.activate!(type = "svg")
            try
                cached = render_profile_formula_svg_uri(formula)
                length(PROFILE_FORMULA_CACHE) >= 200 && empty!(PROFILE_FORMULA_CACHE)
                PROFILE_FORMULA_CACHE[key] = cached
            catch error
                @warn "The profile formula could not be rendered." exception =
                    (error, catch_backtrace())
            finally
                GLMakie.activate!()
            end
        end

        cached === nothing || (rendered = cached)
    end

    set_if_changed!(bindings.profile_formula_image, rendered.uri)
    set_if_changed!(bindings.profile_formula_width, rendered.width)
    set_if_changed!(bindings.profile_formula_note, note)

    return nothing
end


function render_equation_catalog(
    registry::Dict{String, RD.ModelSpec};
    on_progress::Union{Nothing, Function} = nothing,
)
    images = Dict{String, Vector{String}}()
    widths = Dict{String, Float64}()
    CairoMakie.activate!(type = "svg")

    try
        entries = sort(collect(registry); by = first)
        total = length(entries)
        for (index, (key, model)) in enumerate(entries)
            rendered = render_model_equations_svg_uri(model.latex_equations)
            images[key] = isempty(rendered.uri) ? String[] : String[rendered.uri]
            widths[key] = rendered.width
            on_progress === nothing || on_progress(index, total)
        end
    finally
        GLMakie.activate!()
    end

    return images, widths
end


function model_catalog_json(registry::Dict{String, RD.ModelSpec})
    families = String[]

    for family in RD.model_menu_catalog(registry)
        models = [
            "{" *
            "\"key\":" * json_string(entry.key) * "," *
            "\"label\":" * json_string(entry.label) * "," *
            "\"profileSets\":" * json_string_array(first.(registry[entry.key].spatial_profile_sets)) *
            "}"
            for entry in family.models
        ]
        push!(
            families,
            "{" *
            "\"family\":" * json_string(family.family) * "," *
            "\"models\":[" * join(models, ",") * "]" *
            "}",
        )
    end

    return "[" * join(families, ",") * "]"
end


function active_model_menu_name(key::AbstractString)
    return "$(RD.model_family_name(key)) / $(RD.MODEL_REGISTRY[String(key)].display_name)"
end


function current_perturbation_modes(app::RD.AppState)
    state = RD.active_perturbation_state(app)
    state === nothing && return (true, false)

    return (state.random_mode[], state.absolute_mode[])
end


function update_model_bindings!(controller::QMLController)
    model = controller.app.sim.model
    bindings = controller.bindings
    active_key = bindings.active_model_key[]
    set_if_changed!(bindings.active_model_name, active_model_menu_name(active_key))
    set_if_changed!(bindings.model_description, model.description)
    set_if_changed!(
        bindings.model_parameters_json,
        model_parameters_json(model, controller.app.sim.params),
    )
    set_if_changed!(
        bindings.active_profile_set,
        RD._active_spatial_profile_set_index(controller.app.sim.params, model.spatial_profile_sets),
    )
    set_if_changed!(bindings.variables_json, json_string_array(model.varnames))
    set_if_changed!(
        bindings.equation_images_json,
        json_string_array(get(controller.equation_images_by_model, active_key, String[])),
    )
    set_if_changed!(
        bindings.equation_preferred_width,
        get(controller.equation_widths_by_model, active_key, 0.0),
    )
    refresh_profile_formula!(controller)

    return nothing
end


function update_partition_bindings!(
    controller::QMLController;
    reset_index::Bool = false,
)
    app = controller.app
    count = length(app.simulations)
    controller.selected_segment = clamp(controller.selected_segment, 1, count)
    simulation = app.simulations[controller.selected_segment]
    split_maximum = max(2, simulation.N - 2)

    if reset_index || !(2 <= controller.split_index <= split_maximum)
        controller.split_index = clamp(round(Int, simulation.N / 2), 2, split_maximum)
    end

    set_if_changed!(controller.bindings.selected_segment, controller.selected_segment)
    set_if_changed!(controller.bindings.segment_count, count)
    set_if_changed!(controller.bindings.split_maximum, split_maximum)
    set_if_changed!(controller.bindings.split_index, controller.split_index)

    return nothing
end


function refresh_qml_state!(controller::QMLController)
    controller.graphics_busy[] && return nothing

    # A running series owns the plots and keeps graphics_busy set, so this
    # always shows the live state, also in series mode.
    RD.refresh_ui_from_latest_snapshots!(controller.app)
    refresh_series_overlays!(controller)
    random_mode, absolute_mode = current_perturbation_modes(controller.app)
    perturbation_values = RD.perturbation_control_values(controller.app)
    set_if_changed!(controller.bindings.random_mode, random_mode)
    set_if_changed!(controller.bindings.absolute_mode, absolute_mode)
    set_if_changed!(
        controller.bindings.perturbation_width,
        perturbation_values.width,
    )
    set_if_changed!(
        controller.bindings.perturbation_height,
        perturbation_values.height,
    )
    set_if_changed!(
        controller.bindings.domain_length,
        controller.app.plot_panel.domain_length_scale,
    )
    update_partition_bindings!(controller)

    return nothing
end


function enqueue_graphics_action!(
    controller::QMLController,
    action::Function,
)
    lock(controller.graphics_actions_lock)

    try
        controller.graphics_busy[] && return false
        controller.graphics_busy[] = true
        push!(controller.graphics_actions, action)
    finally
        unlock(controller.graphics_actions_lock)
    end

    return true
end


function take_graphics_action!(controller::QMLController)
    lock(controller.graphics_actions_lock)

    try
        isempty(controller.graphics_actions) && return nothing
        return popfirst!(controller.graphics_actions)
    finally
        unlock(controller.graphics_actions_lock)
    end
end


function process_graphics_actions!(controller::QMLController)
    while true
        action = take_graphics_action!(controller)
        action === nothing && break

        try
            action()
        catch error
            report_error!(controller, "Graphics update failed", error)
        finally
            controller.graphics_busy[] = false
        end

        refresh_qml_state!(controller)
    end

    return nothing
end


function qml_renderfunction(screen, scene_or_figure)
    controller = ACTIVE_QML_CONTROLLER[]

    if controller !== nothing
        process_graphics_actions!(controller)
        apply_pending_series_preview_update!(controller)
    end

    QMLMakie.renderfunction(screen, scene_or_figure)
    # Only record the frame here; run_qml_app reveals the window from the
    # event loop, so no window property changes during a render pass.
    controller === nothing || (controller.first_workspace_frame_rendered[] = true)
    return nothing
end


function wait_for_first_workspace_frame!(
    controller::QMLController,
    splash::Union{Nothing, StartupSplash.StartupSplashHandle};
    timeout_seconds::Float64 = 30.0,
)
    started = time()
    while !controller.first_workspace_frame_rendered[]
        QML.process_eventloop_updates()
        QML.process_events()
        # The last stage: without this check the window would still open.
        StartupSplash.startup_cancelled(splash) && throw(StartupSplash.StartupCancelled())
        if time() - started >= timeout_seconds
            @warn "The first workspace frame did not render before the startup timeout."
            return false
        end
        yield()
        sleep(0.015)
    end
    return true
end


function install_qml_renderfunction!(controller::QMLController)
    ACTIVE_QML_CONTROLLER[] = controller

    if QML_RENDER_CFUNCTION[] === nothing
        QML_RENDER_CFUNCTION[] =
            @safe_cfunction(qml_renderfunction, Cvoid, (Any, Any))
    end

    QML.set_default_makie_renderfunction(QML_RENDER_CFUNCTION[])
    return nothing
end


function report_error!(controller::QMLController, context::AbstractString, error)
    message = "$context: $(sprint(showerror, error))"
    controller.bindings.message[] = message
    @error context exception = (error, catch_backtrace())

    return false
end


function guarded_action(action, controller::QMLController, context::AbstractString)
    try
        action()
        set_if_changed!(controller.bindings.message, "")
        refresh_qml_state!(controller)
        return true
    catch error
        return report_error!(controller, context, error)
    end
end


# ============================================================
# Series controls and runtime bridge
# ============================================================

function refresh_series_bindings!(controller::QMLController)
    series = controller.series
    settings = series.settings
    set_if_changed!(controller.bindings.series_running, series.running[])
    set_if_changed!(controller.bindings.series_completed_runs, series.completed_runs)
    set_if_changed!(controller.bindings.series_total_runs, settings.run_count)
    set_if_changed!(controller.bindings.series_status, series.status)
    set_if_changed!(controller.bindings.series_run_count, settings.run_count)
    set_if_changed!(controller.bindings.series_maximum_time, settings.maximum_time)
    set_if_changed!(
        controller.bindings.series_maximum_steps,
        settings.maximum_steps_per_panel,
    )
    set_if_changed!(controller.bindings.series_check_interval, settings.check_interval)
    set_if_changed!(controller.bindings.series_tolerance, settings.tolerance)
    set_if_changed!(
        controller.bindings.series_required_checks,
        settings.required_consecutive_checks,
    )
    set_if_changed!(controller.bindings.series_dtmax, settings.dtmax)
    set_if_changed!(controller.bindings.series_seed, string(settings.seed))
    set_if_changed!(controller.bindings.series_head_variable, settings.head_variable)
    set_if_changed!(controller.bindings.series_live_preview, settings.live_preview)
    set_if_changed!(controller.bindings.series_selected_segment, series.selected_segment)
    set_if_changed!(controller.bindings.series_selected_variable, series.selected_variable)
    set_if_changed!(controller.bindings.series_position, series.selected_position)
    set_if_changed!(
        controller.bindings.series_perturbations_json,
        series_perturbations_json(controller),
    )
    # The preset selector always shows the state of the selected panel.
    ensure_panel_preset_state!(controller)
    model_key = controller.bindings.active_model_key[]
    segment = clamp(series.selected_segment, 1, length(series.panel_presets))
    set_if_changed!(
        controller.bindings.series_presets_json,
        series_presets_json(
            SERIES_PRESETS,
            model_key;
            include_custom = series.custom_sets[segment] !== nothing,
        ),
    )
    initial_available = !isempty(series.panel_initial_values[segment])
    set_if_changed!(controller.bindings.series_preset_initial_available, initial_available)
    set_if_changed!(
        controller.bindings.series_use_preset_initial,
        initial_available && series.panel_apply_initial_values[segment],
    )
    selected_preset = series.panel_presets[segment]
    if selected_preset ∉ ("none", "custom") &&
       series_preset_by_key(model_key, selected_preset) === nothing
        selected_preset = "none"
        series.panel_presets[segment] = selected_preset
    end
    set_if_changed!(controller.bindings.series_selected_preset, selected_preset)

    if series.published_results_revision != series.results_revision ||
       series.published_results_segment != series.selected_segment
        set_if_changed!(
            controller.bindings.series_results_json,
            series_results_json(controller),
        )
        series.published_results_revision = series.results_revision
        series.published_results_segment = series.selected_segment
    end

    return nothing
end


function latest_runtime_snapshots(app::RD.AppState)
    snapshots = RD.SimulationSnapshot[]

    for runtime in app.segment_runtimes
        lock(runtime.snapshot_lock)
        try
            runtime.latest_snapshot[] === nothing || push!(snapshots, runtime.latest_snapshot[])
        finally
            unlock(runtime.snapshot_lock)
        end
    end

    return snapshots
end


function refresh_series_residual_status!(controller::QMLController, running::Bool)
    series = controller.series
    panel = controller.app.plot_panel
    status_snapshots = RD.SimulationSnapshot[]
    residuals = Float64[]

    lock(series.lock)
    try
        residuals = copy(series.latest_residuals)
        if running
            length(series.base_snapshots) == length(panel.segment_status_observables) ||
                return nothing
            for segment in eachindex(series.base_snapshots)
                candidate = series.latest_snapshots[segment]
                push!(
                    status_snapshots,
                    candidate === nothing ? series.base_snapshots[segment] : candidate,
                )
            end
        end
    finally
        unlock(series.lock)
    end

    # Outside a run the status of the live state carries the residuals of the
    # last run; once its results are cleared there is nothing to add.
    if !running
        any(isfinite, residuals) || return nothing
        status_snapshots = latest_runtime_snapshots(controller.app)
    end

    length(residuals) == length(status_snapshots) == length(panel.segment_status_observables) ||
        return nothing
    label = running ? "R" : "R(last)"
    for segment in eachindex(status_snapshots)
        value = residuals[segment]
        formatted = isfinite(value) ? @sprintf("%.2e", value) : "--"
        status = RD.compact_segment_status(status_snapshots[segment]) *
                 "\n" * label * "=" * formatted
        set_if_changed!(panel.segment_status_observables[segment], status)
    end

    return nothing
end


function refresh_series_runtime!(controller::QMLController)
    controller.bindings.series_mode[] || return nothing
    series = controller.series
    snapshots = RD.SimulationSnapshot[]
    running = series.running[]
    task = series.task_ref[]
    publish_snapshots = false
    publish_residuals = false
    publish_profiles = false
    profiles = nothing

    lock(series.lock)
    try
        if running && series.settings.live_preview &&
           series.snapshot_revision != series.published_snapshot_revision &&
           length(series.latest_snapshots) == length(controller.app.simulations) &&
           all(snapshot -> snapshot !== nothing, series.latest_snapshots)
            snapshots = RD.SimulationSnapshot[
                snapshot::RD.SimulationSnapshot for snapshot in series.latest_snapshots
            ]
            series.published_snapshot_revision = series.snapshot_revision
            publish_snapshots = true
        end

        if running && series.settings.live_preview &&
           series.profile_revision != series.published_profile_revision
            profiles = series.latest_profiles
            series.published_profile_revision = series.profile_revision
            publish_profiles = true
        end

        if running && series.residual_revision != series.published_residual_revision
            series.published_residual_revision = series.residual_revision
            publish_residuals = true
        end
    finally
        unlock(series.lock)
    end

    if publish_snapshots &&
       length(snapshots) == length(controller.app.simulations) &&
       !isempty(snapshots)
        try
            snapshot = RD.partition_snapshot_from_segments(snapshots, series.generation)
            RD.refresh_app_from_snapshot!(controller.app, snapshot)
        catch error
            report_error!(controller, "Series display refresh failed", error)
        end
    end

    if publish_profiles
        try
            profiles === nothing ?
                RD.refresh_spatial_profile_panel!(controller.app) :
                RD.show_spatial_profiles!(controller.app, profiles)
        catch error
            report_error!(controller, "Series profile display failed", error)
        end
    end

    if publish_snapshots || publish_residuals
        try
            refresh_series_residual_status!(controller, running)
        catch error
            report_error!(controller, "Series residual display failed", error)
        end
    end

    if !running && task !== nothing && istaskdone(task)
        finish_series_run!(controller)
    elseif !running && task === nothing &&
           !series_results_match_panels(series, controller.app)
        # A safety net: no result may outlive the panels it belongs to.
        clear_series_results!(controller)
    end

    refresh_series_bindings!(controller)

    return nothing
end


function clear_series_previews!(controller::QMLController)
    controller.series.pending_preview_update = :clear
    return nothing
end


function show_series_previews!(controller::QMLController)
    controller.series.pending_preview_update = :show
    return nothing
end


function apply_pending_series_preview_update!(controller::QMLController)
    request = controller.series.pending_preview_update
    request === :none && return nothing
    controller.series.pending_preview_update = :none

    try
        request === :show && !controller.app.worker_running[] ?
            show_series_previews_now!(controller) :
            clear_series_previews_now!(controller)
    catch error
        report_error!(controller, "Series preview update failed", error)
    end

    return nothing
end


function clear_series_previews_now!(controller::QMLController)
    series = controller.series

    for item in series.preview_items
        try
            RD.delete_plot_panel_item!(item)
        catch error
            @debug "Series preview item was already deleted." exception = error
        end
    end

    empty!(series.preview_items)
    empty!(series.preview_geometry)
    RD.rescale_solution_axes!(controller.app.plot_panel, controller.app.simulations)
    return nothing
end


function series_preview_anchor(
    controller::QMLController,
    perturbation::RD.SeriesPerturbation,
)
    # With "Preset" a realization starts from the preset value, not from the
    # plotted live state.
    model = controller.app.simulations[perturbation.segment].model
    applied = applied_panel_initial_values(controller.series, perturbation.segment)
    initial_value = get(applied, model.varnames[perturbation.variable], nothing)
    initial_value === nothing || return initial_value

    panel = controller.app.plot_panel
    x = panel.segment_x_observables[perturbation.segment][]
    y = panel.segment_observables[perturbation.segment][perturbation.variable][]
    centre = perturbation.position * series_display_length(controller.app, perturbation.segment)
    index = RD.nearest_grid_index(x, centre)
    return y[index]
end


function add_series_preview_box!(
    controller::QMLController,
    perturbation::RD.SeriesPerturbation,
    width::Float64,
    height::Float64;
    color,
    linewidth::Float64,
)
    panel = controller.app.plot_panel
    axis = panel.segment_axes[perturbation.segment][perturbation.variable]
    base = series_preview_anchor(controller, perturbation)
    # Position and width are fractions of the panel length.
    displayed_length = series_display_length(controller.app, perturbation.segment)
    centre = perturbation.position * displayed_length
    left = centre - width * displayed_length / 2
    right = centre + width * displayed_length / 2
    top = base + height
    x = [left, right, right, left, left]
    y = [base, base, top, top, base]
    outline = lines!(axis, x, y; color = color, linestyle = :dash, linewidth = linewidth)
    push!(controller.series.preview_items, outline)
    return nothing
end


function show_series_previews_now!(controller::QMLController)
    series = controller.series
    clear_series_previews_now!(controller)

    for perturbation in series.perturbations
        clamp_series_perturbation!(controller.app, perturbation) || continue
        add_series_preview_box!(
            controller,
            perturbation,
            perturbation.width_max,
            perturbation.height_max;
            color = (:gray, 0.40),
            linewidth = 1.5,
        )
        add_series_preview_box!(
            controller,
            perturbation,
            perturbation.width_min,
            perturbation.height_min;
            color = (:gray, 0.80),
            linewidth = 2.0,
        )
    end

    rescale_series_preview_axes!(controller)
    series.preview_geometry = series_preview_geometry(controller)

    return nothing
end


function series_preview_geometry(controller::QMLController)
    # Everything the boxes are drawn from: comparing it notices a click on a
    # plot, a new initial condition, a rescaled domain or rebuilt panels, wherever
    # they came from.
    app = controller.app
    geometry = Float64[app.generation[]]

    for perturbation in controller.series.perturbations
        perturbation.segment <= length(app.simulations) || continue
        append!(
            geometry,
            (
                perturbation.segment,
                perturbation.variable,
                perturbation.position,
                perturbation.width_min,
                perturbation.width_max,
                perturbation.height_min,
                perturbation.height_max,
                series_display_length(app, perturbation.segment),
                series_preview_anchor(controller, perturbation),
            ),
        )
    end

    return geometry
end


function refresh_series_overlays!(controller::QMLController)
    # What series mode adds to the ordinary refresh, which fits the y axes to
    # the solution alone. The boxes stay hidden while the main simulation
    # plays: its profile would leave them behind at once.
    series = controller.series
    controller.bindings.series_mode[] && !series.running[] || return nothing

    try
        if series.editor_open
            if controller.app.worker_running[]
                isempty(series.preview_items) || clear_series_previews!(controller)
            else
                isequal(series_preview_geometry(controller), series.preview_geometry) ||
                    show_series_previews!(controller)
                isempty(series.preview_items) || rescale_series_preview_axes!(controller)
            end
        end

        refresh_series_residual_status!(controller, false)
    catch error
        report_error!(controller, "Series preview refresh failed", error)
    end

    return nothing
end


function rescale_series_preview_axes!(controller::QMLController)
    app = controller.app
    panel = app.plot_panel
    nvars = app.sim.model.nvars

    for variable in 1:nvars
        values = Float64[]
        axes = Axis[]

        for segment in eachindex(app.simulations)
            append!(values, RD.finite_values(panel.segment_observables[segment][variable][]))
            append!(
                values,
                RD.finite_values(panel.segment_preview_observables[segment][variable][]),
            )

            for perturbation in controller.series.perturbations
                perturbation.segment == segment || continue
                perturbation.variable == variable || continue
                base = series_preview_anchor(controller, perturbation)
                push!(values, base, base + perturbation.height_min, base + perturbation.height_max)
            end

            push!(axes, panel.segment_axes[segment][variable])
        end

        RD.set_axes_y_limits_from_values!(axes, values)
    end

    return nothing
end


function update_series_position_marker!(controller::QMLController)
    series = controller.series
    segment = series.selected_segment
    1 <= segment <= length(controller.app.simulations) || return nothing
    sim = controller.app.simulations[segment]
    displayed_length = series_display_length(controller.app, segment)
    displayed_length > 0.0 && sim.N >= 5 || return nothing
    index = clamp(
        round(Int, series.selected_position * sim.N),
        2,
        sim.N - 2,
    )

    # Reuse the established split-marker implementation verbatim.  It owns
    # the persistent Makie plot, token-based fade and lifecycle handling.
    RD.update_split_marker!(controller.app, segment, index)
    controller.app.plot_panel.split_marker_color_observables[segment][] = :gold

    return nothing
end


function clear_series_position_marker!(controller::QMLController)
    RD.update_split_marker!(controller.app, 0, 0)
    return nothing
end


function update_series_editor_selection!(controller::QMLController)
    series = controller.series
    perturbation = series_perturbation_by_id(series, series.selected_perturbation_id)

    if perturbation !== nothing
        series.selected_segment = perturbation.segment
        series.selected_variable = perturbation.variable
        series.selected_position = perturbation.position
    end

    series.selected_segment = clamp(series.selected_segment, 1, length(controller.app.simulations))
    series.selected_variable = clamp(
        series.selected_variable,
        1,
        controller.app.simulations[series.selected_segment].model.nvars,
    )
    series.selected_position = clamp(series.selected_position, 0.0, 1.0)
    return nothing
end


function open_series_editor!(controller::QMLController)
    series = controller.series
    series.running[] && return nothing
    series.editor_open = true
    update_series_editor_selection!(controller)
    series.status = isempty(series.perturbations) ?
        "Add at least one perturbation" :
        "Ready to run"
    controller.series.editor_open && show_series_previews!(controller)
    refresh_series_bindings!(controller)
    return nothing
end


function close_series_editor!(controller::QMLController)
    controller.series.editor_open = false
    clear_series_previews!(controller)
    clear_series_position_marker!(controller)
    return nothing
end


function set_series_mode!(controller::QMLController, enabled)
    return guarded_action(controller, "Series mode change failed") do
        app = controller.app
        series = controller.series
        enabled = Bool(enabled)
        enabled == controller.bindings.series_mode[] && return nothing

        if enabled
            # Nothing is captured here: Start takes everything from the live
            # state. Until then the main window keeps working as usual.
            RD.stop_worker!(app; wait = true)
            lock(series.lock)
            try
                series.task_ref[] = nothing
                series.stop_requested[] = false
                reset_series_results_locked!(series, panel_point_counts(app))
                series.latest_residuals = fill(NaN, length(app.simulations))
                series.residual_revision += 1
            finally
                unlock(series.lock)
            end
            show_live_series_display!(controller)
            controller.bindings.series_mode[] = true
            open_series_editor!(controller)
        else
            # Leaving series mode is blocked until the running series is stopped.
            series.running[] && return nothing
            task = series.task_ref[]
            task !== nothing && !istaskdone(task) && wait(task)
            task === nothing || finish_series_run!(controller)
            controller.bindings.series_mode[] = false
            close_series_editor!(controller)
            show_live_series_display!(controller)
            refresh_series_bindings!(controller)
            refresh_qml_state!(controller)
        end

        return nothing
    end
end


function select_series_segment!(controller::QMLController, segment_value)
    # One selection drives the perturbation editor and the results view.
    # During a run it only switches the displayed results.
    series = controller.series
    series.selected_segment = clamp(Int(segment_value), 1, length(controller.app.simulations))

    if series.running[]
        refresh_series_bindings!(controller)
        return nothing
    end

    series.selected_variable = clamp(
        series.selected_variable,
        1,
        controller.app.simulations[series.selected_segment].model.nvars,
    )
    update_series_position_marker!(controller)
    refresh_series_bindings!(controller)
    return nothing
end


function select_series_variable!(controller::QMLController, variable_value)
    series = controller.series
    series.running[] && return nothing
    nvars = controller.app.simulations[series.selected_segment].model.nvars
    series.selected_variable = clamp(Int(variable_value), 1, nvars)
    update_series_position_marker!(controller)
    refresh_series_bindings!(controller)
    return nothing
end


function set_series_position!(controller::QMLController, value)
    return guarded_action(controller, "Series-position change failed") do
        series = controller.series
        series.running[] && return nothing
        # A fraction of the panel length, like the position of a perturbation.
        series.selected_position = clamp(
            parse_finite_qml_number(value, "Series position"),
            0.0,
            1.0,
        )

        # The slider only chooses the centre for the *next* perturbation.
        # Existing perturbations and their dashed preview boxes are never
        # moved or recreated while the user drags it.
        update_series_position_marker!(controller)
        refresh_series_bindings!(controller)
    end
end


function series_preset_perturbations(
    controller::QMLController,
    preset::SeriesPresetDefinition,
    segment::Int,
)
    model = controller.app.simulations[segment].model
    perturbations = RD.SeriesPerturbation[]

    for definition in preset.perturbations
        variable = findfirst(==(definition.variable_name), model.varnames)
        variable === nothing &&
            error(
                "Preset $(preset.name) requires variable '$(definition.variable_name)', " *
                "which is unavailable in the selected model.",
            )
        push!(
            perturbations,
            RD.SeriesPerturbation(
                id = 0,
                segment = segment,
                variable = variable,
                position = definition.position_fraction,
                width_min = definition.width_min_fraction,
                width_max = definition.width_max_fraction,
                height_min = definition.height_min,
                height_max = definition.height_max,
            ),
        )
    end

    return perturbations
end


function select_series_preset!(controller::QMLController, preset_key_value)
    # Replaces the perturbations and initial values of the selected panel
    # only; every other panel keeps its own preset.
    return guarded_action(controller, "Series preset selection failed") do
        series = controller.series
        series.running[] && return nothing
        ensure_panel_preset_state!(controller)
        preset_key = String(preset_key_value)
        segment = clamp(series.selected_segment, 1, length(controller.app.simulations))
        model = controller.app.simulations[segment].model

        if preset_key == "none"
            perturbations = RD.SeriesPerturbation[]
            initial_values = Dict{String, Float64}()
            apply_initial_values = false
            status = "Cleared the perturbations of panel $segment"
        elseif preset_key == "custom"
            custom = series.custom_sets[segment]
            custom === nothing && error("Panel $segment has no custom perturbations.")
            perturbations = deepcopy(custom.perturbations)
            initial_values = copy(custom.initial_values)
            apply_initial_values = custom.apply_initial_values
            status = "Restored the custom perturbations of panel $segment"
        else
            model_key = controller.bindings.active_model_key[]
            preset = series_preset_by_key(model_key, preset_key)
            preset === nothing && error("This Series preset is not available for the selected model.")
            perturbations = series_preset_perturbations(controller, preset, segment)
            initial_values = copy(preset.initial_values)
            apply_initial_values = !isempty(initial_values)
            status = "Loaded preset $(preset.name) into panel $segment"
        end

        for variable_name in keys(initial_values)
            variable_name in model.varnames ||
                error("The preset requires variable '$variable_name', which is unavailable in this model.")
        end

        filter!(perturbation -> perturbation.segment != segment, series.perturbations)

        for perturbation in perturbations
            perturbation.id = series.next_perturbation_id
            perturbation.segment = segment
            series.next_perturbation_id += 1
            clamp_series_perturbation!(controller.app, perturbation)
            push!(series.perturbations, perturbation)
        end

        series.selected_perturbation_id = isempty(perturbations) ? 0 : last(perturbations).id
        series.panel_presets[segment] = preset_key
        series.panel_initial_values[segment] = initial_values
        series.panel_apply_initial_values[segment] = apply_initial_values
        clear_series_results!(controller)
        series.status = isempty(series.perturbations) ? "Add at least one perturbation" : status
        update_series_editor_selection!(controller)
        series.editor_open && show_series_previews!(controller)
        clear_series_position_marker!(controller)
        refresh_series_bindings!(controller)
    end
end


function set_series_use_preset_initial!(controller::QMLController, use_preset)
    # The switch of the selected panel. The values stay remembered in both
    # positions; without any, only "Current state" exists.
    return guarded_action(controller, "Initial-condition change failed") do
        series = controller.series
        series.running[] && return nothing
        ensure_panel_preset_state!(controller)
        segment = clamp(series.selected_segment, 1, length(controller.app.simulations))
        apply_values = Bool(use_preset) && !isempty(series.panel_initial_values[segment])
        series.panel_apply_initial_values[segment] == apply_values && return nothing
        series.panel_apply_initial_values[segment] = apply_values
        series.panel_presets[segment] == "custom" && mark_panel_custom!(controller, segment)
        clear_series_results!(controller)
        series.editor_open && show_series_previews!(controller)
        refresh_series_bindings!(controller)
    end
end


function add_series_perturbation!(controller::QMLController)
    series = controller.series
    series.running[] && return nothing
    segment = series.selected_segment
    variable = series.selected_variable
    perturbation = RD.SeriesPerturbation(
        id = series.next_perturbation_id,
        segment = segment,
        variable = variable,
        position = round(series.selected_position; digits = SERIES_POSITION_DIGITS),
        width_min = 0.05,
        width_max = 0.10,
        height_min = 1.0,
        height_max = 2.0,
    )
    clamp_series_perturbation!(controller.app, perturbation)
    push!(series.perturbations, perturbation)
    series.next_perturbation_id += 1
    series.selected_perturbation_id = perturbation.id
    mark_panel_custom!(controller, perturbation.segment)
    series.status = "Ready to run"
    series.editor_open && show_series_previews!(controller)
    clear_series_position_marker!(controller)
    refresh_series_bindings!(controller)
    return nothing
end


function delete_series_perturbation!(controller::QMLController, id_value)
    series = controller.series
    series.running[] && return nothing
    id = Int(id_value)
    deleted = series_perturbation_by_id(series, id)
    deleted === nothing && return nothing
    filter!(perturbation -> perturbation.id != id, series.perturbations)
    series.selected_perturbation_id == id && (series.selected_perturbation_id = 0)
    mark_panel_custom!(controller, deleted.segment)
    series.status = isempty(series.perturbations) ? "Add at least one perturbation" : "Ready to run"
    series.editor_open && show_series_previews!(controller)
    refresh_series_bindings!(controller)
    return nothing
end


function parse_series_width(value, label::AbstractString)
    width = parse_finite_qml_number(value, label)
    0.0 < width <= 1.0 ||
        error("$label is a fraction of the panel length and must be greater than 0 and at most 1.")
    return max(round(width; digits = SERIES_WIDTH_DIGITS), SERIES_WIDTH_STEP)
end


function parse_series_position(value)
    position = parse_finite_qml_number(value, "Position")
    0.0 <= position <= 1.0 ||
        error("Position is a fraction of the panel length and must be between 0 and 1.")
    return round(position; digits = SERIES_POSITION_DIGITS)
end


function update_series_perturbation!(controller::QMLController, id_value, field_value, value)
    series = controller.series
    series.running[] && return nothing
    perturbation = series_perturbation_by_id(series, Int(id_value))
    perturbation === nothing && return nothing
    field = String(field_value)
    previous_segment = perturbation.segment
    # Worked out on a copy: a refused edit leaves the perturbation as it was.
    edited = deepcopy(perturbation)

    if field == "panel"
        # Fractions of the panel length need no rescaling for another panel.
        edited.segment = clamp(Int(value), 1, length(controller.app.simulations))
    elseif field == "variable"
        edited.variable = Int(value)
    elseif field == "position"
        edited.position = parse_series_position(value)
    elseif field == "widthMin"
        edited.width_min = parse_series_width(value, "Width minimum")
    elseif field == "widthMax"
        edited.width_max = parse_series_width(value, "Width maximum")
    elseif field == "heightMin"
        edited.height_min = round(
            parse_finite_qml_number(value, "Height minimum");
            digits = SERIES_HEIGHT_DIGITS,
        )
    elseif field == "heightMax"
        edited.height_max = round(
            parse_finite_qml_number(value, "Height maximum");
            digits = SERIES_HEIGHT_DIGITS,
        )
    else
        error("Unknown series-perturbation field: $field")
    end

    clamp_series_perturbation!(controller.app, edited)
    edited.width_min <= edited.width_max ||
        error("Width minimum cannot exceed width maximum.")
    edited.height_min <= edited.height_max ||
        error("Height minimum cannot exceed height maximum.")

    for name in fieldnames(RD.SeriesPerturbation)
        setfield!(perturbation, name, getfield(edited, name))
    end

    series.selected_perturbation_id = perturbation.id
    mark_panel_custom!(controller, perturbation.segment)
    previous_segment == perturbation.segment || mark_panel_custom!(controller, previous_segment)
    update_series_editor_selection!(controller)
    series.editor_open && show_series_previews!(controller)
    refresh_series_bindings!(controller)
    return nothing
end


function set_series_integer_setting!(controller::QMLController, field::Symbol, value)
    return guarded_action(controller, "Series setting change failed") do
        _set_series_integer_setting!(controller, field, value)
    end
end


function _set_series_integer_setting!(controller::QMLController, field::Symbol, value)
    series = controller.series
    # Starting a series moves focus out of a settings field, which makes Qt
    # emit editingFinished: ignore such a late write instead of reporting it.
    series.running[] && return nothing
    integer = Int(round(parse_finite_qml_number(value, String(field))))
    integer >= 1 || error("$(field) must be at least one.")

    if field == :run_count
        series.settings.run_count = integer
    elseif field == :maximum_steps
        series.settings.maximum_steps_per_panel = integer
    elseif field == :required_checks
        series.settings.required_consecutive_checks = integer
    elseif field == :head_variable
        nvars = controller.app.sim.model.nvars
        series.settings.head_variable = clamp(integer, 1, nvars)
    else
        error("Unknown series integer setting: $field")
    end

    refresh_series_bindings!(controller)
    return nothing
end


function set_series_float_setting!(controller::QMLController, field::Symbol, value)
    return guarded_action(controller, "Series setting change failed") do
        _set_series_float_setting!(controller, field, value)
    end
end


function _set_series_float_setting!(controller::QMLController, field::Symbol, value)
    series = controller.series
    # Starting a series moves focus out of a settings field, which makes Qt
    # emit editingFinished: ignore such a late write instead of reporting it.
    series.running[] && return nothing
    number = parse_finite_qml_number(value, String(field))
    number > 0.0 || error("$(field) must be positive.")

    if field == :maximum_time
        series.settings.maximum_time = number
    elseif field == :check_interval
        series.settings.check_interval = number
    elseif field == :dtmax
        series.settings.dtmax = number
    elseif field == :tolerance
        series.settings.tolerance = number
    else
        error("Unknown series floating-point setting: $field")
    end

    refresh_series_bindings!(controller)
    return nothing
end


function set_series_seed!(controller::QMLController, value)
    series = controller.series
    series.running[] && return nothing
    parsed = tryparse(UInt64, strip(String(value)))
    parsed === nothing && error("Random seed must be a non-negative integer.")
    series.settings.seed = parsed
    refresh_series_bindings!(controller)
    return nothing
end


function set_series_live_preview!(controller::QMLController, enabled)
    controller.series.running[] && return nothing
    controller.series.settings.live_preview = Bool(enabled)
    refresh_series_bindings!(controller)
    return nothing
end


function series_runtime_perturbations(
    controller::QMLController,
    templates::Vector{RD.SeriesSegmentTemplate},
)
    runtime_perturbations = RD.SeriesPerturbation[]

    for perturbation in controller.series.perturbations
        template = templates[perturbation.segment]
        solver_length = template.boundary_condition == :periodic ?
            last(template.x) - first(template.x) + template.dx :
            max(last(template.x) - first(template.x), 0.0)
        push!(
            runtime_perturbations,
            RD.SeriesPerturbation(
                id = perturbation.id,
                segment = perturbation.segment,
                variable = perturbation.variable,
                position = first(template.x) + perturbation.position * solver_length,
                width_min = perturbation.width_min * solver_length,
                width_max = perturbation.width_max * solver_length,
                height_min = perturbation.height_min,
                height_max = perturbation.height_max,
            ),
        )
    end

    return runtime_perturbations
end


function capture_series_base!(controller::QMLController)
    app = controller.app
    RD.stop_worker!(app; wait = true)
    templates = RD.SeriesSegmentTemplate[]
    snapshots = RD.SimulationSnapshot[]

    lock(app.simlock)
    try
        app.generation[] += 1
        generation = app.generation[]

        for segment in eachindex(app.simulations)
            runtime = app.segment_runtimes[segment]
            lock(runtime.lock)
            try
                push!(templates, RD.make_series_template(app.simulations[segment]))
                push!(snapshots, RD.make_snapshot(app.simulations[segment], generation))
            finally
                unlock(runtime.lock)
            end
        end

        return templates, snapshots, generation
    finally
        unlock(app.simlock)
    end
end


function record_series_outcomes!(
    controller::QMLController,
    outcomes::Vector{RD.SeriesPanelOutcome},
    templates::Vector{RD.SeriesSegmentTemplate},
    head_variable::Int,
)
    series = controller.series

    lock(series.lock)
    try
        for segment in eachindex(outcomes)
            outcome = outcomes[segment]
            snapshot = outcome.final_snapshot
            U = reshape(snapshot.y, snapshot.N, snapshot.nvars)
            push!(series.patterns[segment], copy(U[:, head_variable]))
            push!(series.pattern_converged[segment], outcome.converged)

            outcome.converged || begin
                series.not_converged_counts[segment] += 1
                continue
            end
            template = templates[segment]
            RD.assign_head_configuration!(
                series.configuration_groups[segment],
                RD.normalized_head_positions(outcome.heads, template.x, template.boundary_condition),
                template.boundary_condition == :periodic,
            )

            head_count = length(outcome.heads)
            counts = series.head_count_counts[segment]
            counts[head_count] = get(counts, head_count, 0) + 1

            for head in outcome.heads
                index = RD.nearest_grid_index(templates[segment].x, head.position)
                series.location_counts[segment][index] += 1
            end
        end

        series.completed_runs += 1
        series.status = "Run $(series.completed_runs)/$(series.settings.run_count) complete"
        series.results_revision += 1
    finally
        unlock(series.lock)
    end

    return nothing
end


function reset_series_results_locked!(
    series::SeriesController,
    point_counts::Vector{Int},
)
    # The caller holds series.lock. One empty entry per panel.
    series.completed_runs = 0
    series.location_counts = [zeros(Int, count) for count in point_counts]
    series.head_count_counts = [Dict{Int, Int}() for _ in point_counts]
    series.not_converged_counts = zeros(Int, length(point_counts))
    series.patterns = [Vector{Float64}[] for _ in point_counts]
    series.pattern_converged = [Bool[] for _ in point_counts]
    series.configuration_groups = [RD.HeadConfigurationGroup[] for _ in point_counts]
    series.results_revision += 1
    return nothing
end


panel_point_counts(app::RD.AppState) = Int[sim.N for sim in app.simulations]


function series_results_match_panels(series::SeriesController, app::RD.AppState)
    return length.(series.location_counts) == panel_point_counts(app)
end


function clear_series_results!(controller::QMLController)
    series = controller.series
    series.running[] && return nothing

    lock(series.lock)
    try
        # The status of the last run would no longer describe the window.
        series.completed_runs > 0 && (series.status = isempty(series.perturbations) ?
            "Add at least one perturbation" : "Ready to run")
        # Keep one (empty) result entry per panel, so the series window keeps
        # showing empty charts instead of hiding them.
        point_counts = panel_point_counts(controller.app)
        reset_series_results_locked!(series, point_counts)
        series.latest_residuals = fill(NaN, length(point_counts))
        series.residual_revision += 1
    finally
        unlock(series.lock)
    end

    refresh_series_bindings!(controller)
    return nothing
end


function capture_live_snapshots(app::RD.AppState)
    # runtime.lock keeps a running segment worker out, so this also works while
    # the main simulation is playing.
    snapshots = RD.SimulationSnapshot[]

    lock(app.simlock)
    try
        for segment in eachindex(app.simulations)
            runtime = app.segment_runtimes[segment]
            lock(runtime.lock)
            try
                push!(snapshots, RD.make_snapshot(app.simulations[segment], app.generation[]))
            finally
                unlock(runtime.lock)
            end
        end
    finally
        unlock(app.simlock)
    end

    return snapshots
end


function show_live_series_display!(controller::QMLController)
    # Series realizations are never adopted by the main solvers: this returns
    # the main plots and the ordinary refresh to the live state.
    series = controller.series
    app = controller.app
    snapshots = capture_live_snapshots(app)

    lock(series.lock)
    try
        series.latest_snapshots = Union{Nothing, RD.SimulationSnapshot}[snapshots...]
        series.snapshot_revision += 1
        series.published_snapshot_revision = series.snapshot_revision
        series.latest_profiles = nothing
        series.profile_revision += 1
        series.published_profile_revision = series.profile_revision
    finally
        unlock(series.lock)
    end

    RD.store_runtime_snapshots!(app, snapshots)
    RD.refresh_app_from_snapshot!(
        app,
        RD.partition_snapshot_from_segments(snapshots, app.generation[]),
    )
    RD.refresh_spatial_profile_panel!(app)
    return nothing
end


function finish_series_run!(controller::QMLController)
    # The first event-loop pass after a run ended: unlock the main window and
    # show the live state again, which also keeps later graphics actions from
    # being mistaken for the end of this run.
    series = controller.series
    series.task_ref[] = nothing
    controller.app.mouse_perturbations_enabled[] = true
    controller.graphics_busy[] = false

    try
        show_live_series_display!(controller)
    catch error
        report_error!(controller, "Series display refresh failed", error)
    end

    if series.editor_open
        show_series_previews!(controller)
        update_series_position_marker!(controller)
    end

    refresh_qml_state!(controller)
    return nothing
end


function capture_series_templates!(controller::QMLController)
    # Everything a series uses comes from here, at the click on Start: state,
    # parameters, profiles, panels, boundary conditions and the domain.
    templates, base_snapshots, generation = capture_series_base!(controller)
    ensure_panel_preset_state!(controller)

    for (segment, template) in enumerate(templates)
        apply_series_initial_values!(
            [template],
            applied_panel_initial_values(controller.series, segment),
        )
    end

    return templates, base_snapshots, generation
end


function start_series!(controller::QMLController)
    series = controller.series
    app = controller.app
    series.running[] && return nothing
    previous_task = series.task_ref[]
    previous_task !== nothing && !istaskdone(previous_task) && wait(previous_task)
    previous_task === nothing || finish_series_run!(controller)
    # A queued plot rebuild would end by clearing graphics_busy during the run.
    controller.graphics_busy[] && error("Wait until the plots have been updated.")
    isempty(series.perturbations) && error("Add at least one perturbation before starting a series.")
    RD.validate_series_settings(series.settings, app.sim.model.nvars)

    for perturbation in series.perturbations
        clamp_series_perturbation!(app, perturbation) ||
            error("A perturbation points to an unavailable panel.")
    end

    templates, base_snapshots, generation = capture_series_templates!(controller)
    runtime_perturbations = series_runtime_perturbations(controller, templates)
    run_setup = series_run_setup(controller, templates)
    app.mouse_perturbations_enabled[] = false
    RD.clear_perturbation_previews!(app.plot_panel)
    clear_series_previews!(controller)
    clear_series_position_marker!(controller)
    # The capture moved to a new generation; the ordinary refresh follows it.
    RD.store_runtime_snapshots!(app, base_snapshots)
    run_indices = 1:series.settings.run_count

    lock(series.lock)
    try
        series.base_snapshots = base_snapshots
        series.run_setup = run_setup
        series.latest_snapshots = Union{Nothing, RD.SimulationSnapshot}[base_snapshots...]
        series.snapshot_revision += 1
        series.published_snapshot_revision = -1
        series.generation = generation
        reset_series_results_locked!(series, Int[length(template.x) for template in templates])
        series.status = "Running 0/$(series.settings.run_count)"
        series.stop_requested[] = false
        series.running[] = true
        series.latest_residuals = fill(NaN, length(templates))
        series.residual_revision += 1
    finally
        unlock(series.lock)
    end

    controller.graphics_busy[] = true
    refresh_series_bindings!(controller)
    settings = deepcopy(series.settings)
    perturbations = deepcopy(runtime_perturbations)

    series.task_ref[] = Threads.@spawn begin
        stopped = false

        try
            for run_index in run_indices
                series.stop_requested[] && (stopped = true; break)
                lock(series.lock)
                try
                    fill!(series.latest_residuals, NaN)
                    series.residual_revision += 1
                finally
                    unlock(series.lock)
                end
                outcomes = RD.run_series_realization!(
                    templates,
                    perturbations,
                    settings,
                    generation,
                    run_index;
                    cancelled = () -> series.stop_requested[],
                    on_snapshot = (segment, snapshot) -> begin
                        lock(series.lock)
                        try
                            series.latest_snapshots[segment] = snapshot
                            series.snapshot_revision += 1
                        finally
                            unlock(series.lock)
                        end
                    end,
                    on_residual = (segment, residual) -> begin
                        lock(series.lock)
                        try
                            series.latest_residuals[segment] = residual
                            series.residual_revision += 1
                        finally
                            unlock(series.lock)
                        end
                    end,
                    on_profiles = profiles -> begin
                        lock(series.lock)
                        try
                            series.latest_profiles = profiles
                            series.profile_revision += 1
                        finally
                            unlock(series.lock)
                        end
                    end,
                )
                series.stop_requested[] && (stopped = true; break)
                record_series_outcomes!(controller, outcomes, templates, settings.head_variable)
            end
        catch error
            lock(series.lock)
            try
                series.status = "Series failed: $(sprint(showerror, error))"
            finally
                unlock(series.lock)
            end
            @error "Series worker failed." exception = (error, catch_backtrace())
        finally
            lock(series.lock)
            try
                if stopped
                    series.status = "Stopped after $(series.completed_runs)/$(settings.run_count) runs"
                elseif series.completed_runs == settings.run_count
                    series.status = "Completed $(settings.run_count) runs"
                end
                series.running[] = false
                series.results_revision += 1
            finally
                unlock(series.lock)
            end
        end
    end

    return nothing
end


function stop_series!(controller::QMLController)
    series = controller.series
    series.running[] || return nothing
    series.stop_requested[] = true
    series.status = "Stopping after the current safe solver step..."
    refresh_series_bindings!(controller)
    return nothing
end


function clear_series_perturbations!(controller::QMLController)
    series = controller.series
    empty!(series.perturbations)
    series.selected_perturbation_id = 0
    clear_panel_preset_state!(controller)
    series.selected_segment = 1
    series.selected_variable = 1
    series.selected_position = 0.5
    series.status = "Add at least one perturbation"
    clear_series_previews!(controller)
    clear_series_position_marker!(controller)
    clear_series_results!(controller)
    return nothing
end


function update_series_after_rebuild!(controller::QMLController)
    # Reset and a boundary-condition change rebuild the panels of the same
    # model. In series mode the setup of the panels that still exist stays;
    # outside it they clear it as they always did.
    controller.bindings.series_mode[] || return clear_series_perturbations!(controller)
    return keep_series_setup_of_remaining_panels!(controller)
end


function keep_series_setup_of_remaining_panels!(controller::QMLController)
    series = controller.series
    clear_series_position_marker!(controller)
    ensure_panel_preset_state!(controller)
    clamp_all_series_perturbations!(controller)
    series_perturbation_by_id(series, series.selected_perturbation_id) === nothing &&
        (series.selected_perturbation_id = 0)
    series.status = isempty(series.perturbations) ? "Add at least one perturbation" : "Ready to run"
    series.editor_open && show_series_previews!(controller)
    clear_series_results!(controller)
    return nothing
end


function clamp_all_series_perturbations!(controller::QMLController)
    series = controller.series
    filter!(perturbation -> clamp_series_perturbation!(controller.app, perturbation), series.perturbations)
    update_series_editor_selection!(controller)
    return nothing
end


function remap_series_after_split!(
    controller::QMLController,
    split_segment::Int,
    split_position::Float64,
    parent_length::Float64,
)
    # Positions and widths are fractions of a panel: convert them from the
    # parent panel to the half each perturbation falls into.
    # Both halves inherit the initial values; perturbations that came from a
    # preset no longer match it, so a non-empty panel becomes custom.
    series = controller.series
    ensure_panel_preset_state!(controller, length(controller.app.simulations) - 1)
    had_setup = series.panel_presets[split_segment] != "none"
    insert!(series.panel_presets, split_segment + 1, "none")
    insert!(series.panel_initial_values, split_segment + 1, copy(series.panel_initial_values[split_segment]))
    insert!(series.panel_apply_initial_values, split_segment + 1, series.panel_apply_initial_values[split_segment])
    insert!(series.custom_sets, split_segment + 1, nothing)

    left_length = series_display_length(controller.app, split_segment)
    right_length = series_display_length(controller.app, split_segment + 1)

    for perturbation in controller.series.perturbations
        if perturbation.segment > split_segment
            perturbation.segment += 1
        elseif perturbation.segment == split_segment
            centre = perturbation.position * parent_length
            if centre > split_position
                perturbation.segment += 1
                perturbation.position = (centre - split_position) / right_length
                perturbation.width_min *= parent_length / right_length
                perturbation.width_max *= parent_length / right_length
            else
                perturbation.position = centre / left_length
                perturbation.width_min *= parent_length / left_length
                perturbation.width_max *= parent_length / left_length
            end
        end
    end

    if had_setup
        mark_panel_custom!(controller, split_segment)
        mark_panel_custom!(controller, split_segment + 1)
    end

    clamp_all_series_perturbations!(controller)
    controller.series.editor_open && show_series_previews!(controller)
    clear_series_results!(controller)
    refresh_series_bindings!(controller)
    return nothing
end


function remap_series_after_merge!(
    controller::QMLController,
    left_segment::Int,
    left_display_length::Float64,
)
    right_segment = left_segment + 1
    series = controller.series
    ensure_panel_preset_state!(controller, length(controller.app.simulations) + 1)
    had_setup = series.panel_presets[left_segment] != "none" ||
                series.panel_presets[right_segment] != "none"
    same_initial_condition =
        series.panel_initial_values[left_segment] == series.panel_initial_values[right_segment] &&
        series.panel_apply_initial_values[left_segment] == series.panel_apply_initial_values[right_segment]
    if !same_initial_condition
        series.panel_initial_values[left_segment] = Dict{String, Float64}()
        series.panel_apply_initial_values[left_segment] = false
    end
    series.panel_presets[left_segment] = "none"
    series.custom_sets[left_segment] = nothing
    deleteat!(series.panel_presets, right_segment)
    deleteat!(series.panel_initial_values, right_segment)
    deleteat!(series.panel_apply_initial_values, right_segment)
    deleteat!(series.custom_sets, right_segment)

    # Positions and widths are fractions of a panel: convert them to the
    # merged panel.
    merged_length = series_display_length(controller.app, left_segment)
    right_display_length = merged_length - left_display_length

    for perturbation in controller.series.perturbations
        if perturbation.segment == left_segment
            perturbation.position *= left_display_length / merged_length
            perturbation.width_min *= left_display_length / merged_length
            perturbation.width_max *= left_display_length / merged_length
        elseif perturbation.segment == right_segment
            perturbation.segment = left_segment
            perturbation.position =
                (left_display_length + perturbation.position * right_display_length) / merged_length
            perturbation.width_min *= right_display_length / merged_length
            perturbation.width_max *= right_display_length / merged_length
        elseif perturbation.segment > right_segment
            perturbation.segment -= 1
        end
    end

    had_setup && mark_panel_custom!(controller, left_segment)

    clamp_all_series_perturbations!(controller)
    controller.series.editor_open && show_series_previews!(controller)
    clear_series_results!(controller)
    refresh_series_bindings!(controller)
    return nothing
end


function remap_series_after_swap!(controller::QMLController, left_segment::Int)
    right_segment = left_segment + 1
    series = controller.series
    ensure_panel_preset_state!(controller)

    for values in (
        series.panel_presets,
        series.panel_initial_values,
        series.panel_apply_initial_values,
        series.custom_sets,
    )
        values[left_segment], values[right_segment] = values[right_segment], values[left_segment]
    end

    for perturbation in controller.series.perturbations
        if perturbation.segment == left_segment
            perturbation.segment = right_segment
        elseif perturbation.segment == right_segment
            perturbation.segment = left_segment
        end
    end

    clamp_all_series_perturbations!(controller)
    controller.series.editor_open && show_series_previews!(controller)
    clear_series_results!(controller)
    refresh_series_bindings!(controller)
    return nothing
end


function remap_series_after_delete!(controller::QMLController, deleted_segment::Int)
    series = controller.series
    ensure_panel_preset_state!(controller, length(controller.app.simulations) + 1)
    deleteat!(series.panel_presets, deleted_segment)
    deleteat!(series.panel_initial_values, deleted_segment)
    deleteat!(series.panel_apply_initial_values, deleted_segment)
    deleteat!(series.custom_sets, deleted_segment)
    filter!(perturbation -> perturbation.segment != deleted_segment, controller.series.perturbations)

    for perturbation in controller.series.perturbations
        perturbation.segment > deleted_segment && (perturbation.segment -= 1)
    end

    clamp_all_series_perturbations!(controller)
    controller.series.editor_open && show_series_previews!(controller)
    clear_series_results!(controller)
    refresh_series_bindings!(controller)
    return nothing
end


function toggle_running!(controller::QMLController)
    return guarded_action(controller, "Simulation control failed") do
        controller.series.running[] && return nothing
        app = controller.app

        if app.worker_running[] || app.running[] || app.synchronization_running[]
            RD.stop_worker!(app; wait = true)
            RD.update_all_perturbation_previews!(app; stop_simulation = false)
        else
            RD.clear_perturbation_previews!(app.plot_panel)
            RD.start_worker!(
                app;
                steps_per_frame = controller.steps_per_frame,
                sleep_time = controller.worker_sleep_time,
            )
        end
    end
end


function reset_simulation!(controller::QMLController)
    return guarded_action(controller, "Reset failed") do
        RD.reset_initial_condition_app!(
            controller.app;
            plot_grid = controller.plot_grid,
            title_obs = controller.title_obs,
            steps_per_frame = controller.steps_per_frame,
            worker_sleep_time = controller.worker_sleep_time,
        )
        controller.selected_segment = 1
        update_model_bindings!(controller)
        update_partition_bindings!(controller; reset_index = true)
        update_series_after_rebuild!(controller)
    end
end


function select_model!(controller::QMLController, key)
    key_string = String(key)

    return guarded_action(controller, "Model change failed") do
        model = RD.get_model(controller.registry, key_string)
        RD.switch_model_app!(
            controller.app,
            controller.plot_grid,
            model;
            N = controller.app.initial_N,
            dtmax = RD.current_dtmax(controller.app.sim),
            reltol = controller.reltol,
            abstol = controller.abstol,
            boundary_condition = controller.app.sim.boundary_condition,
            title_obs = controller.title_obs,
            model_name_obs = controller.model_name_obs,
            bc_name_obs = controller.boundary_name_obs,
        )
        RD.set_diffusion_scale_app!(
            controller.app,
            controller.diffusion_scale;
            steps_per_frame = controller.steps_per_frame,
            worker_sleep_time = controller.worker_sleep_time,
        )
        controller.bindings.active_model_key[] = key_string
        controller.selected_segment = 1
        update_model_bindings!(controller)
        refresh_current_equation_image!(controller)
        update_partition_bindings!(controller; reset_index = true)
        clear_series_perturbations!(controller)
    end
end


function hard_reset!(controller::QMLController)
    # Reload the active model as if it were chosen again: default parameters
    # and profile set, one panel and no series perturbations.
    return select_model!(controller, controller.bindings.active_model_key[])
end


function select_boundary_condition!(controller::QMLController, label)
    label_string = String(label)

    return guarded_action(controller, "Boundary-condition change failed") do
        boundary_condition = RD.boundary_condition_from_label(label_string)
        RD.switch_boundary_condition_app!(
            controller.app,
            controller.plot_grid,
            boundary_condition;
            N = controller.app.initial_N,
            dtmax = RD.current_dtmax(controller.app.sim),
            reltol = controller.reltol,
            abstol = controller.abstol,
            title_obs = controller.title_obs,
            bc_name_obs = controller.boundary_name_obs,
        )
        RD.set_diffusion_scale_app!(
            controller.app,
            controller.diffusion_scale;
            steps_per_frame = controller.steps_per_frame,
            worker_sleep_time = controller.worker_sleep_time,
        )
        controller.selected_segment = 1
        update_partition_bindings!(controller; reset_index = true)
        refresh_current_equation_image!(controller)
        update_series_after_rebuild!(controller)
    end
end


function set_dt_exponent!(controller::QMLController, exponent)
    return guarded_action(controller, "Maximum time-step change failed") do
        RD.set_dtmax_app!(controller.app, 10.0^Float64(exponent))
    end
end


function set_domain_exponent!(controller::QMLController, exponent)
    return guarded_action(controller, "Domain rescale failed") do
        controller.series.running[] && error("Stop the Series run before changing the domain scale.")
        controller.diffusion_scale = 10.0^Float64(exponent)
        RD.set_diffusion_scale_app!(
            controller.app,
            controller.diffusion_scale;
            steps_per_frame = controller.steps_per_frame,
            worker_sleep_time = controller.worker_sleep_time,
        )
        if controller.bindings.series_mode[]
            clear_series_results!(controller)
            controller.series.editor_open && show_series_previews!(controller)
        end
        # Fractions are unchanged; the axis-unit values shown are not.
        refresh_series_bindings!(controller)
        update_model_bindings!(controller)
        refresh_current_equation_image!(controller)
    end
end


function set_domain_resolution!(controller::QMLController, value)
    resolution = Int(value)
    resolution in (16, 40, 100) || error("Unsupported domain-slider resolution.")
    controller.bindings.domain_resolution[] = resolution
    return nothing
end


function set_model_parameter_from_qml!(controller::QMLController, name, value_text)
    return guarded_action(controller, "Model parameter change failed") do
        controller.series.running[] && error("Stop the Series run before changing model parameters.")
        value = tryparse(Float64, String(value_text))
        value === nothing && error("Invalid parameter value: $(String(value_text))")
        RD.set_model_parameter_app!(
            controller.app,
            Symbol(String(name)),
            value;
            steps_per_frame = controller.steps_per_frame,
            worker_sleep_time = controller.worker_sleep_time,
        )
        clear_series_results!(controller)
        update_model_bindings!(controller)
        refresh_current_equation_image!(controller)
    end
end


function select_spatial_profile_set!(controller::QMLController, index::Int)
    return guarded_action(controller, "Profile set change failed") do
        controller.series.running[] && error("Stop the Series run before changing the profile set.")
        app = controller.app
        sets = app.sim.model.spatial_profile_sets
        1 <= index <= length(sets) || error("Invalid spatial profile set index: $index.")
        index == RD._active_spatial_profile_set_index(app.sim.params, sets) && return nothing
        RD.set_active_spatial_profile_set_app!(
            app,
            index;
            steps_per_frame = controller.steps_per_frame,
            worker_sleep_time = controller.worker_sleep_time,
        )
    end
end


function set_equation_values_visible!(controller::QMLController, visible)
    return guarded_action(controller, "Equation display change failed") do
        controller.bindings.equation_values_visible[] = Bool(visible)
        refresh_current_equation_image!(controller)
        refresh_profile_formula!(controller)
    end
end


function apply_constant_initial_condition!(
    controller::QMLController,
    zero_based_variable,
    value_text,
)
    return guarded_action(controller, "Steady-state change failed") do
        value = tryparse(Float64, String(value_text))
        value === nothing && error("Invalid numeric value: $(String(value_text))")
        variable = Int(zero_based_variable) + 1
        RD.set_single_constant_initial_condition_app!(
            controller.app;
            variable = variable,
            value = value,
            segment = controller.selected_segment,
            steps_per_frame = controller.steps_per_frame,
            worker_sleep_time = controller.worker_sleep_time,
        )
    end
end


function update_selected_segment!(
    controller::QMLController,
    segment::Integer;
    show_split_marker::Bool,
)
    count = length(controller.app.simulations)
    controller.selected_segment = clamp(Int(segment), 1, count)
    update_partition_bindings!(controller; reset_index = true)

    if show_split_marker
        RD.update_split_marker!(
            controller.app,
            controller.selected_segment,
            controller.split_index,
        )
    end

    return nothing
end


function select_segment!(controller::QMLController, one_based_segment)
    return guarded_action(controller, "Segment selection failed") do
        update_selected_segment!(
            controller,
            Int(one_based_segment);
            show_split_marker = false,
        )
    end
end


function select_split_segment!(controller::QMLController, one_based_segment)
    return guarded_action(controller, "Split-panel selection failed") do
        update_selected_segment!(
            controller,
            Int(one_based_segment);
            show_split_marker = true,
        )
    end
end


function change_selected_segment!(controller::QMLController, direction)
    return guarded_action(controller, "Segment selection failed") do
        update_selected_segment!(
            controller,
            controller.selected_segment + Int(direction);
            show_split_marker = true,
        )
    end
end


function set_split_index!(controller::QMLController, index)
    return guarded_action(controller, "Split-point change failed") do
        simulation = controller.app.simulations[controller.selected_segment]
        controller.split_index = clamp(Int(round(index)), 2, simulation.N - 2)
        update_partition_bindings!(controller)
        RD.update_split_marker!(
            controller.app,
            controller.selected_segment,
            controller.split_index,
        )
    end
end


function split_selected_segment!(controller::QMLController)
    return guarded_action(controller, "Domain split failed") do
        split_segment = controller.selected_segment
        old_display_length = series_display_length(controller.app, split_segment)
        old_point_count = controller.app.simulations[split_segment].N
        split_position = old_display_length * controller.split_index / old_point_count
        clear_series_position_marker!(controller)
        success = RD.split_domain_segment_app!(
            controller.app,
            controller.plot_grid,
            split_segment,
            controller.split_index;
            title_obs = controller.title_obs,
        )
        success || error("The selected split point is not valid.")
        update_partition_bindings!(controller; reset_index = true)
        remap_series_after_split!(controller, split_segment, split_position, old_display_length)
    end
end


function merge_boundary!(controller::QMLController, one_based_boundary)
    return guarded_action(controller, "Domain merge failed") do
        boundary = Int(one_based_boundary)
        left_display_length = series_display_length(controller.app, boundary)
        clear_series_position_marker!(controller)
        success = RD.merge_domain_segments_app!(
            controller.app,
            controller.plot_grid,
            boundary;
            title_obs = controller.title_obs,
        )
        success || error("The selected boundary is not valid.")
        controller.selected_segment = clamp(
            controller.selected_segment,
            1,
            length(controller.app.simulations),
        )
        update_partition_bindings!(controller; reset_index = true)
        remap_series_after_merge!(controller, boundary, left_display_length)
    end
end


function swap_boundary!(controller::QMLController, one_based_boundary)
    return guarded_action(controller, "Domain swap failed") do
        boundary = Int(one_based_boundary)
        selected_before_swap = controller.selected_segment
        clear_series_position_marker!(controller)
        success = RD.swap_adjacent_domain_segments_app!(
            controller.app,
            controller.plot_grid,
            boundary;
            title_obs = controller.title_obs,
            steps_per_frame = controller.steps_per_frame,
            worker_sleep_time = controller.worker_sleep_time,
        )
        success || error("The selected swap boundary is not valid.")
        controller.selected_segment = if selected_before_swap == boundary
            boundary + 1
        elseif selected_before_swap == boundary + 1
            boundary
        else
            selected_before_swap
        end
        update_partition_bindings!(controller; reset_index = true)
        remap_series_after_swap!(controller, boundary)
    end
end


function delete_selected_segment!(controller::QMLController)
    return guarded_action(controller, "Domain deletion failed") do
        deleted_segment = controller.selected_segment
        clear_series_position_marker!(controller)
        success = RD.delete_domain_segment_app!(
            controller.app,
            controller.plot_grid,
            deleted_segment;
            title_obs = controller.title_obs,
            steps_per_frame = controller.steps_per_frame,
            worker_sleep_time = controller.worker_sleep_time,
        )
        success || error("The last remaining panel cannot be deleted.")
        controller.selected_segment = clamp(
            deleted_segment,
            1,
            length(controller.app.simulations),
        )
        update_partition_bindings!(controller; reset_index = true)
        remap_series_after_delete!(controller, deleted_segment)
    end
end


function synchronize_domains!(controller::QMLController)
    return guarded_action(controller, "Synchronization failed") do
        RD.synchronize_domains_app!(controller.app)
    end
end


function toggle_random_mode!(controller::QMLController)
    return guarded_action(controller, "Perturbation-mode change failed") do
        RD.toggle_perturbation_random_mode!(controller.app)
    end
end


function toggle_absolute_mode!(controller::QMLController)
    return guarded_action(controller, "Perturbation-mode change failed") do
        RD.toggle_perturbation_absolute_mode!(controller.app)
    end
end


function parse_finite_qml_number(value, label::AbstractString)
    number = value isa Real ? Float64(value) : tryparse(Float64, String(value))
    number === nothing && error("$label must be a number.")
    isfinite(number) || error("$label must be finite.")

    return number
end


function set_perturbation_width!(controller::QMLController, value)
    return guarded_action(controller, "Perturbation width change failed") do
        controller.series.running[] && return nothing
        width = parse_finite_qml_number(value, "Width")
        0.0 < width <= 1.0 || error("Width must be greater than 0 and at most 1.")
        RD.set_perturbation_width_value!(controller.app, width) ||
            error("Perturbation controls are not available.")
    end
end


function set_perturbation_height!(controller::QMLController, value)
    return guarded_action(controller, "Perturbation height change failed") do
        controller.series.running[] && return nothing
        height = parse_finite_qml_number(value, "Height")
        RD.set_perturbation_height_value!(controller.app, height) ||
            error("Perturbation controls are not available.")
    end
end


function request_close!(controller::QMLController)
    controller.close_requested[] = true
    return nothing
end


function shutdown!(controller::QMLController)
    stop_series!(controller)
    series_task = controller.series.task_ref[]
    if series_task !== nothing && series_task !== current_task() && !istaskdone(series_task)
        wait(series_task)
    end
    clear_series_previews!(controller)
    clear_series_position_marker!(controller)
    RD.stop_worker!(controller.app; wait = true)

    return nothing
end


function cleanup_qml_runtime!()
    try
        with_logger(NullLogger()) do
            GLMakie.closeall()
        end
    catch error
        @debug "Makie resources will be released with the QML context." exception = error
    end

    try
        QML.quit(QML.get_qmlengine())
    catch error
        @debug "QML engine was already closed." exception = error
    end

    try
        QML.quit()
    catch error
        @debug "QML application was already closed." exception = error
    end

    try
        QML.cleanup()
        QML.process_events()
    catch error
        @debug "QML resources were already released." exception = error
    end

    return nothing
end


function run_qml_event_loop!(
    controller::QMLController;
    poll_interval::Float64 = 0.015,
)
    while !controller.close_requested[]
        QML.process_eventloop_updates()
        QML.process_events()
        refresh_series_runtime!(controller)
        controller.close_requested[] && break

        yield()
        sleep(poll_interval)
    end

    return nothing
end


include("SaveLoadQML.jl")


function register_qml_functions!(controller::QMLController)
    # Callbacks whose functions do not report their own errors. An exception
    # escaping a QML callback terminates the application, so it is shown as a
    # message instead. Functions that already use guarded_action are not
    # wrapped again: the outer success would clear the inner error message.
    guarded(action, context) =
        (arguments...) -> guarded_action(() -> action(arguments...), controller, context)

    QML.qmlfunction("refreshUI", () -> refresh_qml_state!(controller))
    QML.qmlfunction("toggleRunning", () -> toggle_running!(controller))
    QML.qmlfunction("saveSimulation", name -> save_simulation!(controller, String(name)))
    QML.qmlfunction("saveSeries", name -> save_series!(controller, String(name)))
    QML.qmlfunction("refreshSimulationSaves", () -> refresh_simulation_saves!(controller))
    QML.qmlfunction(
        "selectSimulationSave",
        file -> select_simulation_save!(controller, String(file)),
    )
    QML.qmlfunction(
        "loadSimulationSave",
        file -> begin
            file_name = String(file)
            enqueue_graphics_action!(
                controller,
                () -> load_simulation_save!(controller, file_name),
            )
        end,
    )
    QML.qmlfunction(
        "resetSimulation",
        () -> enqueue_graphics_action!(
            controller,
            () -> reset_simulation!(controller),
        ),
    )
    QML.qmlfunction(
        "hardReset",
        () -> enqueue_graphics_action!(
            controller,
            () -> hard_reset!(controller),
        ),
    )
    QML.qmlfunction(
        "selectModel",
        key -> begin
            key_string = String(key)
            enqueue_graphics_action!(
                controller,
                () -> select_model!(controller, key_string),
            )
        end,
    )
    QML.qmlfunction(
        "selectBoundaryCondition",
        label -> begin
            label_string = String(label)
            enqueue_graphics_action!(
                controller,
                () -> select_boundary_condition!(controller, label_string),
            )
        end,
    )
    QML.qmlfunction("setDtExponent", value -> set_dt_exponent!(controller, value))
    QML.qmlfunction(
        "setDomainExponent",
        value -> set_domain_exponent!(controller, value),
    )
    QML.qmlfunction(
        "setDomainResolution",
        guarded(value -> set_domain_resolution!(controller, value), "Domain-slider change failed"),
    )
    QML.qmlfunction(
        "setModelParameter",
        (name, value) -> set_model_parameter_from_qml!(controller, name, value),
    )
    QML.qmlfunction("selectSpatialProfileSet", index -> select_spatial_profile_set!(controller, Int(index)))
    QML.qmlfunction(
        "setEquationValuesVisible",
        value -> set_equation_values_visible!(controller, value),
    )
    QML.qmlfunction(
        "applyConstantInitialCondition",
        (index, value) -> apply_constant_initial_condition!(controller, index, value),
    )
    QML.qmlfunction(
        "selectSegment",
        index -> select_segment!(controller, index),
    )
    QML.qmlfunction(
        "selectSplitSegment",
        index -> select_split_segment!(controller, index),
    )
    QML.qmlfunction(
        "changeSelectedSegment",
        direction -> change_selected_segment!(controller, direction),
    )
    QML.qmlfunction("setSplitIndex", index -> set_split_index!(controller, index))
    QML.qmlfunction(
        "splitSelectedSegment",
        () -> enqueue_graphics_action!(
            controller,
            () -> split_selected_segment!(controller),
        ),
    )
    QML.qmlfunction(
        "mergeBoundary",
        index -> begin
            boundary = Int(index)
            enqueue_graphics_action!(
                controller,
                () -> merge_boundary!(controller, boundary),
            )
        end,
    )
    QML.qmlfunction(
        "swapBoundary",
        index -> begin
            boundary = Int(index)
            enqueue_graphics_action!(
                controller,
                () -> swap_boundary!(controller, boundary),
            )
        end,
    )
    QML.qmlfunction(
        "deleteSelectedSegment",
        () -> enqueue_graphics_action!(
            controller,
            () -> delete_selected_segment!(controller),
        ),
    )
    QML.qmlfunction("synchronizeDomains", () -> synchronize_domains!(controller))
    QML.qmlfunction("toggleRandomMode", () -> toggle_random_mode!(controller))
    QML.qmlfunction("toggleAbsoluteMode", () -> toggle_absolute_mode!(controller))
    QML.qmlfunction(
        "setPerturbationWidth",
        value -> set_perturbation_width!(controller, value),
    )
    QML.qmlfunction(
        "setPerturbationHeight",
        value -> set_perturbation_height!(controller, value),
    )
    QML.qmlfunction("setSeriesMode", value -> set_series_mode!(controller, value))
    QML.qmlfunction(
        "setSeriesUsePresetInitial",
        value -> set_series_use_preset_initial!(controller, value),
    )
    QML.qmlfunction(
        "selectSeriesSegment",
        guarded(value -> select_series_segment!(controller, value), "Series panel selection failed"),
    )
    QML.qmlfunction(
        "selectSeriesVariable",
        guarded(value -> select_series_variable!(controller, value), "Series variable selection failed"),
    )
    QML.qmlfunction("setSeriesPosition", value -> set_series_position!(controller, value))
    QML.qmlfunction("selectSeriesPreset", value -> select_series_preset!(controller, value))
    QML.qmlfunction(
        "addSeriesPerturbation",
        guarded(() -> add_series_perturbation!(controller), "Adding a perturbation failed"),
    )
    QML.qmlfunction(
        "deleteSeriesPerturbation",
        guarded(value -> delete_series_perturbation!(controller, value), "Deleting a perturbation failed"),
    )
    QML.qmlfunction(
        "updateSeriesPerturbation",
        guarded(
            (id, field, value) -> update_series_perturbation!(controller, id, field, value),
            "Perturbation change failed",
        ),
    )
    QML.qmlfunction(
        "setSeriesRunCount",
        value -> set_series_integer_setting!(controller, :run_count, value),
    )
    QML.qmlfunction(
        "setSeriesMaximumTime",
        value -> set_series_float_setting!(controller, :maximum_time, value),
    )
    QML.qmlfunction(
        "setSeriesMaximumSteps",
        value -> set_series_integer_setting!(controller, :maximum_steps, value),
    )
    QML.qmlfunction(
        "setSeriesCheckInterval",
        value -> set_series_float_setting!(controller, :check_interval, value),
    )
    QML.qmlfunction(
        "setSeriesTolerance",
        value -> set_series_float_setting!(controller, :tolerance, value),
    )
    QML.qmlfunction(
        "setSeriesRequiredChecks",
        value -> set_series_integer_setting!(controller, :required_checks, value),
    )
    QML.qmlfunction(
        "setSeriesDtmax",
        value -> set_series_float_setting!(controller, :dtmax, value),
    )
    QML.qmlfunction(
        "setSeriesSeed",
        guarded(value -> set_series_seed!(controller, value), "Series setting change failed"),
    )
    QML.qmlfunction(
        "setSeriesHeadVariable",
        value -> set_series_integer_setting!(controller, :head_variable, value),
    )
    QML.qmlfunction(
        "setSeriesLivePreview",
        guarded(value -> set_series_live_preview!(controller, value), "Series setting change failed"),
    )
    QML.qmlfunction("startSeries", guarded(() -> start_series!(controller), "Series start failed"))
    QML.qmlfunction("stopSeries", guarded(() -> stop_series!(controller), "Series stop failed"))
    QML.qmlfunction("requestClose", () -> request_close!(controller))

    return nothing
end


function qml_property_map(
    controller::QMLController,
    catalog_json::String;
    auto_close_ms::Int = 0,
)
    app = controller.app
    bindings = controller.bindings

    return QML.JuliaPropertyMap(
        "running" => app.running,
        "synchronizationStatus" => app.synchronization_status,
        "dtmax" => app.dtmax_obs,
        "modelName" => bindings.active_model_name,
        "activeModelKey" => bindings.active_model_key,
        "boundaryName" => controller.boundary_name_obs,
        "domainLength" => bindings.domain_length,
        "randomMode" => bindings.random_mode,
        "absoluteMode" => bindings.absolute_mode,
        "perturbationWidth" => bindings.perturbation_width,
        "perturbationHeight" => bindings.perturbation_height,
        "selectedSegment" => bindings.selected_segment,
        "segmentCount" => bindings.segment_count,
        "splitIndex" => bindings.split_index,
        "splitMaximum" => bindings.split_maximum,
        "variablesJson" => bindings.variables_json,
        "equationImagesJson" => bindings.equation_images_json,
        "equationPreferredWidth" => bindings.equation_preferred_width,
        "modelDescription" => bindings.model_description,
        "modelParametersJson" => bindings.model_parameters_json,
        "profileFormulaImage" => bindings.profile_formula_image,
        "profileFormulaWidth" => bindings.profile_formula_width,
        "profileFormulaNote" => bindings.profile_formula_note,
        "activeProfileSet" => bindings.active_profile_set,
        "simulationSavesJson" => bindings.simulation_saves_json,
        "simulationSaveDetailsJson" => bindings.simulation_save_details_json,
        "equationValuesVisible" => bindings.equation_values_visible,
        "domainResolution" => bindings.domain_resolution,
        "mainWindowVisible" => bindings.main_window_visible,
        "notice" => bindings.notice,
        "modelCatalogJson" => Observable(catalog_json),
        "message" => bindings.message,
        "graphicsBusy" => controller.graphics_busy,
        "seriesRunning" => bindings.series_running,
        "seriesCompletedRuns" => bindings.series_completed_runs,
        "seriesTotalRuns" => bindings.series_total_runs,
        "seriesStatus" => bindings.series_status,
        "seriesRunCount" => bindings.series_run_count,
        "seriesMaximumTime" => bindings.series_maximum_time,
        "seriesMaximumSteps" => bindings.series_maximum_steps,
        "seriesCheckInterval" => bindings.series_check_interval,
        "seriesTolerance" => bindings.series_tolerance,
        "seriesRequiredChecks" => bindings.series_required_checks,
        "seriesDtmax" => bindings.series_dtmax,
        "seriesSeed" => bindings.series_seed,
        "seriesHeadVariable" => bindings.series_head_variable,
        "seriesLivePreview" => bindings.series_live_preview,
        "seriesSelectedSegment" => bindings.series_selected_segment,
        "seriesSelectedVariable" => bindings.series_selected_variable,
        "seriesPosition" => bindings.series_position,
        "seriesPerturbationsJson" => bindings.series_perturbations_json,
        "seriesPresetsJson" => bindings.series_presets_json,
        "seriesSelectedPreset" => bindings.series_selected_preset,
        "seriesResultsJson" => bindings.series_results_json,
        "seriesMode" => bindings.series_mode,
        "seriesPresetInitialAvailable" => bindings.series_preset_initial_available,
        "seriesUsePresetInitial" => bindings.series_use_preset_initial,
        "autoCloseMs" => Observable(auto_close_ms),
    )
end


function create_qml_controller(;
    N::Int,
    boundary_condition0::Symbol,
    dtmax0::Float64,
    reltol::Float64,
    abstol::Float64,
    steps_per_frame::Int,
    worker_sleep_time::Float64,
    startup_splash::Union{Nothing, StartupSplash.StartupSplashHandle} = nothing,
)
    RD.validate_boundary_condition(boundary_condition0)
    registry = RD.MODEL_REGISTRY
    StartupSplash.startup_stage!(startup_splash, :equations)
    stage_started_ns = time_ns()
    equation_images_by_model, equation_widths_by_model = render_equation_catalog(
        registry;
        on_progress = (completed, total) -> StartupSplash.startup_stage!(
            startup_splash,
            :equations;
            fraction = completed / total,
            detail = "($completed/$total)",
        ),
    )
    report_startup_stage("Render equation catalog", stage_started_ns)

    labels = RD.model_labels(registry)
    isempty(labels) && error("No models found in MODEL_REGISTRY.")
    first_label = first(labels)
    first_key = RD.model_registry_key_for_label(registry, first_label)
    first_model = RD.get_model(registry, first_key)

    StartupSplash.startup_stage!(startup_splash, :simulation)
    stage_started_ns = time_ns()
    simulation = RD.create_simulation_state(
        first_model;
        N = N,
        dtmax = dtmax0,
        reltol = reltol,
        abstol = abstol,
        boundary_condition = boundary_condition0,
    )
    report_startup_stage("Create initial simulation", stage_started_ns)

    StartupSplash.startup_stage!(startup_splash, :warm_up)
    stage_started_ns = time_ns()
    try
        RD.warm_up_solver!(simulation; reltol = reltol, abstol = abstol)
    catch err
        @warn "Solver warm-up failed; the application will continue normally." exception =
            (err, catch_backtrace())
    end
    report_startup_stage("Warm up solver", stage_started_ns)

    StartupSplash.startup_stage!(startup_splash, :plots)
    stage_started_ns = time_ns()
    running = Observable(false)
    dtmax = Observable(dtmax0)
    dt = Observable(RD.current_internal_dt(simulation))
    time = Observable(RD.current_display_time(simulation))
    steps = Observable(simulation.step_counter[])
    model_name = Observable(first_model.display_name)
    boundary_name = Observable(RD.boundary_condition_label(boundary_condition0))
    title = lift(model_name, boundary_name, time, steps) do _, _, t, step_count
        "t = $(@sprintf("%.1e", t)) | steps = $step_count"
    end
    figure = Figure(size = (1300, 820))
    plot_grid = GridLayout(tellwidth = false, tellheight = false)
    figure[1, 1] = plot_grid
    rowsize!(figure.layout, 1, Auto(false, 1.0))
    colsize!(figure.layout, 1, Relative(1.0))
    app = RD.AppState(
        simulation,
        RD.SimulationState[simulation],
        N,
        boundary_condition0,
        RD.empty_plot_panel(),
        running,
        dtmax,
        dt,
        time,
        steps,
        Threads.Atomic{Bool}(false),
        Ref{Union{Nothing, Task}}(nothing),
        Threads.Atomic{Int}(0),
        ReentrantLock(),
        RD.SegmentRuntime[RD.empty_segment_runtime()],
        Threads.Atomic{Bool}(false),
        Ref{Union{Nothing, Task}}(nothing),
        Observable("Synchronized"),
        Threads.Atomic{Bool}(true),
        Dict{Symbol, Float64}(),
        Observable(0),
    )
    app.plot_panel = RD.build_plot_panel!(plot_grid, app; title_obs = title)
    report_startup_stage("Create application and plots", stage_started_ns)

    stage_started_ns = time_ns()
    series_defaults = RD.SeriesSettings()
    bindings = QMLBindings(
        Observable(first_key),
        Observable(active_model_menu_name(first_key)),
        Observable(1.0),
        Observable(true),
        Observable(false),
        Observable(1),
        Observable(1),
        Observable(clamp(round(Int, N / 2), 2, N - 2)),
        Observable(max(2, N - 2)),
        Observable(json_string_array(first_model.varnames)),
        Observable(json_string_array(equation_images_by_model[first_key])),
        Observable(get(equation_widths_by_model, first_key, 0.0)),
        Observable(0.05),
        Observable(0.0),
        Observable(""),
        Observable(false),
        Observable(0),
        Observable(100),
        Observable("Configure perturbations"),
        Observable(series_defaults.run_count),
        Observable(series_defaults.maximum_time),
        Observable(series_defaults.maximum_steps_per_panel),
        Observable(series_defaults.check_interval),
        Observable(series_defaults.tolerance),
        Observable(series_defaults.required_consecutive_checks),
        Observable(series_defaults.dtmax),
        Observable(string(series_defaults.seed)),
        Observable(1),
        Observable(series_defaults.live_preview),
        Observable(1),
        Observable(1),
        Observable(0.5),
        Observable("[]"),
        Observable(series_presets_json(SERIES_PRESETS, first_key)),
        Observable("none"),
        Observable("[]"),
        Observable(false),
        Observable(false),
        Observable(false),
        Observable(first_model.description),
        Observable(model_parameters_json(first_model, simulation.params)),
        Observable(false),
        Observable(16),
        Observable(false),
        Observable(""),
        Observable(""),
        Observable(0.0),
        Observable(""),
        Observable(RD._active_spatial_profile_set_index(simulation.params, first_model.spatial_profile_sets)),
        Observable("{\"saves\":[],\"skipped\":[]}"),
        Observable("{}"),
    )
    controller = QMLController(
        app,
        plot_grid,
        title,
        model_name,
        boundary_name,
        registry,
        equation_images_by_model,
        equation_widths_by_model,
        bindings,
        empty_series_controller(),
        1.0,
        1,
        bindings.split_index[],
        steps_per_frame,
        worker_sleep_time,
        reltol,
        abstol,
        Function[],
        ReentrantLock(),
        Observable(false),
        Threads.Atomic{Bool}(false),
        Threads.Atomic{Bool}(false),
    )
    controller.series.selected_position = 0.5
    refresh_series_bindings!(controller)
    refresh_profile_formula!(controller)
    # Keep the sidebar's selected profile, parameter fields and formula in sync.
    on(app.spatial_profile_set_revision) do _
        guarded_action(controller, "Profile set change failed") do
            controller.bindings.series_mode[] && clear_series_results!(controller)
            update_model_bindings!(controller)
            refresh_current_equation_image!(controller)
        end
    end
    report_startup_stage("Create QML controller", stage_started_ns)

    return controller, figure
end


function run_qml_app(;
    N::Int = 500,
    boundary_condition0::Symbol = :neumann,
    dtmax0::Float64 = 1e-2,
    reltol::Float64 = 1e-5,
    abstol::Float64 = 1e-7,
    steps_per_frame::Int = 5,
    worker_sleep_time::Float64 = 0.001,
    auto_close_ms::Int = 0,
    startup_started_ns::UInt64 = time_ns(),
    startup_splash::Union{Nothing, StartupSplash.StartupSplashHandle} = nothing,
    compile_started_ns::Union{Nothing, UInt64} = nothing,
)
    # The first call compiles this function together with everything it calls,
    # which takes seconds before this line runs; the caller starts that clock.
    compile_started_ns === nothing ||
        report_startup_stage("Compile application code", compile_started_ns)
    isfile(QML_FILE) || error("QML interface file does not exist: $QML_FILE")

    if Threads.nthreads() == 1
        @warn "Julia is running with one thread; use --threads=auto for independent solvers."
    end

    splash = startup_splash === nothing ?
             StartupSplash.open_startup_splash!() : startup_splash

    controller = nothing
    qml_engine = nothing
    try
        controller, figure = create_qml_controller(
            N = N,
            boundary_condition0 = boundary_condition0,
            dtmax0 = dtmax0,
            reltol = reltol,
            abstol = abstol,
            steps_per_frame = steps_per_frame,
            worker_sleep_time = worker_sleep_time,
            startup_splash = splash,
        )
        StartupSplash.startup_stage!(splash, :connect)
        stage_started_ns = time_ns()
        install_qml_renderfunction!(controller)
        report_startup_stage("Install QML render function", stage_started_ns)

        stage_started_ns = time_ns()
        register_qml_functions!(controller)
        report_startup_stage("Register QML callbacks", stage_started_ns)

        stage_started_ns = time_ns()
        properties = qml_property_map(
            controller,
            model_catalog_json(controller.registry),
            auto_close_ms = auto_close_ms,
        )
        report_startup_stage("Prepare QML properties", stage_started_ns)

        StartupSplash.startup_stage!(splash, :workspace)
        stage_started_ns = time_ns()
        qml_engine = QML.init_qmlapplicationengine()
        QML.loadqml(qml_engine, QML_FILE; plot = figure, ui = properties)
        report_startup_stage("QML.loadqml", stage_started_ns)

        StartupSplash.startup_stage!(splash, :first_frame)
        stage_started_ns = time_ns()
        wait_for_first_workspace_frame!(controller, splash)
        controller.bindings.main_window_visible[] = true
        report_startup_stage("First workspace frame", stage_started_ns)
        StartupSplash.close_startup_splash!(splash)
        report_startup_stage("Total before QML event loop", startup_started_ns)
        println("[startup] Entering QML event loop")
        flush(stdout)

        run_qml_event_loop!(controller)
    catch err
        err isa StartupSplash.StartupCancelled || rethrow()
        println("[startup] Startup cancelled")
    finally
        StartupSplash.close_startup_splash!(splash)
        controller === nothing || shutdown!(controller)
        # Before loadqml there is no engine to release, and quitting a missing
        # engine crashes inside Qt (e.g. on Cancel during the equations).
        qml_engine === nothing || cleanup_qml_runtime!()
        ACTIVE_QML_CONTROLLER[] = nothing
    end

    return nothing
end


export run_qml_app

end
