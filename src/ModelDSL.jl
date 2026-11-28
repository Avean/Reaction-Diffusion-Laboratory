# src/ModelDSL.jl

# ============================================================
# Model DSL
# ============================================================
#
# User-facing layer for defining reaction-diffusion models.
#
# Supports:
#
#     - variables U.u, U.v, ...
#     - reaction fields F.u, F.v, ...
#     - parameters p.a, p.Du, ...
#     - spatial profiles p.ρ, p.source, ...
#     - active spatial profile sets switchable from the UI
#     - the domain length p.domain_length
#
# ============================================================


const ACTIVE_SPATIAL_PROFILE_SET_PARAM = :__active_spatial_profile_set_index
const SPATIAL_PROFILE_OVERRIDE_PREFIX = "__spatial_profile_override__"

# Squared domain length L^2, set by the domain slider. Every model is solved
# on the unit interval, so a domain of length L acts through the diffusion
# coefficients as D / L^2. The parameters themselves always keep the values
# given by the model or typed by the user; only the right-hand side divides.
const DIFFUSION_SCALE_PARAM = :__diffusion_scale

# The domain length L as models read it, e.g. a kernel with a fixed physical
# range: p.domain_length. It is not a model parameter and cannot be edited.
const DOMAIN_LENGTH_FIELD = :domain_length

# A model that declares freezable variables, RDModel(...; freezable = (:sd,)),
# gets this parameter (default 0). While it is 1 (any value above 1/2), the
# reaction and diffusion of those variables are zero: they keep their values,
# for example a slow source density frozen at its steady state. It is an
# ordinary model parameter, so saves, series and the API carry it.
const FROZEN_PARAM = :frozen


function diffusion_scale(p_dict::AbstractDict{Symbol})
    return Float64(get(p_dict, DIFFUSION_SCALE_PARAM, 1.0))
end


"Whether the freezable variables of a model are frozen by `params`."
function variables_frozen(model::ModelSpec, params::AbstractDict{Symbol})
    isempty(model.freezable_variables) && return false
    return Float64(get(params, FROZEN_PARAM, 0.0)) > 0.5
end


"Indices of the variables that `params` freeze (empty when none are)."
function frozen_variable_indices(model::ModelSpec, params::AbstractDict{Symbol})
    return variables_frozen(model, params) ? copy(model.freezable_variables) : Int[]
end


"""
    freezable_rate_weights(model, params) -> Vector{Float64}

Weights of the stationarity check of Cut and run, one per variable: 1, and
for a freezable variable its declared time scale (freezable = (sd = :τ,)
gives p.τ). The rate of a variable whose equation is divided by τ is then
measured in the units of its own equation, so a slow source density must be
close to its equilibrium, not only slow, to count as stationary.
"""
function freezable_rate_weights(model::ModelSpec, params::AbstractDict{Symbol})
    weights = ones(Float64, model.nvars)

    for (index, scale) in zip(model.freezable_variables, model.freezable_time_scales)
        value = scale === nothing ? 1.0 :
                scale isa Symbol ? Float64(get(params, scale, 1.0)) :
                Float64(scale)
        isfinite(value) && value > 0.0 && (weights[index] = value)
    end

    return weights
end


function spatial_profile_override_key(profile_name::AbstractString)
    return Symbol(SPATIAL_PROFILE_OVERRIDE_PREFIX, profile_name)
end


# ============================================================
# Variable views
# ============================================================

struct VariableViews{M <: AbstractMatrix}
    data::M
    var_index::Dict{Symbol, Int}
end


function Base.getproperty(V::VariableViews, name::Symbol)
    if name === :data || name === :var_index
        return getfield(V, name)
    end

    if haskey(V.var_index, name)
        return view(V.data, :, V.var_index[name])
    end

    error("Unknown variable: $(name)")
end


function Base.propertynames(V::VariableViews; private::Bool = false)
    names = collect(keys(V.var_index))

    if private
        append!(names, [:data, :var_index])
    end

    return Tuple(names)
end


# ============================================================
# Parameters
# ============================================================

function _make_parameter_dict(parameters::NamedTuple)
    params = Dict{Symbol, Float64}()

    for name in propertynames(parameters)
        value = getproperty(parameters, name)

        value isa Real ||
            error("Parameter $(name) must be a real number.")

        params[name] = Float64(value)
    end

    return params
