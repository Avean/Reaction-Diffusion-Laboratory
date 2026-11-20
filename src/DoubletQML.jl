# src/DoubletQML.jl

# ============================================================
# Source tools of the window
# ============================================================
#
# Freeze SD, the half buttons, Cut and Cut and run in the "Source density"
# section of the model drawer (qml/Main.qml). The AppState-level operations
# are in DoubletApp.jl, the headless ones in Doublet.jl. Included by
# QMLInterface.jl.
#
# Freeze SD, Cut and the installation of a Cut and run result rebuild the
# plots, so they run as graphics actions inside the render function, like
# Reset or Split (enqueue_graphics_action!). Cut and run computes the whole
# body on a background task, with the live simulation stopped and the
# controls disabled; refresh_qml_state! shows its progress and, once it is
# done, queues the installation of the cut piece (poll_cut_run!).


function require_source_tools_idle(controller::QMLController)
    controller.series.running[] && error("Stop the Series run first.")
    controller.cut_run.running && error("Wait until Cut and run has finished, or stop it.")
    return nothing
end


function parse_positive_length(text, what::AbstractString)
    value = tryparse(Float64, strip(String(text)))
    value === nothing && error("$what: '$(String(text))' is not a number.")
    isfinite(value) && value > 0.0 || error("$what must be a positive number.")
    return value
end


# The interface after the plots were rebuilt (Freeze SD, Cut, Cut and run).
# In series mode the series setup of the panel stays, with its previews.
function refresh_after_source_tool!(controller::QMLController; reset_selection::Bool)
    reset_selection && (controller.selected_segment = 1)
    update_model_bindings!(controller)
    refresh_current_equation_image!(controller)
    update_partition_bindings!(controller; reset_index = reset_selection)
    # Fractions are unchanged; the axis-unit values shown may not be.
    refresh_series_bindings!(controller)

    if controller.bindings.series_mode[]
        keep_series_setup_of_remaining_panels!(controller)
    else
        # Perturbations of panels that no longer exist are dropped.
        clamp_all_series_perturbations!(controller)
        clear_series_results!(controller)
    end

    return nothing
end


function set_source_frozen!(controller::QMLController, value)
    frozen = Bool(value)

    return guarded_action(controller, "Freeze SD failed") do
        require_source_tools_idle(controller)
        RD.set_variables_frozen_app!(
            controller.app,
            controller.plot_grid,
            frozen;
            title_obs = controller.title_obs,
            steps_per_frame = controller.steps_per_frame,
            worker_sleep_time = controller.worker_sleep_time,
        )
        refresh_after_source_tool!(controller; reset_selection = false)
        controller.bindings.notice[] = frozen ? "SD frozen" : "SD released"
    end
end


function apply_half_operation!(controller::QMLController, name)
    operation = Symbol(String(name))

    return guarded_action(controller, "Half operation failed") do
        require_source_tools_idle(controller)
        operation in RD.HALF_OPERATIONS || error("Unknown half operation '$(String(name))'.")
        RD.apply_half_operation_app!(
            controller.app,
            operation;
            steps_per_frame = controller.steps_per_frame,
            worker_sleep_time = controller.worker_sleep_time,
        )
        clear_series_results!(controller)
    end
end


function cut_center!(controller::QMLController, length_text)
    return guarded_action(controller, "Cut failed") do
        require_source_tools_idle(controller)
        cut_length = parse_positive_length(length_text, "Cut length")
        result = RD.cut_center_app!(
            controller.app,
            controller.plot_grid,
            cut_length;
            title_obs = controller.title_obs,
            steps_per_frame = controller.steps_per_frame,
            worker_sleep_time = controller.worker_sleep_time,
            reltol = controller.reltol,
            abstol = controller.abstol,
        )
        controller.diffusion_scale = result.length^2
        refresh_after_source_tool!(controller; reset_selection = true)
        controller.bindings.notice[] =
            @sprintf("Cut: %d points, length %.6g", result.points, result.length)
    end
end


