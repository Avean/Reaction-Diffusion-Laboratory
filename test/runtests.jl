# test/runtests.jl
#
#     julia --project --threads=auto test/runtests.jl
#
# Tests of the headless core and the scripting API. The reproduction of saved
# application series (gui_reproduction.jl) runs when the saved_graphs folders
# are available (see that file); test/gui_vs_api.jl compares the running
# application with the API and needs a display.

using Test

const REPO = normpath(joinpath(@__DIR__, ".."))
const TEST_OUT = mktempdir()

include(joinpath(REPO, "src", "RDLabAPI.jl"))
using .RDLabAPI
const C = RDLabAPI.C

@testset "RD Lab scripting API" begin
    @testset "core without GUI packages" begin
        gui_packages = ("QML", "QMLMakie", "GLMakie", "CairoMakie", "Makie", "CxxWrap")
        loaded = [id.name for id in keys(Base.loaded_modules)]
        @test isempty(intersect(loaded, gui_packages))
        @test length(load_models()) == length(C.model_files(C.MODEL_DIR))
        key, model = find_model(:gierer_meinhardt_rho)
        @test key == "GiererMeinhardt/rho"
        @test find_model("rho")[1] == key
    end

    include("test_piece_rule.jl")
    include("test_cut_join.jl")
    include("test_e4b_smoke.jl")
    include("gui_reproduction.jl")
end