end


function _make_named_parameters(
    params::AbstractDict{Symbol},
    param_names::Vector{Symbol},
)
    values = map(name -> params[name], param_names)

    return NamedTuple{Tuple(param_names)}(Tuple(values))
end


# ============================================================
# Variables
# ============================================================

function _normalize_variables(variables)
    vars = collect(Symbol.(variables))

    isempty(vars) &&
        error("Model must contain at least one variable.")

    length(unique(vars)) == length(vars) ||
        error("Variable names must be unique.")

    return vars
end


function _make_variable_index(vars::Vector{Symbol})
    var_index = Dict{Symbol, Int}()

    for (j, var) in enumerate(vars)
        var_index[var] = j
    end

    return var_index
end


# ============================================================
# Diffusion
# ============================================================

function _normalize_diffusion(diffusion)
    diffusion isa NamedTuple ||
        error("diffusion must be a NamedTuple, for example (u = :Du, v = :Dv).")

    return diffusion
end


function _validate_diffusion(
    diffusion::NamedTuple,
    vars::Vector{Symbol},
    param_names::Vector{Symbol},
)
    for var in propertynames(diffusion)
        var in vars ||
            error("Diffusion coefficient specified for unknown variable $(var).")

        coeff = getproperty(diffusion, var)

        if coeff isa Symbol
            coeff in param_names ||
                error("Unknown diffusion parameter $(coeff) for variable $(var).")

        elseif coeff isa Real
            nothing

        elseif coeff isa Function
            nothing

        else
            error("""
            Invalid diffusion coefficient for variable $(var).

            Allowed forms are:

                u = :Du
                u = 0.01
                u = p -> p.Du
            """)
        end
    end

    return nothing
end


function _diffusion_coefficient(
    diffusion::NamedTuple,
    var::Symbol,
    p,
)
    if !(var in propertynames(diffusion))
        return 0.0
    end

    coeff = getproperty(diffusion, var)

    if coeff isa Symbol
        return getproperty(p, coeff)

    elseif coeff isa Real
        return Float64(coeff)

    elseif coeff isa Function
        return coeff(p)

    else
        error("Invalid diffusion coefficient for variable $(var).")
    end
end


# ============================================================
# Spatial profile sets
# ============================================================
#
# A profile set is a NamedTuple of profile functions. Besides the profiles
# it may carry three optional entries:
#
#     formula     LaTeX of the profile, shown under Model parameters: a
#                 string such as raw"\rho(x) = \rho_0 + \rho_1 x", or
#                 piecewise(...) for a profile made of several parts.
#     note        a short text shown under the formula.
#     parameters  the parameters the profiles use, e.g. (:ρ0, :ρ1). Usually
#                 not needed: they are found by evaluating the profiles once.
#
# While a set is active, the parameters that only other profile sets use
# are hidden from the parameter fields.
#
# Example:
#
#     HeadFoot = (
#         ρ = (x, p) -> ...,
#         formula = piecewise(raw"\rho(x)",
#             raw"\rho_0 + \rho_1 (x + 1 - \rho_{split})" => raw"x < \rho_{split}",
#             raw"\rho_0 + \rho_1 (x - \rho_{split})" => raw"x \geq \rho_{split}",
#         ),
#     ),
#
# In formulas a parameter is written as the application writes it when it
# substitutes the current values: a Greek first letter becomes its command
# and the rest a subscript, in braces when it is longer than one character
# (μu -> \mu_u, ρ0 -> \rho_0, ρsplit -> \rho_{split}, ρpeak_pos ->
# \rho_{peak\_pos}).

const SPATIAL_PROFILE_SET_METADATA = (:formula, :note, :parameters)


# LaTeX of a profile made of several parts, drawn with a curly brace:
#
#     piecewise(raw"\rho(x)",
#         expression_1 => condition_1,
#         expression_2 => condition_2,
#     )
struct PiecewiseFormula
    lhs::String
    pieces::Vector{Pair{String, String}}
end


function piecewise(lhs::AbstractString, pieces::Pair...)
    isempty(pieces) &&
        error("piecewise needs at least one expression => condition pair.")

    return PiecewiseFormula(
        String(lhs),
        [String(first(piece)) => String(last(piece)) for piece in pieces],
    )
