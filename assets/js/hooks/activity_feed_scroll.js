export const ActivityFeedScroll = {
  mounted() {
    this.autoScroll = true
    this.scrollToBottom()

    this.el.addEventListener("scroll", () => {
      const { scrollTop, scrollHeight, clientHeight } = this.el
      this.autoScroll = scrollHeight - scrollTop - clientHeight < 50
    })
  },

  updated() {
    if (this.autoScroll) {
      this.scrollToBottom()
    }
  },

  scrollToBottom() {
    requestAnimationFrame(() => {
      this.el.scrollTop = this.el.scrollHeight
    })
  }
}
