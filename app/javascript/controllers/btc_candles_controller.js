// app/javascript/controllers/btc_candles_controller.js
import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="btc-candles"
export default class extends Controller {
  static values = {
    candles: Array
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
    const { createChart, CandlestickSeries } = window.LightweightCharts

    this.chart = createChart(this.element, {
      width: this.element.clientWidth || 600,
      height: 360,
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
        timeVisible: true,
        secondsVisible: false
      }
    })

    this.candleSeries = this.chart.addSeries(CandlestickSeries, {
      upColor: "#22c55e",
      downColor: "#ef4444",
      borderVisible: false,
      wickUpColor: "#22c55e",
      wickDownColor: "#ef4444"
    })

    this.candleSeries.setData(this.normalizedCandles())
    this.chart.timeScale().fitContent()
  }

  normalizedCandles() {
    return (this.candlesValue || [])
      .filter(c => c && c.time != null && c.open != null && c.high != null && c.low != null && c.close != null)
      .map(c => ({
        time: this.timeToLocal(Number(c.time)),
        open: Number(c.open),
        high: Number(c.high),
        low: Number(c.low),
        close: Number(c.close)
      }))
  }

  // Recommandé par la doc Lightweight Charts pour afficher dans le fuseau local
  timeToLocal(originalTime) {
    const d = new Date(originalTime * 1000)

    return Date.UTC(
      d.getFullYear(),
      d.getMonth(),
      d.getDate(),
      d.getHours(),
      d.getMinutes(),
      d.getSeconds(),
      d.getMilliseconds()
    ) / 1000
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