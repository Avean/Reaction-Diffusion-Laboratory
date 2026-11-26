# Models/ReceptorBased/receptor_source/model.jl

# ============================================================
# Receptor-based model with a dynamic source density produced by the
# receptors u (Receptor + Source)
# ============================================================
#
# The receptor model (Models/ReceptorBased/receptor) with the source density
# sd coupled as in the Gierer-Meinhardt Source model: sd multiplies the
# production of the ligand (the diffusing part of the activating pair) and of
# the enzyme (the inhibitor), and it is produced linearly by the receptors u,
# as the Gierer-Meinhardt source density is produced by the activator:
#
#     u_t  =          pu - μ1 u + m1 c
#     v_t  = Dv v_xx + pv - μ2 v + m2 sd c - v w
#     w_t  = Dw w_xx      - μ3 w + m3 sd c
#     τ sd_t = Dsd sd_xx + ksd u - μsd sd,        c = u v / (1 + u v).
#
# Until 26.11.2026 Receptor + Source produced sd from the receptor signal c;
# that model is now Models/ReceptorBased/receptor_source_c (Receptor + Source
# (c)). At the steady state u = (pu + m1 c)/μ1, so ksd u = c + pu/m1 for the
# default ksd = μ1/m1: the source density is that of the c model plus
# pu/(m1 μsd) ≈ 0.009 (a basal level: at rest u = pu/μ1 > 0, while c ≈ 1e-6),
# and the two models agree up to this shift.
#
# Why not sd in the receptor production: the head then carries u ≈ sd m1/μ1,
# its source density grows with it and the head spreads over the whole body
# (24.11.2026). With sd in the ligand and enzyme production the activation
# and the inhibition grow together, as with ρ in Gierer-Meinhardt.
#
# Defaults: kinetics as in the receptor model (GM-like regime, body of
# length 7.17: set the domain length to 7.17; the diffusion coefficients are
# the values for a body of length 1 times 7.17², see the receptor model);
# Dsd and μsd as in Receptor + Source (c), whose steady state with one head
# at s = 0 has sd = 3.98, 1.55, 0.90, 0.55, 0.33 at s = 0, 0.33, 0.5, 0.67, 1,
# the Reference profile of the Gierer-Meinhardt Source model of the
# RoleOfSource paper (3.99, 1.51, 0.89, 0.55, 0.33).
#
# Freeze SD and the other Source tools work as in the Gierer-Meinhardt
# Source model; Cut and run (bump of u at the left end) gives one head.
#
# ============================================================