end


function _normalize_spatial_profiles(spatial_profiles)
    spatial_profiles isa NamedTuple ||
        error("spatial_profiles must be a NamedTuple.")

    return spatial_profiles
end


function _profile_entry_names(profile_set::NamedTuple)
    return [
        name for name in propertynames(profile_set)
        if !(name in SPATIAL_PROFILE_SET_METADATA)
    ]
end


function _wrap_one_spatial_profile_set(
    profile_set::NamedTuple,
    param_names::Vector{Symbol},
)
    wrapped_profiles = Tuple{String, Function}[]

    for name in _profile_entry_names(profile_set)
        profile_fun = getproperty(profile_set, name)

        profile_fun isa Function ||
            error("Spatial profile $(name) must be a function.")

        # A profile may take a third argument: the random generator of a
        # series realization, or nothing outside series mode.
        wrapped_profile_fun = function (x, p_dict, rng = nothing)
            p = _make_named_parameters(p_dict, param_names)
            return applicable(profile_fun, x, p, rng) ?
                   profile_fun(x, p, rng) :
                   profile_fun(x, p)
        end

        push!(
            wrapped_profiles,
            (string(name), wrapped_profile_fun),
        )
    end

    isempty(wrapped_profiles) &&
        error("A spatial profile set must contain at least one profile function.")

    return wrapped_profiles
end


function _profile_set_metadata(
    profile_set::NamedTuple,
    set_name::AbstractString,
    param_names::Vector{Symbol},
)
    formula = get(profile_set, :formula, nothing)

    if formula isa AbstractString
        formula = String(formula)
    elseif !(formula === nothing || formula isa PiecewiseFormula)
        error("The formula of spatial profile set $(set_name) must be a LaTeX string or piecewise(...).")
    end

    note = get(profile_set, :note, "")
    note isa AbstractString ||
        error("The note of spatial profile set $(set_name) must be a string.")

    parameters = get(profile_set, :parameters, nothing)

    if parameters !== nothing
        parameters = Symbol[Symbol(name) for name in parameters]

        for name in parameters
            name in param_names ||
                error("Spatial profile set $(set_name) lists unknown parameter $(name).")
        end
    end

    return (formula = formula, note = String(note), parameters = parameters)
end


function _is_flat_spatial_profile_tuple(spatial_profiles::NamedTuple)
    names = _profile_entry_names(spatial_profiles)

    isempty(names) &&
        return false

    return all(name -> getproperty(spatial_profiles, name) isa Function, names)
end


function _is_spatial_profile_set_tuple(spatial_profiles::NamedTuple)
    names = propertynames(spatial_profiles)

    isempty(names) &&
        return false

    return all(name -> getproperty(spatial_profiles, name) isa NamedTuple, names)
end


function _spatial_profile_set_list(spatial_profiles::NamedTuple)
    # The profile sets as (name, set) pairs.
    set_list = Tuple{String, NamedTuple}[]

    isempty(propertynames(spatial_profiles)) &&
        return set_list

    # Backward-compatible flat syntax:
    #
    #     spatial_profiles = (
    #         ρ = (x, p) -> ...,
    #     )
    #
    # becomes one set named "default".
    if _is_flat_spatial_profile_tuple(spatial_profiles)
        push!(set_list, ("default", spatial_profiles))
        return set_list
    end

    # Grouped syntax:
    #
    #     spatial_profiles = (
    #         linear = (
    #             ρ = (x, p) -> ...,
    #         ),
    #
    #         gaussian = (
    #             ρ = (x, p) -> ...,
    #         ),
    #     )
    if _is_spatial_profile_set_tuple(spatial_profiles)
        for set_name in propertynames(spatial_profiles)
            push!(set_list, (string(set_name), getproperty(spatial_profiles, set_name)))
        end

        return set_list
    end

    error("""
    Invalid spatial_profiles format.

    Use either flat syntax:

        spatial_profiles = (
            ρ = (x, p) -> ...,
        )

    or grouped syntax:

        spatial_profiles = (
            linear = (
                ρ = (x, p) -> ...,
            ),
            gaussian = (
                ρ = (x, p) -> ...,
            ),
        )
    """)
end


