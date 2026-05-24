import { Controller } from "@hotwired/stimulus"
import { Chart, registerables } from "chart.js"

Chart.register(...registerables)

export default class extends Controller {
  static values = { points: Array }

  connect() {
    const pts = this.pointsValue || []
    if (pts.length === 0) return

    const labels = pts.map(p => p.x)
    const data = pts.map(p => Number(p.y))

    const ctx = this.element.getContext("2d")

    this.chart = new Chart(ctx, {
      type: "line",
      data: {
        labels,
        datasets: [{
          label: "BTC (USD)",
          data
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false
      }
    })
  }

  disconnect() {
    if (this.chart) this.chart.destroy()
  }
}
