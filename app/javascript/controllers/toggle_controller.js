import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "icon", "label"]
  static values = {
    show: String,
    hide: String
  }

  toggle() {
    const hidden = this.contentTarget.classList.toggle("hidden")

    if (this.hasIconTarget) {
      this.iconTarget.textContent = hidden ? "▸" : "▾"
    }

    if (this.hasLabelTarget) {
      this.labelTarget.textContent = hidden
        ? this.showValue
        : this.hideValue
    }
  }
}
