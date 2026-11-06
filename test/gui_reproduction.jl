# test/gui_reproduction.jl — reproduce series saved by the application.
#
# The application's former Save graph button wrote a folder
# saved_graphs/<date>_<time>/ with parameters.txt (the settings, rounded for
# display), metadata.json (panel lengths at full precision),
# spatial_profiles.csv, series_head_counts.csv, series_configurations.csv and
# series_patterns.csv (the final head-variable profile of every run, at full
# precision). This test rebuilds each such series from those files, runs it
# with the API exactly as the application computes it (one realization at a
# time, MKL at its default threads) and compares the head counts, the
# configuration counts and every final profile.
#
# Folders: every subfolder of saved_graphs/ and test/saved_graphs/ that holds
# a parameters.txt, plus the folders listed (separated by newlines or ';') in
# the environment variable RDLAB_SAVED_GRAPHS. test/saved_graphs/ holds two
# folders written by the application at 7e05f77 (see their fixture.toml and
# test/tools/make_old_app_fixtures.jl). The expected counts stated for
# the experiments are in test/gui_reference.toml. Run alone with
#
#     julia --project --threads=auto test/gui_reproduction.jl [folder ...]
#
# What parameters.txt cannot give exactly is reconstructed and reported:
# parameter values are printed with three significant digits (read as typed),
# the domain scale is the slider's 10^exponent (the candidates consistent with
# the printed exponent and the full-precision length are tried), and wound
# positions are printed in axis units (the simplest fraction of the panel
# that prints the same is used).

if !isdefined(Main, :RDLabAPI)
    using Test
    const REPO = normpath(joinpath(@__DIR__, ".."))
    const TEST_OUT = mktempdir()
    include(joinpath(REPO, "src", "RDLabAPI.jl"))
    using .RDLabAPI
    const C = RDLabAPI.C
end

using Printf
using Dates
import TOML

# The time of the commit after which parameters.txt shows the model's own
# diffusion coefficients; before it, D / L^2 (914465d, "Domain length rescales
# diffusion inside the RHS only").
const RESCALED_DISPLAY_UNTIL = DateTime(2026, 11, 5, 17, 4, 52)

# Before effe81d the linear profiles of the Rho profile model were
# ρ0 - ρ1/2 + ρ1 x (ρ0 at the centre); now they are ρ0 + ρ1 x. The profile
# saved in spatial_profiles.csv is used as it is, so this matters only for a
# folder without that file.
const CENTRED_LINEAR_PROFILES_UNTIL = DateTime(2026, 11, 5, 17, 16, 45)

# ------------------------------------------------------------
# parameters.txt
# ------------------------------------------------------------

function column_value(line::AbstractString, key::AbstractString)
    m = match(Regex("(?:^|\\s)" * key * "\\s{2,}(\\S(?:.*?\\S)??)(?=\\s{5,}|\\s*\$)"), line)
    return m === nothing ? nothing : String(m.captures[1])
end

function section_lines(lines, title)
    start = findfirst(line -> startswith(strip(line), title), lines)
    start === nothing && return String[]
    stop = findnext(line -> isempty(strip(line)), lines, start + 1)
    return lines[(start + 1):(stop === nothing ? length(lines) : stop - 1)]
end

function find_value(lines, key)
    for line in lines
        value = column_value(line, key)
        value === nothing || return value
    end
    error("parameters.txt has no '$key'.")
end

