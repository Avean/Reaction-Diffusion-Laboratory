# The profiles of the former Rho profile model (GiererMeinhardt/rho, removed
# in 46b4ebf), which the two-piece model reproduces: the base profile
# (ρ0 + ρ1 y, or ρa + ρb exp(ρc y) for the Exp... sets) at the coordinate y
# below, left of the split s = ρsplit (x < s) and right of it.
const LEGACY_RHO_COORDINATES = (
    FootHead = ((x, s) -> x, (x, s) -> x),
    HeadFoot = ((x, s) -> x + 1 - s, (x, s) -> x - s),
    FootHeadReverse = ((x, s) -> x, (x, s) -> 1 + s - x),
    HeadFootReverse = ((x, s) -> s - x, (x, s) -> x),
)

function legacy_rho(base, orientation, x, s)
    left, right = LEGACY_RHO_COORDINATES[orientation]
    return [base(s >= 1 || xi < s ? left(xi, s) : right(xi, s)) for xi in x]
end

@testset "Rho profile 2 piece" begin
    params = (ρ0 = 0.75, ρ1 = 0.5, ρa = 0.5, ρb = 0.5, ρc = 1.0)
    bases = (
        Linear = y -> params.ρ0 + params.ρ1 * y,
        Exponential = y -> params.ρa + params.ρb * exp(params.ρc * y),
    )
    # (ρleft, ρright) of the former sets FootHead, HeadFoot, FootHeadReverse,
    # HeadFootReverse (Linear) and ExpFootHead, ExpHeadFoot, ExpFootHeadR,
    # ExpHeadFootR (Exponential).
    for family in (:Linear, :Exponential), split in (0.3, 0.5, 0.7)
        for ((left, right), orientation) in zip(((3, 1), (1, 3), (3, 2), (4, 1)),
                                                (:FootHead, :HeadFoot, :FootHeadReverse, :HeadFootReverse))
            current = make_state(:gierer_meinhardt_rho_two_piece; N = 101, rho = String(family),
                params = merge(params, (ρsplit = split, ρleft = left, ρright = right)))
            @test rho_values(current) ≈ legacy_rho(bases[family], orientation, panel_fractions(current), split)
        end
    end

    # The same source end can be selected for both pieces, with independent orientation.
    current = make_state(:gierer_meinhardt_rho_two_piece; N = 5,
        params = (ρsplit = 0.5, ρleft = 2, ρright = 1, ρ0 = 0, ρ1 = 1))
    @test rho_values(current) ≈ [1.0, 0.75, 0.5, 0.75, 1.0]

    for split in (0.0, 1.0)
        current = make_state(:gierer_meinhardt_rho_two_piece; N = 5,
            params = (ρsplit = split, ρleft = 2, ρright = 4, ρ0 = 0, ρ1 = 1))
        @test rho_values(current) ≈ [1.0, 0.75, 0.5, 0.25, 0.0]
    end
end
