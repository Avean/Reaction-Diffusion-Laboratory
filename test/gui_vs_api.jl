# test/gui_vs_api.jl
#
# The application and the scripting API compute the same series.
#
# Starts the real application (needs a display; on a headless machine run it
# under xvfb-run), drives its series window through the same controller
# functions the buttons call (model, parameters, domain slider, series mode,
# preset, run count, Start, Save series, Save / Load), closes it, then runs
# the same series with RDLabAPI and compares every realization:
#
#   - computed as the application does (threads = 1, mkl_threads = :default):
#     the final profiles must be bitwise identical;
#   - with the API defaults (parallel, one MKL thread per factorization): the
#     same heads in every run, profiles equal up to ~1e-9.
#
#     xvfb-run -a julia --project --threads=4 test/gui_vs_api.jl

using Test
using Dates
import TOML

const REPO = normpath(joinpath(@__DIR__, ".."))
const SCRATCH = mktempdir()

include(joinpath(REPO, "src", "StartupSplash.jl"))
using .StartupSplash
import QML
import GLMakie, QMLMakie, CairoMakie
import DifferentialEquations
include(joinpath(REPO, "src", "ReactionDiffusionApp.jl"))
include(joinpath(REPO, "src", "QMLInterface.jl"))
using .ReactionDiffusionQML
const Q = ReactionDiffusionQML

# Two series of the Rho profile model on a panel of length 1.2: without
# source density (ρ ≡ 1) and with it (FootHead ρ0 + ρ1 x).
const CASES = [
    (name = "no_SD", params = ["ρ0" => "1", "ρ1" => "0"], exponent = 2 * log10(1.2),
     preset = "ends_and_center.toml", runs = 12),
    (name = "SD", params = ["ρ0" => "0.85", "ρ1" => "0.3"], exponent = 2 * log10(1.2),
     preset = "left_center_right.toml", runs = 12),
]

const GUI = Dict{String, Any}()

function check_message(c, what)
    message = c.bindings.message[]
    isempty(message) || error("$what failed in the application: $message")
    return nothing
end

