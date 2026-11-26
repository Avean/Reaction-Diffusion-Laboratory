# scripts/experiments/Receptor_SD.jl
#
# The experiments of the RoleOfSource paper (E1 fragments, E2 ring doublets,
# E3 grafts) for the receptor model without source density
# (Models/ReceptorBased/receptor, sd ≡ 1) and with it
# (Models/ReceptorBased/receptor_source_c, until 26.11.2026 receptor_source: sd produced by the signal c, dynamic sd, τ = 500).
#
# Protocol as in RoleOfSource simulations/warianty/licz_ms_tau500_uvE1.jl:
#   - body of length BODY = 7.17 (as the GM simulations; doublet 2.43), N = 300, Neumann;
#     head at s = 0, on the RIGHT end of a panel; s, D_DOUBLET and GRAFT are fractions of the body;
#   - Reference: steady state with one head (τ = 1 for the source model, which does
#     not change the steady state); every piece inherits u, v, w and sd from it;
#   - wounds on u AND v (two Wound entries per site, same distribution):
#     free ends width 6 % of the piece, doublet junction and graft width 0.02 of the body
#     (0.143), height U(1.5, 3.5); at a graft u = max(u, wound), v = max(v, wound);
#   - readout at t = 96; a head is an active region {u > 0.9} (the receptor head is a
#     plateau whose u maximum can lie inside the panel, so the region, not the
#     maximum, says which end the head touches); A/B/M/G: the region reaches within
#     5 % of the panel of the left end, right end, junction or graft centre.
#
# Run (RUNS realizations per variant, default 100; TEST=1 for a quick check):
#
#     RUNS=1000 julia --project --threads=auto scripts/experiments/Receptor_SD.jl
#
# Writes results/Receptor_SD/summary_<date>.csv with the counts per variant and model.

include(joinpath(@__DIR__, "..", "..", "src", "RDLabAPI.jl"))
using .RDLabAPI
using Random
using Printf
using Dates

# ---- settings ----------------------------------------------------------------
const TEST = get(ENV, "TEST", "0") == "1"
const RUNS = TEST ? 4 : parse(Int, get(ENV, "RUNS", "100"))
const SEED = 12345
const N = 300
const T_READ = 96.0
const HEAD_THRESHOLD = 0.9
const WINDOW = 0.05
const END_WIDTH_FRACTION = 0.06
const BODY = 7.17                # body length; the regime was found for 1, D scale with BODY²
const JUNCTION_WIDTH = 0.02 * BODY
const HEIGHT = (1.5, 3.5)
const D_DOUBLET = 0.339          # doublet length / body (2.43 / 7.17 in the GM paper)
const GRAFT = 0.018              # graft length / body

const KIN = (Dv = 0.23134, Dw = 0.43698, m1 = 3.2, m2 = 9.0, m3 = 21.0,
             μ1 = 0.7, μ2 = 0.6, μ3 = 0.7, pu = 1e-3, pv = 1e-3)
const SDPAR = (Dsd = 0.17222, μsd = 0.0367)
const TAU = 500.0

const MODELS = Dict("rec" => :receptor_based, "sd" => :receptor_based_source_c)
nvars(m) = m == "sd" ? 4 : 3
run_params(m) = m == "sd" ? merge(KIN, SDPAR, (τ = TAU,)) : KIN
ref_params(m) = m == "sd" ? merge(KIN, SDPAR, (τ = 1.0,)) : KIN

const SOLVER = (tolerance = 1e-6, check_interval = 1e3, required_consecutive_checks = 3,
                maximum_time = 1e15, maximum_steps = 10_000_000, dtmax = 1e10,
                reltol = 1e-5, abstol = 1e-7)

# ---- Reference -----------------------------------------------------------------
# Grid index i ↔ panel fraction x = (i - 1)/(N - 1) ↔ body coordinate s = 1 - x.
function reference(m)
    x = range(0.0, 1.0; length = N)
    U = zeros(N, nvars(m))
    U[:, 1] .= KIN.pu / KIN.μ1
    U[:, 2] .= KIN.pv / KIN.μ2
    head = x .>= 0.97
    U[head, 1] .= 3.0
    U[head, 2] .= 1.0
    m == "sd" && (U[:, 4] .= 0.33 .+ 3.66 .* exp.(-(1 .- x) ./ 0.3))
    st = make_state(MODELS[m]; N, length = BODY, params = ref_params(m), initial = U, label = "body")
    ref = steady_state(st; SOLVER...)
    F = hcat([field(ref, k) for k in 1:nvars(m)]...)
    regions = head_regions(F[:, 1])
    @printf("Reference %-3s converged = %s, t = %.0f, head regions (x) = %s\n", m,
            ref.info["converged"], ref.info["steady_time"], string([(round(a; digits = 3), round(b; digits = 3)) for (a, b) in regions]))
    m == "sd" && @printf("  sd at s = 0, 0.33, 0.5, 0.67, 1: %s\n",
                         string(round.([interp(x, F[:, 4], 1 - s) for s in (0.0, 0.33, 0.5, 0.67, 1.0)]; digits = 3)))
    length(regions) == 1 && regions[1][2] >= 1 - WINDOW ||
        error("Reference $m: expected one head at the right end.")
    return F