function start_cut_and_run!(controller::QMLController, body_text, cut_text)
    return guarded_action(controller, "Cut and run failed") do
        require_source_tools_idle(controller)
        controller.graphics_busy[] && error("Wait until the plots have been updated.")

        app = controller.app
        model = app.sim.model
        isempty(model.freezable_variables) &&
            error("Cut and run needs a model with a source density to freeze.")
        isempty(model.spatial_profile_sets) ||
            error("Cut and run works only for models without spatial profiles.")
        app.sim.boundary_condition == :neumann ||
            error("Cut and run works with Neumann boundary conditions: select Neumann first.")

        body_length = parse_positive_length(body_text, "Body length")
        cut_length = parse_positive_length(cut_text, "Cut length")
        cut_length <= body_length || error("The cut length must not exceed the body length.")

        # The current parameters (not the domain length, which Cut and run
        # sets), the series settings for the stationarity check, the grid of
        # the application and the live maximum time step for the piece.
        params = Dict{Symbol, Any}(
            name => app.sim.params[name] for name in RD.public_model_parameter_names(model)
        )
        settings = deepcopy(controller.series.settings)
        settings.head_variable = 1
        tolerance = settings.tolerance
        N = app.initial_N
        cut_dtmax = RD.current_dtmax(app.sim)

        RD.stop_worker!(app; wait = true)

        state = controller.cut_run
        state.cancel[] = false
        lock(state.lock) do
            state.result = nothing
            state.error = nothing
            state.status = @sprintf(
                "Cut and run: whole body of length %.6g (N = %d), running to a steady state",
                body_length,
                N,
            )
        end
        state.model_id = model.id
        state.running = true
        controller.bindings.cut_run_running[] = true
        controller.bindings.cut_run_status[] = state.status

        function report_residual(residual)
            lock(state.lock) do
                state.status = @sprintf(
                    "Cut and run: residual %.2e (tolerance %.0e)",
                    residual,
                    tolerance,
                )
            end
            return nothing
        end

        state.task = Threads.@spawn begin
            try
                result = RD.cut_and_run(
                    model,
                    params;
                    N = N,
                    body_length = body_length,
                    cut_length = cut_length,
                    settings = settings,
                    cut_dtmax = cut_dtmax,
                    cancelled = () -> state.cancel[],
                    on_residual = report_residual,
                )
                lock(state.lock) do
                    state.result = result
                end
            catch error
                lock(state.lock) do
                    state.error = error
                end
                @error "Cut and run failed." exception = (error, catch_backtrace())
            end
        end
    end
end


function stop_cut_and_run!(controller::QMLController)
    state = controller.cut_run
    state.running || return nothing
    state.cancel[] = true

    lock(state.lock) do
        state.status = "Cut and run: stopping"
    end

    return nothing
end


# Called by refresh_qml_state! on the interface thread.
function poll_cut_run!(controller::QMLController)
    state = controller.cut_run
    state.running || return nothing

    status, done = lock(state.lock) do
        state.status, state.task === nothing || istaskdone(state.task)
    end
    set_if_changed!(controller.bindings.cut_run_status, status)
    done || return nothing

    result, failure = lock(state.lock) do
        state.result, state.error
    end
    stopped = state.cancel[] || (result !== nothing && result.cancelled)
    install = failure === nothing && result !== nothing && !stopped

    # The installation rebuilds the plots: queued for the render function.
    # The queue is free here (refresh_qml_state! returns early while it is
    # busy); if it is not, the next refresh tries again.
    install && !enqueue_graphics_action!(
        controller,
        () -> install_cut_and_run_result!(controller, result),
    ) && return nothing

    lock(state.lock) do
        state.result = nothing
        state.error = nothing
    end
    state.running = false
    state.task = nothing
    controller.bindings.cut_run_running[] = false
    set_if_changed!(controller.bindings.cut_run_status, "")

    if failure !== nothing
        controller.bindings.message[] = "Cut and run failed: " * sprint(showerror, failure)
    elseif stopped
        controller.bindings.notice[] = "Cut and run stopped"
    end

    return nothing
end


function install_cut_and_run_result!(controller::QMLController, result)
    outcome = result.outcome
    heads = length(outcome.heads)

    installed = guarded_action(controller, "Cut and run failed") do
        app = controller.app
        app.sim.model.id == controller.cut_run.model_id ||
            error("The model changed while Cut and run was computing; its result was discarded.")
        RD.install_single_panel_app!(
            app,
            controller.plot_grid,
            result.state;
            title_obs = controller.title_obs,
            domain_length_scale = result.length,
            restart = false,
            steps_per_frame = controller.steps_per_frame,
            worker_sleep_time = controller.worker_sleep_time,
        )
        controller.diffusion_scale = result.length^2
        # Reset keeps SD frozen, as after the Freeze SD button.
        app.parameter_overrides[RD.FROZEN_PARAM] = 1.0
        refresh_after_source_tool!(controller; reset_selection = true)
        controller.bindings.notice[] = @sprintf(
            "Cut and run: %s at t = %.3g, %d head%s; cut %d points, length %.6g, SD frozen",
            outcome.converged ? "steady state" : "not stationary",
            outcome.time,
            heads,
            heads == 1 ? "" : "s",
            result.state.N,
            result.length,
        )
    end

    # Shown after guarded_action, which clears the message on success.
    if installed && !outcome.converged
        controller.bindings.message[] = @sprintf(
            "Cut and run: the whole body was not stationary when the run stopped (t = %.3g, %d steps, residual %.2e); the piece was cut anyway.",
            outcome.time,
            outcome.steps,
            outcome.residual,
        )
    elseif installed && heads != 1
        controller.bindings.message[] =
            "Cut and run: the whole body has $heads heads instead of one; the piece was cut anyway."
    end

    return nothing
end