function drive_application()
    c = nothing
    try
        while (c = Q.ACTIVE_QML_CONTROLLER[]) === nothing || !c.bindings.main_window_visible[]
            sleep(0.2)
        end
        sleep(1.0)

        for case in CASES
            Q.select_model!(c, "GiererMeinhardt/rho")
            check_message(c, "Model selection")
            for (name, value) in case.params
                Q.set_model_parameter_from_qml!(c, name, value)
                check_message(c, "Parameter $name")
            end
            Q.set_domain_exponent!(c, case.exponent)
            check_message(c, "Domain rescale")
            Q.set_series_mode!(c, true)
            check_message(c, "Series mode")
            Q.select_series_preset!(c, case.preset)
            check_message(c, "Series preset")
            Q.set_series_integer_setting!(c, :run_count, case.runs)
            check_message(c, "Run count")
            Q.start_series!(c)
            started = time()

            while c.series.running[] || c.series.task_ref[] !== nothing
                time() - started < 1800 || error("The application series did not finish.")
                sleep(0.5)
            end

            lock(c.series.lock)
            try
                GUI[case.name] = (
                    completed = c.series.completed_runs,
                    patterns = deepcopy(c.series.patterns[1]),
                    converged = copy(c.series.pattern_converged[1]),
                    head_counts = copy(c.series.head_count_counts[1]),
                    groups = [(g.reference, g.count) for g in c.series.configuration_groups[1]],
                    status = c.series.status,
                    elapsed = time() - started,
                )
            finally
                unlock(c.series.lock)
            end

            Q.save_series!(c, "gui_vs_api_$(case.name)"; root = SCRATCH)
            check_message(c, "Save series")
            Q.set_series_mode!(c, false)
            check_message(c, "Leaving series mode")
            println("[gui] $(case.name): ", GUI[case.name].status, " in ", round(GUI[case.name].elapsed; digits = 1), " s")
        end

        # Save and Load of the simulation, through the split SaveLoad files.
        Q.save_simulation!(c, "gui_vs_api"; root = SCRATCH)
        check_message(c, "Save")
        directory = joinpath(SCRATCH, "simulation", "gierer_meinhardt_rho")
        file = only(filter(name -> endswith(name, ".json"), readdir(directory)))
        GUI["load"] = Q.load_simulation_save!(c, file; root = SCRATCH)
        check_message(c, "Load")

        Q.select_model!(c, "GiererMeinhardt/rho_two_piece")
        check_message(c, "Two-piece model selection")
        for (name, value) in (("ρsplit", "0.3"), ("ρleft", "1"), ("ρright", "3"))
            Q.set_model_parameter_from_qml!(c, name, value)
            check_message(c, "Two-piece parameter $name")
        end
        Q.select_spatial_profile_set!(c, 2)
        check_message(c, "Exponential profile selection")
        Q.save_simulation!(c, "two_piece"; root = SCRATCH)
        check_message(c, "Save two-piece model")
        Q.select_spatial_profile_set!(c, 1)
        check_message(c, "Linear profile selection")
        Q.set_model_parameter_from_qml!(c, "ρleft", "3")
        check_message(c, "Change left piece")
        directory = joinpath(SCRATCH, "simulation", "gierer_meinhardt_rho_two_piece")
        file = only(filter(name -> endswith(name, ".json"), readdir(directory)))
        GUI["two_piece_load"] = Q.load_simulation_save!(c, file; root = SCRATCH)
        check_message(c, "Load two-piece model")
        GUI["two_piece_set"] = c.bindings.active_profile_set[]
        GUI["two_piece_profile"] = only(Q.RD.current_spatial_profile_values(c.app.simulations))["ρ"]

        GUI["sidebar_profiles"] = String[]
        for (key, index) in (("rho", 7), ("rho_independent", 2), ("rho_graft", 2))
            Q.select_model!(c, "GiererMeinhardt/$key")
            check_message(c, "Model selection for $key")
            Q.select_spatial_profile_set!(c, index)
            check_message(c, "Sidebar profile selection for $key")
            sets = c.app.sim.model.spatial_profile_sets
            push!(GUI["sidebar_profiles"], first(sets[c.bindings.active_profile_set[]]))
        end

        # Save preset and Delete preset of the series window, into a scratch
        # folder instead of the model folder.
        Q.select_model!(c, "GiererMeinhardt/rho")
        check_message(c, "Model selection for presets")
        Q.set_series_mode!(c, true)
        check_message(c, "Series mode for presets")
        Q.select_series_preset!(c, "three_wounds_narrow.toml")
        check_message(c, "Series preset for Save preset")
        folder = mkpath(joinpath(SCRATCH, "presets"))
        name = "GUI ends"
        before = Q.JSON.parse(Q.series_preset_target_json(c, name; directory = folder))
        Q.save_series_preset!(c, name, "Saved by the test", false; directory = folder)
        check_message(c, "Save preset")
        path = joinpath(folder, "gui_ends.toml")
        saved = Q.RD.load_series_preset(path, "GiererMeinhardt/rho")
        panel = filter(p -> p.segment == 1, c.series.perturbations)
        varnames = c.app.simulations[1].model.varnames
        after = Q.JSON.parse(Q.series_preset_target_json(c, name; directory = folder))
        listed = Q.JSON.parse(c.bindings.series_presets_json[])
        GUI["preset_saved"] = (
            target = (before["exists"], after["exists"], endswith(before["file"], "/gui_ends.toml")),
            selected = c.bindings.series_selected_preset[],
            listed = any(entry -> entry["key"] == "gui_ends.toml", listed),
            values = [(p.variable_name, p.position_fraction, p.width_min_fraction, p.width_max_fraction,
                       p.height_min, p.height_max) for p in saved.perturbations],
            panel = [(varnames[p.variable], p.position, p.width_min, p.width_max,
                      p.height_min, p.height_max) for p in panel],
        )
        Q.save_series_preset!(c, name, "Not saved", false; directory = folder)
        GUI["preset_refused"] = !isempty(c.bindings.message[]) &&
                                Q.RD.load_series_preset(path, "GiererMeinhardt/rho").description == "Saved by the test"
        Q.save_series_preset!(c, name, "Replaced", true; directory = folder)
        check_message(c, "Replace preset")
        GUI["preset_replaced"] = Q.RD.load_series_preset(path, "GiererMeinhardt/rho").description
        Q.delete_series_preset!(c, "gui_ends.toml")
        check_message(c, "Delete preset")
        listed = Q.JSON.parse(c.bindings.series_presets_json[])
        GUI["preset_deleted"] = (
            file = isfile(path),
            listed = any(entry -> entry["key"] == "gui_ends.toml", listed),
            selected = c.bindings.series_selected_preset[],
            kept = count(p -> p.segment == 1, c.series.perturbations),
        )

        # A minimum above the maximum raises the maximum, a maximum below the
        # minimum lowers the minimum (the fields of a perturbation card).
        edited = first(filter(p -> p.segment == 1, c.series.perturbations))
        ranges = Tuple{Float64, Float64, Float64, Float64}[]
        for (field, value) in (("heightMin", "3"), ("heightMax", "1"), ("widthMin", "0.5"), ("widthMax", "0.02"))
            Q.update_series_perturbation!(c, edited.id, field, value)
            check_message(c, "Perturbation field $field")
            push!(ranges, (edited.width_min, edited.width_max, edited.height_min, edited.height_max))
        end
        GUI["ranges"] = ranges
        Q.set_series_mode!(c, false)
        check_message(c, "Leaving series mode after presets")
    catch error
        GUI["error"] = sprint(showerror, error, catch_backtrace())
    finally
        c === nothing || (c.close_requested[] = true)
    end
