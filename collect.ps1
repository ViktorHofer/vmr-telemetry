[CmdletBinding()]
param(
    [switch]$RefreshAll
)

$ErrorActionPreference = 'Stop'

$dataPath = Join-Path $PSScriptRoot 'data.js'
$apiRoot = 'https://dev.azure.com/dnceng-public/public/_apis'
$definitionId = 278
$branch = 'refs/heads/main'

function Get-Median([double[]]$Values) {
    if ($Values.Count -eq 0) {
        return 0
    }

    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) {
        return [double]$sorted[$middle]
    }

    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

function Get-DurationMinutes($Record) {
    if (-not $Record.startTime -or -not $Record.finishTime) {
        return $null
    }

    return [Math]::Round(
        (([DateTimeOffset]$Record.finishTime) - ([DateTimeOffset]$Record.startTime)).TotalMinutes,
        3)
}

function ConvertTo-IsoTime($Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    return ([DateTimeOffset]$Value).ToUniversalTime().ToString('o')
}

function Read-ExistingData {
    if (-not (Test-Path $dataPath)) {
        return @{
            builds = @()
            signals = @()
            investigations = @()
        }
    }

    $content = Get-Content -Raw $dataPath
    $match = [regex]::Match(
        $content,
        '^\s*globalThis\.vmrBuildTimeData\s*=\s*(?<json>\{.*\})\s*;\s*$',
        [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        throw "Unable to parse $dataPath. Expected a globalThis.vmrBuildTimeData JSON assignment."
    }

    $data = $match.Groups['json'].Value | ConvertFrom-Json -AsHashtable -DateKind String
    if (-not $data.ContainsKey('builds')) {
        $data.builds = @()
    }
    if (-not $data.ContainsKey('signals')) {
        $data.signals = @()
    }
    if (-not $data.ContainsKey('investigations')) {
        $data.investigations = @()
    }

    foreach ($build in @($data.builds)) {
        $build.queueTime = ConvertTo-IsoTime $build.queueTime
        $build.startTime = ConvertTo-IsoTime $build.startTime
        $build.finishTime = ConvertTo-IsoTime $build.finishTime
        foreach ($job in @($build.jobs)) {
            $job.startTime = ConvertTo-IsoTime $job.startTime
            $job.finishTime = ConvertTo-IsoTime $job.finishTime
            foreach ($task in @($job.tasks)) {
                $task.startTime = ConvertTo-IsoTime $task.startTime
                $task.finishTime = ConvertTo-IsoTime $task.finishTime
            }
        }
    }

    return $data
}

function Get-JobAncestorId($Record, [hashtable]$RecordsById) {
    $current = $Record
    while ($current -and $current.parentId) {
        $parent = $RecordsById[[string]$current.parentId]
        if (-not $parent) {
            return $null
        }
        if ($parent.type -eq 'Job') {
            return [string]$parent.id
        }
        $current = $parent
    }

    return $null
}

function Get-BuildRecord($Build) {
    $timelineUrl = "$apiRoot/build/builds/$($Build.id)/timeline?api-version=7.1"
    $timeline = Invoke-RestMethod -Uri $timelineUrl
    $recordsById = @{}
    foreach ($record in $timeline.records) {
        $recordsById[[string]$record.id] = $record
    }

    $jobRecords = @($timeline.records | Where-Object {
        $_.type -eq 'Job' -and $_.startTime -and $_.finishTime
    })
    $passedJobs = @($jobRecords | Where-Object {
        $_.result -in @('succeeded', 'succeededWithIssues')
    }).Count
    $passRate = if ($jobRecords.Count -eq 0) { 0 } else { $passedJobs / $jobRecords.Count }
    $eligible = $Build.result -eq 'succeeded' -or (
        $Build.result -eq 'failed' -and $passRate -ge 0.95)
    if (-not $eligible) {
        Write-Host "Skipping build $($Build.id): result=$($Build.result), job pass rate=$([Math]::Round($passRate * 100, 1))%"
        return $null
    }

    $tasksByJob = @{}
    foreach ($task in @($timeline.records | Where-Object {
        $_.type -eq 'Task' -and $_.startTime -and $_.finishTime
    })) {
        $jobId = Get-JobAncestorId $task $recordsById
        if (-not $jobId) {
            continue
        }
        if (-not $tasksByJob.ContainsKey($jobId)) {
            $tasksByJob[$jobId] = [Collections.Generic.List[object]]::new()
        }

        $tasksByJob[$jobId].Add([ordered]@{
            name = [string]$task.name
            result = [string]$task.result
            startTime = ([DateTimeOffset]$task.startTime).ToUniversalTime().ToString('o')
            finishTime = ([DateTimeOffset]$task.finishTime).ToUniversalTime().ToString('o')
            durationMinutes = Get-DurationMinutes $task
        })
    }

    $jobs = foreach ($job in $jobRecords) {
        $jobId = [string]$job.id
        $tasks = if ($tasksByJob.ContainsKey($jobId)) {
            @($tasksByJob[$jobId] | Sort-Object { $_.startTime }, { $_.name })
        } else {
            @()
        }
        $buildTasks = @($tasks | Where-Object { $_.name -eq 'Build' })
        $buildMinutes = if ($buildTasks.Count -eq 0) {
            $null
        } else {
            [Math]::Round(
                ($buildTasks | ForEach-Object { [double]$_.durationMinutes } | Measure-Object -Sum).Sum,
                3)
        }

        [ordered]@{
            jobName = [string]$job.name
            result = [string]$job.result
            startTime = ([DateTimeOffset]$job.startTime).ToUniversalTime().ToString('o')
            finishTime = ([DateTimeOffset]$job.finishTime).ToUniversalTime().ToString('o')
            durationMinutes = Get-DurationMinutes $job
            buildMinutes = $buildMinutes
            tasks = $tasks
        }
    }

    return [ordered]@{
        buildId = [int]$Build.id
        buildNumber = [string]$Build.buildNumber
        result = [string]$Build.result
        sourceVersion = [string]$Build.sourceVersion
        queueTime = ([DateTimeOffset]$Build.queueTime).ToUniversalTime().ToString('o')
        startTime = ([DateTimeOffset]$Build.startTime).ToUniversalTime().ToString('o')
        finishTime = ([DateTimeOffset]$Build.finishTime).ToUniversalTime().ToString('o')
        passedJobs = $passedJobs
        totalJobs = $jobRecords.Count
        jobPassRate = [Math]::Round($passRate, 4)
        jobs = @($jobs | Sort-Object { $_.jobName })
    }
}

function Get-VarianceSignals($Builds) {
    $historyByJob = @{}
    $signals = [Collections.Generic.List[object]]::new()

    foreach ($build in @($Builds | Sort-Object { $_.finishTime })) {
        foreach ($job in @($build.jobs | Sort-Object { $_.jobName })) {
            if ($job.result -notin @('succeeded', 'succeededWithIssues')) {
                continue
            }

            $jobName = [string]$job.jobName
            if (-not $historyByJob.ContainsKey($jobName)) {
                $historyByJob[$jobName] = [Collections.Generic.List[object]]::new()
            }

            $history = $historyByJob[$jobName]
            $baseline = @($history | Select-Object -Last 28)
            if ($baseline.Count -ge 12) {
                $durations = [double[]]@($baseline | ForEach-Object { [double]$_.durationMinutes })
                $median = Get-Median $durations
                $absoluteDeviations = [double[]]@($durations | ForEach-Object { [Math]::Abs($_ - $median) })
                $robustSigma = 1.4826 * (Get-Median $absoluteDeviations)
                $isIosSimulator = $jobName -match 'iOSSimulator'
                $absoluteFloor = if ($isIosSimulator) { 12.0 } else { 5.0 }
                $relativeFloor = $median * $(if ($isIosSimulator) { 0.20 } else { 0.10 })
                $sigmaMultiplier = if ($isIosSimulator) { 3.5 } else { 3.0 }
                $threshold = [Math]::Max(
                    $absoluteFloor,
                    [Math]::Max($relativeFloor, $sigmaMultiplier * $robustSigma))
                $impact = [double]$job.durationMinutes - $median

                if ($impact -gt $threshold) {
                    $baselineBuildDurations = [double[]]@(
                        $baseline |
                            Where-Object { $null -ne $_.buildMinutes } |
                            ForEach-Object { [double]$_.buildMinutes })
                    $baselineBuildMedian = if ($baselineBuildDurations.Count -eq 0) {
                        $null
                    } else {
                        Get-Median $baselineBuildDurations
                    }
                    $buildImpact = if ($null -eq $job.buildMinutes -or $null -eq $baselineBuildMedian) {
                        $null
                    } else {
                        [double]$job.buildMinutes - $baselineBuildMedian
                    }

                    $signals.Add([ordered]@{
                        buildId = [int]$build.buildId
                        buildNumber = [string]$build.buildNumber
                        finishTime = [string]$build.finishTime
                        jobName = $jobName
                        selectedMinutes = [Math]::Round([double]$job.durationMinutes, 3)
                        baselineMinutes = [Math]::Round($median, 3)
                        impactMinutes = [Math]::Round($impact, 3)
                        thresholdMinutes = [Math]::Round($threshold, 3)
                        robustSigmaMinutes = [Math]::Round($robustSigma, 3)
                        baselineRunCount = $baseline.Count
                        buildSelectedMinutes = if ($null -eq $job.buildMinutes) { $null } else { [Math]::Round([double]$job.buildMinutes, 3) }
                        buildBaselineMinutes = if ($null -eq $baselineBuildMedian) { $null } else { [Math]::Round($baselineBuildMedian, 3) }
                        buildImpactMinutes = if ($null -eq $buildImpact) { $null } else { [Math]::Round($buildImpact, 3) }
                        iosSimulatorNoiseAdjusted = $isIosSimulator
                    })
                }
            }

            $history.Add($job)
        }
    }

    return @($signals | Sort-Object { $_.finishTime }, { $_.jobName })
}

$data = Read-ExistingData
$existingById = @{}
foreach ($build in @($data.builds)) {
    $existingById[[string]$build.buildId] = $build
}

$buildsUrl = "$apiRoot/build/builds?definitions=$definitionId&branchName=$([Uri]::EscapeDataString($branch))&statusFilter=completed&reasonFilter=schedule&queryOrder=finishTimeDescending&%24top=500&api-version=7.1"
if (-not $RefreshAll -and $data.builds.Count -gt 0) {
    $latestFinishTime = @($data.builds | Sort-Object { $_.finishTime } -Descending | Select-Object -First 1).finishTime
    $buildsUrl += "&minTime=$([Uri]::EscapeDataString($latestFinishTime))"
}

$response = Invoke-RestMethod -Uri $buildsUrl
$queriedBuilds = @($response.value | Where-Object {
    $_.reason -eq 'schedule' -and
    $_.sourceBranch -eq $branch -and
    $_.status -eq 'completed'
})

foreach ($build in $queriedBuilds) {
    Write-Host "Collecting build $($build.id) ($($build.buildNumber))"
    $record = Get-BuildRecord $build
    if ($null -ne $record) {
        $existingById[[string]$record.buildId] = $record
    } elseif ($existingById.ContainsKey([string]$build.id)) {
        $existingById.Remove([string]$build.id)
    }
}

$mergedBuilds = @($existingById.Values | Sort-Object { $_.finishTime })
foreach ($mergedBuild in $mergedBuilds) {
    foreach ($mergedJob in @($mergedBuild.jobs)) {
        $storedBuildTasks = @($mergedJob.tasks | Where-Object { $_.name -eq 'Build' })
        $mergedJob.buildMinutes = if ($storedBuildTasks.Count -eq 0) {
            $null
        } else {
            [Math]::Round(
                ($storedBuildTasks | ForEach-Object { [double]$_.durationMinutes } | Measure-Object -Sum).Sum,
                3)
        }
    }
}
$output = [ordered]@{
    generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    pipeline = [ordered]@{
        organization = 'dnceng-public'
        project = 'public'
        definitionId = $definitionId
        definitionName = 'dotnet-unified-build'
        branch = $branch
        reason = 'schedule'
    }
    builds = $mergedBuilds
    signals = Get-VarianceSignals $mergedBuilds
    investigations = @($data.investigations)
}

$json = $output | ConvertTo-Json -Depth 100
$content = "globalThis.vmrBuildTimeData = $json;`n"
[IO.File]::WriteAllText($dataPath, $content, [Text.UTF8Encoding]::new($false))

Write-Host "Wrote $($mergedBuilds.Count) builds, $($output.signals.Count) signals, and $($output.investigations.Count) investigations to $dataPath"
