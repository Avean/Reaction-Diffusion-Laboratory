# Models/GiererMainhardt/rho/model.jl

# ============================================================
# Classical Gierer-Meinhardt reaction-diffusion system
# ============================================================
#
# Model:
#
#     u_t = Du u_xx + a - b u + u^2 / (v+1)
#     v_t = Dv v_xx + u^2 - v
#
# Here:
#
#     u = activator
#     v = inhibitor
#
# Usually Du << Dv.
#
# ============================================================


# Number of grid points left of the jump in the two-part profiles: ρsplit is
# the jump position as a fraction of the whole domain (0.5 = the middle; 0 and
# 1 leave a single part, so no jump).
rho_split_index(x, p) = round(Int, clamp(p.ρsplit, 0, 1) * length(x))


# Exponential profiles ρ(x) = ρa + ρb exp(ρc x), evaluated once for the part
# left of the jump and once for the part right of it. In a series realization
# (rng given) each part draws its own ρa, ρb, ρc, varied by a relative ±ρσa,
# ±ρσb, ±ρσc (uniform); outside series mode both parts use the nominal values.
function rho_exponential_parts(x, p, rng)
    vary(value, σ) = rng === nothing ? value : value * (1 + σ * (2 * rand(rng) - 1))

    function draw()
        a = vary(p.ρa, p.ρσa)
        b = vary(p.ρb, p.ρσb)
        c = vary(p.ρc, p.ρσc)
        return @. a + b * exp(c * x)
    end

    left = draw()
    right = draw()
    return left, right, rho_split_index(x, p), length(x)
end


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

        ρ0 = 1.0,
        ρ1 = 0.5,

        # Two-part profiles (HeadFoot, ..., ExpHeadFootR): position of the
        # jump between the parts, as a fraction of the whole domain.
        ρsplit = 0.5,

        # Exponential profiles: ρ(x) = ρa + ρb exp(ρc x)
        ρa = 0.5,
        ρb = 0.5,
        ρc = 1.0,

        # Series mode only: relative variation of ρa, ρb, ρc, drawn
        # separately for each half of the domain in every realization.
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
            ρ = (x, p) -> begin
                ρx = @. p.ρ0 - p.ρ1 / 2 + p.ρ1 * x
                return ρx
            end,
        ),

        # The jump between the two parts is at ρsplit: J points lie left of it.
        HeadFoot = (
            ρ = (x, p) -> begin
                J = rho_split_index(x, p)
                N = length(x)
                ρx = @. p.ρ0 - p.ρ1 / 2 + p.ρ1 * x

                return [ρx[(N - J + 1):end]; ρx[1:(N - J)]]
            end,
        ),

        FootHeadReverse = (
            ρ = (x, p) -> begin
                J = rho_split_index(x, p)
                ρx = @. p.ρ0 - p.ρ1 / 2 + p.ρ1 * x

                return [ρx[1:J]; reverse(ρx[(J + 1):end])]
            end,
        ),

        HeadFootReverse = (
            ρ = (x, p) -> begin
                J = rho_split_index(x, p)
                ρx = @. p.ρ0 - p.ρ1 / 2 + p.ρ1 * x

                return [reverse(ρx[1:J]); ρx[(J + 1):end]]
            end,
        ),

        ZigZag = (
            ρ = (x, p) -> begin
                x1 = 0.2
                x2 = 0.9

                ρx = @. ifelse(
                    x < x1,
                    p.ρ0 + p.ρ1 * x,
                    ifelse(
                        x < x2,
                        p.ρ0 + p.ρ1 * (x - x1),
                        p.ρ0 + p.ρ1 * (x - x2),
                    )
                )

                return ρx
            end,
        ),

        # The part left of the jump comes from the left draw, the part right
        # of it from the right draw.
        ExpFootHead = (
            ρ = (x, p, rng) -> begin
                left, right, J, N = rho_exponential_parts(x, p, rng)

                return [left[1:J]; right[(J + 1):end]]
            end,
        ),

        ExpHeadFoot = (
            ρ = (x, p, rng) -> begin
                left, right, J, N = rho_exponential_parts(x, p, rng)

                return [left[(N - J + 1):end]; right[1:(N - J)]]
            end,
        ),

        ExpFootHeadR = (
            ρ = (x, p, rng) -> begin
                left, right, J, N = rho_exponential_parts(x, p, rng)

                return [left[(N - J + 1):end]; reverse(right[1:(N - J)])]
            end,
        ),

        ExpHeadFootR = (
            ρ = (x, p, rng) -> begin
                left, right, J, N = rho_exponential_parts(x, p, rng)

                return [reverse(left[1:J]); right[(J + 1):end]]
            end,
        ),
    ),

    latex_equations = (
    raw"\partial_t u = D_u \partial_{xx} u + a\cdot\rho(x) \frac{u^2}{v + 1} - \mu_u u",
    raw"\partial_t v = D_v \partial_{xx} v + b\cdot \rho(x) u^2 - \mu_v v",
    ),
)
