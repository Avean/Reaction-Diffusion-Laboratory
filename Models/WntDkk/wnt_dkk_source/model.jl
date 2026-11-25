# Models/WntDkk/wnt_dkk_source/model.jl

# ============================================================
# Reduced Wnt-Dkk model (S = Wl) with a dynamic source density
# ============================================================
#
# The model Models/WntDkk/wnt_dkk with a source density sd that multiplies
# the production of W, Wd and A (switches sdW, sdD, sdA; sd enters as sd^γ)
# and is produced by W as in the Gierer-Meinhardt Source model:
#
#     W_t  = pW + mW β6 W / ((1 + A)(1 + C)(1 + β3 W)) - W
#     A_t  = νA A_xx + mA β1 / (1 + β4 W) - A
#     Wd_t = νWd Wd_xx + mD β2 W^2 - Wd
#     C_t  = νC C_xx + Wd / (1 + β5 W) - C
#     τ sd_t = Dsd sd_xx + ksd W - μsd sd
#
# with mX = sd^γ when the switch sdX = 1 and mX = 1 when it is 0.
#
# sdW and sdD are the coupling of S in the original model. sdA is needed:
# the rest state grows at the rate β6 mW / (1 + β1 mA) - 1. With sd in W
# alone it becomes unstable once sd > (1 + β1) / β6 ≈ 1.1, and the source
# density alone decides where heads appear (every outcome 100 %). With sd in
# W and A the rate stays below β6 / β1 - 1 < 0 for every sd, as ρ cancels
# from the local stability of Gierer-Meinhardt: the wound decides whether a
# head forms, the source density where. With sd in A (and Wd) but not in W,
# the head cannot hold where sd is high. Scaling C as well makes the
# inhibitor grow like sd² and weakens the polarity (25.11.2026, Python
# mirror of RD Lab).
#
# Defaults, for a body of length 7.17 (set the domain length to 7.17; the
# diffusion coefficients are the values for a body of length 1 times 7.17²,
# see the wnt_dkk model): kinetics of wnt_dkk (set B); Dsd = 0.0036 × 7.17²,
# μsd as in the receptor source model, ksd fitted (τ = 1) so that the steady
# state with one head at s = 0 has sd = 3.99, 1.48, 0.91, 0.60, 0.40 at
# s = 0, 0.33, 0.5, 0.67, 1 (Reference of the Gierer-Meinhardt Source model:
# 3.99, 1.51, 0.89, 0.55, 0.33). Cut and run from W = A = Wd = C = 0, sd = 1
# (τ = 500, N = 300) gives one head at the left end and reaches the same
# steady state, sd = 3.99, 1.48, 0.91, 0.60, 0.40. The upper homogeneous state
# (W, A, Wd, C, sd) ≈ (0.0998, 89.2, 0.378, 0.321, 12.2) is stable without
# diffusion and Turing unstable with it (τ = 1).
#
# ============================================================

