# Models/GiererMainhardt/rho_independent/model.jl

# ============================================================
# Gierer-Meinhardt system with a source density rho(x) glued from two
# independent parts
# ============================================================
#
# Model:
#
#     u_t = Du u_xx + a rho(x) u^2 / (v + 1) - mu_u u + p_u
#     v_t = Dv v_xx + b rho(x) u^2 - mu_v v + p_v
#
# rho(x), with x in [0, 1] whatever the domain length, has its own set of
# coefficients left and right of the gluing point x = ρsplit:
#
#     Linear:       ρaL + ρbL x            (x < ρsplit)
#                   ρaR + ρbR x            (x ≥ ρsplit)
#
#     Exponential:  ρaL + ρbL exp(ρcL x)   (x < ρsplit)
#                   ρaR + ρbR exp(ρcR x)   (x ≥ ρsplit)
#
# Both parts use the same x, measured from the left end of the domain.
# ρsplit = 0 or 1 leaves only the right or the left part.
#
# ============================================================

let
    split_point(p) = clamp(p.ρsplit, 0.0, 1.0)
    left_of_split(x, s) = s >= 1 || x < s

    # In a series realization (rng given) each part varies its coefficients
    # by a relative ±ρσa, ±ρσb, ±ρσc (uniform), drawn separately for the
    # left and the right part; outside series mode they keep their values.
    vary(value, σ, rng) = rng === nothing ? value : value * (1 + σ * (2 * rand(rng) - 1))

    function linear_parts(p, rng)
        left = (a = vary(p.ρaL, p.ρσa, rng), b = vary(p.ρbL, p.ρσb, rng))
        right = (a = vary(p.ρaR, p.ρσa, rng), b = vary(p.ρbR, p.ρσb, rng))
        return left, right
    end

    function exponential_parts(p, rng)
        left = (
            a = vary(p.ρaL, p.ρσa, rng),
            b = vary(p.ρbL, p.ρσb, rng),
            c = vary(p.ρcL, p.ρσc, rng),
        )
        right = (
            a = vary(p.ρaR, p.ρσa, rng),
            b = vary(p.ρbR, p.ρσb, rng),
            c = vary(p.ρcR, p.ρσc, rng),
        )
        return left, right
    end

    function glued(x, p, left_value, right_value)
        s = split_point(p)
        return [left_of_split(xi, s) ? left_value(xi) : right_value(xi) for xi in x]
    end

    series_note(coefficients) = "Series: the left and the right part draw their own $(coefficients) in every run, varied by a relative ±ρσ. With all ρσ = 0 nothing is random."

    RDModel(
        id = :gierer_meinhardt_rho_independent,

        display_name = "Rho profile independent",
        description = "A Gierer-Meinhardt model modulated by a source density rho(x) glued at ρsplit from two parts, linear or exponential, each with its own coefficients.",

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

            # Gluing point, as a fraction of the whole domain.
            ρsplit = 0.5,

            # Left part (x < ρsplit): ρaL + ρbL x or ρaL + ρbL exp(ρcL x)
            ρaL = 0.75,
            ρbL = 0.5,
            ρcL = 1.0,

            # Right part (x ≥ ρsplit): ρaR + ρbR x or ρaR + ρbR exp(ρcR x)
            ρaR = 0.75,
            ρbR = 0.5,
            ρcR = 1.0,

            # Series mode only: relative variation of the coefficients,
            # drawn separately for each part in every realization.
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
            Linear = (
                ρ = (x, p, rng) -> begin
                    left, right = linear_parts(p, rng)
                    glued(
                        x, p,
                        xi -> left.a + left.b * xi,
                        xi -> right.a + right.b * xi,
                    )
                end,
                formula = piecewise(raw"\rho(x)",
                    raw"\rho_{aL} + \rho_{bL} x" => raw"x < \rho_{split}",
                    raw"\rho_{aR} + \rho_{bR} x" => raw"x \geq \rho_{split}",
                ),
                note = series_note("a, b"),
            ),

            Exponential = (
                ρ = (x, p, rng) -> begin
                    left, right = exponential_parts(p, rng)
                    glued(
                        x, p,
                        xi -> left.a + left.b * exp(left.c * xi),
                        xi -> right.a + right.b * exp(right.c * xi),
                    )
                end,
                formula = piecewise(raw"\rho(x)",
                    raw"\rho_{aL} + \rho_{bL} e^{\rho_{cL} x}" => raw"x < \rho_{split}",
                    raw"\rho_{aR} + \rho_{bR} e^{\rho_{cR} x}" => raw"x \geq \rho_{split}",
                ),
                note = series_note("a, b, c"),
            ),
        ),

        latex_equations = (
        raw"\partial_t u = D_u \partial_{xx} u + a\cdot\rho(x) \frac{u^2}{v + 1} - \mu_u u",
        raw"\partial_t v = D_v \partial_{xx} v + b\cdot \rho(x) u^2 - \mu_v v",
        ),
    )
end
