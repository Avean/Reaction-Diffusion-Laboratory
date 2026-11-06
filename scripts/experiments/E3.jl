# scripts/experiments/E3.jl
#
# E3: the whole body (s from 0 to 1) starting from rest (u = v = 0), wounded
# at both ends, with and without source density (SD). Does a head form, and
# where?
#
#     julia --project --threads=auto scripts/experiments/E3.jl

include(joinpath(@__DIR__, "..", "..", "src", "RDLabAPI.jl"))
using .RDLabAPI

# ---- body -------------------------------------------------------------------
const L = 2.0          # body length
const RHO0 = 1.0       # ρ at the body centre
const RHO1 = 0.5       # ρ_body(s) = ρ0 + ρ1 (1/2 - s), s = 0 head, 1 foot
const MODEL = :gierer_meinhardt_rho
const PARAMS = (Du = 0.01, Dv = 1.0, a = 1.5, b = 2.0, μu = 0.5, μv = 1.0)
const N = 300

# ---- wounds -----------------------------------------------------------------
const WOUND_WIDTH = (0.06, 0.13) .* L    # absolute length units
const WOUND_HEIGHT = (2.0, 4.0)

# ---- series -----------------------------------------------------------------
const RUNS = 100
const SEED = 12345

body = Body(L, RHO0, RHO1)
wounds = [Wound(:ends; width = WOUND_WIDTH, height = WOUND_HEIGHT, variable = :u)]

for (label, b) in (("SD", body), ("noSD", without_sd(body)))
    start = make_state(MODEL; body = b, N = N, params = PARAMS, initial = :rest)
    spec = SeriesSpec(
        experiment = "E3",
        name = label,
        start = start,
        wounds = wounds,
        runs = RUNS,
        seed = SEED,
        save_fields = 5,
        notes = "Whole body from rest, wounds at both ends.",
    )
    run_series(spec)
end