RDModel(
    id = :receptor_based_source,

    display_name = "Receptor + Source",
    description = "Receptor model (non-diffusing receptors u, ligand v, enzyme w) with a dynamic source density sd that multiplies ligand and enzyme production and is produced linearly by the receptors u (ksd u; Receptor + Source (c) produces it from the signal uv/(1+uv)). Body of length 7.17 (set the domain length to 7.17). Freeze SD (frozen = 1) keeps sd as a fixed profile. ic_head = 1 starts with one head at the right end and sd = 1, ic_head = 0 near the upper homogeneous state with 1 % noise.",

    variables = (:u, :v, :w, :sd),

    # Freeze SD (frozen = 1) keeps sd at its current values. Its equation is
    # divided by τ, so Cut and run measures its rate times τ.
    freezable = (sd = :τ,),

    parameters = (
        τ = 500.0,

        # Values for a body of length 1 (0.0045, 0.0085, 0.00335) times 7.17².
        Dv = 0.23134,
        Dw = 0.43698,
        Dsd = 0.17222,

        m1 = 3.2,
        m2 = 9.0,
        m3 = 21.0,

        μ1 = 0.7,
        μ2 = 0.6,
        μ3 = 0.7,
        μsd = 0.0367,

        # Production of sd per receptor: μ1/m1 gives the sd of Receptor + Source (c).
        ksd = 0.21875,

        pu = 1e-3,
        pv = 1e-3,

        # Initial condition: 1 = one head at the right end and sd = 1,
        # 0 = upper homogeneous state with 1 % noise.
        ic_head = 1.0,
    ),

    initial = function (U, x, p)
        n = length(x)

        if p.ic_head > 0.5
            U.u .= p.pu / p.μ1
            U.v .= p.pv / p.μ2
            U.w .= 0.0
            U.sd .= 1.0
            head = x .>= 0.97
            U.u[head] .= 3.0
            U.v[head] .= 1.0
        else
            # Upper homogeneous state (pu = pv = 0): with c the receptor
            # signal, u = η1 c = η1 - 1/v, v = 1/(η1 (1 - c)),
            # sd = ksd u/μsd = ksd η1 c/μsd, w = η3 sd c, and c is the larger
            # root in (0, 1) of φ(c) = m2 sd c - (μ2 + w) v, found by scanning
            # and bisection.
            η1 = p.m1 / p.μ1
            η3 = p.m3 / p.μ3
            s(c) = p.ksd * η1 * c / p.μsd
            φ(c) = p.m2 * s(c) * c - (p.μ2 + η3 * s(c) * c) / (η1 * (1 - c))

            croot = NaN
            grid = range(1e-4, 1 - 1e-6; length = 20_001)
            for k in length(grid):-1:2
                a, b = grid[k - 1], grid[k]
                if sign(φ(a)) != sign(φ(b))
                    for _ in 1:80
                        m = (a + b) / 2
                        sign(φ(a)) == sign(φ(m)) ? (a = m) : (b = m)
                    end
                    croot = (a + b) / 2
                    break
                end
            end

            if isfinite(croot)
                v0 = 1 / (η1 * (1 - croot))
                u0 = η1 - 1 / v0
                sd0 = s(croot)
                w0 = η3 * sd0 * croot
            else
                u0, v0, w0, sd0 = 1.0, 1.0, 1.0, 1.0
            end

            U.u .= u0 .* (1 .+ 0.01 .* randn(n))
            U.v .= v0 .* (1 .+ 0.01 .* randn(n))
            U.w .= w0 .* (1 .+ 0.01 .* randn(n))
            U.sd .= sd0 .* (1 .+ 0.01 .* randn(n))
        end

        return nothing
    end,

    reaction = function (F, U, x, p, t)
        @. F.u = p.pu - p.μ1 * U.u +
                 p.m1 * max(U.u, 0.0) * max(U.v, 0.0) / (1.0 + max(U.u, 0.0) * max(U.v, 0.0))
        @. F.v = p.pv - p.μ2 * U.v - U.v * U.w +
                 p.m2 * U.sd * max(U.u, 0.0) * max(U.v, 0.0) / (1.0 + max(U.u, 0.0) * max(U.v, 0.0))
        @. F.w = -p.μ3 * U.w +
                 p.m3 * U.sd * max(U.u, 0.0) * max(U.v, 0.0) / (1.0 + max(U.u, 0.0) * max(U.v, 0.0))
        @. F.sd = (p.ksd * max(U.u, 0.0) - p.μsd * U.sd) / p.τ

        return nothing
    end,

    diffusion = (
        v = :Dv,
        w = :Dw,
        sd = p -> p.Dsd / p.τ,
    ),

    latex_equations = (
        raw"\partial_t u = p_u - \mu_1 u + m_1 \frac{u v}{1 + u v}",
        raw"\partial_t v = D_v \partial_{xx} v + p_v - \mu_2 v + m_2 \, s \frac{u v}{1 + u v} - v w",
        raw"\partial_t w = D_w \partial_{xx} w - \mu_3 w + m_3 \, s \frac{u v}{1 + u v}",
        raw"\partial_t s = \frac{1}{\tau}\left(D_{s} \partial_{xx} s + k_{s} u - \mu_{s} s\right)",
    ),
)
