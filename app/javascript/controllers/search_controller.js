import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "results"]

  timeout = null

  search() {
    clearTimeout(this.timeout)

    this.timeout = setTimeout(() => {
      const q = this.inputTarget.value.trim()

      if (q.length === 0) {
        this.resultsTarget.innerHTML = ""
        return
      }

      fetch(`/search/live?q=${encodeURIComponent(q)}`, {
        headers: {
          Accept: "text/vnd.turbo-stream.html, text/html"
        }
      })
        .then(r => r.text())
        .then(html => {
          this.resultsTarget.innerHTML = html
        })
    }, 150)
  }
}
