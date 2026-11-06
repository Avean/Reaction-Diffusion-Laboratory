module ReactionDiffusionApp

using GLMakie
using DifferentialEquations
using OrdinaryDiffEqSDIRK: TRBDF2
using SparseArrays
using LinearAlgebra
using Random
using Printf
using LaTeXStrings
using Statistics

# ============================================================
# Main module file
# ============================================================
#
# The application builds on the headless core (RDLabCore.jl): models,
# simulation states, partitioned domains, head detection, series and save
# files. Every core name, exported or not, is imported here, so the window
# code below and ReactionDiffusionQML (as RD.<name>) use the core functions
# exactly as when they were part of this module.

include("RDLabCore.jl")

for name in names(RDLabCore; all = true)
    text = String(name)
    (startswith(text, "#") || name in (:RDLabCore, :eval, :include)) && continue
    @eval import .RDLabCore: $name
end

@printf(
    "[startup] %s %8.3f s\n",
    rpad("Load model registry", 36, '.'),
    MODEL_REGISTRY_LOAD_SECONDS,
)
flush(stdout)

# Types of the window: plot panel, application state, segment workers.
include("AppTypes.jl")

# AppState-level split, merge, swap and delete of panels.
include("DomainPartitionApp.jl")

include("PerturbationPanel.jl")
include("PlotPanel.jl")

include("UIRuntime.jl")
include("PartitionControlPanel.jl")


export ModelSpec
export RDModel

export SimulationState
export neumann_laplacian_1d
export periodic_laplacian_1d
export laplacian_1d
export warm_up_solver!

export model_files
export create_simulation_state

end
