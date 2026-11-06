# scripts/experiments/E6a.jl
#
# E6a: doublets. Two pieces of the body, UPPER = [S1, S2] (towards the head)
# and LOWER = [S2, S3], are joined in four configurations. On a panel a piece
# that is not flipped has its foot end on the left and its head end on the
# right; `join(left, right)` puts the right end of `left` against the left
# end of `right`:
#
#     H2F oriented       join(LOWER, UPPER)                  →→  the body order: LOWER's head end
#                                                                meets UPPER's foot end
#     H2F anti-oriented  join(UPPER, LOWER)                  →→  UPPER's head end meets LOWER's
#                                                                foot end (the pieces swapped)
#     H2H                join(LOWER, UPPER; flip_right)      →←  head end meets head end
#     F2F                join(LOWER, UPPER; flip_left)       ←→  foot end meets foot end
#
# The pieces carry their ρ (piece rule). Every doublet is wounded at both ends
# and at the junction.
#
#     julia --project --threads=auto scripts/experiments/E6a.jl

include(joinpath(@__DIR__, "..", "..", "src", "RDLabAPI.jl"))
using .RDLabAPI

# ---- body -------------------------------------------------------------------
const L = 2.0          # body length
const RHO0 = 1.0       # ρ at the body centre
const RHO1 = 0.5       # ρ_body(s) = ρ0 + ρ1 (1/2 - s), s = 0 head, 1 foot
const SD = true        # false: ρ ≡ ρ0
const MODEL = :gierer_meinhardt_rho
const PARAMS = (Du = 0.01, Dv = 1.0, a = 1.5, b = 2.0, μu = 0.5, μv = 1.0)
const N = 300

# ---- pieces -----------------------------------------------------------------
const S1 = 0.2
const S2 = 0.5
const S3 = 0.8
# true: cut the pieces out of the intact animal's steady state (tissue keeps
# u and v); false: build them from rest by the piece rule.
const FROM_INTACT = true
const INTACT_INITIAL = (u = 1.0, v = 2.0)

# ---- wounds -----------------------------------------------------------------
const WOUND_WIDTH = (0.06, 0.13) .* ((S3 - S1) * L / 2)   # absolute length units
const WOUND_HEIGHT = (2.0, 4.0)

# ---- series -----------------------------------------------------------------
const RUNS = 100
const SEED = 12345

body = SD ? Body(L, RHO0, RHO1) : without_sd(Body(L, RHO0, RHO1))

if FROM_INTACT
    intact = steady_state(make_state(MODEL; body = body, N = N, params = PARAMS, initial = INTACT_INITIAL))
    upper = cut(intact, S1, S2; rename = "upper")
    lower = cut(intact, S2, S3; rename = "lower")
else
    upper = make_state(MODEL; body = body, piece = (S1, S2), N = N, params = PARAMS, initial = :rest, label = "upper")
    lower = make_state(MODEL; body = body, piece = (S2, S3), N = N, params = PARAMS, initial = :rest, label = "lower")
end

doublets = [
    "H2F_oriented" => join(lower, upper),
    "H2F_anti" => join(upper, lower),
    "H2H" => join(lower, upper; flip_right = true),
    "F2F" => join(lower, upper; flip_left = true),
]

wounds = [
    Wound(:ends; width = WOUND_WIDTH, height = WOUND_HEIGHT, variable = :u),
    Wound(:junctions; width = WOUND_WIDTH, height = WOUND_HEIGHT, variable = :u),
]

for (name, doublet) in doublets
    describe(doublet)
    spec = SeriesSpec(
        experiment = "E6a",
        name = "$(name)_$(SD ? "SD" : "noSD")",
        start = doublet,
        wounds = wounds,
        runs = RUNS,
        seed = SEED,
        save_fields = 5,
        notes = "Doublet $name of [$S1, $S2] and [$S2, $S3]; wounds at both ends and at the junction.",
    )
    run_series(spec)
end
