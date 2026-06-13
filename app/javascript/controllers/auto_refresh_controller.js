import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    url: String,
    interval: { type: Number, default: 5000 }
  }

  connect() {
    console.log("AUTO REFRESH CONNECTED", this.element)

    this.timer = setInterval(() => {
      console.log("AUTO REFRESH RELOAD", this.urlValue)

      this.element.setAttribute("src", this.urlValue)
      this.element.reload()
    }, this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }
}