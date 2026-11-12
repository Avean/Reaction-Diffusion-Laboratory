# test/test_series_presets.jl
#
# Series presets written by Save preset in the series window: the TOML file
# reads back with the same values, is found where the built-in presets are
# (so a restart shows it), never replaces a file unasked, and Delete preset
# removes it. Everything is written to temporary folders, never to Models/.

function same_preset_perturbations(a, b)
    length(a) == length(b) || return false
    return all(
        getfield(x, name) === getfield(y, name)
        for (x, y) in zip(a, b) for name in fieldnames(C.SeriesPresetPerturbation)
    )
end

@testset "series preset files" begin
    root = mktempdir()
    try
        # A model folder as at startup: model_files only needs model.jl to exist.
        model_key = "Family/model"
        directory = C.series_preset_directory(model_key; root = root)
        mkpath(directory)
        touch(joinpath(directory, "model.jl"))

        perturbations = [
            C.SeriesPresetPerturbation("u", 0.0, 0.03, 0.06, 1.6, 2.6),
            # Values that need every digit to read back identically.
            C.SeriesPresetPerturbation("u", 1 / 3, 0.1 / 3, 0.2 / 3, -0.5, 1.25),
            C.SeriesPresetPerturbation("v", 1.0, 1e-12, 0.5, 2.0, 2.0),
        ]
        initial_values = Dict("u" => 0.0, "v" => 2.5)
        name = "Ends \"strong\" 1.6–2.6 \\ test"
        description = "Both ends, 3–6 % of the panel."

        @testset "write and read back" begin
            preset = C.write_series_preset(
                directory, model_key, "  $name  ", description, initial_values, perturbations,
            )
            @test preset.key == "ends_strong_1_6_2_6_test.toml"
            @test preset.path == joinpath(directory, preset.key)
            @test isfile(preset.path)
            @test preset.name == name
            @test preset.description == description
            @test preset.model_key == model_key
            @test preset.initial_values == initial_values
            @test same_preset_perturbations(preset.perturbations, perturbations)

            # As the application finds presets at startup.
            found = C.load_series_presets(root)
            @test length(found) == 1
            reloaded = only(found)
            @test (reloaded.key, reloaded.name, reloaded.description, reloaded.model_key) ==
                  (preset.key, name, description, model_key)
            @test reloaded.initial_values == initial_values
            @test same_preset_perturbations(reloaded.perturbations, perturbations)
            @test !any(endswith(".tmp"), readdir(directory))
            json = C.JSON.parse(C.series_presets_json(found, model_key))
            @test json[end]["key"] == preset.key
            @test json[end]["name"] == name
            @test json[end]["file"] == replace(preset.path, '\\' => '/')
        end

        @testset "no replacement without overwrite" begin
            path = joinpath(directory, "ends_strong_1_6_2_6_test.toml")
            before = read(path, String)
            @test_throws ErrorException C.write_series_preset(
                directory, model_key, name, "", Dict{String, Float64}(), perturbations[1:1],
            )
            @test read(path, String) == before

            replaced = C.write_series_preset(
                directory, model_key, name, "", Dict{String, Float64}(), perturbations[1:1];
                overwrite = true,
            )
            @test replaced.path == path
            @test replaced.description == ""
            @test isempty(replaced.initial_values)
            @test same_preset_perturbations(replaced.perturbations, perturbations[1:1])
            @test length(C.load_series_presets(root)) == 1
        end

        @testset "refused input writes nothing" begin
            count = length(readdir(directory))
            @test_throws ErrorException C.write_series_preset(
                directory, model_key, "   ", "", Dict{String, Float64}(), perturbations,
            )
            @test_throws ErrorException C.write_series_preset(
                directory, model_key, "Empty", "", Dict{String, Float64}(), C.SeriesPresetPerturbation[],
            )
            @test_throws ErrorException C.write_series_preset(
                joinpath(root, "missing"), model_key, "Elsewhere", "", Dict{String, Float64}(), perturbations,
            )
            @test length(readdir(directory)) == count
        end

        @testset "file names" begin
            @test C.series_preset_file_name("Rana – końce (wąska)") == "rana_konce_waska.toml"
            @test C.series_preset_file_name("u left wound (narrow)") == "u_left_wound_narrow.toml"
            @test C.series_preset_file_name("ρρ") == "preset.toml"
            @test C.series_preset_file_name("CON") == "con_preset.toml"
            @test length(C.series_preset_file_name(repeat("a", 200))) <= 65
        end

        @testset "registry and delete" begin
            preset = only(C.load_series_presets(root))
            presets = C.SeriesPresetDefinition[]
            C.register_series_preset!(presets, preset)
            C.register_series_preset!(presets, preset)
            @test length(presets) == 1

            C.delete_series_preset_file(preset)
            @test !isfile(preset.path)
            @test isempty(C.load_series_presets(root))
            C.unregister_series_preset!(presets, preset)
            @test isempty(presets)
            # A file that is already gone is no error.
            C.delete_series_preset_file(preset)
            @test isfile(joinpath(directory, "model.jl"))
        end

        @testset "built-in presets read back unchanged" begin
            for builtin in C.load_series_presets(C.MODEL_DIR)
                folder = mkpath(joinpath(root, "copies", builtin.model_key))
                copy = C.write_series_preset(
                    folder, builtin.model_key, builtin.name, builtin.description,
                    builtin.initial_values, builtin.perturbations; overwrite = true,
                )
                @test (copy.name, copy.description) == (builtin.name, builtin.description)
                @test copy.initial_values == builtin.initial_values
                @test same_preset_perturbations(copy.perturbations, builtin.perturbations)
            end
        end
    finally
        rm(root; recursive = true, force = true)
    end
end
