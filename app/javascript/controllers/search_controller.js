import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static targets = ["input", "results"]

  search() {
    const query = this.inputTarget.value.trim()

    if (query.length < 2) {
      this.resultsTarget.innerHTML = ""
      return
    }

    clearTimeout(this.timeout)

    this.timeout = setTimeout(() => {
      fetch(`/search/live?q=${encodeURIComponent(query)}`)
        .then(response => response.text())
        .then(html => {
          this.resultsTarget.innerHTML = html
        })
    }, 200)
  }

  submit(event) {
    event.preventDefault()

    const firstQuestionLink = this.resultsTarget.querySelector("[data-question-url]")

    if (firstQuestionLink) {
      Turbo.visit(firstQuestionLink.dataset.questionUrl, { frame: "dashboard_answer" })
      this.resultsTarget.innerHTML = ""
      return
    }

    const query = this.inputTarget.value.trim()

    if (query.length > 0) {
      fetch(`/search/live?q=${encodeURIComponent(query)}`)
        .then(response => response.text())
        .then(html => {
          this.resultsTarget.innerHTML = html
        })
    }
  }

  loadQuestion(event) {
    event.preventDefault()

    const url = event.currentTarget.dataset.questionUrl
    if (!url) return

    Turbo.visit(url, { frame: "dashboard_answer" })
    this.resultsTarget.innerHTML = ""
  }
}