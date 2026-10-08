# src/ParameterHistory.jl

# ============================================================
# Parameter history: Save appends the current settings to one text file
# ============================================================
#
# Each entry records the model, its parameters, the domain, the series
# settings and the series perturbations of every panel, under the time of
# saving. The file is created on the first save and appended to afterwards.

const PARAMETER_HISTORY_FILE = normpath(joinpath(@__DIR__, "..", "parameters_history.txt"))
const PARAMETER_HISTORY_RULE = repeat("═", 72)


function history_number(value::Real)
    number = Float64(value)
    isinteger(number) && abs(number) < 1e6 && return string(Int(number))
    return display_number(number)
end


function history_columns(io::IO, pairs::Vector{Pair{String, String}}; columns::Int = 3)
    # Name / value pairs in aligned columns.
    isempty(pairs) && return nothing
    name_width = maximum(length(first(pair)) for pair in pairs)
    value_width = maximum(length(last(pair)) for pair in pairs)

    for row in Iterators.partition(pairs, columns)
        cells = [rpad(name, name_width) * "  " * rpad(value, value_width) for (name, value) in row]
        println(io, "  ", rstrip(join(cells, "     ")))
    end

    return nothing
end


function history_preset_label(controller::QMLController, segment::Int)
    key = controller.series.panel_presets[segment]
    key == "none" && return "None"
    key == "custom" && return "Custom"
    preset = series_preset_by_key(controller.bindings.active_model_key[], key)
    return preset === nothing ? key : preset.name
end


function write_history_model!(io::IO, controller::QMLController)
    sim = controller.app.sim
    model = sim.model
    println(io, "Model parameters")
    history_columns(
        io,
        [String(name) => history_number(sim.params[name]) for name in RD.public_model_parameter_names(model)],
    )

    if !isempty(model.spatial_profile_sets)
        set_index = RD._active_spatial_profile_set_index(sim.params, model.spatial_profile_sets)
        println(io, "  Spatial profile   ", first(model.spatial_profile_sets[set_index]))
    end

    return nothing
end


function write_history_domain!(io::IO, controller::QMLController)
    app = controller.app
    count = length(app.simulations)
    panel_lengths = [series_display_length(app, segment) for segment in 1:count]
    lengths = [@sprintf("%.4g", value) for value in panel_lengths]
    points = [string(sim.N) for sim in app.simulations]

    println(io, "Domain")
    history_columns(
        io,
        [
            "Boundary" => RD.boundary_condition_label(app.initial_boundary_condition),
            "Domain length" => @sprintf("%.4g", sum(panel_lengths)),
            "Rescale" => "10^" * @sprintf("%.3g", log10(controller.diffusion_scale)),
            "Maximum dt" => display_number(app.dtmax_obs[]),
            "Panels" => string(count),
            "Panel lengths" => join(lengths, " | "),
            "Grid points" => join(points, " | "),
        ];
        columns = 2,
    )

    return nothing
end


function write_history_series_settings!(io::IO, controller::QMLController)
    settings = controller.series.settings
    model = controller.app.sim.model
    head_variable = clamp(settings.head_variable, 1, model.nvars)

    println(io, "Series settings")
    history_columns(
        io,
        [
            "Runs" => string(settings.run_count),
            "Maximum time" => display_number(settings.maximum_time),
            "Check interval" => display_number(settings.check_interval),
            "Tolerance" => display_number(settings.tolerance),
            "Consecutive checks" => string(settings.required_consecutive_checks),
            "Series dtmax" => display_number(settings.dtmax),
            "Step limit" => display_number(settings.maximum_steps_per_panel),
            "Seed" => string(settings.seed),
            "Head variable" => model.varnames[head_variable],
        ],
    )

    return nothing
end


function write_history_perturbations!(io::IO, controller::QMLController)
    app = controller.app
    series = controller.series
    ensure_panel_preset_state!(controller)

    println(io, "Series perturbations   (position in axis units, widths as fractions of the panel)")

    for segment in eachindex(app.simulations)
        initial_values = series.panel_initial_values[segment]
        initial_text = isempty(initial_values) ? "" :
            "   initial " * join(["$(name) = $(history_number(value))" for (name, value) in sort(collect(initial_values))], ", ")
        println(io, "  Panel $segment   preset: ", history_preset_label(controller, segment), initial_text)

        perturbations = filter(perturbation -> perturbation.segment == segment, series.perturbations)
        if isempty(perturbations)
            println(io, "     no perturbations")
            continue
        end

        displayed_length = series_display_length(app, segment)
        varnames = app.simulations[segment].model.varnames
        println(io, "      #   var    position   width min   width max   height min   height max")
        for (number, perturbation) in enumerate(perturbations)
            @printf(
                io,
                "     %2d   %-5s %9.2f   %9.2f   %9.2f   %10.1f   %10.1f\n",
                number,
                varnames[perturbation.variable],
                perturbation.position * displayed_length,
                perturbation.width_min,
                perturbation.width_max,
                perturbation.height_min,
                perturbation.height_max,
            )
        end
    end

    return nothing
end


function parameter_history_entry(controller::QMLController, time::DateTime)
    io = IOBuffer()
    println(io, PARAMETER_HISTORY_RULE)
    println(io, Dates.format(time, "yyyy-mm-dd HH:MM:SS"), "   ", active_model_menu_name(controller.bindings.active_model_key[]))
    println(io, PARAMETER_HISTORY_RULE)
    println(io)
    write_history_model!(io, controller)
    println(io)
    write_history_domain!(io, controller)
    println(io)
    write_history_series_settings!(io, controller)
    println(io)
    write_history_perturbations!(io, controller)
    println(io)
    println(io)
    return String(take!(io))
end


function save_parameter_history!(controller::QMLController; path::AbstractString = PARAMETER_HISTORY_FILE)
    return guarded_action(controller, "Saving the parameters failed") do
        time = Dates.now()
        entry = parameter_history_entry(controller, time)
        # Append mode creates the file on the first save.
        open(path, "a") do io
            write(io, entry)
        end
        controller.bindings.notice[] =
            "Parameters saved to $(basename(path)) at $(Dates.format(time, "HH:MM:SS"))"
    end
end
