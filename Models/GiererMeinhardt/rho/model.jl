# Models/GiererMeinhardt/rho/model.jl

# ============================================================
# Gierer-Meinhardt system with a source density rho(x)
# ============================================================
#
# Model:
#
#     u_t = Du u_xx + a rho(x) u^2 / (v + 1) - mu_u u + p_u
#     v_t = Dv v_xx + b rho(x) u^2 - mu_v v + p_v
#
# rho(x) is one of the profiles below, with x in [0, 1] whatever the
# domain length. Linear profiles are built from rho0 + rho1 y, exponential
# ones from rhoa + rhob exp(rhoc y). The two-part profiles jump at
# x = ρsplit, a fraction of the domain; 0 or 1 leaves a single part.
#
# ============================================================

let
    # x lies in the left part of a two-part profile.
    split_point(p) = clamp(p.ρsplit, 0.0, 1.0)
    left_of_split(x, s) = s >= 1 || x < s

    # Values of a two-part profile: left(x, s) left of the jump, right(x, s)
    # right of it.
    function two_parts(x, p, left, right)
        s = split_point(p)
        return [left_of_split(xi, s) ? left(xi, s) : right(xi, s) for xi in x]
    end

    linear(p, y) = p.ρ0 + p.ρ1 * y

    # The linear profile restarting at its two drops ρz1 and ρz2.
    function zigzag(p, x)
        x < p.ρz1 && return linear(p, x)
        x < p.ρz2 && return linear(p, x - p.ρz1)
        return linear(p, x - p.ρz2)
    end

    # In a series realization (rng given) the parts left and right of the
    # jump draw their own ρa, ρb, ρc, varied by a relative ±ρσa, ±ρσb, ±ρσc
    # (uniform); outside series mode both use the nominal values.
    function exponential_parts(p, rng)
        vary(value, σ) = rng === nothing ? value : value * (1 + σ * (2 * rand(rng) - 1))
        draw() = (a = vary(p.ρa, p.ρσa), b = vary(p.ρb, p.ρσb), c = vary(p.ρc, p.ρσc))
        left = draw()
        right = draw()
        return left, right
    end

    exponential(e, y) = e.a + e.b * exp(e.c * y)

    exponential_note = "Series: the parts left and right of ρsplit draw their own ρa, ρb, ρc in every run, each within ±ρσa, ±ρσb, ±ρσc (relative). With all ρσ = 0 nothing is random."

    RDModel(
        id = :gierer_meinhardt,

        display_name = "Rho profile",
        description = "A Gierer-Meinhardt model modulated by the spatial profile rho(x). Used to test the role of spatial gradient",

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

            # Linear profiles: ρ0 + ρ1 y
            ρ0 = 0.75,
            ρ1 = 0.5,

            # Two-part profiles: position of the jump between the parts, as
            # a fraction of the whole domain.
            ρsplit = 0.5,

            # ZigZag: positions of its two drops, as fractions of the domain.
            ρz1 = 0.2,
            ρz2 = 0.9,

            # Exponential profiles: ρa + ρb exp(ρc y)
            ρa = 0.5,
            ρb = 0.5,
            ρc = 1.0,

            # Series mode only: relative variation of ρa, ρb, ρc, drawn
            # separately for each part of the domain in every realization.
            ρσa = 0.0,
            ρσb = 0.0,
            ρσc = 0.0,
        ),

        initial = function (U, x, p)

            u0 = 1.0
            v0 = 2.0

            U.u .= u0 .+ 0.01 .* randn(length(x))
            U.v .= v0 .+ 0.01 .* randn(length(x))

            return nothing
        end,

        reaction = function (F, U, x, p, t)
            @. F.u = p.a * p.ρ * U.u^2 / (U.v + 1.0) - p.μu * U.u + p.pu
            @. F.v = p.b * p.ρ * U.u^2 - p.μv * U.v + p.pv

            return nothing
        end,

        diffusion = (
            u = :Du,
            v = :Dv,
        ),

        spatial_profiles = (
            FootHead = (
                ρ = (x, p) -> [linear(p, xi) for xi in x],
                formula = raw"\rho(x) = \rho_0 + \rho_1 x",
            ),

            HeadFoot = (
                ρ = (x, p) -> two_parts(
                    x, p,
                    (xi, s) -> linear(p, xi + 1 - s),
                    (xi, s) -> linear(p, xi - s),
                ),
                formula = piecewise(raw"\rho(x)",
                    raw"\rho_0 + \rho_1 (x + 1 - \rho_{split})" => raw"x < \rho_{split}",
                    raw"\rho_0 + \rho_1 (x - \rho_{split})" => raw"x \geq \rho_{split}",
                ),
            ),

            FootHeadReverse = (
                ρ = (x, p) -> two_parts(
                    x, p,
                    (xi, s) -> linear(p, xi),
                    (xi, s) -> linear(p, 1 + s - xi),
                ),
                formula = piecewise(raw"\rho(x)",
                    raw"\rho_0 + \rho_1 x" => raw"x < \rho_{split}",
                    raw"\rho_0 + \rho_1 (1 + \rho_{split} - x)" => raw"x \geq \rho_{split}",
                ),
            ),

            HeadFootReverse = (
                ρ = (x, p) -> two_parts(
                    x, p,
                    (xi, s) -> linear(p, s - xi),
                    (xi, s) -> linear(p, xi),
                ),
                formula = piecewise(raw"\rho(x)",
                    raw"\rho_0 + \rho_1 (\rho_{split} - x)" => raw"x < \rho_{split}",
                    raw"\rho_0 + \rho_1 x" => raw"x \geq \rho_{split}",
                ),
            ),

            ZigZag = (
                ρ = (x, p) -> [zigzag(p, xi) for xi in x],
                formula = piecewise(raw"\rho(x)",
                    raw"\rho_0 + \rho_1 x" => raw"x < \rho_{z1}",
                    raw"\rho_0 + \rho_1 (x - \rho_{z1})" => raw"\rho_{z1} \leq x < \rho_{z2}",
                    raw"\rho_0 + \rho_1 (x - \rho_{z2})" => raw"x \geq \rho_{z2}",
                ),
            ),

            ExpFootHead = (
                ρ = (x, p, rng) -> begin
                    left, right = exponential_parts(p, rng)
                    two_parts(
                        x, p,
                        (xi, s) -> exponential(left, xi),
                        (xi, s) -> exponential(right, xi),
                    )
                end,
                formula = raw"\rho(x) = \rho_a + \rho_b e^{\rho_c x}",
                note = exponential_note,
            ),

            ExpHeadFoot = (
                ρ = (x, p, rng) -> begin
                    left, right = exponential_parts(p, rng)
                    two_parts(
                        x, p,
                        (xi, s) -> exponential(left, xi + 1 - s),
                        (xi, s) -> exponential(right, xi - s),
                    )
                end,
                formula = piecewise(raw"\rho(x)",
                    raw"\rho_a + \rho_b e^{\rho_c (x + 1 - \rho_{split})}" => raw"x < \rho_{split}",
                    raw"\rho_a + \rho_b e^{\rho_c (x - \rho_{split})}" => raw"x \geq \rho_{split}",
                ),
                note = exponential_note,
            ),

            ExpFootHeadR = (
                ρ = (x, p, rng) -> begin
                    left, right = exponential_parts(p, rng)
                    two_parts(
                        x, p,
                        (xi, s) -> exponential(left, xi),
                        (xi, s) -> exponential(right, 1 + s - xi),
                    )
                end,
                formula = piecewise(raw"\rho(x)",
                    raw"\rho_a + \rho_b e^{\rho_c x}" => raw"x < \rho_{split}",
                    raw"\rho_a + \rho_b e^{\rho_c (1 + \rho_{split} - x)}" => raw"x \geq \rho_{split}",
                ),
                note = exponential_note,
            ),

            ExpHeadFootR = (
                ρ = (x, p, rng) -> begin
                    left, right = exponential_parts(p, rng)
                    two_parts(
                        x, p,
                        (xi, s) -> exponential(left, s - xi),
                        (xi, s) -> exponential(right, xi),
                    )
                end,
                formula = piecewise(raw"\rho(x)",
                    raw"\rho_a + \rho_b e^{\rho_c (\rho_{split} - x)}" => raw"x < \rho_{split}",
                    raw"\rho_a + \rho_b e^{\rho_c x}" => raw"x \geq \rho_{split}",
                ),
                note = exponential_note,
            ),
        ),

        latex_equations = (
        raw"\partial_t u = D_u \partial_{xx} u + a\cdot\rho(x) \frac{u^2}{v + 1} - \mu_u u",
        raw"\partial_t v = D_v \partial_{xx} v + b\cdot \rho(x) u^2 - \mu_v v",
        ),
    )
end
