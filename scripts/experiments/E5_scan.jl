# scripts/experiments/E5_scan.jl
#
# E5: fragment length scan. Fragments of length f L, f = 0.1 ... 0.6, centred
# at body coordinate S_CENTRE, start from rest and are wounded at both ends,
# with and without source density (SD). Every series writes its own folder;
# the scan table results/E5_scan/<time>_scan.csv lists the head counts of all.
#
#     julia --project --threads=auto scripts/experiments/E5_scan.jl

include(joinpath(@__DIR__, "..", "..", "src", "RDLabAPI.jl"))
using .RDLabAPI
using Dates

# ---- body -------------------------------------------------------------------
const L = 2.0          # body length
const RHO0 = 1.0       # ρ at the body centre
const RHO1 = 0.5       # ρ_body(s) = ρ0 + ρ1 (1/2 - s), s = 0 head, 1 foot
const MODEL = :gierer_meinhardt_rho
const PARAMS = (Du = 0.01, Dv = 1.0, a = 1.5, b = 2.0, μu = 0.5, μv = 1.0)
const N = 300

# ---- scan -------------------------------------------------------------------
const FRACTIONS = 0.1:0.1:0.6   # fragment length as a fraction of L
const S_CENTRE = 0.5            # body coordinate of the fragment centre
const WOUND_WIDTH_FRACTION = (0.06, 0.13)   # of the fragment length...
const WOUND_HEIGHT = (2.0, 4.0)             # ...converted to absolute widths below

# ---- series -----------------------------------------------------------------
const RUNS = 100
const SEED = 12345

body = Body(L, RHO0, RHO1)
rows = Any[]

for f in FRACTIONS, (label, b) in (("SD", body), ("noSD", without_sd(body)))
    s_a = round(S_CENTRE - f / 2; digits = 10)
    s_b = round(S_CENTRE + f / 2; digits = 10)
    start = make_state(MODEL; body = b, piece = (s_a, s_b), N = N, params = PARAMS, initial = :rest)
    width = WOUND_WIDTH_FRACTION .* (f * L)
    spec = SeriesSpec(
        experiment = "E5_scan",
        name = "$(label)_f$(f)",
        start = start,
        wounds = [Wound(:ends; width = width, height = WOUND_HEIGHT, variable = :u)],
        runs = RUNS,
        seed = SEED,
        notes = "Fragment [$s_a, $s_b] (f = $f) from rest, wounds at both ends.",
    )
    result = run_series(spec)
    counts = result.summary["head_counts"]
    push!(rows, (label, f, s_a, s_b, f * L, result.summary["converged"], [get(counts, string(k), 0) for k in 0:3], basename(result.dir)))
end

table = joinpath(RESULTS_DIR, "E5_scan", Dates.format(now(), "yyyy-mm-dd_HH-MM-SS") * "_scan.csv")
mkpath(dirname(table))
open(table, "w") do io
    println(io, "sd,fraction,s_a,s_b,length,converged,heads_0,heads_1,heads_2,heads_3,folder")
    for (label, f, s_a, s_b, len, converged, counts, folder) in rows
        println(io, join(Any[label, f, s_a, s_b, len, converged, counts..., folder], ","))
    end
end
println("Scan table: ", table)