function _wrap_spatial_profile_sets(
    set_list::Vector{Tuple{String, NamedTuple}},
    param_names::Vector{Symbol},
)
    wrapped_sets = Tuple{String, Vector{Tuple{String, Function}}}[]

    for (set_name, profile_set) in set_list
        push!(
            wrapped_sets,
            (set_name, _wrap_one_spatial_profile_set(profile_set, param_names)),
        )
    end

    return wrapped_sets
end


# ============================================================
# Parameters used by the profile sets
# ============================================================
#
# Every profile set is evaluated once with the default parameters while a
# tracer records which parameters it reads. The reaction, the initial
# condition and the diffusion coefficients are traced the same way, and a
# parameter they read is never hidden.

struct _ParameterTracer{T <: NamedTuple}
    values::T
    read::Set{Symbol}
end


function Base.getproperty(tracer::_ParameterTracer, name::Symbol)
    push!(getfield(tracer, :read), name)
    return getproperty(getfield(tracer, :values), name)
end


Base.propertynames(tracer::_ParameterTracer) =
    propertynames(getfield(tracer, :values))


function _traced_parameters(f::Function, values::NamedTuple)
    tracer = _ParameterTracer(values, Set{Symbol}())
    f(tracer)
    return getfield(tracer, :read)
end


function _profile_set_read_parameters(
    profile_set::NamedTuple,
    values::NamedTuple,
    x::Vector{Float64},
)
    read = Set{Symbol}()

    for name in _profile_entry_names(profile_set)
        profile_fun = getproperty(profile_set, name)
        # With a generator, profiles that vary in series runs read their
        # variation parameters as well.
        rng = Random.Xoshiro(1)

        union!(read, _traced_parameters(values) do p
            applicable(profile_fun, x, p, rng) ?
                profile_fun(x, p, rng) :
                profile_fun(x, p)
        end)
    end

    return read
end


function _hidden_profile_parameters(
    set_list::Vector{Tuple{String, NamedTuple}},
    metadata,
    param_names::Vector{Symbol},
    default_params::AbstractDict{Symbol},
    vars::Vector{Symbol},
    var_index::Dict{Symbol, Int},
    initial::Function,
    reaction::Function,
    diffusion::NamedTuple,
)
    hidden = Vector{Symbol}[Symbol[] for _ in set_list]
    isempty(set_list) && return hidden

    x = collect(range(0.0, 1.0; length = 21))
    values = merge(
        _make_named_parameters(default_params, param_names),
        NamedTuple{(DOMAIN_LENGTH_FIELD,)}((1.0,)),
    )

    set_reads = Union{Nothing, Set{Symbol}}[]

    for ((set_name, profile_set), meta) in zip(set_list, metadata)
        if meta.parameters !== nothing
            push!(set_reads, Set{Symbol}(meta.parameters))
            continue
        end

        read = try
            intersect(_profile_set_read_parameters(profile_set, values, x), param_names)
        catch error
            @warn "Spatial profile set $(set_name) could not be evaluated to find the parameters it uses; none are hidden while it is active." exception = error
            nothing
        end

        push!(set_reads, read)
    end

    # Parameters read outside the profiles stay visible for every set.
    profile_names = unique(vcat(
        [_profile_entry_names(profile_set) for (_, profile_set) in set_list]...,
    ))
    model_values = merge(
        values,
        NamedTuple{Tuple(profile_names)}(Tuple(ones(length(x)) for _ in profile_names)),
    )

    outside = try
        read = Set{Symbol}()

        union!(read, _traced_parameters(model_values) do p
            U = VariableViews(fill(0.5, length(x), length(vars)), var_index)
            F = VariableViews(zeros(length(x), length(vars)), var_index)
            reaction(F, U, x, p, 0.0)
        end)

        union!(read, _traced_parameters(model_values) do p
            U = VariableViews(zeros(length(x), length(vars)), var_index)
            initial(U, x, p)
        end)

        for var in propertynames(diffusion)
            coeff = getproperty(diffusion, var)

            if coeff isa Symbol
                push!(read, coeff)
            elseif coeff isa Function
                union!(read, _traced_parameters(p -> coeff(p), model_values))
            end
        end

        read
    catch error
        @warn "The reaction or initial condition could not be evaluated to find the parameters they use; no parameter is hidden." exception = error
        return hidden
    end

    known_reads = [read for read in set_reads if read !== nothing]
    isempty(known_reads) && return hidden

    profile_parameters = setdiff(union(known_reads...), outside)

    for (index, read) in enumerate(set_reads)
        read === nothing && continue
        hidden[index] = sort!(collect(setdiff(profile_parameters, read)); by = String)
    end

    return hidden