RDModel(
    id = :wnt_dkk_source,

    display_name = "Wnt-Dkk (S = Wl) + Source",
    description = "Reduced Wnt-Dkk model (S = Wl) with a dynamic source density sd that multiplies the production of W, Wd and A (switches sdW, sdD, sdA; sd enters as sd^γ) and is produced by W. Body of length 7.17 (set the domain length to 7.17). Freeze SD (frozen = 1) keeps sd as a fixed profile. ic_head = 1 starts with one head at the right end and sd = 1, ic_head = 0 near the upper homogeneous state with 1 % noise.",

    variables = (:W, :A, :Wd, :C, :sd),

    # Freeze SD (frozen = 1) keeps sd at its current values. Its equation is
    # divided by τ, so Cut and run measures its rate times τ.
    freezable = (sd = :τ,),

    parameters = (
        τ = 500.0,

        β1 = 11.495,
        β2 = 3.1156,
        β3 = 1.5173,
        β4 = 5.7268,
        β5 = 1.7809,
        β6 = 11.2524,

        # Values for a body of length 1 (5.395e-5, 0.04752, 2.183e-4, 0.0036)
        # times 7.17².
        νA = 0.0027735,
        νWd = 2.44295,
        νC = 0.0112226,
        Dsd = 0.185072,

        μsd = 0.0367,
        ksd = 4.4838,

        pW = 1e-4,

        # Which productions sd multiplies (1 = yes) and the exponent of sd.
        sdW = 1.0,
        sdD = 1.0,
        sdA = 1.0,
        γ = 1.0,

        # Initial condition: 1 = one head at the right end and sd = 1,
        # 0 = upper homogeneous state with 1 % noise.
        ic_head = 1.0,
    ),

    initial = function (U, x, p)
        n = length(x)
        m(flag, s) = flag * s^p.γ + (1 - flag)
        if p.ic_head > 0.5
            U.W .= p.pW / (1 - p.β6 / (1 + p.β1))
            U.sd .= 1.0
            head = x .>= 0.97
            U.W[head] .= 1.44
        else
            # Upper homogeneous state (pW = 0): sd = ksd W / μsd and W solves
            # g(W) = mW β6 / ((1 + A)(1 + C)(1 + β3 W)) - 1 = 0 with A, Wd, C
            # at their steady values; the upper root by scanning and bisection.
            function g(W)
                s = p.ksd * W / p.μsd
                A = m(p.sdA, s) * p.β1 / (1 + p.β4 * W)
                Wd = m(p.sdD, s) * p.β2 * W^2
                C = Wd / (1 + p.β5 * W)
                return m(p.sdW, s) * p.β6 / ((1 + A) * (1 + C) * (1 + p.β3 * W)) - 1
            end
            Wu = 0.1
            grid = exp.(range(log(1e-6), log(1e3); length = 20_001))
            for k in length(grid):-1:2
                a, b = grid[k - 1], grid[k]
                if sign(g(a)) != sign(g(b))
                    for _ in 1:80
                        mid = (a + b) / 2
                        sign(g(a)) == sign(g(mid)) ? (a = mid) : (b = mid)
                    end
                    Wu = (a + b) / 2
                    break
                end
            end
            U.W .= Wu .* (1 .+ 0.01 .* randn(n))
            U.sd .= p.ksd * Wu / p.μsd .* (1 .+ 0.01 .* randn(n))
        end
        @. U.A = m(p.sdA, U.sd) * p.β1 / (1 + p.β4 * U.W)
        @. U.Wd = m(p.sdD, U.sd) * p.β2 * U.W^2
        @. U.C = U.Wd / (1 + p.β5 * U.W)
        return nothing
    end,

    reaction = function (F, U, x, p, t)
        @. F.W = p.pW - U.W +
                 (p.sdW * max(U.sd, 0.0)^p.γ + (1 - p.sdW)) *
                 p.β6 * max(U.W, 0.0) /
                 ((1 + max(U.A, 0.0)) * (1 + max(U.C, 0.0)) * (1 + p.β3 * max(U.W, 0.0)))
        @. F.A = (p.sdA * max(U.sd, 0.0)^p.γ + (1 - p.sdA)) * p.β1 / (1 + p.β4 * max(U.W, 0.0)) - U.A
        @. F.Wd = (p.sdD * max(U.sd, 0.0)^p.γ + (1 - p.sdD)) * p.β2 * max(U.W, 0.0)^2 - U.Wd
        @. F.C = max(U.Wd, 0.0) / (1 + p.β5 * max(U.W, 0.0)) - U.C
        @. F.sd = (p.ksd * max(U.W, 0.0) - p.μsd * U.sd) / p.τ
        return nothing
    end,

    diffusion = (
        A = :νA,
        Wd = :νWd,
        C = :νC,
        sd = p -> p.Dsd / p.τ,
    ),

    latex_equations = (
        raw"\partial_t W = p_W + s^{\gamma} \frac{\beta_6 W}{(1 + A)(1 + C)(1 + \beta_3 W)} - W",
        raw"\partial_t A = \nu_A \partial_{xx} A + s^{\gamma} \frac{\beta_1}{1 + \beta_4 W} - A",
        raw"\partial_t W_d = \nu_{W_d} \partial_{xx} W_d + s^{\gamma} \beta_2 W^2 - W_d",
        raw"\partial_t C = \nu_C \partial_{xx} C + \frac{W_d}{1 + \beta_5 W} - C",
        raw"\partial_t s = \frac{1}{\tau}\left(D_{s} \partial_{xx} s + k_{s} W - \mu_{s} s\right)",
    ),
)
