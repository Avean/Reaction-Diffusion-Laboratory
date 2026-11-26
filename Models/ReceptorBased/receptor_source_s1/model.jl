# Models/ReceptorBased/receptor_source_s1/model.jl

# ============================================================
# Receptor-based model with a dynamic source density, parameter set S1
# ============================================================
#
# The Receptor + Source model (Models/ReceptorBased/receptor_source) with the
# same equations and kinetics and a different source density: Dsd = 0.562,
# μsd = 0.052 (set S1 of the frozen-SD search of 25/26.11.2026, RoleOfSource):
#
#     u_t  =          pu - μ1 u + m1 c
#     v_t  = Dv v_xx + pv - μ2 v + m2 sd c - v w
#     w_t  = Dw w_xx      - μ3 w + m3 sd c
#     τ sd_t = Dsd sd_xx + c - μsd sd,        c = u v / (1 + u v)
#
# Protocol of the search: sd frozen from the moment of the experiment (cut,
# doublet, graft; Freeze SD, frozen = 1 from t = 0) and read out at the
# steady state. With the default source density of receptor_source, a head
# lit at an end where sd falls towards the end (end B of the anti-oriented
# H2F doublet) moves up the sd gradient to the junction; with the lower and
# flatter sd of S1 it stays at the end.
#
# Reference (steady state of the whole body of length 7.17, one head at
# s = 0): sd = 1.955, 1.076, 0.789, 0.608, 0.477 at s = 0, 1/3, 1/2, 2/3, 1
# (receptor_source: 3.98, 1.53, 0.90, 0.56, 0.33). The upper homogeneous
# state (u, v, w, sd) ≈ (1.19, 0.295, 38.9, 4.99) is stable without
# diffusion and Turing unstable with it (modes 2-40 on a body of length 7.17).
#
# Wounds of S1 (series presets in this folder, on u and v): ends 6 % of the
# panel, u 2.085-4.865, v 1.781-4.155; junction and graft width 0.185
# (absolute), u 1.193-2.783, v 1.018-2.376. The search applied graft wounds
# as max(field, wound); the series window adds them.
#
# Freeze SD, Cut and Cut and run work as in receptor_source. Use Body length
# 7.17 and the cut lengths 4.30 (0.6 of the body), 2.15 (0.3) or 2.43
# (doublet).
#
# ============================================================

RDModel(
    id = :receptor_based_source_s1,

    display_name = "Receptor + Source (S1)",
    description = "Receptor + Source with the source density of set S1 (Dsd = 0.562, μsd = 0.052: lower, flatter sd, Reference sd(0) ≈ 1.96). Receptor model (non-diffusing receptors u, ligand v, enzyme w) with a dynamic source density sd that multiplies ligand and enzyme production and is produced by the receptor signal uv/(1+uv). Body of length 7.17 (set the domain length to 7.17). Freeze SD (frozen = 1) keeps sd as a fixed profile. ic_head = 1 starts with one head at the right end and sd = 1, ic_head = 0 near the upper homogeneous state with 1 % noise.",

    variables = (:u, :v, :w, :sd),

    # Freeze SD (frozen = 1) keeps sd at its current values. Its equation is
    # divided by τ, so Cut and run measures its rate times τ.
    freezable = (sd = :τ,),

    parameters = (
        τ = 500.0,

        # Values for a body of length 1 (0.0045, 0.0085, 0.010932) times 7.17².
        Dv = 0.23134,
        Dw = 0.43698,
        Dsd = 0.562,

        m1 = 3.2,
        m2 = 9.0,
        m3 = 21.0,

        μ1 = 0.7,
        μ2 = 0.6,
        μ3 = 0.7,
        μsd = 0.052,

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
            # signal, u = η1 - 1/v, v = 1/(η1 (1 - c)), sd = c/μsd,
            # w = η3 sd c, and c is the larger root in (0, 1) of
            # φ(c) = m2 sd c - (μ2 + w) v, found by scanning and bisection.
            η1 = p.m1 / p.μ1
            η3 = p.m3 / p.μ3
            φ(c) = p.m2 * c^2 / p.μsd - (p.μ2 + η3 * c^2 / p.μsd) / (η1 * (1 - c))

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
                sd0 = croot / p.μsd
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
        @. F.sd = (max(U.u, 0.0) * max(U.v, 0.0) / (1.0 + max(U.u, 0.0) * max(U.v, 0.0)) - p.μsd * U.sd) / p.τ

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
        raw"\partial_t s = \frac{1}{\tau}\left(D_{s} \partial_{xx} s + \frac{u v}{1 + u v} - \mu_{s} s\right)",
    ),
)
