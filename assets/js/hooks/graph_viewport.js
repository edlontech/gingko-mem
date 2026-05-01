import cytoscape from "cytoscape"

const DEFAULT_TYPE_STYLES = {
  episodic: {label: "episodic", fill: "#ffe3ea", border: "#c2416c"},
  intent: {label: "intent", fill: "#e6f7e6", border: "#3a8e44"},
  procedural: {label: "procedural", fill: "#efe9ff", border: "#7059b6"},
  semantic: {label: "semantic", fill: "#daf0ff", border: "#3d83c8"},
  source: {label: "source", fill: "#f2f4f8", border: "#829ab1"},
  subgoal: {label: "subgoal", fill: "#fff1c7", border: "#c18a00"},
  tag: {label: "tag", fill: "#ffe6d3", border: "#ca6a22"}
}

const BASE_LAYOUT = {
  animate: true,
  animationDuration: 350,
  fit: true,
  padding: 28
}

const TOOLTIP_OFFSET = 24
const TOOLTIP_HIDE_DELAY_MS = 140

const isDarkMode = () => {
  const theme = document.documentElement.getAttribute("data-theme")
  if (theme === "dark") return true
  if (theme === "light") return false
  return window.matchMedia("(prefers-color-scheme: dark)").matches
}

const labelColor = () => isDarkMode() ? "#e2e8f0" : "#1f2933"
const selectedBorderColor = () => isDarkMode() ? "#e2e8f0" : "#0f172a"

const forceLayout = () => ({
  ...BASE_LAYOUT,
  name: "cose",
  idealEdgeLength: 120,
  nodeOverlap: 12,
  edgeElasticity: 120
})

const selectorForType = (type) => `node[type = "${type}"]`

const baseStyles = () => [
  {
    selector: "node",
    style: {
      "background-color": "#f5f7fa",
      "border-color": "#51606d",
      "border-width": 2,
      "label": "data(displayLabel)",
      "color": labelColor(),
      "font-size": 11,
      "font-weight": 600,
      "text-wrap": "none",
      "text-valign": "bottom",
      "text-margin-y": 18,
      "width": 36,
      "height": 36,
      "transition-property": "border-width, border-color, background-color",
      "transition-duration": "160ms"
    }
  },
  {
    selector: "edge",
    style: {
      "line-color": "#9aa5b1",
      "opacity": 0.8,
      "width": 2,
      "curve-style": "bezier",
      "line-style": "solid"
    }
  },
  {
    selector: 'edge[linkType = "membership"]',
    style: {
      "line-color": "#7a9ec4",
      "width": 2,
      "line-style": "solid"
    }
  },
  {
    selector: 'edge[linkType = "provenance"]',
    style: {
      "line-color": "#8b7bb5",
      "width": 2,
      "line-style": "dashed",
      "line-dash-pattern": [6, 3]
    }
  },
  {
    selector: 'edge[linkType = "hierarchical"]',
    style: {
      "line-color": "#5a8a5e",
      "width": 3,
      "line-style": "solid"
    }
  },
  {
    selector: 'edge[linkType = "sibling"]',
    style: {
      "line-color": "#b0a080",
      "width": 2,
      "line-style": "dotted",
      "line-dash-pattern": [2, 4]
    }
  },
  {
    selector: "node.is-selected",
    style: {
      "border-width": 4,
      "border-color": selectedBorderColor()
    }
  },
  {
    selector: "node.is-hovered",
    style: {
      "border-width": 4,
      "overlay-opacity": 0.08,
      "overlay-color": "#1f2933"
    }
  },
  {
    selector: ".is-filtered-out",
    style: {
      "display": "none"
    }
  },
  {
    selector: "node.is-dimmed",
    style: {
      "opacity": 0.25,
      "transition-property": "opacity",
      "transition-duration": "200ms"
    }
  },
  {
    selector: "edge.is-dimmed",
    style: {
      "opacity": 0.1,
      "transition-property": "opacity",
      "transition-duration": "200ms"
    }
  }
]

const NODE_SIZE_OVERRIDES = {
  episodic: 48,
  tag: 26
}

const typeStyles = (styles) => {
  return Object.entries(styles || {}).map(([type, style]) => {
    const size = NODE_SIZE_OVERRIDES[type]
    return {
      selector: selectorForType(type),
      style: {
        "background-color": style.fill,
        "border-color": style.border,
        ...(size && {"width": size, "height": size})
      }
    }
  })
}

