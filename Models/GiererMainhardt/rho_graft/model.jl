# Models/GiererMainhardt/rho_graft/model.jl

# ============================================================
# Gierer-Meinhardt system with a source density rho(x) and a graft
# ============================================================
#
# Model:
#
#     u_t = Du u_xx + a rho(x) u^2 / (v + 1) - mu_u u + p_u
#     v_t = Dv v_xx + b rho(x) u^2 - mu_v v + p_v
#
# rho(x) is one of two profiles (Linear, Gauss). A graft adds ρpeak_height
# to it on [ρpeak_pos ± ρpeak_width / 2]; position and width are fractions
# of the whole domain, and a height (or width) of 0 leaves rho(x) unchanged.
#
# ============================================================


# Raises the profile by ρpeak_height on the graft interval of the whole
# domain, so the top of the tower follows the profile below it.
function rho_graft_with_peak(ρx, x, p)
    p.ρpeak_width > 0 && p.ρpeak_height != 0 || return ρx

    xmin = first(x)
    length_x = last(x) - xmin
    centre = xmin + p.ρpeak_pos * length_x
    half_width = p.ρpeak_width * length_x / 2

    return @. ifelse(abs(x - centre) <= half_width, ρx + p.ρpeak_height, ρx)
end


RDModel(
    id = :gierer_meinhardt_rho_graft,

    display_name = "Rho graft",
    description = "A Gierer-Meinhardt model modulated by the source density rho(x), linear or Gaussian-decaying, with an optional graft: a tower of given height and width added to rho(x) at a chosen position.",

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

        # Linear profile: ρ(x) = ρ0 - ρ1 / 2 + ρ1 x
        ρ0 = 1.0,
        ρ1 = 0.5,

        # Gauss profile: ρ(x) = ρa + ρb exp(-ρc x²), decreasing towards ρa
        ρa = 0.7,
        ρb = 3.5,
        ρc = 15.0,

        # Graft: ρpeak_height is added to ρ(x) (0 = no graft); position and
        # width are fractions of the whole domain.
        ρpeak_pos = 0.5,
        ρpeak_height = 0.0,
        ρpeak_width = 0.05,
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
            ρ = (x, p) -> rho_graft_with_peak(@.(p.ρ0 - p.ρ1 / 2 + p.ρ1 * x), x, p),
        ),

        Gauss = (
            ρ = (x, p) -> rho_graft_with_peak(@.(p.ρa + p.ρb * exp(-p.ρc * x^2)), x, p),
        ),
    ),

    latex_equations = (
    raw"\partial_t u = D_u \partial_{xx} u + a\cdot\rho(x) \frac{u^2}{v + 1} - \mu_u u",
    raw"\partial_t v = D_v \partial_{xx} v + b\cdot \rho(x) u^2 - \mu_v v",
    ),
)
