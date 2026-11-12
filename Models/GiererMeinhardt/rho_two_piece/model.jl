let
    # q is the distance along this piece on the combined [0, 1] axis.
    # The choices are Top →, Top ←, Bottom →, Bottom ←, in that order.
    source_coordinate(q, width, choice) = (1 - width + q, 1 - q, q, width - q)[choice]

    function two_piece_profile(f, x, p)
        split = clamp(p.ρsplit, 0.0, 1.0)
        left = round(Int, clamp(p.ρleft, 1, 4))
        right = round(Int, clamp(p.ρright, 1, 4))
        return [
            split == 1.0 || xi < split ?
                f(source_coordinate(xi, split, left)) :
                f(source_coordinate(xi - split, 1 - split, right))
            for xi in x
        ]
    end

    note = "The formula shows the base profile. Top takes its headward end, Bottom its footward end. Each piece keeps the width it occupies in the joined profile."

    # E6 ring doublets of the RoleOfSource project: the base profile covers the
    # body segment s = 0.3125–0.6875 of an animal of length 8.544 (s = distance
    # from the head as a fraction of the body), with x = 0 at its footward end
    # (s = 0.6875) and x = 1 at its headward end (s = 0.3125). Away from the
    # head the steady source density of the dynamic SD model is
    # C cosh(L (1 - s) / ℓ) with ℓ = sqrt(Dsd / μsd).
    e6_body_length = 8.544
    e6_s_head = 0.3125
    e6_s_foot = 0.6875
    function e6_cosh(C, ℓ)
        return source_x -> begin
            s = e6_s_foot - (e6_s_foot - e6_s_head) * source_x
            C * cosh(e6_body_length * (1 - s) / ℓ)
        end
    end
    e6_note(variant) = "Steady SD profile of the dynamic model ($(variant)) on the E6 ring segment s = 0.3125–0.6875 of a body of length 8.544. Top is the upper ring (s = 0.3125–0.5), Bottom the lower ring (s = 0.5–0.6875). Set the domain length to 3.204 and ρsplit to 0.5. " * note

    RDModel(
        id = :gierer_meinhardt_rho_two_piece,
        display_name = "Rho profile 2 piece",
        description = "A shared source-density profile assembled from two independently oriented pieces.",
        variables = (:u, :v),
        parameters = (
            Du = 1e-2,
            Dv = 1e0,
            a = 1.5,
            b = 2.0,
            μu = 0.5,
            μv = 1.0,
            pu = 0.0,
            pv = 0.0,
            ρsplit = 0.5,
            ρleft = 3,
            ρright = 1,
            ρ0 = 0.75,
            ρ1 = 0.5,
            ρa = 0.5,
            ρb = 0.5,
            ρc = 1.0,
        ),
        initial = function (U, x, p)
            U.u .= 1.0 .+ 0.01 .* randn(length(x))
            U.v .= 2.0 .+ 0.01 .* randn(length(x))
            return nothing
        end,
        reaction = function (F, U, x, p, t)
            @. F.u = p.a * p.ρ * U.u^2 / (U.v + 1.0) - p.μu * U.u + p.pu
            @. F.v = p.b * p.ρ * U.u^2 - p.μv * U.v + p.pv
            return nothing
        end,
        diffusion = (u = :Du, v = :Dv),
        spatial_profiles = (
            Linear = (
                ρ = (x, p) -> two_piece_profile(source_x -> p.ρ0 + p.ρ1 * source_x, x, p),
                formula = raw"\rho(x) = \rho_0 + \rho_1 x,\quad x \in [0,1]",
                parameters = (:ρsplit, :ρleft, :ρright, :ρ0, :ρ1),
                note = note,
            ),
            Exponential = (
                ρ = (x, p) -> two_piece_profile(source_x -> p.ρa + p.ρb * exp(p.ρc * source_x), x, p),
                formula = raw"\rho(x) = \rho_a + \rho_b e^{\rho_c x},\quad x \in [0,1]",
                parameters = (:ρsplit, :ρleft, :ρright, :ρa, :ρb, :ρc),
                note = note,
            ),
            SD_current = (
                ρ = (x, p) -> two_piece_profile(e6_cosh(0.702, 3.1344647034939954), x, p),
                formula = raw"\rho(x) = 0.702\,\mathrm{cosh}(8.544\,(1 - s)/3.1345),\quad s = 0.6875 - 0.375\,x",
                parameters = (:ρsplit, :ρleft, :ρright),
                note = e6_note("current: Dsd = 1.0427, μsd = 0.1061"),
            ),
            SD_variant_B = (
                ρ = (x, p) -> two_piece_profile(e6_cosh(0.3683936561746725, 2.078982984695077), x, p),
                formula = raw"\rho(x) = 0.3684\,\mathrm{cosh}(8.544\,(1 - s)/2.0790),\quad s = 0.6875 - 0.375\,x",
                parameters = (:ρsplit, :ρleft, :ρright),
                note = e6_note("variant B: Dsd = 0.3289, μsd = 0.0761"),
            ),
        ),
        latex_equations = (
            raw"\partial_t u = D_u \partial_{xx} u + a\cdot\rho(x) \frac{u^2}{v + 1} - \mu_u u + p_u",
            raw"\partial_t v = D_v \partial_{xx} v + b\cdot\rho(x) u^2 - \mu_v v + p_v",
        ),
    )
end
