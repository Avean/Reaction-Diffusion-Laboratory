# Repository guide

Use [README.md](README.md) for the desktop app and [API.md](API.md) for
scripting experiments.

## Changes to the simulation

- Preserve the numerics, default tolerances, model files (`Models/`) and
  application behavior unless the task explicitly calls for a change.
- Keep `src/RDLabCore.jl` independent of QML, QMLMakie, GLMakie and CairoMakie.
  The desktop module `src/ReactionDiffusionApp.jl` imports the core names.
  The interface in `src/QMLInterface.jl` accesses them through `RD`.
- Put window code in the application layer. This includes
  `ReactionDiffusionApp.jl`, `AppTypes.jl`, `DomainPartitionApp.jl`,
  `PlotPanel.jl`, `PerturbationPanel.jl`, `UIRuntime.jl`, `QMLInterface.jl` and
  `SaveLoadQML.jl`.

## Verification

After changing the core, run `julia --project --threads=auto test/runtests.jl`.
After changing code used by the desktop app, also run
`julia --project --threads=4 test/gui_vs_api.jl` to compare the real series
window with the API. The desktop test needs a display. On a Linux machine
without one, prefix the command with `xvfb-run -a`.