end


function _active_spatial_profile_set_index(
    p_dict::AbstractDict{Symbol},
    spatial_profile_sets,
)
    isempty(spatial_profile_sets) &&
        return 0

    if !haskey(p_dict, ACTIVE_SPATIAL_PROFILE_SET_PARAM)
        return 1
    end

    index = round(Int, p_dict[ACTIVE_SPATIAL_PROFILE_SET_PARAM])

    return clamp(index, 1, length(spatial_profile_sets))
end


function _evaluate_spatial_profile_for_parameter(
    x::AbstractVector,
    p_dict::AbstractDict{Symbol},
    profile_name::String,
    profile_fun::Function;
    rng = nothing,
)
    raw = applicable(profile_fun, x, p_dict, rng) ?
          profile_fun(x, p_dict, rng) :
          profile_fun(x, p_dict)

    y = if raw isa Number
        fill(Float64(raw), length(x))
    else
        Float64.(collect(raw))
    end

    length(y) == length(x) ||
        error("Spatial profile $(profile_name) has wrong length.")

    return y
end


function _make_named_parameters_with_active_spatial_profiles(
    p_dict::AbstractDict{Symbol},
    param_names::Vector{Symbol},
    spatial_profile_sets,
    x::AbstractVector,
)
    p_base = merge(
        _make_named_parameters(p_dict, param_names),
        NamedTuple{(DOMAIN_LENGTH_FIELD,)}((sqrt(diffusion_scale(p_dict)),)),
    )

    isempty(spatial_profile_sets) &&
        return p_base

    set_index = _active_spatial_profile_set_index(
        p_dict,
        spatial_profile_sets,
    )

    _, profiles = spatial_profile_sets[set_index]

    profile_symbols = Symbol[]
    profile_values = Any[]

    for (profile_name, profile_fun) in profiles
        profile_symbol = Symbol(profile_name)

        (profile_symbol in param_names || profile_symbol == DOMAIN_LENGTH_FIELD) &&
            error("Spatial profile $(profile_name) conflicts with an existing parameter name.")

        push!(profile_symbols, profile_symbol)

        override_key = spatial_profile_override_key(profile_name)

        y = if haskey(p_dict, override_key)
            override = Float64.(collect(p_dict[override_key]))

            length(override) == length(x) ||
                error("Spatial profile override $(profile_name) has wrong length.")

            override
        else
            _evaluate_spatial_profile_for_parameter(
                x,
                p_dict,
                profile_name,
                profile_fun,
            )
        end

        push!(profile_values, y)
    end

    p_profiles = NamedTuple{Tuple(profile_symbols)}(Tuple(profile_values))

    return merge(p_base, p_profiles)
end


# ============================================================
# Main model constructor
# ============================================================

function _make_latex_equations(latex_equations)
    if latex_equations === nothing
        return String[]

    elseif latex_equations isa AbstractString
        return String[latex_equations]

    elseif latex_equations isa Tuple || latex_equations isa AbstractVector
        return [String(eq) for eq in latex_equations]

    else
        error("latex_equations must be a string, tuple of strings, or vector of strings.")
    end
end

# Heights of the Cut and run bump, one per variable, from
# cut_run_bump = (u = 4.0, v = 1.0): the variables not named get 0. Without
# the declaration (nothing), the first variable gets CUT_RUN_BUMP_HEIGHT.
function _make_cut_run_bump(cut_run_bump, vars, var_index)
    cut_run_bump === nothing && return default_cut_run_bump(length(vars))

    cut_run_bump isa NamedTuple ||
        error("cut_run_bump must name variables with their heights, e.g. cut_run_bump = (u = 4.0, v = 1.0).")

    heights = zeros(Float64, length(vars))
    for (var, height) in pairs(cut_run_bump)
        haskey(var_index, var) ||
            error("cut_run_bump: $(var) is not a model variable ($(join(vars, ", "))).")
        height isa Real && !(height isa Bool) ||
            error("cut_run_bump: the height of $(var) must be a number.")
        heights[var_index[var]] = Float64(height)
    end

    return validate_cut_run_bump(heights, string.(vars))
