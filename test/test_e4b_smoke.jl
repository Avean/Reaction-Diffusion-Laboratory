# test/test_e4b_smoke.jl — E4b: steady state of the intact animal, cut the
# middle 0.6 L, run a series from that state with wounds at both ends.

@testset "E4b smoke test" begin
    middle = cut(INTACT, 0.2, 0.8)
    @test panel_length(middle) ≈ 0.6 * CUT_JOIN_BODY.L
    runs = 8
    wounds = [Wound(:ends; width = (0.05, 0.10), height = (2.0, 4.0))]
    spec = SeriesSpec(experiment = "E4b_smoke", name = "middle_0.6L", start = middle, wounds = wounds,
        runs = runs, seed = 12345, save_fields = 2)
    result = run_series(spec; out = TEST_OUT, verbose = false)

    for file in ("spec.toml", "meta.json", "outcomes.csv", "summary.json",
                 joinpath("fields", "initial.csv"), joinpath("fields", "run_001.csv"), joinpath("fields", "run_002.csv"))
        @test isfile(joinpath(result.dir, file))
    end
    @test !isfile(joinpath(result.dir, "fields", "run_003.csv"))
    @test occursin(joinpath(TEST_OUT, "E4b_smoke"), result.dir)
    @test endswith(basename(result.dir), "_middle_0.6L")

    lines = readlines(joinpath(result.dir, "outcomes.csv"))
    @test length(lines) == runs + 1
    @test startswith(lines[1], "run,seed,converged,final_time,steps,residual,n_heads,head_x,head_s")
    @test all(o -> o.converged, result.outcomes)

    for o in result.outcomes
        fractions = RDLabAPI.head_fractions(o.heads, middle.sim)
        @test all(p -> 0.0 <= p <= 1.0, fractions)
        @test all(s -> 0.2 - 1e-9 <= s <= 0.8 + 1e-9, RDLabAPI.body_coordinate.(Ref(middle.smap), fractions))
    end

    meta = C.JSON.parsefile(joinpath(result.dir, "meta.json"))
    @test meta["seed"] == 12345
    @test meta["julia_version"] == string(VERSION)
    @test haskey(meta["git"], "commit") && haskey(meta["git"], "dirty")
    @test meta["threads"] == Threads.nthreads()
    @test meta["panel"]["length"] ≈ 1.2
    @test meta["panel"]["N"] == 300
    @test meta["panel"]["diffusion"]["Du"]["D_over_length2"] ≈ 0.01 / 1.2^2
    @test only(meta["panel"]["pieces"])["piece_rule"]["rho0"] ≈ body_rho(CUT_JOIN_BODY, 0.5)
    @test length(meta["wounds"]) == 2
    @test meta["wounds"][1]["width"] ≈ [0.05, 0.10]
    @test meta["wounds"][1]["width_fraction"] ≈ [0.05, 0.10] ./ 1.2

    summary = C.JSON.parsefile(joinpath(result.dir, "summary.json"))
    @test summary["runs"] == runs
    @test sum(values(summary["head_counts"])) == summary["converged"]

    # The realizations do not depend on how many run at once.
    sequential = run_series(spec; out = TEST_OUT, threads = 1, verbose = false)
    @test all(sequential.outcomes[k].final_snapshot.y == result.outcomes[k].final_snapshot.y for k in 1:runs)

    # spec.toml is enough to run the series again.
    again = rerun(joinpath(result.dir, "spec.toml"); out = TEST_OUT, verbose = false)
    @test all(again.outcomes[k].final_snapshot.y == result.outcomes[k].final_snapshot.y for k in 1:runs)

    # run_single computes realization `run` of the series, recording profiles.
    single = SingleSpec(experiment = "E4b_smoke", name = "run3", start = middle, wounds = wounds, run = 3,
        times = [0.0, 10.0, 100.0])
    one = run_single(single; out = TEST_OUT, verbose = false)
    @test isfile(joinpath(one.dir, "profiles.csv"))
    @test length(readlines(joinpath(one.dir, "profiles.csv"))) == 1 + 3 * 300
    @test [t for (t, _) in one.snapshots] == [0.0, 10.0, 100.0]
    @test length(one.outcome.heads) == length(result.outcomes[3].heads)
end
