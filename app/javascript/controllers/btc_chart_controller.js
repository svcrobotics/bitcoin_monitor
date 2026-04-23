import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="btc-chart"
export default class extends Controller {
  static values = {
    series: Array
  }

  connect() {
    if (!window.LightweightCharts) {
      console.error("LightweightCharts is not loaded yet")
      return
    }

    this.buildChart()
    this.installResizeObserver()
  }

  disconnect() {
    this.teardownResizeObserver()

    if (this.chart) {
      this.chart.remove()
      this.chart = null
    }
  }

  buildChart() {
    const { createChart, LineSeries } = window.LightweightCharts

    this.chart = createChart(this.element, {
      width: this.element.clientWidth || 600,
      height: 320,
      layout: {
        background: { color: "transparent" },
        textColor: "#9ca3af"
      },
      grid: {
        vertLines: { color: "rgba(75, 85, 99, 0.15)" },
        horzLines: { color: "rgba(75, 85, 99, 0.15)" }
      },
      rightPriceScale: {
        borderColor: "rgba(75, 85, 99, 0.35)"
      },
      timeScale: {
        borderColor: "rgba(75, 85, 99, 0.35)",
        timeVisible: false,
        secondsVisible: false
      }
    })

    this.lineSeries = this.chart.addSeries(LineSeries, {
      color: "#f97316",
      lineWidth: 2,
      priceLineVisible: true,
      lastValueVisible: true
    })

    this.lineSeries.setData(this.normalizedSeries())
    this.chart.timeScale().fitContent()
  }

  normalizedSeries() {
    return (this.seriesValue || [])
      .filter(point => point && point.x && point.y != null)
      .map(point => ({
        time: point.x,
        value: Number(point.y)
      }))
  }

  installResizeObserver() {
    this.resizeObserver = new ResizeObserver(() => {
      if (!this.chart) return

      this.chart.applyOptions({
        width: this.element.clientWidth || 600
      })
    })

    this.resizeObserver.observe(this.element)
  }

  teardownResizeObserver() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
      this.resizeObserver = null
    }
  }
}