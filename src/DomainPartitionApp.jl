# src/DomainPartitionApp.jl

# ============================================================
# Partitioned domains of the application window
# ============================================================
#
# The AppState-level operations on the panels: split, merge, swap and delete
# of a segment, and the displayed coordinates. The operations on single
# simulation states they build on (split_simulation_state,
# merge_simulation_states, ...) are in the core file DomainPartition.jl.


function segment_base_length(app::AppState, segment::Int)
    sim = app.simulations[segment]

    if length(app.simulations) == 1 && sim.boundary_condition == :periodic
        return (last(sim.x) - first(sim.x)) + sim.dx
    end

    return last(sim.x) - first(sim.x)
end


function segment_display_coordinates(
    app::AppState,
    segment::Int,
    domain_length_scale::Real,
)
    sim = app.simulations[segment]
    displayed_length =
        segment_base_length(app, segment) * Float64(domain_length_scale)

    if sim.boundary_condition == :periodic && length(app.simulations) == 1
        step = displayed_length / sim.N
        return collect(range(0.0; step = step, length = sim.N))
    end

    return collect(range(0.0, displayed_length; length = sim.N))
end


function split_domain_segment!(
    app::AppState,
    segment::Int,
    left_count::Int,
)
    1 <= segment <= length(app.simulations) ||
        error("Invalid segment index.")

    left, right = split_simulation_state(
        app.simulations[segment],
        left_count,
    )

    splice!(app.simulations, segment:segment, (left, right))
    splice!(
        app.segment_runtimes,
        segment:segment,
        (empty_segment_runtime(), empty_segment_runtime()),
    )
    app.sim = first(app.simulations)

    return nothing
end


function merge_domain_segments!(
    app::AppState,
    left_segment::Int,
)
    1 <= left_segment < length(app.simulations) ||
        error("Invalid merge boundary.")

    merged_boundary_condition =
        length(app.simulations) == 2 ?
        app.initial_boundary_condition :
        :neumann

    merged = merge_simulation_states(
        app.simulations[left_segment],
        app.simulations[left_segment + 1];
        boundary_condition = merged_boundary_condition,
    )

    splice!(
        app.simulations,
        left_segment:(left_segment + 1),
        (merged,),
    )
    splice!(
        app.segment_runtimes,
        left_segment:(left_segment + 1),
        (empty_segment_runtime(),),
    )
    app.sim = first(app.simulations)

    return nothing
end


function swap_adjacent_domain_segments!(
    app::AppState,
    left_segment::Int,
)
    1 <= left_segment < length(app.simulations) ||
        error("Invalid swap boundary.")
    length(app.simulations) == length(app.segment_runtimes) ||
        error("Segment runtime count does not match the simulation partition.")

    right_segment = left_segment + 1
    app.simulations[left_segment], app.simulations[right_segment] =
        app.simulations[right_segment], app.simulations[left_segment]
    app.segment_runtimes[left_segment], app.segment_runtimes[right_segment] =
        app.segment_runtimes[right_segment], app.segment_runtimes[left_segment]

    rebase_partition_coordinates!(app.simulations)
    app.sim = first(app.simulations)

    return nothing
end


function delete_domain_segment!(app::AppState, segment::Int)
    length(app.simulations) > 1 ||
        error("The last remaining domain segment cannot be deleted.")
    1 <= segment <= length(app.simulations) ||
        error("Invalid segment index.")
    length(app.simulations) == length(app.segment_runtimes) ||
        error("Segment runtime count does not match the simulation partition.")

    deleteat!(app.simulations, segment)
    deleteat!(app.segment_runtimes, segment)
    rebase_partition_coordinates!(app.simulations)
    app.sim = first(app.simulations)

    return nothing
end