const stylesForGraph = (graph) => [...baseStyles(), ...typeStyles(graph.type_styles)]

const toElements = (graph) => {
  const nodes = (graph.nodes || []).map((node) => ({
    data: {
      id: node.id,
      label: node.label,
      displayLabel: node.display_label || node.label,
      tooltipLabel: node.tooltip_label || node.label,
      tooltipSections: node.tooltip_sections || [],
      type: String(node.type),
      degree: node.degree || 0,
      sortKey: node.sort_key || node.id
    },
    classes: (node.classes || []).join(" ")
  }))

  const edges = (graph.edges || []).map((edge) => ({
    data: {
      id: edge.id,
      source: edge.source,
      target: edge.target,
      linkType: edge.type || "sibling"
    }
  }))

  return [...nodes, ...edges]
}

const readGraphPayload = (el) => {
  try {
    const payload = JSON.parse(el.dataset.graph || "{}")
    return {
      selection: payload.selection || {},
      type_styles: payload.type_styles || DEFAULT_TYPE_STYLES,
      nodes: payload.nodes || [],
      edges: payload.edges || []
    }
  } catch (_error) {
    return {
      selection: {},
      type_styles: DEFAULT_TYPE_STYLES,
      nodes: [],
      edges: []
    }
  }
}

export const GraphViewport = {
  mounted() {
    this.graphRoot = this.el.closest('[data-role="graph-viewport"]')
    this.tooltipEl = this.ensureTooltip()
    this.tooltipContentEl = this.tooltipEl?.querySelector('[data-role="graph-tooltip-content"]') || null
    this.hideTooltipTimer = null
    this.isTooltipHovered = false
    this.graph = readGraphPayload(this.el)
    this.typeVisibility = this.buildTypeVisibility(this.graph)
    this.visibleTypes = this.visibleTypesForGraph(this.graph)
    this.cy = cytoscape({
      container: this.el,
      elements: toElements(this.graph),
      style: stylesForGraph(this.graph),
      minZoom: 0.3,
      maxZoom: 2.6,
      wheelSensitivity: 0.18
    })

    this.cy.on("tap", "node", (event) => {
      this.pushEvent("select_graph_node", {id: event.target.id()})
    })

    this.cy.on("mouseover", "node", (event) => {
      this.clearHideTooltipTimer()
      const node = event.target
      node.addClass("is-hovered")
      this.highlightNeighborhood(node)
      this.showTooltip(node)
    })

    this.cy.on("mouseout", "node", (event) => {
      event.target.removeClass("is-hovered")
      this.clearHighlight()
      this.scheduleHideTooltip()
    })

    this.cy.on("pan zoom resize", () => {
      this.positionTooltip()
    })

    this.bindFilterControls()
    this.applyLayout(true)
    this.applyTypeFilter()
    this.syncFilterControls()

    this.handleEvent("update_graph", (payload) => {
      this.graph = {
        selection: payload.selection || {},
        type_styles: payload.type_styles || DEFAULT_TYPE_STYLES,
        nodes: payload.nodes || [],
        edges: payload.edges || []
      }
      this.typeVisibility = this.buildTypeVisibility(this.graph, this.typeVisibility)
      this.visibleTypes = this.visibleTypesForGraph(this.graph)
      this.cy.json({elements: toElements(this.graph)})
      this.cy.style(stylesForGraph(this.graph))
      this.hideTooltip()
      this.bindFilterControls()
      this.applyLayout(false)
      this.applyTypeFilter()
      this.syncFilterControls()
    })

    this.handleEvent("select_graph_node_highlight", ({id}) => {
      this.cy.nodes(".is-selected").removeClass("is-selected")
      if (id) {
        this.cy.getElementById(id).addClass("is-selected")
      }
    })
  },

  updated() {
    const nextGraph = readGraphPayload(this.el)
    this.graph = nextGraph
    this.typeVisibility = this.buildTypeVisibility(nextGraph, this.typeVisibility)
    this.visibleTypes = this.visibleTypesForGraph(nextGraph)
    this.cy.json({elements: toElements(nextGraph)})
    this.cy.style(stylesForGraph(nextGraph))
    this.hideTooltip()
    this.bindFilterControls()
    this.applyLayout(false)
    this.applyTypeFilter()
    this.syncFilterControls()
  },

  applyLayout(isInitial) {
    const layout = this.cy.layout({
      ...forceLayout(),
      animate: isInitial ? false : true
    })

    layout.run()
  },

  availableTypes(graph) {
    return Array.from(
      new Set((graph.nodes || []).map((node) => String(node.type)).filter(Boolean))
    ).sort()
  },

  buildTypeVisibility(graph, existingVisibility = new Map()) {
    const nextVisibility = new Map(existingVisibility)

    this.availableTypes(graph).forEach((type) => {
      if (!nextVisibility.has(type)) {
        nextVisibility.set(type, true)
      }
    })

    return nextVisibility
  },

  visibleTypesForGraph(graph) {
    return new Set(
      this.availableTypes(graph).filter((type) => this.typeVisibility.get(type) !== false)
    )
  },

  visibleTypeCount() {
    return this.availableTypes(this.graph).filter((type) => this.typeVisibility.get(type) !== false).length
  },

  bindFilterControls() {
    this.graphRoot = this.el.closest('[data-role="graph-viewport"]')

    if (!this.graphRoot) {
      return
    }

    this.graphRoot.querySelectorAll('[data-role="graph-type-toggle"]').forEach((button) => {
      if (button.dataset.graphBound === "true") {
        return
      }

      button.dataset.graphBound = "true"
      button.addEventListener("click", (event) => {
        event.preventDefault()
        this.toggleType(button.dataset.type)
      })
    })

    const resetButton = this.graphRoot.querySelector('[data-role="graph-filter-reset"]')

    if (resetButton && resetButton.dataset.graphBound !== "true") {
      resetButton.dataset.graphBound = "true"
      resetButton.addEventListener("click", (event) => {
        event.preventDefault()
        this.showAllTypes()
      })
    }
  },

  syncFilterControls() {
    if (!this.graphRoot) {
      return
    }

    this.graphRoot.querySelectorAll('[data-role="graph-type-toggle"]').forEach((button) => {
      const active = this.typeVisibility.get(button.dataset.type) !== false

      button.dataset.active = String(active)
      button.setAttribute("aria-pressed", String(active))
      button.classList.toggle("btn-soft", active)
      button.classList.toggle("btn-ghost", !active)
      button.classList.toggle("opacity-50", !active)
    })

    const resetButton = this.graphRoot.querySelector('[data-role="graph-filter-reset"]')

    if (resetButton) {
      resetButton.disabled = this.visibleTypeCount() === this.availableTypes(this.graph).length
    }
  },

  toggleType(type) {
    if (!type) {
      return
    }

    if (this.typeVisibility.get(type) !== false) {
      if (this.visibleTypeCount() === 1) {
        return
      }

      this.typeVisibility.set(type, false)
    } else {
      this.typeVisibility.set(type, true)
    }

    this.visibleTypes = this.visibleTypesForGraph(this.graph)
    this.applyTypeFilter()
    this.syncFilterControls()
  },

  showAllTypes() {
    this.typeVisibility = new Map(
      Array.from(this.typeVisibility.entries(), ([type]) => [type, true])
    )
    this.visibleTypes = this.visibleTypesForGraph(this.graph)
    this.applyTypeFilter()
    this.syncFilterControls()
  },

  applyTypeFilter() {
    this.cy.batch(() => {
      this.cy.nodes().forEach((node) => {
        const visible = this.visibleTypes.has(String(node.data("type")))
        node.toggleClass("is-filtered-out", !visible)
      })

      this.cy.edges().forEach((edge) => {
        const visible =
          !edge.source().hasClass("is-filtered-out") && !edge.target().hasClass("is-filtered-out")

        edge.toggleClass("is-filtered-out", !visible)
      })
    })

    if (this.activeTooltipNode?.hasClass("is-filtered-out")) {
      this.hideTooltip()
    }

    const visibleNodes = this.cy.nodes().filter((node) => !node.hasClass("is-filtered-out"))

    if (visibleNodes.length > 0) {
      this.cy.fit(visibleNodes, BASE_LAYOUT.padding)
    }
  },

  ensureTooltip() {
    if (!this.graphRoot) {
      return null
    }

    let tooltip = this.graphRoot.querySelector('[data-role="graph-tooltip"]')

    if (tooltip) {
      this.bindTooltipHover(tooltip)
      return tooltip
    }

    tooltip = document.createElement("div")
    tooltip.dataset.role = "graph-tooltip"
    tooltip.className = "pointer-events-auto absolute z-10 hidden max-w-[18rem] rounded-xl border border-base-300 bg-base-100 shadow-lg"

    const content = document.createElement("div")
    content.dataset.role = "graph-tooltip-content"
    content.className = "px-3 py-2 text-xs leading-5 text-base-content"

    tooltip.appendChild(content)
    this.graphRoot.appendChild(tooltip)
    this.bindTooltipHover(tooltip)
    return tooltip
  },

  bindTooltipHover(tooltip) {
    if (!tooltip || tooltip.dataset.graphBound === "true") {
      return
    }

    tooltip.dataset.graphBound = "true"
    tooltip.addEventListener("mouseenter", () => {
      this.isTooltipHovered = true
      this.clearHideTooltipTimer()
    })
    tooltip.addEventListener("mouseleave", () => {
      this.isTooltipHovered = false
      this.scheduleHideTooltip()
    })
  },

  showTooltip(node) {
    if (!this.tooltipEl) {
      return
    }

    this.clearHideTooltipTimer()
    this.activeTooltipNode = node
    this.renderTooltip(node)
    this.tooltipEl.classList.remove("hidden")
    this.positionTooltip()
  },

  scheduleHideTooltip() {
    this.clearHideTooltipTimer()

    this.hideTooltipTimer = window.setTimeout(() => {
      if (!this.isTooltipHovered) {
        this.hideTooltip()
      }
    }, TOOLTIP_HIDE_DELAY_MS)
  },

  clearHideTooltipTimer() {
    if (this.hideTooltipTimer) {
      window.clearTimeout(this.hideTooltipTimer)
      this.hideTooltipTimer = null
    }
  },

  hideTooltip() {
    this.clearHideTooltipTimer()
    this.activeTooltipNode = null
    this.isTooltipHovered = false

    if (this.tooltipEl) {
      this.tooltipEl.classList.add("hidden")
    }
  },

  positionTooltip() {
    if (!this.tooltipEl || !this.activeTooltipNode) {
      return
    }

    const position = this.activeTooltipNode.renderedPosition()
    const tooltipWidth = this.tooltipEl.offsetWidth || 0
    const maxLeft = Math.max(this.el.clientWidth - tooltipWidth - 8, 8)
    const left = Math.min(Math.max(position.x + TOOLTIP_OFFSET, 8), maxLeft)
    const top = Math.max(position.y - TOOLTIP_OFFSET, 8)

    this.tooltipEl.style.left = `${left}px`
    this.tooltipEl.style.top = `${top}px`
  },

  renderTooltip(node) {
    const sections = node.data("tooltipSections") || []
    const tooltipLabel = node.data("tooltipLabel") || node.data("label") || ""
    const container = this.tooltipContentEl || this.tooltipEl

    if (!container) {
      return
    }

    if (Array.isArray(sections) && sections.length > 0) {
      container.replaceChildren(
        ...sections.map((section, index) => {
          const wrapper = document.createElement("div")

          if (index < sections.length - 1) {
            wrapper.className = "mb-2"
          }

          const label = document.createElement("p")
          label.className = "text-[11px] font-semibold uppercase tracking-wide text-base-content/60"
          label.textContent = section.label || ""

          const value = document.createElement("p")
          value.className = "mt-1 whitespace-pre-line text-xs leading-5 text-base-content"
          value.textContent = section.value || ""

          wrapper.append(label, value)
          return wrapper
        })
      )

      return
    }

    container.replaceChildren(document.createTextNode(tooltipLabel))
  },

  highlightNeighborhood(node) {
    const neighborhood = node.closedNeighborhood()
    this.cy.batch(() => {
      this.cy.elements().addClass("is-dimmed")
      neighborhood.removeClass("is-dimmed")
    })
  },

  clearHighlight() {
    this.cy.batch(() => {
      this.cy.elements().removeClass("is-dimmed")
    })
  },

  destroyed() {
    this.hideTooltip()

    if (this.cy) {
      this.cy.destroy()
      this.cy = null
    }
  }
}
