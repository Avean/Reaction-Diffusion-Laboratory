# scripts/experiments/E4a.jl
#
# E4a: a body fragment regenerating from rest. The piece [S_A, S_B] of the
# body becomes a panel by the piece rule (length f L, ρ1 f, ρ0 at the piece
# centre; head side on the right), starts from rest (u = v = 0) and is
# wounded at both cut ends. Run with and without source density (SD).
#
#     julia --project --threads=auto scripts/experiments/E4a.jl

include(joinpath(@__DIR__, "..", "..", "src", "RDLabAPI.jl"))
using .RDLabAPI

# ---- body -------------------------------------------------------------------
const L = 2.0          # body length
const RHO0 = 1.0       # ρ at the body centre
const RHO1 = 0.5       # gradient: ρ_body(s) = ρ0 + ρ1 (1/2 - s), s = 0 head, 1 foot
const MODEL = :gierer_meinhardt_rho
const PARAMS = (Du = 0.01, Dv = 1.0, a = 1.5, b = 2.0, μu = 0.5, μv = 1.0)
const N = 300

# ---- fragment and wounds ----------------------------------------------------
const S_A = 0.2        # head-side end of the fragment
const S_B = 0.8        # foot-side end
const WOUND_WIDTH = (0.06, 0.13) .* (S_B - S_A) .* L   # absolute length units
const WOUND_HEIGHT = (2.0, 4.0)

# ---- series -----------------------------------------------------------------
const RUNS = 100
const SEED = 12345

body = Body(L, RHO0, RHO1)
wounds = [Wound(:ends; width = WOUND_WIDTH, height = WOUND_HEIGHT, variable = :u)]

for (label, b) in (("SD", body), ("noSD", without_sd(body)))
    start = make_state(MODEL; body = b, piece = (S_A, S_B), N = N, params = PARAMS, initial = :rest)
    spec = SeriesSpec(
        experiment = "E4a",
        name = "$(label)_s$(S_A)-$(S_B)",
        start = start,
        wounds = wounds,
        runs = RUNS,
        seed = SEED,
        save_fields = 5,
        notes = "Fragment [$S_A, $S_B] of Body(L = $L, ρ0 = $RHO0, ρ1 = $(b.ρ1)) from rest, wounds at both ends.",
    )
    run_series(spec)
end
