@testset "Rho profile 2 piece" begin
    for (family, references) in (
        ("Linear", ("FootHead", "HeadFoot", "FootHeadReverse", "HeadFootReverse")),
        ("Exponential", ("ExpFootHead", "ExpHeadFoot", "ExpFootHeadR", "ExpHeadFootR")),
    ), split in (0.3, 0.5, 0.7)
        for ((left, right), reference) in zip(((3, 1), (1, 3), (3, 2), (4, 1)), references)
            params = (ρsplit = split,)
            legacy = make_state(:gierer_meinhardt_rho; N = 101, params, rho = reference)
            current = make_state(:gierer_meinhardt_rho_two_piece; N = 101, rho = family,
                params = merge(params, (ρleft = left, ρright = right)))
            @test rho_values(current) ≈ rho_values(legacy)
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
