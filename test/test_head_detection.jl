# test/test_head_detection.jl
#
# Head detection on synthetic profiles: heads at a Neumann boundary, with the
# maximum on the boundary or a little inside the panel (a plateau head with a
# shallow dip at the boundary, as the receptor model forms after Cut and run),
# small bumps that must not count, and a periodic domain.

@testset "head detection" begin
    N = 300
    x = collect(range(0.0, 1.0; length = N))
    heads(u; bc = :neumann) = [h.position for h in C.detect_heads(u, x; boundary_condition = bc)]
    bump(c, w) = @. exp(-((x - c) / w)^2)

    # A plateau head at an end whose maximum lies inside the panel: u = 2.95
    # at x ≈ 0.037 and 2.9155 at the boundary (as the receptor head).
    plateau = @. 0.001 + 2.95 / (1 + exp((x - 0.08) / 0.01)) - 0.035 * exp(-(x / 0.03)^2)
    @test argmax(plateau) > 1
    @test plateau[1] < maximum(plateau)
    @test length(heads(plateau)) == 1
    @test only(heads(plateau)) < 0.08
    @test length(heads(reverse(plateau))) == 1
    @test only(heads(reverse(plateau))) > 0.92

    # The same head with a higher head elsewhere: both count.
    two = plateau .+ 4.0 .* bump(0.7, 0.03)
    @test length(heads(two)) == 2

    # A head with its maximum on the boundary (half of a mirrored head).
    @test heads(bump(1.0, 0.05)) == [1.0]
    @test heads(bump(0.0, 0.05)) == [0.0]

    # One head in the middle and two heads.
    @test length(heads(bump(0.5, 0.05))) == 1
    @test length(heads(bump(0.25, 0.05) .+ bump(0.75, 0.05))) == 2

    # A small bump next to the boundary, beside a big head, stays below the
    # prominence threshold (5 % of the range, at least 0.1).
    small = 3.0 .* bump(1.0, 0.05) .+ 0.05 .* bump(0.02, 0.02)
    @test heads(small) == [1.0]

    # Flat and nearly flat profiles have no head.
    @test isempty(heads(fill(1.0, N)))
    @test isempty(heads(1.0 .+ 0.01 .* sin.(20 .* x)))

    # Periodic domain (grid without the repeated end point): two heads, and a
    # head across the seam counts once.
    xp = collect(0:(N - 1)) ./ N
    pheads(u) = [h.position for h in C.detect_heads(u, xp; boundary_condition = :periodic)]
    pbump(c, w) = @. exp(-(min(abs(xp - c), 1 - abs(xp - c)) / w)^2)
    @test length(pheads(pbump(0.25, 0.05) .+ pbump(0.75, 0.05))) == 2
    @test pheads(pbump(0.0, 0.05)) == [0.0]
    @test length(pheads(pbump(0.999, 0.05))) == 1
end