end

function RDModel(;
    id::Symbol,
    display_name::String,
    description::String = "",
    variables,
    parameters,
    initial::Function,
    reaction::Function,
    diffusion = NamedTuple(),
    default_boundary_condition::Union{Nothing, Symbol} = nothing,
    spatial_profiles = NamedTuple(),
    latex_equations = String[],
    freezable = (),
    cut_run_bump = nothing,
)
    vars = _normalize_variables(variables)
    var_index = _make_variable_index(vars)
    cut_run_heights = _make_cut_run_bump(cut_run_bump, vars, var_index)

    parameters isa NamedTuple ||
        error("parameters must be a NamedTuple.")

    default_params = _make_parameter_dict(parameters)
    param_names = collect(Symbol.(propertynames(parameters)))

    DOMAIN_LENGTH_FIELD in param_names &&
        error("Parameter name $(DOMAIN_LENGTH_FIELD) is reserved: models read the domain length as p.$(DOMAIN_LENGTH_FIELD).")

    # Freezable variables: the model gets the parameter `frozen` (default 0),
    # which stops their reaction and diffusion while it is 1. Either a tuple
    # of names, freezable = (:sd,), or names with the time scale their
    # equation is divided by, freezable = (sd = :τ,) (a parameter or a number).
    freezable_entries = Pair{Int, Union{Nothing, Symbol, Float64}}[]
    freezable_list = freezable isa NamedTuple ?
        collect(pairs(freezable)) :
        [entry => nothing for entry in freezable]
    for (entry, time_scale) in freezable_list
        var = Symbol(entry)
        haskey(var_index, var) || error("Freezable variable $(var) is not a model variable.")
        scale = if time_scale === nothing
            nothing
        elseif time_scale isa Symbol
            time_scale in param_names ||
                error("Time scale $(time_scale) of freezable variable $(var) is not a model parameter.")
            time_scale
        elseif time_scale isa Real
            Float64(time_scale)
        else
            error("The time scale of freezable variable $(var) must be a parameter name or a number.")
        end
        any(e -> first(e) == var_index[var], freezable_entries) ||
            push!(freezable_entries, var_index[var] => scale)
    end
    sort!(freezable_entries; by = first)
    freezable_indices = Int[first(e) for e in freezable_entries]
    freezable_time_scales = Union{Nothing, Symbol, Float64}[last(e) for e in freezable_entries]
    if !isempty(freezable_indices)
        FROZEN_PARAM in param_names &&
            error("Parameter name $(FROZEN_PARAM) is reserved for models with freezable variables.")
        default_params[FROZEN_PARAM] = 0.0
        push!(param_names, FROZEN_PARAM)
    end

    diffusion = _normalize_diffusion(diffusion)
    _validate_diffusion(diffusion, vars, param_names)

    spatial_profiles = _normalize_spatial_profiles(spatial_profiles)
    spatial_profile_set_list = _spatial_profile_set_list(spatial_profiles)

    wrapped_spatial_profile_sets = _wrap_spatial_profile_sets(
        spatial_profile_set_list,
        param_names,
    )
    spatial_profile_metadata = [
        _profile_set_metadata(profile_set, set_name, param_names)
        for (set_name, profile_set) in spatial_profile_set_list
    ]
    spatial_profile_hidden_parameters = _hidden_profile_parameters(
        spatial_profile_set_list,
        spatial_profile_metadata,
        param_names,
        default_params,
        vars,
        var_index,
        initial,
        reaction,
        diffusion,
    )

    if !isempty(wrapped_spatial_profile_sets)
        default_params[ACTIVE_SPATIAL_PROFILE_SET_PARAM] = 1.0
    end

    function initialize_wrapped!(
        Umat::AbstractMatrix,
        x::AbstractVector,
        p_dict::AbstractDict{Symbol},
    )
        size(Umat, 2) == length(vars) ||
            error("Initial condition matrix has wrong number of variables.")

        U = VariableViews(Umat, var_index)

        p = _make_named_parameters_with_active_spatial_profiles(
            p_dict,
            param_names,
            wrapped_spatial_profile_sets,
            x,
        )

        initial(U, x, p)

        return nothing
    end

    function rhs_wrapped!(
        dUmat::AbstractMatrix,
        Umat::AbstractMatrix,
        Lap,
        x::AbstractVector,
        p_dict::AbstractDict{Symbol},
        t,
    )
        size(Umat, 2) == length(vars) ||
            error("State matrix has wrong number of variables.")

        size(dUmat, 2) == length(vars) ||
            error("RHS matrix has wrong number of variables.")

        U = VariableViews(Umat, var_index)
        F = VariableViews(dUmat, var_index)

        p = _make_named_parameters_with_active_spatial_profiles(
            p_dict,
            param_names,
            wrapped_spatial_profile_sets,
            x,
        )

        fill!(dUmat, zero(eltype(dUmat)))

        reaction(F, U, x, p, t)

        # Frozen variables keep their values: no reaction, no diffusion.
        frozen = !isempty(freezable_indices) &&
                 Float64(get(p_dict, FROZEN_PARAM, 0.0)) > 0.5

        if frozen
            for j in freezable_indices
                fill!(view(dUmat, :, j), zero(eltype(dUmat)))
            end
        end

        tmp = similar(view(Umat, :, 1))

        # The model is solved on the unit interval: on a domain of length L
        # every diffusion coefficient acts as D / L^2.
        scale = diffusion_scale(p_dict)

        for var in vars
            j = var_index[var]
            frozen && j in freezable_indices && continue
            D = _diffusion_coefficient(diffusion, var, p) / scale

            if D != 0.0
                u = view(Umat, :, j)
                du = view(dUmat, :, j)

                mul!(tmp, Lap, u)

                @. du += D * tmp
            end
        end

        return nothing
    end

    return ModelSpec(
        id = id,
        display_name = display_name,
        description = description,
        nvars = length(vars),
        varnames = string.(vars),
        default_params = default_params,
        initialize! = initialize_wrapped!,
        rhs! = rhs_wrapped!,
        default_boundary_condition = default_boundary_condition,
        spatial_profile_sets = wrapped_spatial_profile_sets,
        spatial_profile_formulas = Any[meta.formula for meta in spatial_profile_metadata],
        spatial_profile_notes = String[meta.note for meta in spatial_profile_metadata],
        spatial_profile_hidden_parameters = spatial_profile_hidden_parameters,
        latex_equations = _make_latex_equations(latex_equations),
        freezable_variables = freezable_indices,
        freezable_time_scales = freezable_time_scales,
        cut_run_bump = cut_run_heights,
    )
