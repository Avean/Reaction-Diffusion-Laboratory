# scripts/experiments/E4b.jl
#
# E4b: like E4a, but the fragment starts from the tissue state of the intact
# animal: the whole body is run to its steady state (one head), the piece
# [S_A, S_B] is cut out of it (u, v and ρ are kept) and wounded at both cut
# ends.
#
#     julia --project --threads=auto scripts/experiments/E4b.jl

include(joinpath(@__DIR__, "..", "..", "src", "RDLabAPI.jl"))
using .RDLabAPI

# ---- body -------------------------------------------------------------------
const L = 2.0          # body length
const RHO0 = 1.0       # ρ at the body centre
const RHO1 = 0.5       # ρ_body(s) = ρ0 + ρ1 (1/2 - s), s = 0 head, 1 foot
const MODEL = :gierer_meinhardt_rho
const PARAMS = (Du = 0.01, Dv = 1.0, a = 1.5, b = 2.0, μu = 0.5, μv = 1.0)
const N = 300
const INTACT_INITIAL = (u = 1.0, v = 2.0)   # start of the intact animal's steady-state run

# ---- fragment and wounds ----------------------------------------------------
const S_A = 0.2        # the middle 0.6 L
const S_B = 0.8
const WOUND_WIDTH = (0.06, 0.13) .* (S_B - S_A) .* L   # absolute length units
const WOUND_HEIGHT = (2.0, 4.0)

# ---- series -----------------------------------------------------------------
const RUNS = 100
const SEED = 12345

body = Body(L, RHO0, RHO1)
wounds = [Wound(:ends; width = WOUND_WIDTH, height = WOUND_HEIGHT, variable = :u)]

for (label, b) in (("SD", body), ("noSD", without_sd(body)))
    intact = steady_state(make_state(MODEL; body = b, N = N, params = PARAMS, initial = INTACT_INITIAL))
    describe(intact)
    fragment = cut(intact, S_A, S_B)
    spec = SeriesSpec(
        experiment = "E4b",
        name = "$(label)_s$(S_A)-$(S_B)",
        start = fragment,
        wounds = wounds,
        runs = RUNS,
        seed = SEED,
        save_fields = 5,
        notes = "Fragment [$S_A, $S_B] cut from the steady state of the intact animal, wounds at both ends.",
    )
    run_series(spec)
end
