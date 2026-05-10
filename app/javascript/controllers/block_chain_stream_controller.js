import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["block"]

  connect() {
    this.animate()
  }

  animate() {
    this.blockTargets.forEach((block, index) => {
      block.style.opacity = "0"
      block.style.transform = "translateX(24px) scale(0.96)"

      window.setTimeout(() => {
        block.style.opacity = "1"
        block.style.transform = "translateX(0) scale(1)"
      }, index * 90)
    })
  }
}