end

function interp(x, y, xq)
    xq <= first(x) && return y[1]
    xq >= last(x) && return y[end]
    k = searchsortedlast(x, xq)
    t = (xq - x[k]) / (x[k + 1] - x[k])
    return (1 - t) * y[k] + t * y[k + 1]
end

# ---- heads ---------------------------------------------------------------------
"Active regions {u > HEAD_THRESHOLD} as (x_lo, x_hi) panel fractions."
function head_regions(u)
    n = length(u)
    x = range(0.0, 1.0; length = n)
    out = Tuple{Float64, Float64}[]
    i = 1
    while i <= n
        if u[i] > HEAD_THRESHOLD
            j = i
            while j < n && u[j + 1] > HEAD_THRESHOLD
                j += 1
            end
            push!(out, (x[i], x[j]))
            i = j + 1
        else
            i += 1
        end
    end
    return out
end

function site(region, junction, graft_x)
    lo, hi = region
    if graft_x !== nothing
        hi >= 1 - WINDOW && return "B"
        lo <= graft_x + WINDOW && hi >= graft_x - WINDOW && return "G"
        return "other"
    end
    lo <= WINDOW && return "A"
    hi >= 1 - WINDOW && return "B"
    junction !== nothing && lo <= junction + WINDOW && hi >= junction - WINDOW && return "M"
    return "i"
end

function category(kind, sites)
    n = length(sites)
    if kind == :fragment            # B = apical end (right), A = basal
        n == 0 && return "none"
        sites == ["B"] && return "apical"
        sites == ["A"] && return "basal"
        sites == ["A", "B"] && return "two"
        return "other"
    elseif kind == :doublet
        n == 0 && return "none"
        (n <= 2 && allunique(sites) && all(in(("A", "B", "M")), sites)) || return "other"
        return join(sort(sites; by = q -> findfirst(==(q), ("A", "B", "M"))))
    else                            # graft
        sites == ["B"] && return "host_only"
        if n == 2 && count(==("B"), sites) == 1
            return "G" in sites ? "second_axis_at_graft" : "second_axis_elsewhere"
        end
        return "other"
    end
end

# ---- pieces --------------------------------------------------------------------
xindex(j) = N - j        # 0-based body index j (s = j/(N-1)) → 1-based grid index

"Fragment s ∈ [sa, sb]: apical end (sa) on the right."
function fragment(F, sa, sb)
    ja = round(Int, sa * (N - 1)); jb = round(Int, sb * (N - 1))
    idx = [xindex(j) for j in jb:-1:ja]
    return (F = F[idx, :], length = BODY * (length(idx) - 1) / (N - 1), junction = nothing, graft_x = nothing)
end

const CONFIGS = Dict("H2H" => ("U", :right, "U", :left),
                     "H2F_oriented" => ("U", :left, "L", :left),
                     "H2F_anti" => ("L", :left, "U", :left),
                     "F2F" => ("U", :left, "L", :right))

"Ring doublet from the Reference nodes (as Cut in the application, no interpolation)."
function doublet(F, config)
    target = D_DOUBLET * (N - 1) + 1
    M = round(Int, target)
    isodd(N - M) && (M = target >= M ? M + 1 : M - 1)
    na = M ÷ 2
    nb = M - na
    ka, ea, kb, eb = CONFIGS[config]
    c = N ÷ 2
    ring(kind, n, head_end) = begin
        js = kind == "U" ? collect((c - n):(c - 1)) : collect(c:(c + n - 1))   # from the head side
        head_end == :right ? reverse(js) : js
    end
    js = vcat(ring(ka, na, ea), ring(kb, nb, eb))
    return (F = F[[xindex(j) for j in js], :], length = BODY * (M - 1) / (N - 1),
            junction = (na - 0.5) / (M - 1), graft_x = nothing)
end

"Host Reference with GRAFT-long donor tissue from s = donor_start inserted around s_h."
function graft(F, s_h, donor_start)
    s = [(N - i) / (N - 1) for i in 1:N]          # body coordinate of grid index i
    sgrid = [j / (N - 1) for j in 0:(N - 1)]       # increasing s
    Fs = F[[xindex(j) for j in 0:(N - 1)], :]      # fields ordered by increasing s
    h = 1 / (N - 1)
    lo, hi = s_h - GRAFT / 2, s_h + GRAFT / 2
    G = copy(F)
    for i in 1:N
        a, b = max(s[i] - h / 2, 0.0), min(s[i] + h / 2, 1.0)
        olo, ohi = max(a, lo), min(b, hi)
        ohi > olo || continue
        share = (ohi - olo) / (b - a)
        σ = range(olo, ohi; length = 201) .- lo .+ donor_start
        for k in 1:size(F, 2)
            donor = sum(interp(sgrid, Fs[:, k], q) for q in σ) / length(σ)
            G[i, k] = (1 - share) * F[i, k] + share * donor
        end
    end
    return (F = G, length = BODY, junction = nothing, graft_x = 1 - s_h)
end

