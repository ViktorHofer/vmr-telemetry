(() => {
  const data = globalThis.vmrBuildTimeData;
  const jobSelect = document.querySelector("#job-select");
  const metricSelect = document.querySelector("#metric-select");
  const chart = document.querySelector("#trend-chart");
  const chartTooltip = document.querySelector("#chart-tooltip");
  const stats = document.querySelector("#job-stats");
  const investigations = document.querySelector("#investigations");
  const signalByKey = new Map(
    data.signals.map((signal) => [`${signal.buildId}|${signal.jobName}`, signal]),
  );

  const jobs = [...new Set(
    data.builds.flatMap((build) => build.jobs.map((job) => job.jobName)),
  )].sort();

  const parameters = new URLSearchParams(globalThis.location.search);
  const requestedJob = parameters.get("job");
  const requestedMetric = parameters.get("metric");
  const defaultJob = requestedJob && jobs.includes(requestedJob)
    ? requestedJob
    : jobs.includes("Windows_x64")
      ? "Windows_x64"
      : jobs[0];
  if (["durationMinutes", "buildMinutes"].includes(requestedMetric)) {
    metricSelect.value = requestedMetric;
  }

  document.querySelector("#generated").textContent =
    `Generated ${new Date(data.generatedAt).toLocaleString()} from pipeline definition ${data.pipeline.definitionId}.`;
  document.querySelector("#investigation-count").textContent =
    `${data.investigations.length} explained signals`;

  const failedIncluded = data.builds.filter((build) => build.result === "failed").length;
  const uniqueJobs = jobs.length;
  const dateRange = `${formatDate(data.builds[0].finishTime)} - ${formatDate(data.builds.at(-1).finishTime)}`;
  document.querySelector("#summary").innerHTML = [
    summaryCard(data.builds.length, "retained builds"),
    summaryCard(uniqueJobs, "job series"),
    summaryCard(data.signals.length, "variance signals"),
    summaryCard(failedIncluded, "near-green failed builds"),
  ].join("");

  for (const job of jobs) {
    const option = document.createElement("option");
    option.value = job;
    option.textContent = job;
    option.selected = job === defaultJob;
    jobSelect.append(option);
  }

  function getSeries(jobName, metric) {
    return data.builds
      .map((build) => {
        const job = build.jobs.find((candidate) => candidate.jobName === jobName);
        if (!job || !["succeeded", "succeededWithIssues"].includes(job.result)) {
          return null;
        }
        const value = job[metric];
        if (value == null) {
          return null;
        }
        return {
          buildId: build.buildId,
          buildNumber: build.buildNumber,
          finishTime: build.finishTime,
          value,
          signal: signalByKey.get(`${build.buildId}|${jobName}`),
        };
      })
      .filter(Boolean);
  }

  function renderChart() {
    const jobName = jobSelect.value;
    const metric = metricSelect.value;
    const metricLabel = metric === "buildMinutes" ? "Build task" : "Whole job";
    const series = getSeries(jobName, metric);
    document.querySelector("#chart-title").textContent = `${jobName} - ${metricLabel}`;

    if (series.length === 0) {
      chart.innerHTML = '<text x="550" y="215" text-anchor="middle" class="axis-label">No passing data for this metric.</text>';
      stats.innerHTML = "";
      return;
    }

    const values = series.map((point) => point.value);
    const medianValue = median(values.slice(-28));
    const min = Math.min(...values, medianValue);
    const max = Math.max(...values, medianValue);
    const padding = Math.max(2, (max - min) * 0.14);
    const yMin = Math.max(0, min - padding);
    const yMax = max + padding;
    const plot = { left: 76, right: 1075, top: 24, bottom: 360 };
    const width = plot.right - plot.left;
    const height = plot.bottom - plot.top;
    const x = (index) =>
      plot.left + (series.length === 1 ? width / 2 : index * width / (series.length - 1));
    const y = (value) => plot.bottom - ((value - yMin) / (yMax - yMin)) * height;

    const grid = [];
    for (let index = 0; index <= 5; index += 1) {
      const value = yMin + (yMax - yMin) * index / 5;
      const yPosition = y(value);
      grid.push(
        `<line class="grid-line" x1="${plot.left}" x2="${plot.right}" y1="${yPosition}" y2="${yPosition}"></line>`,
        `<text class="tick-label" x="${plot.left - 12}" y="${yPosition + 4}" text-anchor="end">${value.toFixed(0)}</text>`,
      );
    }

    const xTicks = [];
    const tickCount = Math.min(7, series.length);
    for (let index = 0; index < tickCount; index += 1) {
      const pointIndex = Math.round(index * (series.length - 1) / Math.max(1, tickCount - 1));
      const point = series[pointIndex];
      xTicks.push(
        `<text class="tick-label" x="${x(pointIndex)}" y="392" text-anchor="middle">${formatDate(point.finishTime)}</text>`,
      );
    }

    const linePath = series
      .map((point, index) => `${index === 0 ? "M" : "L"} ${x(index).toFixed(2)} ${y(point.value).toFixed(2)}`)
      .join(" ");
    const points = series.map((point, index) => {
      const classes = ["point"];
      if (point.signal) classes.push("signal");
      if (index === series.length - 1) classes.push("latest");
      const signalText = point.signal
        ? `; signal +${point.signal.impactMinutes.toFixed(1)} min`
        : "";
      return `<circle class="${classes.join(" ")}" cx="${x(index)}" cy="${y(point.value)}" r="${point.signal ? 6 : 4}"
        data-build-id="${point.buildId}"
        data-build-number="${escapeHtml(point.buildNumber)}"
        data-finish-time="${escapeHtml(point.finishTime)}"
        data-value="${point.value.toFixed(3)}"
        data-metric="${escapeHtml(metricLabel)}">
        <title>${point.buildNumber}: ${point.value.toFixed(1)} min${signalText}</title>
      </circle>`;
    }).join("");

    chart.innerHTML = [
      ...grid,
      `<line class="median-line" x1="${plot.left}" x2="${plot.right}" y1="${y(medianValue)}" y2="${y(medianValue)}"></line>`,
      `<text class="tick-label" x="${plot.right}" y="${y(medianValue) - 8}" text-anchor="end">28-run median ${medianValue.toFixed(1)} min</text>`,
      `<path class="trend-line" d="${linePath}"></path>`,
      points,
      ...xTicks,
      `<text class="axis-label" transform="translate(20 210) rotate(-90)" text-anchor="middle">Minutes</text>`,
      `<text class="axis-label" x="575" y="424" text-anchor="middle">${dateRange}</text>`,
    ].join("");

    const latest = series.at(-1);
    const delta = latest.value - medianValue;
    const signalCount = series.filter((point) => point.signal).length;
    stats.innerHTML = [
      stat("Latest", `${latest.value.toFixed(1)} min`),
      stat("Latest passing sample", formatDate(latest.finishTime)),
      stat("Dataset through", formatDate(data.builds.at(-1).finishTime)),
      stat("28-run median", `${medianValue.toFixed(1)} min`),
      stat("Latest vs median", `${delta >= 0 ? "+" : ""}${delta.toFixed(1)} min`),
      stat("Signals", signalCount),
      stat("Passing samples", series.length),
    ].join("");
    enablePointTooltips();
  }

  function renderInvestigations() {
    const signalLookup = new Map(
      data.signals.map((signal) => [`${signal.buildId}|${signal.jobName}`, signal]),
    );
    investigations.innerHTML = [...data.investigations]
      .sort((left, right) => right.buildId - left.buildId)
      .map((investigation) => {
        const signal = signalLookup.get(`${investigation.buildId}|${investigation.jobName}`);
        const pathText = investigation.criticalPath
          .map((entry) => `${entry.repository} ${signed(entry.impactMinutes)} min`)
          .join(" -> ");
        return `<article class="investigation">
          <div class="investigation-top">
            <button type="button" data-job="${escapeHtml(investigation.jobName)}">
              ${escapeHtml(investigation.jobName)}
              <span class="muted"> / build ${investigation.buildId}</span>
            </button>
            <span class="impact">${signal ? signed(signal.impactMinutes) : ""} min</span>
          </div>
          <p>${escapeHtml(investigation.summary)}</p>
          <p class="cause">${escapeHtml(investigation.causeSummary)}</p>
          <div class="path">${escapeHtml(pathText)}</div>
        </article>`;
      })
      .join("");

    investigations.querySelectorAll("button[data-job]").forEach((button) => {
      button.addEventListener("click", () => {
        jobSelect.value = button.dataset.job;
        renderChart();
        document.querySelector(".chart-panel").scrollIntoView({ behavior: "smooth" });
      });
    });
  }

  function enablePointTooltips() {
    chart.querySelectorAll(".point").forEach((point) => {
      point.addEventListener("pointerenter", showPointTooltip);
      point.addEventListener("pointermove", movePointTooltip);
      point.addEventListener("pointerleave", hidePointTooltip);
    });
  }

  function showPointTooltip(event) {
    const point = event.currentTarget;
    chartTooltip.innerHTML = [
      `<strong>${escapeHtml(point.dataset.buildNumber)} - ${escapeHtml(point.dataset.metric)}</strong>`,
      `<span>${Number(point.dataset.value).toFixed(3)} minutes</span>`,
      `<span>${formatFullDate(point.dataset.finishTime)} / build ${escapeHtml(point.dataset.buildId)}</span>`,
    ].join("");
    chartTooltip.hidden = false;
    movePointTooltip(event);
  }

  function movePointTooltip(event) {
    chartTooltip.style.left = `${event.clientX}px`;
    chartTooltip.style.top = `${event.clientY}px`;
  }

  function hidePointTooltip() {
    chartTooltip.hidden = true;
  }

  function summaryCard(value, label) {
    return `<div class="summary-card"><strong>${value}</strong><span>${label}</span></div>`;
  }

  function stat(label, value) {
    return `<span class="stat">${label}: <strong>${value}</strong></span>`;
  }

  function median(values) {
    const sorted = [...values].sort((left, right) => left - right);
    const middle = Math.floor(sorted.length / 2);
    return sorted.length % 2 === 1
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
  }

  function signed(value) {
    return `${value >= 0 ? "+" : ""}${value.toFixed(3)}`;
  }

  function formatDate(value) {
    return new Date(value).toLocaleDateString(undefined, {
      month: "short",
      day: "numeric",
    });
  }

  function formatFullDate(value) {
    return new Date(value).toLocaleString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });
  }

  function escapeHtml(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  }

  jobSelect.addEventListener("change", renderChart);
  metricSelect.addEventListener("change", renderChart);
  renderChart();
  renderInvestigations();
})();
