# src/RDLabCore.jl

# ============================================================
# RD Lab core: everything that runs without a window
# ============================================================
#
# Models and their DSL, simulation states and the solver, partitioned
# domains (split / merge of states), head detection, series realizations,
# the save files and the series preset files. Nothing here loads QML,
# QMLMakie, GLMakie or CairoMakie, so the core can be used from scripts (see
# RDLabAPI.jl) as well as by the interactive application, which builds on it
# (ReactionDiffusionApp.jl).
#
# The model files in Models/ are loaded once, when this module is loaded.
#
# ============================================================

module RDLabCore

using DifferentialEquations
using OrdinaryDiffEqSDIRK: TRBDF2
using SparseArrays
using LinearAlgebra
using Random
using Printf
using Statistics
using Dates
import JSON
import TOML

include("Types.jl")
include("Spatial.jl")

# User-friendly model definition layer.
# Must be included before ModelLoader.jl, because model files use RDModel(...).
include("ModelDSL.jl")

include("ModelLoader.jl")

const MODEL_DIR = normpath(joinpath(@__DIR__, "..", "Models"))

# The model registry and the time it took to load it; the application prints
# that time among its startup stages.
const MODEL_REGISTRY, MODEL_REGISTRY_LOAD_SECONDS = let started_ns = time_ns()
    registry = load_model_registry(MODEL_DIR)
    registry, (time_ns() - started_ns) / 1.0e9
end

include("Simulation.jl")
include("DomainPartition.jl")
include("HeadDetection.jl")
include("HeadConfigurations.jl")
include("SeriesSimulation.jl")
include("SaveLoad.jl")
include("SeriesPresets.jl")


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
