import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "pulse",
    "status",
    "lag",
    "cluster",
    "profile",
    "height",
    "time",
    "outputs",
    "spent",
    "drain",
    "flushers",
    "resolve",
    "process",
    "labels",
    "exchange",
    "cadencePanel",
    "cadenceVerdict",
    "cadenceSummary",
    "cadenceMetrics",
    "networkBlocks"
  ]

  static values = {
    url: String,
    interval: Number
  }

  connect() {
    this.interval = this.hasIntervalValue ? this.intervalValue : 30000
    this.refresh()
    this.timer = setInterval(() => this.refresh(), this.interval)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  async refresh() {
    if (!this.hasUrlValue) return

    try {
      const response = await fetch(this.urlValue, {
        headers: { "Accept": "application/json" },
        cache: "no-store"
      })

      if (!response.ok) return

      const data = await response.json()
      this.applyHeartbeat(data)
    } catch (_error) {
      this.applyStatus("unknown")
    }
  }

  applyHeartbeat(data) {
    const layer1Lag = this.numberFrom(
      data.layer1_lag,
      data.layer1?.lag,
      data.lag
    )

    const clusterLag = this.numberFrom(
      data.cluster_lag,
      data.cluster?.lag_vs_layer1,
      data.cluster?.lag
    )

    const actorMissing = this.numberFrom(
      data.actor_profile_missing,
      data.actor_profile?.missing_profiles,
      data.actor_profiles?.missing_profiles
    )

    const actorMissingLabel = this.textFrom(
      data.actor_profile_missing_label,
      data.actor_profile?.missing_label,
      this.compactNumber(actorMissing)
    )

    const height = this.numberFrom(
      data.height,
      data.layer1?.processed_height,
      data.processed_height
    )

    if (this.hasLagTarget) this.lagTarget.textContent = layer1Lag.toString()
    if (this.hasClusterTarget) this.clusterTarget.textContent = clusterLag.toString()
    if (this.hasProfileTarget) this.profileTarget.textContent = actorMissingLabel
    if (this.hasHeightTarget && height > 0) this.heightTarget.textContent = height.toString()

    if (this.hasOutputsTarget) this.outputsTarget.textContent = this.textFrom(data.outputs, data.buffers?.outputs, "-")
    if (this.hasSpentTarget) this.spentTarget.textContent = this.textFrom(data.spent, data.buffers?.spent, "-")
    if (this.hasDrainTarget) this.drainTarget.textContent = this.textFrom(data.drain, "-")
    if (this.hasFlushersTarget) this.flushersTarget.textContent = this.textFrom(data.flushers, "-")
    if (this.hasResolveTarget) this.resolveTarget.textContent = this.textFrom(data.resolve, "-")
    if (this.hasProcessTarget) this.processTarget.textContent = this.textFrom(data.process, "-")
    if (this.hasLabelsTarget) this.labelsTarget.textContent = this.textFrom(data.labels, "-")
    if (this.hasExchangeTarget) this.exchangeTarget.textContent = this.textFrom(data.exchange, "-")

    this.applyNetworkCadence(data.network_cadence)

    if (this.hasTimeTarget) {
      const now = new Date()
      this.timeTarget.textContent = now.toLocaleTimeString("fr-FR", {
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit"
      })
    }

    this.applyStatus(this.statusFrom({ layer1Lag, clusterLag, actorMissing }))
  }

  applyNetworkCadence(cadence) {
    if (!cadence || cadence.available !== true) {
      if (this.hasCadenceVerdictTarget) {
        this.cadenceVerdictTarget.textContent = "Indisponible"
        this.cadenceVerdictTarget.className = this.cadenceVerdictClass("unknown")
      }

      if (this.hasCadenceSummaryTarget) {
        this.cadenceSummaryTarget.textContent = "Horodatages Bitcoin Core indisponibles"
      }

      if (this.hasCadenceMetricsTarget) {
        this.cadenceMetricsTarget.textContent = "Réseau — · L1 —"
      }

      return
    }

    const diagnosis = this.textFrom(cadence.diagnosis, "unknown")

    if (this.hasCadenceVerdictTarget) {
      this.cadenceVerdictTarget.textContent = this.textFrom(
        cadence.diagnosis_label,
        "Cadence réseau"
      )
      this.cadenceVerdictTarget.className = this.cadenceVerdictClass(diagnosis)
    }

    if (this.hasCadenceSummaryTarget) {
      this.cadenceSummaryTarget.textContent = this.textFrom(
        cadence.diagnosis_detail,
        ""
      )
    }

    if (this.hasCadenceMetricsTarget) {
      const network = this.durationLabel(cadence.average_interval_seconds)
      const certification = this.durationLabel(cadence.certification_average_seconds)
      this.cadenceMetricsTarget.textContent = `Réseau ${network} · L1 ${certification}`
    }

    if (this.hasCadencePanelTarget) {
      const detail = this.textFrom(cadence.diagnosis_detail, "Cadence réseau Bitcoin")
      const network = this.durationLabel(cadence.average_interval_seconds)
      const certification = this.durationLabel(cadence.certification_average_seconds)
      this.cadencePanelTarget.title = `${detail} · Réseau ${network}/bloc · Layer1 ${certification}/bloc`
    }

    if (!this.hasNetworkBlocksTarget) return

    const blocks = Array.isArray(cadence.blocks) ? cadence.blocks.slice(0, 5) : []
    this.networkBlocksTarget.replaceChildren(...blocks.map((block, index) => this.blockCadenceChip(block, index)))
  }

  blockCadenceChip(block, index = 0) {
    const chip = document.createElement("span")
    const state = this.textFrom(block?.state, "waiting")
    const height = this.numberFrom(block?.height)
    const interval = this.durationLabel(block?.interval_seconds)
    const age = this.durationLabel(block?.age_seconds)
    const timestampAnomaly = block?.timestamp_anomaly === true

    chip.className = [
      "h-8 w-[66px] shrink-0 items-center gap-1.5 rounded-lg border px-1.5 font-mono",
      index >= 3 ? "hidden 2xl:inline-flex" : "inline-flex",
      this.blockCadenceClass(state)
    ].join(" ")

    const dot = document.createElement("span")
    dot.className = [
      "h-2 w-2 shrink-0 rounded-full",
      this.blockStateDotClass(state)
    ].join(" ")

    const content = document.createElement("span")
    content.className = "min-w-0 leading-none"

    const heightNode = document.createElement("span")
    heightNode.className = "block text-[10px] font-bold tracking-tight"
    heightNode.textContent = height > 0 ? height.toString() : "—"

    const intervalNode = document.createElement("span")
    intervalNode.className = "mt-0.5 block truncate text-[9px] font-semibold opacity-75"
    intervalNode.textContent = timestampAnomaly
      ? "Δ exclu"
      : interval === "—"
        ? "Δ —"
        : `Δ ${interval}`

    content.append(heightNode, intervalNode)
    chip.append(dot, content)

    chip.title = [
      height > 0 ? `Bloc ${height}` : "Bloc inconnu",
      timestampAnomaly ? "horodatage non monotone, intervalle exclu" : `intervalle ${interval}`,
      `il y a ${age}`,
      this.blockStateLabel(state)
    ].join(" · ")

    return chip
  }

  cadenceVerdictClass(diagnosis) {
    const base = "rounded-full border px-2 py-1 text-[10px] font-bold"

    switch (diagnosis) {
      case "synced":
        return `${base} border-emerald-400/25 bg-emerald-400/10 text-emerald-100`
      case "burst":
        return `${base} border-cyan-400/25 bg-cyan-400/10 text-cyan-100`
      case "catching_up":
        return `${base} border-blue-400/25 bg-blue-400/10 text-blue-100`
      case "waiting":
        return `${base} border-amber-400/25 bg-amber-400/10 text-amber-100`
      case "processing_pressure":
        return `${base} border-rose-400/25 bg-rose-400/10 text-rose-100`
      case "watch":
        return `${base} border-orange-400/25 bg-orange-400/10 text-orange-100`
      default:
        return `${base} border-slate-700 bg-slate-900 text-slate-300`
    }
  }

  blockCadenceClass(state) {
    switch (state) {
      case "certified":
        return "border-emerald-400/20 bg-emerald-400/[0.08] text-emerald-100"
      case "processing":
        return "border-cyan-400/30 bg-cyan-400/12 text-cyan-50 ring-1 ring-cyan-400/10"
      default:
        return "border-amber-400/25 bg-amber-400/[0.09] text-amber-50"
    }
  }

  blockStateDotClass(state) {
    switch (state) {
      case "certified":
        return "bg-emerald-400"
      case "processing":
        return "bg-cyan-300 animate-pulse"
      default:
        return "bg-amber-300"
    }
  }

  blockStateLabel(state) {
    switch (state) {
      case "certified":
        return "certifié"
      case "processing":
        return "en traitement"
      default:
        return "en attente"
    }
  }

  durationLabel(value) {
    const seconds = Number(value)
    if (!Number.isFinite(seconds) || seconds < 0) return "—"

    const rounded = Math.round(seconds)
    if (rounded < 60) return `${rounded}s`

    const minutes = Math.floor(rounded / 60)
    const remaining = rounded % 60
    if (remaining === 0) return `${minutes}m`

    return `${minutes}m${remaining.toString().padStart(2, "0")}`
  }

  statusFrom({ layer1Lag, clusterLag, actorMissing }) {
    if (layer1Lag > 6 || clusterLag > 6) return "critical"
    if (layer1Lag > 0 || clusterLag > 0 || actorMissing > 0) return "syncing"
    return "healthy"
  }

  applyStatus(status) {
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = status

      this.statusTarget.className = [
        "hidden rounded-full border px-2 py-0.5 text-[10px] font-semibold uppercase tracking-[0.14em] sm:inline-flex",
        this.statusClass(status)
      ].join(" ")
    }

    if (this.hasPulseTarget) {
      this.pulseTarget.className = [
        "relative inline-flex h-3 w-3 rounded-full",
        this.dotClass(status)
      ].join(" ")
    }
  }

  statusClass(status) {
    switch (status) {
      case "healthy":
        return "border-emerald-400/20 bg-emerald-400/10 text-emerald-200"
      case "syncing":
        return "border-cyan-400/20 bg-cyan-400/10 text-cyan-200"
      case "critical":
        return "border-rose-400/20 bg-rose-400/10 text-rose-200"
      default:
        return "border-slate-700 bg-slate-900/80 text-slate-400"
    }
  }

  dotClass(status) {
    switch (status) {
      case "healthy":
        return "bg-emerald-400 shadow-emerald-400/40"
      case "syncing":
        return "bg-cyan-400 shadow-cyan-400/40"
      case "critical":
        return "bg-rose-400 shadow-rose-400/40"
      default:
        return "bg-slate-500"
    }
  }

  numberFrom(...values) {
    for (const value of values) {
      if (value === null || value === undefined || value === "") continue

      const number = Number(value)
      if (!Number.isNaN(number)) return Math.max(number, 0)
    }

    return 0
  }

  textFrom(...values) {
    for (const value of values) {
      if (value === null || value === undefined || value === "") continue
      return value.toString()
    }

    return "-"
  }

  compactNumber(value) {
    const number = Number(value || 0)

    if (number >= 1000000) {
      return `${(number / 1000000).toFixed(1).replace(".0", "")}M`
    }

    if (number >= 1000) {
      return `${(number / 1000).toFixed(1).replace(".0", "")}k`
    }

    return number.toString()
  }
}
