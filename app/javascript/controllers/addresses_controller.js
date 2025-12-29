import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["section"]

  connect() {
    // On démarre sur receive en mobile si rien n'est défini
    this.activeTab = "receive"
    this.applyTabVisibility()
  }

  switchTab(event) {
    const tab = event.currentTarget.dataset.tab
    if (!tab) return

    this.activeTab = tab
    this.applyTabVisibility()
    this.highlightTabs()
  }

  toggleMore(event) {
    const btn = event.currentTarget
    const kind = btn.dataset.kind
    if (!kind) return

    const items = this.element.querySelectorAll(`.addr-more[data-kind="${kind}"]`)
    const collapsed = (btn.dataset.state || "collapsed") === "collapsed"

    items.forEach(el => el.classList.toggle("hidden", !collapsed))

    btn.dataset.state = collapsed ? "expanded" : "collapsed"
    const total = btn.dataset.total || ""
    btn.textContent = collapsed ? "Réduire" : `Tout afficher (${total})`
  }

  applyTabVisibility() {
    // Sur desktop (lg+), on laisse les 2 colonnes visibles comme ton layout le fait déjà.
    // Sur <lg, on masque/affiche selon l'onglet.
    const isMobile = window.matchMedia("(max-width: 1023px)").matches

    this.sectionTargets.forEach(sec => {
      const key = sec.dataset.section
      if (!isMobile) {
        // on ne touche pas, ton CSS gère (receive visible, change hidden lg:block etc.)
        return
      }
      sec.classList.toggle("hidden", key !== this.activeTab)
    })
  }

  highlightTabs() {
    const tabs = this.element.querySelectorAll(".addr-tab")
    tabs.forEach(t => {
      const active = t.dataset.tab === this.activeTab
      t.classList.toggle("bg-gray-800", active)
      t.classList.toggle("bg-gray-900", !active)
    })
  }
}
