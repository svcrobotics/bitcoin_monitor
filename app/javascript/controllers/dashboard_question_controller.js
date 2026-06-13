import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "form", "examples", "answer"]

  ask(event) {
    const question = event.currentTarget.dataset.question

    this.inputTarget.value = question
    this.hideExamples()
    this.formTarget.requestSubmit()
  }

  hideExamples() {
    if (this.hasExamplesTarget) {
      this.examplesTarget.classList.add("hidden")
    }
  }

  reset() {
    this.inputTarget.value = ""

    if (this.hasExamplesTarget) {
      this.examplesTarget.classList.remove("hidden")
    }

    if (this.hasAnswerTarget) {
      this.answerTarget.replaceChildren()
    }

    this.inputTarget.focus()
  }

  submitOnEnter(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.hideExamples()
      this.formTarget.requestSubmit()
    }
  }
}