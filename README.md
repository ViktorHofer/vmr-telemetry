<div align="center">

# VMR build-time dashboard

**Build-duration trends and variance investigations for scheduled `dotnet/dotnet` VMR builds.**

[![Open the live dashboard](https://img.shields.io/badge/Open_live_dashboard-0969DA?style=for-the-badge&logo=githubpages&logoColor=white)](https://viktorhofer.github.io/vmr-telemetry/)

[![Data refresh](https://img.shields.io/badge/data_refresh-daily-2EA44F?style=flat-square)](https://viktorhofer.github.io/vmr-telemetry/data.js)
[![Pipeline source](https://img.shields.io/badge/source-Azure_DevOps-0078D4?style=flat-square&logo=azuredevops&logoColor=white)](https://dev.azure.com/dnceng-public/public/_build?definitionId=278&_a=summary)

</div>

## Live dashboard

Explore the [live VMR build-time dashboard](https://viktorhofer.github.io/vmr-telemetry/). The default view selects the `Windows_x64` job and the `Build task` metric.

To open a specific view, pass a job and metric in the query string:

- Whole-job duration: `?job=<job-name>&metric=durationMinutes`
- Build-task duration: `?job=<job-name>&metric=buildMinutes`

For local use, serve this repository with a static web server and open `index.html`.

## What it shows

- Job and Build-task duration trends
- Variance signals against the rolling baseline
- Retained investigations for explained regressions
- Per-point build details on hover
- URL-selectable jobs and metrics for shareable views

## Data source

The dashboard reads the canonical accumulated dataset from [`data.js`](data.js). Its data comes from scheduled `refs/heads/main` builds in the public Azure DevOps [`dotnet-unified-build` pipeline (definition 278)](https://dev.azure.com/dnceng-public/public/_build?definitionId=278&_a=summary).

## Updating the data

1. Start from the latest repository worktree so the existing `data.js` is present.
2. Run `.\collect.ps1` incrementally, without `-RefreshAll`.
3. Confirm that prior retained build history and investigations remain in `data.js`.
4. Review the dashboard, then commit and push the data update to this repository.

Do not regenerate, truncate, or replace the existing dataset before collecting new builds.
