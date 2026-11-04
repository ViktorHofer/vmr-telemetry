# VMR build-time dashboard

[VMR build-time dashboard](https://viktorhofer.github.io/vmr-telemetry/)

Static telemetry visualization for scheduled `dotnet/dotnet` VMR builds. The dashboard reads the accumulated dataset from `data.js` and shows job and Build-task duration trends, variance signals, retained investigations, URL-selectable views, and per-point hover details.

The data comes from the public Azure DevOps [`dotnet-unified-build` pipeline (definition 278)](https://dev.azure.com/dnceng-public/public/_build?definitionId=278&_a=summary) for `refs/heads/main`.

Open `index.html` from a local static web server. The default view is the `Windows_x64` job with the `Build task` metric; use `?job=<job-name>&metric=durationMinutes` or `?job=<job-name>&metric=buildMinutes` to select another view.

## Updating the data

`data.js` is the canonical accumulated dataset. For every update:

1. Start from the latest repository worktree so the existing `data.js` is present.
2. Run `.\collect.ps1` incrementally, without `-RefreshAll`.
3. Confirm the prior retained build history and investigations remain in `data.js`.
4. Review the dashboard, then commit and push the data update to this repository.

Do not regenerate, truncate, or replace the existing dataset before collecting new builds.
