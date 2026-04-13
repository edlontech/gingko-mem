function formatRelative(isoString) {
  if (!isoString) return "n/a"

  const then = new Date(isoString)
  const now = new Date()
  const diffMs = now - then

  if (diffMs < 0) return "just now"

  const seconds = Math.floor(diffMs / 1000)
  if (seconds < 60) return `${seconds}s ago`

  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`

  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`

  const days = Math.floor(hours / 24)
  return `${days}d ago`
}

export const RelativeTime = {
  mounted() {
    this._update()
    this._timer = setInterval(() => this._update(), 30000)
  },

  updated() {
    this._update()
  },

  destroyed() {
    if (this._timer) clearInterval(this._timer)
  },

  _update() {
    const ts = this.el.dataset.timestamp
    this.el.textContent = formatRelative(ts)
  }
}
