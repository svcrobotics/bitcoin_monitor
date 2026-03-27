import { Controller } from "@hotwired/stimulus"

// Usage:
// <div data-controller="dropdown" data-action="click@window->dropdown#closeOnOutside keydown@window->dropdown#closeOnEsc">
//   <button data-action="dropdown#toggle" ...>...</button>
//   <div data-dropdown-target="menu" class="hidden">...</div>
// </div>
export default class extends Controller {
  static targets = ["menu"]

  connect() {
    this.isOpen = false
    this.close()
  }

  toggle(event) {
    event.preventDefault()
    this.isOpen ? this.close() : this.open()
  }

  open() {
    this.isOpen = true
    this.menuTarget.classList.remove("hidden")
  }

  close() {
    this.isOpen = false
    this.menuTarget.classList.add("hidden")
  }

  closeOnOutside(event) {
    if (!this.isOpen) return
    if (this.element.contains(event.target)) return
    this.close()
  }

  closeOnEsc(event) {
    if (!this.isOpen) return
    if (event.key !== "Escape") return
    this.close()
  }
}
