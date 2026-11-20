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
        _, rho_model = find_model(:gierer_meinhardt_rho)
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
        rho_state = make_state(:gierer_meinhardt_rho; N = 101, initial = :model, seed = 3)
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
end
