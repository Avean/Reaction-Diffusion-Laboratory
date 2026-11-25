# src/HeadDetection.jl

# ============================================================
# Head detection for stationary one-dimensional profiles
# ============================================================

# These two constants intentionally live in their own small module file.  They
# are the only scientific tuning knobs for the first version of series runs.
const HEAD_MINIMUM_PROMINENCE_FRACTION = 0.05
const HEAD_MINIMUM_ABSOLUTE_PROMINENCE = 0.1
const HEAD_MINIMUM_DISTANCE_FRACTION = 0.02


struct DetectedHead
    position::Float64
    value::Float64
    prominence::Float64
end


function _head_neighbor_index(index::Int, offset::Int, N::Int, boundary_condition::Symbol)
    candidate = index + offset

    if boundary_condition == :periodic
        return mod1(candidate, N)
    elseif 1 <= candidate <= N
        return candidate
    end

    return nothing
end


function _head_prominence(
    values::AbstractVector{<:Real},
    start_index::Int,
    end_index::Int,
    boundary_condition::Symbol,
)
    N = length(values)
    peak = Float64(values[start_index])
    left_minimum = peak
    right_minimum = peak

    # A side is open when its search ends without a higher value: at the
    # boundary of a non-periodic domain, or after a full turn of a periodic one.
    left_open = true
    right_open = true

    # Search each side until a higher peak is reached.  On a non-periodic
    # domain the search stops at the boundary.
    index = start_index
    for _ in 1:(N - 1)
        next_index = _head_neighbor_index(index, -1, N, boundary_condition)
        next_index === nothing && break
        index = next_index
        value = Float64(values[index])
        left_minimum = min(left_minimum, value)
        if value > peak
            left_open = false
            break
        end
        boundary_condition != :periodic && index == 1 && break
    end

    index = end_index
    for _ in 1:(N - 1)
        next_index = _head_neighbor_index(index, 1, N, boundary_condition)
        next_index === nothing && break
        index = next_index
        value = Float64(values[index])
        right_minimum = min(right_minimum, value)
        if value > peak
            right_open = false
            break
        end
        boundary_condition != :periodic && index == N && break
    end

    # On a Neumann boundary the profile continues as its mirror image, so an
    # open side runs, reflected, back over the head and on into the other side:
    # its basin minimum is the lower of the two, and only a side that meets a
    # higher value limits the prominence. This covers a peak on the boundary
    # itself (half of a mirrored head) and a head whose maximum lies a little
    # inside the panel with a shallow dip at the boundary, such as a plateau
    # head of the receptor model. With both sides open the peak is the highest
    # point and its prominence is the whole drop below it. (On a periodic
    # domain both sides are open only for the highest peak, and each has
    # then seen every value.)
    left_open && (left_minimum = min(left_minimum, right_minimum))
    right_open && (right_minimum = min(right_minimum, left_minimum))

    return peak - max(left_minimum, right_minimum)
end


function _head_distance(
    left::Float64,
    right::Float64,
    x::AbstractVector{<:Real},
    boundary_condition::Symbol,
)
    distance = abs(left - right)

    if boundary_condition == :periodic && length(x) >= 2
        period = (last(x) - first(x)) + (x[2] - x[1])
        distance = min(distance, max(0.0, period - distance))
    end

    return distance
end


function detect_heads(
    values::AbstractVector{<:Real},
    x::AbstractVector{<:Real};
    boundary_condition::Symbol,
    prominence_fraction::Float64 = HEAD_MINIMUM_PROMINENCE_FRACTION,
    minimum_absolute_prominence::Float64 = HEAD_MINIMUM_ABSOLUTE_PROMINENCE,
    minimum_distance_fraction::Float64 = HEAD_MINIMUM_DISTANCE_FRACTION,
)
    N = length(values)
    N == length(x) || error("Head-detection profile and grid have different lengths.")
    N >= 2 || return DetectedHead[]
    validate_boundary_condition(boundary_condition)
    0.0 <= prominence_fraction <= 1.0 ||
        error("Head prominence fraction must lie between 0 and 1.")
    minimum_absolute_prominence >= 0.0 ||
        error("Head minimum absolute prominence must be non-negative.")
    minimum_distance_fraction >= 0.0 ||
        error("Head minimum-distance fraction must be non-negative.")

    finite_values = Float64.(values)
    all(isfinite, finite_values) || return DetectedHead[]
    profile_range = maximum(finite_values) - minimum(finite_values)
    profile_range > 0.0 || return DetectedHead[]
    minimum_prominence = max(prominence_fraction * profile_range, minimum_absolute_prominence)
    candidates = DetectedHead[]

    index = 1
    while index <= N
        plateau_start = index
        plateau_value = finite_values[index]

        while index < N && finite_values[index + 1] == plateau_value
            index += 1
        end

        plateau_end = index
        left_index = _head_neighbor_index(plateau_start, -1, N, boundary_condition)
        right_index = _head_neighbor_index(plateau_end, 1, N, boundary_condition)
        left_value = left_index === nothing ? -Inf : finite_values[left_index]
        right_value = right_index === nothing ? -Inf : finite_values[right_index]

        if plateau_value > left_value && plateau_value > right_value
            prominence = _head_prominence(
                finite_values,
                plateau_start,
                plateau_end,
                boundary_condition,
            )

            if prominence >= minimum_prominence
                position = mean(Float64.(x[plateau_start:plateau_end]))
                push!(candidates, DetectedHead(position, plateau_value, prominence))
            end
        end

        index += 1
    end

    # Keep the most pronounced peak when two candidates are closer than the
    # resolution that is meaningful for the current panel.
    panel_length = max(Float64(last(x) - first(x)), 0.0)
    minimum_distance = minimum_distance_fraction * panel_length
    sort!(candidates; by = head -> (-head.prominence, -head.value, head.position))
    retained = DetectedHead[]

    for candidate in candidates
        all(
            _head_distance(candidate.position, kept.position, x, boundary_condition) >=
            minimum_distance
            for kept in retained
        ) || continue
        push!(retained, candidate)
    end

    sort!(retained; by = head -> head.position)
    return retained
end
