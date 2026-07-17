import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    interval: Number,
    url: String
  }

  connect() {
    this.interval = this.hasIntervalValue ? this.intervalValue : 10000
    this.url = this.hasUrlValue ? this.urlValue : this.element.getAttribute("src")

    this.timer = setInterval(() => {
      this.reload()
    }, this.interval)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  reload() {
    if (document.hidden) return
    if (!this.url) return

    const url = new URL(this.url, window.location.origin)
    url.searchParams.set("_live", Date.now().toString())

    this.element.src = url.toString()
  }
}
