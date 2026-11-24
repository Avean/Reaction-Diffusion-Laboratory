# Models/ReceptorBased/receptor/model.jl

# ============================================================
# Receptor-based model with one non-diffusing component
# ============================================================
#
# Münnich, Cygan, André, Marciniak-Czochra, "Instability mechanisms and
# far-from-equilibrium patterns in reaction-diffusion-ODE systems with
# multiple diffusion scales", system (5.2), inspired by Marciniak-Czochra,
# Math. Biosci. 199 (2006):
#
#     u_t =          pu - μ1 u + m1 c
#     v_t = Dv v_xx + pv - μ2 v + m2 c - v w
#     w_t = Dw w_xx      - μ3 w + m3 c,        c = u v / (1 + u v)
#
#     u = receptors (no diffusion), v = ligand, w = enzyme degrading the ligand
#
# Additions to (5.2), both tiny and off in the paper:
#
#   - pu, pv: basal production of receptors and ligand. u = 0 and v = 0 are
#     invariant in (5.2), so without them a region whose u or v has decayed
#     to round-off can never be reactivated, and the patterns would depend
#     on how small those values became. pu = pv = 1e-3 keep a floor; the
#     resting state (pu/μ1, ~pv/μ2, ~0) stays stable.
#   - c uses max(u, 0) and max(v, 0): negative round-off values relax to 0
#     instead of being amplified towards the pole u v = -1.
#
# Default parameters: the GM-like regime found on 24.11.2026 for a body of
# length 1 (stable resting state, Turing-unstable upper state with 3-4
# peaks de novo, stable states with 1, 2, 3, ... heads, wound-induced heads
# with an inhibition zone of about 0.2). The paper's set (Figs. 3-5) is
# m1 = 2.5, m2 = 9.68, m3 = 7, μ1 = 1, μ2 = 1, μ3 = 0.6 on the domain (0, 1)
# with (Dv, Dw) = (0.1, 1), (0.026, 0.12), (0.0115, 0.037) or (0.006, 0.017)
# and pu = pv = 0; with it a single head spreads over about half the domain.
#
# Heads: the head is the active region where u is on its upper branch; its u
# maximum can lie slightly inside the panel when w is highest at the end.
#
# ============================================================

RDModel(
    id = :receptor_based,

    display_name = "Receptor",
    description = "Receptor-based model (5.2) of Münnich, Cygan, André and Marciniak-Czochra: non-diffusing receptors u, slowly diffusing ligand v and fast-diffusing enzyme w that degrades the ligand. Tiny basal productions pu, pv keep u and v off the invariant zero state. Defaults: GM-like regime on a body of length 1. ic_head = 1 starts with one head at the right end, ic_head = 0 near the upper homogeneous state with 1 % noise.",

    variables = (:u, :v, :w),

    parameters = (
        Dv = 0.0045,
        Dw = 0.0085,

        m1 = 3.2,
        m2 = 9.0,
        m3 = 21.0,

        μ1 = 0.7,
        μ2 = 0.6,
        μ3 = 0.7,

        pu = 1e-3,
        pv = 1e-3,

        # Initial condition: 1 = one head at the right end, 0 = upper
        # homogeneous state with 1 % noise.
        ic_head = 1.0,
    ),

    initial = function (U, x, p)
        n = length(x)

        if p.ic_head > 0.5
            # One head at the right end (the headward end of a panel),
            # resting values elsewhere.
            U.u .= p.pu / p.μ1
            U.v .= p.pv / p.μ2
            U.w .= 0.0
            head = x .>= 0.97
            U.u[head] .= 3.0
            U.v[head] .= 1.0
        else
            # Upper homogeneous state X+ of (5.2) (Theorem 5.2 of the paper,
            # without pu, pv) with 1 % multiplicative noise.
            η1 = p.m1 / p.μ1
            η3 = p.m3 / p.μ3
            α = p.m2 * η1 - η3
            Θ = (α - 2 * p.μ2)^2 - 4 * p.μ2 * (p.μ2 + η3)

            if Θ > 0 && α > 2 * p.μ2
                v0 = (α + 2 * η3 + sqrt(Θ)) / (2 * η1 * (p.μ2 + η3))
                u0 = η1 - 1 / v0
                w0 = η3 - η3 / (η1 * v0)
            else
                u0, v0, w0 = 1.0, 1.0, 1.0
            end

            U.u .= u0 .* (1 .+ 0.01 .* randn(n))
            U.v .= v0 .* (1 .+ 0.01 .* randn(n))
            U.w .= w0 .* (1 .+ 0.01 .* randn(n))
        end

        return nothing
    end,

    reaction = function (F, U, x, p, t)
        @. F.u = p.pu - p.μ1 * U.u +
                 p.m1 * max(U.u, 0.0) * max(U.v, 0.0) / (1.0 + max(U.u, 0.0) * max(U.v, 0.0))
        @. F.v = p.pv - p.μ2 * U.v - U.v * U.w +
                 p.m2 * max(U.u, 0.0) * max(U.v, 0.0) / (1.0 + max(U.u, 0.0) * max(U.v, 0.0))
        @. F.w = -p.μ3 * U.w +
                 p.m3 * max(U.u, 0.0) * max(U.v, 0.0) / (1.0 + max(U.u, 0.0) * max(U.v, 0.0))

        return nothing
    end,

    diffusion = (
        v = :Dv,
        w = :Dw,
    ),

    latex_equations = (
        raw"\partial_t u = p_u - \mu_1 u + m_1 \frac{u v}{1 + u v}",
        raw"\partial_t v = D_v \partial_{xx} v + p_v - \mu_2 v + m_2 \frac{u v}{1 + u v} - v w",
        raw"\partial_t w = D_w \partial_{xx} w - \mu_3 w + m_3 \frac{u v}{1 + u v}",
    ),
)