end

driver = @async drive_application()
Q.run_qml_app(N = 300)
wait(driver)
haskey(GUI, "error") && error(GUI["error"])

# ------------------------------------------------------------
# The same series with the scripting API
# ------------------------------------------------------------

include(joinpath(REPO, "src", "RDLabAPI.jl"))
using .RDLabAPI

function api_spec(case)
    params = Dict(Symbol(name) => parse(Float64, value) for (name, value) in case.params)
    start = make_state(
        :gierer_meinhardt_rho;
        N = 300,
        diffusion_scale = 10.0^case.exponent,
        params = params,
        rho = "FootHead",
        initial = :rest,
    )
    preset = TOML.parsefile(joinpath(REPO, "Models", "GiererMeinhardt", "rho", case.preset))
    wounds = [
        Wound(
            p["position"];
            width_fraction = (p["width_min_fraction"], p["width_max_fraction"]),
            height = (p["height_min"], p["height_max"]),
            variable = p["variable"],
        )
        for p in preset["perturbations"]
    ]
    return SeriesSpec(experiment = "gui_vs_api", name = case.name, start = start, wounds = wounds,
        runs = case.runs, seed = 12345)
end

@testset "application and API compute the same series" begin
    @test GUI["load"] == true
    @test GUI["two_piece_load"] == true
    @test GUI["two_piece_set"] == 2
    legacy = make_state(:gierer_meinhardt_rho; N = 300, params = (ρsplit = 0.3,), rho = "ExpHeadFoot")
    @test GUI["two_piece_profile"] ≈ rho_values(legacy)
    @test GUI["sidebar_profiles"] == ["ExpHeadFoot", "Exponential", "Gauss"]

    saved = GUI["preset_saved"]
    @test saved.target == (false, true, true)
    @test saved.selected == "gui_ends.toml"
    @test saved.listed
    @test saved.values == saved.panel
    @test length(saved.values) == 3
    @test GUI["preset_refused"]
    @test GUI["preset_replaced"] == "Replaced"
    @test GUI["preset_deleted"] == (file = false, listed = false, selected = "custom", kept = 3)
    # Starting from widths 0.03–0.06 and heights 1.6–2.6 (three_wounds_narrow).
    @test GUI["ranges"] == [
        (0.03, 0.06, 3.0, 3.0),
        (0.03, 0.06, 1.0, 1.0),
        (0.5, 0.5, 1.0, 1.0),
        (0.02, 0.02, 1.0, 1.0),
    ]

    catalog = Q.JSON.parse(Q.model_catalog_json(Q.RD.MODEL_REGISTRY))
    profile_sets = Dict(entry["key"] => entry["profileSets"] for family in catalog for entry in family["models"])
    @test profile_sets["GiererMeinhardt/rho"][7] == "ExpHeadFoot"
    @test profile_sets["GiererMeinhardt/rho_independent"] == ["Linear", "Exponential"]
    @test profile_sets["GiererMeinhardt/rho_graft"] == ["Linear", "Gauss"]
    @test isempty(profile_sets["GiererMeinhardt/source"])

    for case in CASES
        gui = GUI[case.name]
        spec = api_spec(case)
        exact = run_series(spec; out = SCRATCH, threads = 1, mkl_threads = :default, verbose = false)
        fast = run_series(spec; out = SCRATCH, verbose = false)

        @testset "$(case.name)" begin
            @test gui.completed == case.runs
            # Computed as the application computes: bitwise the same.
            @test all(exact.outcomes[k].final_snapshot.y[1:300] == gui.patterns[k] for k in 1:case.runs)
            @test [o.converged for o in exact.outcomes] == gui.converged
            api_counts = Dict{Int, Int}()
            for o in exact.outcomes
                o.converged && (api_counts[length(o.heads)] = get(api_counts, length(o.heads), 0) + 1)
            end
            @test api_counts == gui.head_counts
            # API defaults: the same heads, profiles equal to rounding.
            @test [length(o.heads) for o in fast.outcomes] == [length(o.heads) for o in exact.outcomes]
            difference = maximum(maximum(abs.(fast.outcomes[k].final_snapshot.y[1:300] .- gui.patterns[k])) for k in 1:case.runs)
            @test difference < 1e-9
            println("[api] $(case.name): head counts ", sort(collect(api_counts)), "; exact $(round(exact.wall_time; digits = 1)) s, ",
                "parallel $(round(fast.wall_time; digits = 1)) s; largest difference of the parallel run $(difference)")
        end
    end
end
