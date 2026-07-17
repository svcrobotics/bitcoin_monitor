import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    autoDismiss: {
      type: Boolean,
      default: false
    },
    delay: {
      type: Number,
      default: 6000
    }
  }

  connect() {
    if (!this.autoDismissValue) return

    this.dismissTimer = window.setTimeout(() => {
      this.dismiss()
    }, this.delayValue)
  }

  disconnect() {
    this.clearDismissTimer()
  }

  dismiss() {
    this.clearDismissTimer()
    this.element.replaceChildren()
  }

  clearDismissTimer() {
    if (!this.dismissTimer) return

    window.clearTimeout(this.dismissTimer)
    this.dismissTimer = null
  }
}
