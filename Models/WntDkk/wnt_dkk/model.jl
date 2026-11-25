# Models/WntDkk/wnt_dkk/model.jl

# ============================================================
# Wnt-Dkk model of Mercker et al., reduced: S = Wl, no source density
# ============================================================
#
# The dimensionless Wnt-Dkk model of Mercker et al. (variables Wl, A, Wd, C,
# S) with the source density S replaced by Wl (quasi-steady S without
# diffusion). A keeps its own equation and diffusion:
#
#     W_t  = pW + β6 W / ((1 + A)(1 + C)(1 + β3 W)) - W          (no diffusion)
#     A_t  = νA A_xx + β1 / (1 + β4 W) - A
#     Wd_t = νWd Wd_xx + β2 W^2 - Wd
#     C_t  = νC C_xx + Wd / (1 + β5 W) - C
#
# W stands for Wl. pW is a tiny basal production: without it W = 0 is
# invariant.
#
# Rest state W = 0, A = β1, Wd = C = 0: stable iff β6 < 1 + β1. The positive
# homogeneous states solve β6 = (1 + A)(1 + C)(1 + β3 W) with A, Wd and C at
# their steady values. The lower one is the wound threshold. The upper one is
# stable without diffusion and Turing unstable with it (modes 3-25 on the
# body). The self-enhancement of W goes through A (W represses A, A
# represses W), so the diffusion of A sets the width of the head: with A
# eliminated (quasi-steady A) the head edges pin to the grid.
#
# Defaults (set B of 25.11.2026, from a parameter scan in a Python mirror of
# the RD Lab numerics): rest growth rate -0.10, threshold W ≈ 0.03, head
# height W ≈ 1.44, stable states with one head at an end, one in the middle,
# 2, 3, 4 and 5 heads (also N = 600), 4 heads de novo, inhibition zone about
# 0.1 of the body. β6 < β1: with the source density multiplying the
# production of W and A (wnt_dkk_source) the rest state stays stable for
# every sd. These are not the parameters of Mercker et al.
#
# Body of length 7.17, as in the Gierer-Meinhardt simulations of the
# RoleOfSource paper (doublet 2.43 = 0.339 of the body): set the domain length
# to 7.17. Set B was found on a body of length 1 with νA = 5.395e-5,
# νWd = 0.04752, νC = 2.183e-4; the defaults are these times 7.17² = 51.41,
# which gives the same solutions stretched in space (the model is solved on
# the unit interval with D / L²), as for the receptor models.
#
# ============================================================

RDModel(
    id = :wnt_dkk,

    display_name = "Wnt-Dkk (S = Wl)",
    description = "Reduced Wnt-Dkk model of Mercker et al. with the source density S replaced by Wl: non-diffusing W (Wl), diffusing A, Wd and Dkk C. Body of length 7.17 (set the domain length to 7.17). ic_head = 1 starts with one head at the right end, ic_head = 0 near the upper homogeneous state with 1 % noise.",

    variables = (:W, :A, :Wd, :C),

    parameters = (
        β1 = 11.495,
        β2 = 3.1156,
        β3 = 1.5173,
        β4 = 5.7268,
        β5 = 1.7809,
        β6 = 11.2524,

        # Values for a body of length 1 (5.395e-5, 0.04752, 2.183e-4) times 7.17².
        νA = 0.0027735,
        νWd = 2.44295,
        νC = 0.0112226,

        pW = 1e-4,

        # Initial condition: 1 = one head at the right end, 0 = upper
        # homogeneous state with 1 % noise.
        ic_head = 1.0,
    ),

    initial = function (U, x, p)
        n = length(x)
        if p.ic_head > 0.5
            U.W .= p.pW / (1 - p.β6 / (1 + p.β1))
            head = x .>= 0.97
            U.W[head] .= 1.44
        else
            # Upper root of g(W) = β6 / ((1 + A)(1 + C)(1 + β3 W)) - 1 with
            # A, Wd, C at their steady values, by scanning and bisection.
            g(W) = p.β6 / ((1 + p.β1 / (1 + p.β4 * W)) *
                           (1 + p.β2 * W^2 / (1 + p.β5 * W)) * (1 + p.β3 * W)) - 1
            Wu = 1.0
            grid = exp.(range(log(1e-6), log(1e3); length = 20_001))
            for k in length(grid):-1:2
                a, b = grid[k - 1], grid[k]
                if sign(g(a)) != sign(g(b))
                    for _ in 1:80
                        m = (a + b) / 2
                        sign(g(a)) == sign(g(m)) ? (a = m) : (b = m)
                    end
                    Wu = (a + b) / 2
                    break
                end
            end
            U.W .= Wu .* (1 .+ 0.01 .* randn(n))
        end
        U.A .= p.β1 ./ (1 .+ p.β4 .* U.W)
        U.Wd .= p.β2 .* U.W .^ 2
        U.C .= U.Wd ./ (1 .+ p.β5 .* U.W)
        return nothing
    end,

    reaction = function (F, U, x, p, t)
        @. F.W = p.pW - U.W +
                 p.β6 * max(U.W, 0.0) /
                 ((1 + max(U.A, 0.0)) * (1 + max(U.C, 0.0)) * (1 + p.β3 * max(U.W, 0.0)))
        @. F.A = p.β1 / (1 + p.β4 * max(U.W, 0.0)) - U.A
        @. F.Wd = p.β2 * max(U.W, 0.0)^2 - U.Wd
        @. F.C = max(U.Wd, 0.0) / (1 + p.β5 * max(U.W, 0.0)) - U.C
        return nothing
    end,

    diffusion = (
        A = :νA,
        Wd = :νWd,
        C = :νC,
    ),

    latex_equations = (
        raw"\partial_t W = p_W + \frac{\beta_6 W}{(1 + A)(1 + C)(1 + \beta_3 W)} - W",
        raw"\partial_t A = \nu_A \partial_{xx} A + \frac{\beta_1}{1 + \beta_4 W} - A",
        raw"\partial_t W_d = \nu_{W_d} \partial_{xx} W_d + \beta_2 W^2 - W_d",
        raw"\partial_t C = \nu_C \partial_{xx} C + \frac{W_d}{1 + \beta_5 W} - C",
    ),
)
