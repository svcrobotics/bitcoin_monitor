import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  load(event) {
    const url = event.params.url
    const frame = document.getElementById("dashboard_answer")

    if (!frame || !url) return

    frame.src = url
    frame.reload()
  }
}