control(F, s_h) = (F = copy(F), length = BODY, junction = nothing, graft_x = 1 - s_h)

# ---- wounds --------------------------------------------------------------------
"Wound sites (panel fraction, width as panel fraction) in the order of the wound list."
function wound_sites(piece, kind)
    kind == :fragment && return [(0.0, END_WIDTH_FRACTION), (1.0, END_WIDTH_FRACTION)]
    kind == :doublet && return [(0.0, END_WIDTH_FRACTION), (piece.junction, JUNCTION_WIDTH / piece.length),
                                (1.0, END_WIDTH_FRACTION)]
    return [(piece.graft_x, JUNCTION_WIDTH / piece.length)]
end

wounds_for(piece, kind) = [Wound(pos; width_fraction = w, height = HEIGHT, variable = var)
                           for (pos, w) in wound_sites(piece, kind) for var in (:u, :v)]

"Increments of the wounds of realization `run`, drawn as RD Lab draws them."
function wound_increments(piece, kind, run)
    n = size(piece.F, 1)
    x = range(0.0, 1.0; length = n)
    rng = Xoshiro(UInt64(SEED) + UInt64(run - 1))
    d = zeros(n, 2)
    for (pos, w) in wound_sites(piece, kind), var in 1:2
        width = w + (w - w) * rand(rng)
        height = HEIGHT[1] + (HEIGHT[2] - HEIGHT[1]) * rand(rng)
        for i in 1:n
            abs(x[i] - pos) <= width / 2 || continue
            d[i, var] += height * rand(rng)
        end
    end
    return d
end

# ---- one realization -----------------------------------------------------------
function realize(m, piece, kind, run)
    U = copy(piece.F)
    if kind == :graft            # u = max(u, wound), v = max(v, wound)
        d = wound_increments(piece, kind, run)
        U[:, 1] .= max.(U[:, 1] .- d[:, 1], 0.0)
        U[:, 2] .= max.(U[:, 2] .- d[:, 2], 0.0)
    end
    n = size(U, 1)
    st = make_state(MODELS[m]; N = n, length = piece.length, params = run_params(m), initial = U, label = "piece")
    spec = SingleSpec(; experiment = "Receptor_SD", start = st, wounds = wounds_for(piece, kind),
                      seed = SEED, run, times = [T_READ], until_steady = false,
                      dtmax = SOLVER.dtmax, reltol = SOLVER.reltol, abstol = SOLVER.abstol)
    res = run_single(spec; mkl_threads = 1, verbose = false, write_files = false)
    _, y = only(res.snapshots)
    u = reshape(y, n, :)[:, 1]
    sites = [site(r, piece.junction, piece.graft_x) for r in head_regions(u)]
    return category(kind, sites)
end

# ---- variants ------------------------------------------------------------------
function variants()
    v = Any[]
    for f in (0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6)
        push!(v, (@sprintf("E1_f%.2f", f), :fragment, F -> fragment(F, 0.5 - f / 2, 0.5 + f / 2)))
    end
    for c in ("H2H", "H2F_oriented", "H2F_anti", "F2F")
        push!(v, ("E2_" * c, :doublet, F -> doublet(F, c)))
    end
    push!(v, ("E3a_head", :graft, F -> graft(F, 0.5, 0.0)))
    for sd in (0.1, 0.2, 0.3, 0.4, 0.5, 0.7, 0.9)
        push!(v, (@sprintf("E3a_sd%.2f", sd), :graft, F -> graft(F, 0.5, sd - GRAFT / 2)))
    end
    for sh in (0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.5, 0.8)
        push!(v, (@sprintf("E3b_sh%.2f", sh), :graft, F -> graft(F, sh, 0.0)))
    end
    for sh in (0.1, 0.2, 0.3, 0.5)
        push!(v, (@sprintf("C_sh%.2f", sh), :graft, F -> control(F, sh)))
    end
    return v
end

function main()
    refs = Dict(m => reference(m) for m in ("rec", "sd"))
    out = joinpath(@__DIR__, "..", "..", "results", "Receptor_SD")
    mkpath(out)
    file = joinpath(out, "summary_" * Dates.format(now(), "yyyy-mm-dd_HHMM") * (TEST ? "_test" : "") * ".csv")
    open(file, "w") do io
        println(io, "variant,model,runs,category,count,percent")
        for (name, kind, build) in variants(), m in ("rec", "sd")
            piece = build(refs[m])
            cats = Vector{String}(undef, RUNS)
            Threads.@threads for run in 1:RUNS
                cats[run] = realize(m, piece, kind, run)
            end
            counts = Dict{String, Int}()
            for c in cats
                counts[c] = get(counts, c, 0) + 1
            end
            line = join([@sprintf("%s %.0f%%", c, 100 * k / RUNS) for (c, k) in sort(collect(counts); by = t -> -t[2])], ", ")
            @printf("%-14s %-3s %s\n", name, m, line)
            for (c, k) in counts
                @printf(io, "%s,%s,%d,%s,%d,%.1f\n", name, m, RUNS, c, k, 100 * k / RUNS)
            end
            flush(io)
        end
    end
    println("Summary: ", file)
end

main()
