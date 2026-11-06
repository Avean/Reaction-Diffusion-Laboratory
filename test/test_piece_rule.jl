# test/test_piece_rule.jl — body coordinates and the piece rule

@testset "piece rule" begin
    body = Body(2.0, 1.0, 0.5)

    # ρ_body(s) = ρ0 + ρ1 (1/2 - s): highest at the head (s = 0).
    @test body_rho(body, 0.0) == 1.25
    @test body_rho(body, 0.5) == 1.0
    @test body_rho(body, 1.0) == 0.75

    p = piece(body, 0.2, 0.8)
    @test p.length ≈ 0.6 * 2.0
    @test p.ρ1 ≈ 0.5 * 0.6
    @test p.ρ0 ≈ body_rho(body, 0.5)
    q = piece(body, 0.7, 1.0)
    @test q.ρ0 ≈ body_rho(body, 0.85)
    @test q.ρ1 ≈ 0.15
    @test_throws ErrorException piece(body, 0.8, 0.2)
    @test_throws ErrorException piece(body, -0.1, 0.5)

    for (s_a, s_b) in ((0.0, 1.0), (0.0, 0.3), (0.2, 0.8), (0.7, 1.0), (0.1, 0.2))
        st = make_state(:gierer_meinhardt_rho; body = body, piece = (s_a, s_b), N = 101)
        f = s_b - s_a
        x = panel_fractions(st)
        s = body_coordinates(st)
        rho = rho_values(st)

        # The head side is on the right: x = 1 is s_a, x = 0 is s_b.
        @test s ≈ s_b .- f .* x atol = 1e-14
        @test rho[end] ≈ body_rho(body, s_a) atol = 1e-14
        @test rho[1] ≈ body_rho(body, s_b) atol = 1e-14
        @test issorted(rho)
        # ρ on the panel is the body's ρ at the same body coordinate.
        @test rho ≈ body_rho.(Ref(body), s) atol = 1e-14
        # The panel: ρ(x) = ρ0p - ρ1p/2 + ρ1p x.
        pc = piece(body, s_a, s_b)
        @test rho ≈ pc.ρ0 .- pc.ρ1 / 2 .+ pc.ρ1 .* x atol = 1e-15
        @test panel_length(st) ≈ f * body.L

        parameters = panel_parameters(st)
        @test parameters["length"] ≈ f * body.L
        @test parameters["diffusion"]["Du"]["D_over_length2"] ≈ 0.01 / (f * body.L)^2
        @test parameters["diffusion"]["Dv"]["D_over_length2"] ≈ 1.0 / (f * body.L)^2
        piece_rule = only(parameters["pieces"])["piece_rule"]
        @test piece_rule["rho0"] ≈ pc.ρ0
        @test piece_rule["rho1"] ≈ pc.ρ1
    end

    # Without source density ρ ≡ ρ0, exactly.
    flat = make_state(:gierer_meinhardt_rho; body = without_sd(body), piece = (0.2, 0.8), N = 300)
    @test all(==(1.0), rho_values(flat))

    # The piece rule agrees with cutting the same piece out of the whole body.
    whole = make_state(:gierer_meinhardt_rho; body = body, N = 301)
    middle = cut(whole, 0.2, 0.8)
    @test middle.info["cut"] ≈ [0.2, 0.8] atol = 1 / 301
    @test rho_values(middle) ≈ body_rho.(Ref(body), body_coordinates(middle)) atol = 1e-12

    # Adjacent pieces meet with the same ρ.
    head_half = make_state(:gierer_meinhardt_rho; body = body, piece = (0.0, 0.5), N = 50)
    foot_half = make_state(:gierer_meinhardt_rho; body = body, piece = (0.5, 1.0), N = 50)
    @test rho_values(foot_half)[end] ≈ rho_values(head_half)[1]

    # ρ given directly: an array, a linear panel profile, a function.
    values = collect(range(0.5, 1.5; length = 80))
    @test rho_values(make_state(:gierer_meinhardt_rho; N = 80, rho = values)) == values
    linear = make_state(:gierer_meinhardt_rho; N = 80, rho = (ρ0 = 1.0, ρ1 = 0.4))
    @test rho_values(linear) ≈ 1.0 .- 0.2 .+ 0.4 .* panel_fractions(linear)
    @test rho_values(make_state(:gierer_meinhardt_rho; N = 80, rho = x -> 2x)) ≈ 2 .* panel_fractions(linear)
    # The model's own profile: FootHead is ρ0 + ρ1 x in the current model file.
    model_profile = make_state(:gierer_meinhardt_rho; N = 80, params = (ρ0 = 0.75, ρ1 = 0.5), rho = "FootHead")
    @test rho_values(model_profile) ≈ 0.75 .+ 0.5 .* panel_fractions(model_profile)
end
