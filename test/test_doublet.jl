@testset "Source tools: freeze, halves, cut" begin
    @testset "half operations" begin
        U = Float64[1 10; 2 20; 3 30; 4 40]
        expected = Dict(
            :swap => Float64[3 30; 4 40; 1 10; 2 20],
            :flip_left => Float64[2 20; 1 10; 3 30; 4 40],
            :flip_right => Float64[1 10; 2 20; 4 40; 3 30],
            :copy_left_to_right => Float64[1 10; 2 20; 1 10; 2 20],
            :copy_right_to_left => Float64[3 30; 4 40; 3 30; 4 40],
        )
        for operation in C.HALF_OPERATIONS
            @test C.apply_half_operation(U, operation) == expected[operation]
        end
        # The input is not changed.
        @test U == Float64[1 10; 2 20; 3 30; 4 40]

        # With an odd number of points the middle point stays in place.
        V = reshape(collect(1.0:5.0), 5, 1)
        for operation in C.HALF_OPERATIONS
            @test C.apply_half_operation(V, operation)[3, 1] == 3.0
        end
        @test vec(C.apply_half_operation(V, :swap)) == [4.0, 5.0, 3.0, 1.0, 2.0]

        W = reshape(collect(1.0:12.0), 6, 2)
        for operation in (:swap, :flip_left, :flip_right)
            @test C.apply_half_operation(C.apply_half_operation(W, operation), operation) == W
        end
        @test_throws ErrorException C.apply_half_operation(W, :rotate)
    end

    @testset "centred cut range" begin
        # E6 ring: 3.204 of a body of length 8.544 on 1000 points.
        r = C.centered_cut_range(1000, 3.204 / 8.544)
        @test r == 313:688
        @test length(r) == 376

        for (N, fraction) in ((1000, 0.375), (1000, 0.1), (999, 0.375), (101, 0.5), (120, 0.5), (7, 0.6))
            r = C.centered_cut_range(N, fraction)
            @test first(r) - 1 == N - last(r)
            @test isodd(length(r)) == isodd(N)
            @test 1 <= first(r) && last(r) <= N
        end
        @test C.centered_cut_range(1000, 1.0) == 1:1000
        @test C.centered_cut_range(101, 1.0) == 1:101
        for fraction in (0.0, -0.1, 1.5)
            @test_throws ErrorException C.centered_cut_range(1000, fraction)
        end
    end

    @testset "Freeze SD" begin
        key, model = find_model(:gierer_meinhardt_source)
        @test model.freezable_variables == [3]
        @test :frozen in C.public_model_parameter_names(model)
        @test model.default_params[:frozen] == 0.0

        function source_rhs(frozen)
            st = make_state(:gierer_meinhardt_source; N = 51, initial = :model, seed = 1,
                params = (frozen = frozen,))
            sim = st.sim
            U = copy(C.solution_matrix(sim))
            dU = zeros(size(U))
            sim.model.rhs!(dU, U, sim.Lap, sim.x, sim.params, 0.0)
            return sim, dU
        end

        sim, dU = source_rhs(1)
        @test all(iszero, dU[:, 3])
        @test any(!iszero, dU[:, 1])
        @test C.frozen_variable_indices(sim.model, sim.params) == [3]
        @test C.variables_frozen(sim.model, sim.params)

        sim, dU = source_rhs(0)
        @test any(!iszero, dU[:, 3])
        @test isempty(C.frozen_variable_indices(sim.model, sim.params))
        @test !C.variables_frozen(sim.model, sim.params)

        # A model without freezable variables has no parameter frozen.
        _, rho_model = find_model(:gierer_meinhardt_rho_two_piece)
        @test isempty(rho_model.freezable_variables)
        @test !(:frozen in C.public_model_parameter_names(rho_model))

        # Cut and run weights the rate of sd by its time scale τ; the series
        # check without weights is unchanged.
        @test model.freezable_time_scales == [:τ]
        @test C.freezable_rate_weights(model, model.default_params) == [1.0, 1.0, model.default_params[:τ]]
        @test C.freezable_rate_weights(rho_model, rho_model.default_params) == ones(2)
        sim, _ = source_rhs(0)
        plain = C.series_stationarity_residual(sim)
        @test C.series_stationarity_residual(sim; rate_weights = ones(3)) == plain
        @test C.series_stationarity_residual(sim; rate_weights = [1.0, 1.0, 1e5]) >= plain
    end

    @testset "Cut" begin
        st = make_state(:gierer_meinhardt_source; N = 101, length = 2.0, initial = :model, seed = 2)
        U = copy(C.solution_matrix(st.sim))
        piece, len = C.cut_simulation_state(st.sim, 1.0)
        @test len ≈ 1.0
        @test piece.N == 51
        @test C.solution_matrix(piece) == U[26:76, :]
        @test C.diffusion_scale(piece.params) ≈ 1.0
        @test piece.boundary_condition == :neumann
        @test first(piece.x) == 0.0 && last(piece.x) == 1.0
        @test piece.params[:frozen] == 0.0

        frozen_piece, _ = C.cut_simulation_state(st.sim, 1.0; freeze = true)
        @test frozen_piece.params[:frozen] == 1.0
        @test st.sim.params[:frozen] == 0.0

        @test_throws ErrorException C.cut_simulation_state(st.sim, 2.5)
        @test_throws ErrorException C.cut_simulation_state(st.sim, 0.0)

        # A spatial profile would not follow the piece.
        rho_state = make_state(:gierer_meinhardt_rho_two_piece; N = 101, initial = :model, seed = 3)
        @test_throws ErrorException C.cut_simulation_state(rho_state.sim, 0.5)
    end

    @testset "Cut and run" begin
        _, model = find_model(:gierer_meinhardt_source)
        params = Dict{Symbol, Any}(name => model.default_params[name]
                                   for name in C.public_model_parameter_names(model))

        r = C.cut_and_run(model, params; N = 120, body_length = 2.0, cut_length = 1.0,
            settings = C.SeriesSettings())
        @test !r.cancelled
        @test r.outcome.converged
        @test length(r.outcome.heads) == 1
        @test only(r.outcome.heads).position < 0.5
        @test r.length ≈ 2.0 * (length(C.centered_cut_range(120, 0.5)) - 1) / 119
        @test iseven(r.state.N)
        @test r.state.params[:frozen] == 1.0
        @test r.body.params[:frozen] == 0.0
        @test C.solution_matrix(r.state) == C.solution_matrix(r.body)[C.centered_cut_range(120, 0.5), :]
        @test isapprox(C.current_display_time(r.state), 0.0; atol = 1e-12)

        stopped = C.cut_and_run(model, params; N = 40, body_length = 2.0, cut_length = 1.0,
            cancelled = () -> true)
        @test stopped.cancelled
        @test stopped.state === nothing

        @test_throws ErrorException C.cut_and_run(model, params; N = 40, body_length = 1.0, cut_length = 2.0)
    end

    @testset "Cut and run bump" begin
        default_params(model) = Dict{Symbol, Any}(name => model.default_params[name]
                                                  for name in C.public_model_parameter_names(model))
        # cos² over the first CUT_RUN_BUMP_WIDTH of the body, 1 at the left end.
        function bump_profile(sim)
            s = (sim.x .- first(sim.x)) ./ (last(sim.x) - first(sim.x))
            w = C.CUT_RUN_BUMP_WIDTH
            return [si < w ? cos(π * si / (2w))^2 : 0.0 for si in s]
        end

        # A model without cut_run_bump: the first variable only, height 4.
        _, gm = find_model(:gierer_meinhardt_source)
        @test gm.cut_run_bump == [C.CUT_RUN_BUMP_HEIGHT, 0.0, 0.0]
        @test C.CUT_RUN_BUMP_HEIGHT == 4.0
        sim = C.cut_run_initial_state(gm, default_params(gm); N = 101, body_length = 2.0)
        U = C.solution_matrix(sim)
        g = bump_profile(sim)
        @test count(>(0.0), g) == 10
        @test U[:, 1] ≈ 4.0 .* g
        @test U[1, 1] == 4.0
        @test all(iszero, U[:, 2])
        # sd keeps the model's initial condition (1 + 1 % noise), with no bump.
        @test all(abs.(U[:, 3] .- 1.0) .< 0.1)

        # Receptor + Source (c): cut_run_bump = (u = 4.0, v = 1.0).
        _, receptor = find_model(:receptor_based_source_c)
        @test receptor.varnames == ["u", "v", "w", "sd"]
        @test receptor.cut_run_bump == [4.0, 1.0, 0.0, 0.0]
        sim = C.cut_run_initial_state(receptor, default_params(receptor); N = 101, body_length = 7.17)
        U = C.solution_matrix(sim)
        g = bump_profile(sim)
        @test U[:, 1] ≈ 4.0 .* g
        @test U[:, 2] ≈ g
        @test all(iszero, U[:, 3])
        @test all(==(1.0), U[:, 4])      # ic_head = 1: sd = 1
        @test C.diffusion_scale(sim.params) ≈ 7.17^2
        @test sim.params[:frozen] == 0.0

        # Heights passed by the caller (the Bump fields) replace the model's;
        # a height of a freezable variable adds to its initial values.
        sim = C.cut_run_initial_state(receptor, default_params(receptor); N = 101, body_length = 7.17,
            bump_heights = [0.0, 2.5, 0.0, 0.5])
        U = C.solution_matrix(sim)
        @test all(iszero, U[:, 1])
        @test U[:, 2] ≈ 2.5 .* g
        @test U[:, 4] ≈ 1.0 .+ 0.5 .* g
        for heights in ([4.0, 1.0, 0.0], [4.0, -1.0, 0.0, 0.0], [NaN, 1.0, 0.0, 0.0], [Inf, 0.0, 0.0, 0.0], zeros(4))
            @test_throws ErrorException C.cut_run_initial_state(receptor, default_params(receptor);
                N = 101, body_length = 7.17, bump_heights = heights)
        end
        @test_throws ErrorException C.cut_and_run(receptor, default_params(receptor); N = 40,
            body_length = 7.17, cut_length = 2.43, bump_heights = zeros(4))

        # The declaration in RDModel(...).
        declare(bump) = C.RDModel(
            id = :bump_test,
            display_name = "Bump test",
            variables = (:u, :v, :w),
            parameters = (a = 1.0,),
            initial = (U, x, p) -> nothing,
            reaction = (F, U, x, p, t) -> nothing,
            cut_run_bump = bump,
        )
        @test declare(nothing).cut_run_bump == [4.0, 0.0, 0.0]
        @test declare((v = 1.5,)).cut_run_bump == [0.0, 1.5, 0.0]
        @test declare((w = 2, u = 0.5)).cut_run_bump == [0.5, 0.0, 2.0]
        for bad in ((z = 1.0,), (u = -1.0,), (u = Inf,), (u = NaN,), (u = 0.0, v = 0.0),
                    (u = "4",), (u = true,), 4.0, (:u,))
            @test_throws ErrorException declare(bad)
        end
    end
end