end


# ============================================================
# Active profile set: formula and visible parameters
# ============================================================

function active_spatial_profile_formula(
    model::ModelSpec,
    p_dict::AbstractDict{Symbol},
)
    # The formula and note of the active profile set; nothing and "" when
    # the model has no profiles or the set declares no formula.
    isempty(model.spatial_profile_sets) && return (formula = nothing, note = "")

    index = _active_spatial_profile_set_index(p_dict, model.spatial_profile_sets)
    formula = index <= length(model.spatial_profile_formulas) ?
              model.spatial_profile_formulas[index] : nothing
    note = index <= length(model.spatial_profile_notes) ?
           model.spatial_profile_notes[index] : ""

    return (formula = formula, note = note)
end


function hidden_spatial_profile_parameters(
    model::ModelSpec,
    p_dict::AbstractDict{Symbol},
)
    # Parameters used only by profile sets other than the active one.
    isempty(model.spatial_profile_sets) && return Symbol[]
    isempty(model.spatial_profile_hidden_parameters) && return Symbol[]

    index = _active_spatial_profile_set_index(p_dict, model.spatial_profile_sets)
    index <= length(model.spatial_profile_hidden_parameters) || return Symbol[]

    return model.spatial_profile_hidden_parameters[index]
end


# ============================================================
# Public and visible parameter names
# ============================================================

function public_model_parameter_names(model::ModelSpec)
    return sort(
        [
            key for key in keys(model.default_params)
            if !startswith(String(key), "__")
        ];
        by = String,
    )
end


function visible_model_parameter_names(
    model::ModelSpec,
    params::AbstractDict{Symbol},
)
    # The parameter fields: every public parameter except those used only by
    # profile sets other than the active one.
    hidden = hidden_spatial_profile_parameters(model, params)

    return [name for name in public_model_parameter_names(model) if !(name in hidden)]
end
