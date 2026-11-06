# test/tools/make_old_app_fixtures.jl
#
# Drives the application as it was at commit 7e05f77 (before the Nov 5
# changes: Save graph, parameters.txt with D divided by the domain scale,
# linear ρ profiles ρ0 - ρ1/2 + ρ1 x) through the controller functions its
# buttons call, runs two series and saves them with Save graph. This is how
# the folders in test/saved_graphs/ were made:
#
#     git worktree add /tmp/oldapp 7e05f77
#     xvfb-run -a julia --project=. --threads=4 test/tools/make_old_app_fixtures.jl /tmp/oldapp
#
# The folders appear in /tmp/oldapp/saved_graphs/.

const OLD = ARGS[1]
include(joinpath(OLD, "src", "StartupSplash.jl"))
using .StartupSplash
import QML
import GLMakie, QMLMakie, CairoMakie
import DifferentialEquations
include(joinpath(OLD, "src", "ReactionDiffusionApp.jl"))
include(joinpath(OLD, "src", "QMLInterface.jl"))
using .ReactionDiffusionQML
const Q = ReactionDiffusionQML

# Slider exponents: -2 + k * 3 / 99 (finest domain-slider resolution).
const CASES = [
    (name = "E4a_like_noSD", params = ["ρ0" => "1", "ρ1" => "0"], k = 71, preset = "ends_and_center.toml", runs = 24),
    (name = "E4a_like_SD", params = ["ρ0" => "1", "ρ1" => "0.5"], k = 80, preset = "ends_and_center.toml", runs = 24),
]

const STATUS = Dict{String, Any}()

function check(c, what)
    message = c.bindings.message[]
    isempty(message) || error("$what: $message")
end

function drive()
    c = nothing
    try
        while (c = Q.ACTIVE_QML_CONTROLLER[]) === nothing || !c.bindings.main_window_visible[]
            sleep(0.2)
        end
        sleep(1.0)
        for case in CASES
            Q.select_model!(c, "GiererMainhardt/rho"); check(c, "model")
            for (name, value) in case.params
                Q.set_model_parameter_from_qml!(c, name, value); check(c, name)
            end
            Q.set_domain_exponent!(c, -2 + case.k * (3 / 99)); check(c, "domain")
            Q.set_series_mode!(c, true); check(c, "series mode")
            Q.select_series_preset!(c, case.preset); check(c, "preset")
            Q.set_series_integer_setting!(c, :run_count, case.runs); check(c, "runs")
            Q.start_series!(c)
            t0 = time()
            sleep(1.0)
            while c.series.running[] || (c.series.task_ref[] !== nothing && !istaskdone(c.series.task_ref[]))
                sleep(0.5)
            end
            sleep(1.0)
            println("[old gui] $(case.name): ", c.series.status, " in ", round(time() - t0; digits = 1), " s; head counts ",
                sort(collect(c.series.head_count_counts[1])))
            flush(stdout)
            Q.save_graphs!(c); check(c, "save graphs")
            println("[old gui] ", c.bindings.notice[])
            flush(stdout)
            sleep(1.2)
            Q.set_series_mode!(c, false); check(c, "leave series mode")
        end
    catch error
        STATUS["error"] = sprint(showerror, error, catch_backtrace())
    finally
        c === nothing || (c.close_requested[] = true)
    end
end

driver = @async drive()
Q.run_qml_app(N = 300)
wait(driver)
haskey(STATUS, "error") && error(STATUS["error"])
