import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "pulse",
    "status",
    "lag",
    "outputs",
    "spent",
    "drain",
    "resolve",
    "flushers",
    "time"
  ]

  static values = {
    url: String,
    interval: { type: Number, default: 30000 }
  }

  connect() {
    this.refresh()
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  async refresh() {
    try {
      const response = await fetch(this.urlValue, {
        headers: {
          "Accept": "application/json"
        }
      })

      if (!response.ok) throw new Error("Heartbeat unavailable")

      const data = await response.json()

      this.lagTarget.textContent = data.layer1_lag ?? "?"
      this.outputsTarget.textContent = data.outputs_buffer ?? "?"
      this.spentTarget.textContent = data.spent_buffer ?? "?"
      this.drainTarget.textContent = data.layer1_drain ?? "?"
      this.resolveTarget.textContent = data.spent_resolve ?? "?"
      this.timeTarget.textContent = data.generated_at ?? "--:--:--"
      this.flushersTarget.textContent = data.flushers ?? "?"

      this.updateStatus(data.status)
    } catch (error) {
      this.updateStatus("offline")
    }
  }

  updateStatus(status) {
    this.statusTarget.textContent = status

    this.pulseTarget.classList.remove(
      "bg-emerald-400",
      "bg-amber-400",
      "bg-rose-400",
      "bg-slate-500"
    )

    if (status === "healthy") {
      this.pulseTarget.classList.add("bg-emerald-400")
    } else if (status === "warning") {
      this.pulseTarget.classList.add("bg-amber-400")
    } else if (status === "critical") {
      this.pulseTarget.classList.add("bg-rose-400")
    } else {
      this.pulseTarget.classList.add("bg-slate-500")
    }
  }
}