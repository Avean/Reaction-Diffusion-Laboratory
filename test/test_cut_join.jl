# test/test_cut_join.jl — cut, join, flip and graft

const CUT_JOIN_BODY = Body(2.0, 1.0, 0.5)
const INTACT = steady_state(make_state(:gierer_meinhardt_rho; body = CUT_JOIN_BODY, N = 300, initial = (u = 1.0, v = 2.0)))

relative_difference(a, b) = maximum(abs.(a .- b)) / max(1.0, maximum(abs.(b)))

@testset "cut and join" begin
    @test INTACT.info["converged"]
    @test INTACT.info["heads"] == 1
    # The head forms at the head end, on the right of the panel.
    @test only(INTACT.info["head_fractions"]) > 0.9

    # A cut and rejoined state equals the original. split_simulation_state
    # gives each piece N points and merge_simulation_states takes the larger
    # N, both by linear interpolation (as Split and Merge in the window). Where
    # the grids of the pieces contain the original grid points (a cut in the
    # middle) the round trip is exact to rounding; elsewhere linear
    # interpolation cuts the corners of the profile at the original grid
    # points, by up to ~2e-4 of max u at the sharp head of this state.
    for (s_cut, tolerance) in ((0.5, 1e-13), (0.3, 1e-3), (0.71, 1e-3))
        foot = cut(INTACT, s_cut, 1.0)
        head = cut(INTACT, 0.0, s_cut)
        @test panel_length(foot) + panel_length(head) ≈ panel_length(INTACT)
        @test foot.sim.N == head.sim.N == INTACT.sim.N

        rejoined = join(foot, head)
        @test rejoined.sim.N == INTACT.sim.N
        @test rejoined.sim.x ≈ INTACT.sim.x atol = 1e-14
        @test panel_length(rejoined) ≈ panel_length(INTACT)
        for variable in (:u, :v)
            difference = relative_difference(field(rejoined, variable), field(INTACT, variable))
            @test difference < tolerance
            println("  cut at s = $s_cut and join: max |Δ$variable| / max|$variable| = $difference")
        end
        # ρ is linear, so the round trip is exact for it everywhere.
        @test rho_values(rejoined) ≈ rho_values(INTACT) atol = 1e-13
        @test body_coordinates(rejoined) ≈ body_coordinates(INTACT) atol = 1e-12
        @test only(junctions(rejoined)) ≈ only(foot.info["cut"][2:2]) atol = 1e-12
    end

    # A cut keeps u and v: the piece holds the values of the original at the
    # same body coordinates (to the interpolation error of two splits).
    middle = cut(INTACT, 0.2, 0.8)
    @test middle.info["cut"] == [0.2, 0.8]
    @test panel_length(middle) ≈ 1.2
    original_s = body_coordinates(INTACT)
    for variable in (:u, :v)
        expected = C.interpolate_partition_values(reverse(original_s), reverse(field(INTACT, variable)), reverse(body_coordinates(middle)))
        @test relative_difference(reverse(field(middle, variable)), expected) < 1e-3
    end
    @test rho_values(middle) ≈ body_rho.(Ref(CUT_JOIN_BODY), body_coordinates(middle)) atol = 1e-13

    # flip twice is the identity, and joining flipped pieces is the flipped doublet.
    @test field(flip(flip(INTACT)), :u) == field(INTACT, :u)
    @test rho_values(flip(INTACT)) == reverse(rho_values(INTACT))
    foot = cut(INTACT, 0.5, 1.0)
    head = cut(INTACT, 0.0, 0.5)
    doublet = join(foot, head)
    reversed = join(head, foot; flip_left = true, flip_right = true)
    @test relative_difference(field(reversed, :u), reverse(field(doublet, :u))) < 1e-12
    @test body_coordinates(reversed) ≈ reverse(body_coordinates(doublet)) atol = 1e-12

    # Head-to-head doublet: two head pieces, heads facing each other.
    h2h = join(head, head; flip_right = true)
    s = body_coordinates(h2h)
    @test s[1] ≈ 0.5 && s[end] ≈ 0.5
    @test RDLabAPI.body_coordinate(h2h.smap, only(junctions(h2h))) ≈ 0.0 atol = 1e-12
    @test minimum(s) < 1 / h2h.sim.N
    @test panel_length(h2h) ≈ 2.0

    # A piece of another length (another diffusion scale) joins at its physical size.
    small = make_state(:gierer_meinhardt_rho; body = CUT_JOIN_BODY, piece = (0.0, 0.25), N = 120)
    mixed = join(foot, small)
    @test panel_length(mixed) ≈ panel_length(foot) + panel_length(small)
    @test only(junctions(mixed)) ≈ panel_length(foot) / panel_length(mixed)

    # graft: the donor inserted into the host at s.
    donor = make_state(:gierer_meinhardt_rho; body = CUT_JOIN_BODY, piece = (0.0, 0.2), N = 100, label = "donor")
    grafted = graft(INTACT, donor, 0.5)
    @test panel_length(grafted) ≈ panel_length(INTACT) + panel_length(donor)
    @test length(junctions(grafted)) == 2
    @test sort(unique(String[seg.label for seg in grafted.smap])) == ["body", "donor"]
    @test grafted.recipe["op"] == "graft"
    @test grafted.recipe["s"] == 0.5

    # A state is rebuilt from its recipe.
    rebuilt = RDLabAPI.state_from_recipe(middle.recipe)
    @test field(rebuilt, :u) == field(middle, :u)
    @test rho_values(rebuilt) == rho_values(middle)
end
