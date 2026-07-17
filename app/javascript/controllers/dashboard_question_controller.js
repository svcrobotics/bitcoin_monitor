import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "form", "examples", "answer"]

  connect() {
    if (this.hasInputTarget) {
      this.inputTarget.focus()
    }
  }

  ask(event) {
    const question = event.currentTarget.dataset.question

    if (!question || !this.hasInputTarget) return

    this.inputTarget.value = question
    this.hideExamples()
    this.submitForm()
  }

  // Conservé pour compatibilité avec une ancienne liaison HTML.
  // Le nouvel input utilise toutefois la soumission native avec Entrée.
  submitOnEnter(event) {
    if (
      event.key !== "Enter" ||
      event.shiftKey ||
      event.isComposing
    ) {
      return
    }

    event.preventDefault()

    if (!this.hasInputTarget) return
    if (this.inputTarget.value.trim() === "") return

    this.hideExamples()
    this.submitForm()
  }

  submitForm() {
    if (!this.hasFormTarget) return

    if (typeof this.formTarget.requestSubmit === "function") {
      this.formTarget.requestSubmit()
    } else {
      this.formTarget.submit()
    }
  }

  showNewQuestion(event) {
    if (event?.detail && event.detail.success === false) return

    if (this.hasInputTarget) {
      this.inputTarget.value = ""
      this.inputTarget.focus()
    }

    const stream = document.getElementById("terminal_stream")

    if (stream) {
      stream.lastElementChild?.scrollIntoView({
        behavior: "smooth",
        block: "start"
      })
    }
  }

  hideExamples() {
    if (this.hasExamplesTarget) {
      this.examplesTarget.classList.add("hidden")
    }
  }

  reset() {
    if (this.hasInputTarget) {
      this.inputTarget.value = ""
      this.inputTarget.focus()
    }

    if (this.hasExamplesTarget) {
      this.examplesTarget.classList.remove("hidden")
    }
  }
}