function parse_parameters_txt(path::AbstractString)
    lines = readlines(path)
    header = strip(lines[2])
    m = match(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\s+(.+?)\s*/\s*(.+)$", header)
    m === nothing && error("Unexpected header in $path: $header")
    saved_at = DateTime(m.captures[1], dateformat"yyyy-mm-dd HH:MM:SS")

    params = Dict{String, String}()
    profile_set = nothing
    for line in section_lines(lines, "Model parameters")
        stripped = strip(line)
        if startswith(stripped, "Spatial profile")
            profile_set = String(strip(stripped[length("Spatial profile") + 1:end]))
            continue
        end
        tokens = split(stripped)
        for index in 1:2:(length(tokens) - 1)
            params[tokens[index]] = tokens[index + 1]
        end
    end

    domain = section_lines(lines, "Domain")
    settings = section_lines(lines, "Series settings")

    panels = Dict{Int, Any}()
    current = 0
    for line in section_lines(lines, "Series perturbations")
        stripped = strip(line)
        pm = match(r"^Panel (\d+)\s+preset: (.*?)(?:\s{3}initial (.*))?$", stripped)
        if pm !== nothing
            current = parse(Int, pm.captures[1])
            initial = Dict{String, Float64}()
            if pm.captures[3] !== nothing
                for item in split(pm.captures[3], ",")
                    name, value = strip.(split(item, "="))
                    initial[name] = parse(Float64, value)
                end
            end
            panels[current] = (preset = String(pm.captures[2]), initial = initial, rows = Any[])
            continue
        end
        rm = match(r"^(\d+)\s+(\S+)\s+([-0-9.e+]+)\s+([-0-9.e+]+)\s+([-0-9.e+]+)\s+([-0-9.e+]+)\s+([-0-9.e+]+)$", stripped)
        rm === nothing && continue
        push!(panels[current].rows, (
            variable = String(rm.captures[2]),
            position_text = String(rm.captures[3]),
            width = (parse(Float64, rm.captures[4]), parse(Float64, rm.captures[5])),
            height = (parse(Float64, rm.captures[6]), parse(Float64, rm.captures[7])),
        ))
    end

    return (
        saved_at = saved_at,
        family = String(m.captures[2]),
        model_name = String(m.captures[3]),
        params = params,
        profile_set = profile_set,
        boundary = find_value(domain, "Boundary"),
        domain_length = find_value(domain, "Domain length"),
        rescale = find_value(domain, "Rescale"),
        panel_count = parse(Int, find_value(domain, "Panels")),
        panel_lengths = find_value(domain, "Panel lengths"),
        grid_points = find_value(domain, "Grid points"),
        runs = parse(Int, find_value(settings, "Runs")),
        maximum_time = parse(Float64, find_value(settings, "Maximum time")),
        check_interval = parse(Float64, find_value(settings, "Check interval")),
        tolerance = parse(Float64, find_value(settings, "Tolerance")),
        consecutive = parse(Int, find_value(settings, "Consecutive checks")),
        dtmax = parse(Float64, find_value(settings, "Series dtmax")),
        step_limit = round(Int, parse(Float64, find_value(settings, "Step limit"))),
        seed = parse(Int, find_value(settings, "Seed")),
        head_variable = find_value(settings, "Head variable"),
        panels = panels,
    )
end

# ------------------------------------------------------------
# Reconstruction
# ------------------------------------------------------------

normalized_name(text) = lowercase(replace(replace(text, " " => ""), "mainhardt" => "meinhardt", "Mainhardt" => "Meinhardt"))

function model_key_for(family, model_name)
    registry = load_models()
    keys_found = [
        key for (key, model) in registry
        if normalized_name(C.model_family_name(key)) == normalized_name(family) && model.display_name == model_name
    ]
    length(keys_found) == 1 || error("No model '$family / $model_name' in Models/.")
    return only(keys_found)
end

# Domain scales consistent with the printed exponent ("0.697") and the panel
# length: values of the slider (-2 to 3 in steps of 3 / (resolution - 1)), and
# the squares of the full-precision length.
function scale_candidates(p, metadata_length)
    candidates = Float64[]
    exponent_text = replace(p.rescale, "10^" => "")

    for resolution in (16, 40, 100), k in 0:(resolution - 1)
        step = 3 / max(1, resolution - 1)
        for exponent in (-2 + k * step, -2 + 5 * (k * (step / 5)))
            @sprintf("%.3g", exponent) == @sprintf("%.3g", parse(Float64, exponent_text)) || continue
            push!(candidates, 10.0^exponent)
        end
    end

    if metadata_length !== nothing
        filter!(scale -> sqrt(scale) == metadata_length, candidates)
        if isempty(candidates)
            square = metadata_length^2
            for scale in (prevfloat(square, 2), prevfloat(square), square, nextfloat(square), nextfloat(square, 2))
                sqrt(scale) == metadata_length && push!(candidates, scale)
            end
        end
    else
        filter!(scale -> @sprintf("%.4g", sqrt(scale)) == p.domain_length, candidates)
    end

    return unique(candidates)
end

significant(value, digits) = value == 0 ? 0.0 : round(value; sigdigits = digits)

# Significant digits of the shortest form of a number (0.01 -> 1, 7.05e-3 -> 3).
function significant_digits(value::Float64)
    value == 0 && return 0
    mantissa = first(split(lowercase(string(abs(value))), 'e'))
    digits = lstrip(replace(mantissa, "." => ""), '0')
    return length(rstrip(digits, '0'))
end

# The value typed at domain scale 1 that, divided by the scale, prints as
# `shown` (three significant digits): the one with the fewest digits.
function typed_value(shown::Float64, scale::Float64)
    for digits in 1:4
        typed = significant(shown * scale, digits)
        significant(typed / scale, 3) == significant(shown, 3) && return typed
    end
    return significant(shown * scale, 3)
end

# Whether parameters.txt shows the diffusion coefficients divided by the
# domain scale, as the application did before 914465d: the reading in which
# the typed values are the simpler numbers, and the date of the save on a tie.
function rescaled_display(p, scale)
    scale == 1.0 && return false
    as_shown = 0
    as_rescaled = 0
    for (name, text) in p.params
        startswith(name, "D") || continue
        value = parse(Float64, text)
        as_shown += significant_digits(significant(value, 3))
        as_rescaled += significant_digits(typed_value(value, scale))
    end
    as_rescaled == as_shown && return p.saved_at < RESCALED_DISPLAY_UNTIL
    return as_rescaled < as_shown
end

# Model parameters as the application used them (the values typed at scale 1;
# the right-hand side divides the diffusion coefficients by the scale).
function model_parameters(p, model, scale)
    params = Dict{Symbol, Float64}()
    rescaled = rescaled_display(p, scale)

    for (name, text) in p.params
        key = Symbol(name)
        haskey(model.default_params, key) || continue
        value = parse(Float64, text)
        if rescaled && startswith(name, "D")
            value = typed_value(value, scale)
        end
        params[key] = value
    end

    return params
end

# The simplest fraction (fewest decimals, at most three) that prints as the
# axis-unit position of parameters.txt.
function wound_fraction(position_text::AbstractString, panel_length::Float64)
    for digits in 0:3, numerator in 0:(10^digits)
        fraction = numerator / 10^digits
        @sprintf("%.2f", fraction * panel_length) == position_text && return fraction
    end
    error("No fraction of the panel prints as position $position_text.")
end

function read_csv_rows(path)
    lines = readlines(path)
    header = split(lines[1], ",")
    return [Dict(zip(header, split(line, ","))) for line in lines[2:end] if !isempty(line)]
end

function saved_patterns(folder)
    path = joinpath(folder, "series_patterns.csv")
    isfile(path) || return nothing
    runs = Dict{Int, Vector{Float64}}()
    converged = Dict{Int, Bool}()
    for row in read_csv_rows(path)
        row["panel"] == "1" || continue
        run = parse(Int, row["run"])
        push!(get!(runs, run, Float64[]), parse(Float64, row["value"]))
        converged[run] = row["converged"] == "true"
    end
    return [(runs[k], converged[k]) for k in sort(collect(keys(runs)))]
end

function saved_counts(folder)
    heads = Dict{Int, Int}()
    path = joinpath(folder, "series_head_counts.csv")
    if isfile(path)
        for row in read_csv_rows(path)
            row["panel"] == "1" && (heads[parse(Int, row["heads"])] = parse(Int, row["count"]))
        end
    end
    configurations = Int[]
    path = joinpath(folder, "series_configurations.csv")
    if isfile(path)
        for row in read_csv_rows(path)
            row["panel"] == "1" && push!(configurations, parse(Int, row["count"]))
        end
    end
    return heads, configurations
end

function rebuild_series(folder)
    p = parse_parameters_txt(joinpath(folder, "parameters.txt"))
    p.panel_count == 1 || error("Only single-panel series can be rebuilt ($(p.panel_count) panels).")
    p.boundary == "Neumann" || error("Only Neumann series can be rebuilt.")
    key = model_key_for(p.family, p.model_name)
    model = load_models()[key]
    metadata = isfile(joinpath(folder, "metadata.json")) ? C.JSON.parsefile(joinpath(folder, "metadata.json")) : nothing
    metadata_length = metadata === nothing ? nothing : Float64(metadata["panels"][1]["length"])
    scales = scale_candidates(p, metadata_length)
    isempty(scales) && error("No domain scale fits Rescale $(p.rescale) and length $(something(metadata_length, p.domain_length)).")
    panel = p.panels[1]
    isempty(panel.initial) &&
        error("The series started from the live state (Initial condition: Current state), which parameters.txt does not hold.")
    N = parse(Int, p.grid_points)

    # ρ exactly as the plots showed it, when the profile set draws nothing at random.
    rho = p.profile_set
    profiles_path = joinpath(folder, "spatial_profiles.csv")
    random_profile = any(name -> startswith(name, "ρσ") && parse(Float64, p.params[name]) != 0.0, keys(p.params))
    if isfile(profiles_path) && !random_profile
        rows = read_csv_rows(profiles_path)
        column = only(filter(name -> !(name in ("panel", "x")), collect(keys(first(rows)))))
        rho = [parse(Float64, row[column]) for row in rows if row["panel"] == "1"]
        length(rho) == N || error("spatial_profiles.csv has $(length(rho)) values for $N points.")
    elseif p.saved_at < CENTRED_LINEAR_PROFILES_UNTIL && parse(Float64, get(p.params, "ρ1", "0")) != 0.0
        @warn "$(basename(folder)): no spatial_profiles.csv, and the series was saved when ρ0 of the linear profiles was the centre value; ρ is evaluated by today's model file and may differ."
    end

    specs = map(scales) do scale
        params = model_parameters(p, model, scale)
        start = make_state(key; N = N, diffusion_scale = scale, params = params, rho = rho, initial = panel.initial)
        length_ = sqrt(scale)
        wounds = [
            Wound(
                wound_fraction(row.position_text, length_);
                width_fraction = row.width,
                height = row.height,
                variable = row.variable,
            )
            for row in panel.rows
        ]
        SeriesSpec(
            experiment = "gui_reproduction",
            name = basename(rstrip(folder, '/')),
            start = start,
            wounds = wounds,
            runs = p.runs,
            seed = p.seed,
            maximum_time = p.maximum_time,
            check_interval = p.check_interval,
            tolerance = p.tolerance,
            required_consecutive_checks = p.consecutive,
            dtmax = p.dtmax,
            maximum_steps = p.step_limit,
            head_variable = p.head_variable,
        )
    end

    return (parameters = p, specs = specs, scales = scales)
end

# ------------------------------------------------------------
# The folders
# ------------------------------------------------------------

function saved_graph_folders(extra = String[])
    folders = String[]
    for root in (joinpath(REPO, "saved_graphs"), joinpath(REPO, "test", "saved_graphs"))
        isdir(root) || continue
        for name in sort(readdir(root))
            isfile(joinpath(root, name, "parameters.txt")) && push!(folders, joinpath(root, name))
        end
    end
    for item in split(get(ENV, "RDLAB_SAVED_GRAPHS", ""), r"[\n;]")
        isempty(strip(item)) || push!(folders, String(strip(item)))
    end
    append!(folders, extra)
    return unique(abspath.(folders))
end

const GUI_REFERENCE = TOML.parsefile(joinpath(@__DIR__, "gui_reference.toml"))

function expected_configurations(folder)
    for entry in get(GUI_REFERENCE, "series", Any[])
        name = get(entry, "folder", "")
        isempty(name) && continue
        basename(rstrip(folder, '/')) == basename(rstrip(name, '/')) && return entry
    end
    return nothing
end

# A folder made elsewhere for this test (test/saved_graphs/*/fixture.toml)
# names the MKL threads it was computed with; the user's own folders are
# reproduced on the machine that made them, with MKL at its default.
function fixture_settings(folder)
    path = joinpath(folder, "fixture.toml")
    isfile(path) || return (mkl_threads = :default, bitwise = true)
    entry = TOML.parsefile(path)
    return (mkl_threads = get(entry, "mkl_threads", :default), bitwise = get(entry, "bitwise", true))
end

function reproduce(folder)
    rebuilt = rebuild_series(folder)
    patterns = saved_patterns(folder)
    heads, configurations = saved_counts(folder)
    fixture = fixture_settings(folder)
    chosen = first(rebuilt.specs)

    # With several possible domain scales, the one whose first runs match the
    # saved profiles bitwise.
    if length(rebuilt.specs) > 1 && patterns !== nothing
        for spec in rebuilt.specs
            probe = SeriesSpec(; (name => getfield(spec, name) for name in fieldnames(SeriesSpec))..., runs = min(3, spec.runs))
            result = run_series(probe; out = TEST_OUT, threads = 1, mkl_threads = fixture.mkl_threads, verbose = false)
            if all(isapprox(result.outcomes[k].final_snapshot.y[1:length(patterns[k][1])], patterns[k][1]; rtol = 1e-9) for k in 1:probe.runs)
                chosen = spec
                break
            end
        end
    end

    result = run_series(chosen; out = TEST_OUT, threads = 1, mkl_threads = fixture.mkl_threads, verbose = false)
    return (rebuilt = rebuilt, chosen = chosen, result = result, patterns = patterns, heads = heads,
            configurations = configurations, expected = expected_configurations(folder), fixture = fixture)
end

function report_reproduction(folder, r)
    summary = r.result.summary
    api_heads = Dict(parse(Int, k) => v for (k, v) in summary["head_counts"] if v > 0)
    api_configurations = [c["count"] for c in summary["configurations"]]
    params = r.chosen.start.sim.params
    println("  $(basename(folder)): model $(r.chosen.start.model_key), N = $(r.chosen.start.sim.N), ",
        "scale = $(RDLabAPI.diffusion_scale(r.chosen.start)) (candidates $(length(r.rebuilt.scales))), runs = $(r.chosen.runs), ",
        "Du = $(params[:Du]), Dv = $(params[:Dv]) (typed values; the solver divides by the scale)")
    println("    wounds at fractions ", [w.at for w in r.chosen.wounds], ", widths ", [w.width_fraction for w in r.chosen.wounds])
    println("    API configurations $(api_configurations), saved $(r.configurations)",
        r.expected === nothing ? "" : ", expected $(r.expected["configurations"])")
    println("    API head counts $(sort(collect(api_heads))), saved $(sort(collect(r.heads)))")
    if r.patterns !== nothing
        identical = count(k -> r.result.outcomes[k].final_snapshot.y[1:length(r.patterns[k][1])] == r.patterns[k][1], eachindex(r.patterns))
        largest = maximum(maximum(abs.(r.result.outcomes[k].final_snapshot.y[1:length(r.patterns[k][1])] .- r.patterns[k][1])) for k in eachindex(r.patterns))
        println("    final profiles bitwise identical in $identical of $(length(r.patterns)) runs; largest difference $largest ",
            "(MKL threads $(r.fixture.mkl_threads))")
    end
    return api_heads, api_configurations
end

@testset "reproduce saved application series" begin
    folders = saved_graph_folders(abspath(PROGRAM_FILE) == (@__FILE__) ? ARGS : String[])

    if isempty(folders)
        @info "No saved_graphs folders found: put the application's Save graph folders in saved_graphs/ or list them in RDLAB_SAVED_GRAPHS to reproduce them."
        @test_skip "saved_graphs reproduction"
    end

    for folder in folders
        @testset "$(basename(folder))" begin
            r = reproduce(folder)
            api_heads, api_configurations = report_reproduction(folder, r)
            isempty(r.heads) || @test api_heads == Dict(k => v for (k, v) in r.heads if v > 0)
            isempty(r.configurations) || @test api_configurations == r.configurations
            r.expected === nothing || @test sort(api_configurations) == sort(r.expected["configurations"])
            if r.patterns !== nothing
                finals = [r.result.outcomes[k].final_snapshot.y[1:length(r.patterns[k][1])] for k in eachindex(r.patterns)]
                if r.fixture.bitwise
                    @test all(finals[k] == r.patterns[k][1] for k in eachindex(r.patterns))
                else
                    @test all(maximum(abs.(finals[k] .- r.patterns[k][1])) <= 1e-9 * max(1.0, maximum(abs.(r.patterns[k][1]))) for k in eachindex(r.patterns))
                end
                @test [o.converged for o in r.result.outcomes] == [c for (_, c) in r.patterns]
            end
        end
    end
end
