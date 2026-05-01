import cytoscape from "cytoscape"
import fcose from "cytoscape-fcose"
import Graph from "graphology"
import louvain from "graphology-communities-louvain"

if (!cytoscape.__fcoseRegistered) {
  cytoscape.use(fcose)
  cytoscape.__fcoseRegistered = true
}

const CLUSTER_PARENT_PREFIX = "__cluster_parent_"
const MIN_CLUSTER_SIZE_FOR_PARENT = 2

const SMALL_GRAPH_NODES = 200
const MEDIUM_GRAPH_NODES = 800

const EDGE_WEIGHTS = {
  hierarchical: 3.0,
  membership: 2.0,
  provenance: 1.0,
  sibling: 0.5
}

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

const LOD_FAR_THRESHOLD = 0.55
const LOD_MID_THRESHOLD = 0.9
const INITIAL_ZOOM_FLOOR = 1.0

const isDarkMode = () => {
  const theme = document.documentElement.getAttribute("data-theme")
  if (theme === "dark") return true
  if (theme === "light") return false
  return window.matchMedia("(prefers-color-scheme: dark)").matches
}

const labelColor = () => isDarkMode() ? "#e2e8f0" : "#1f2933"
const selectedBorderColor = () => isDarkMode() ? "#e2e8f0" : "#0f172a"

const sizeTier = (nodeCount) => {
  if (nodeCount <= SMALL_GRAPH_NODES) return "small"
  if (nodeCount <= MEDIUM_GRAPH_NODES) return "medium"
  return "large"
}

const computeClusters = (graph) => {
  const nodes = graph.nodes || []
  const edges = graph.edges || []

  if (nodes.length === 0) {
    return []
  }

  const g = new Graph({type: "undirected", multi: false, allowSelfLoops: false})

  nodes.forEach((node) => g.addNode(node.id))

  edges.forEach((edge) => {
    if (!g.hasNode(edge.source) || !g.hasNode(edge.target) || edge.source === edge.target) {
      return
    }

    if (g.hasEdge(edge.source, edge.target)) {
      return
    }

    const weight = EDGE_WEIGHTS[edge.type] ?? 1.0
    g.addEdge(edge.source, edge.target, {weight})
  })

  const communities = louvain(g, {getEdgeWeight: "weight"})
  const buckets = new Map()

  Object.entries(communities).forEach(([nodeId, communityId]) => {
    const key = String(communityId)
    if (!buckets.has(key)) {
      buckets.set(key, [])
    }
    buckets.get(key).push(nodeId)
  })

  nodes.forEach((node) => {
    if (!Object.prototype.hasOwnProperty.call(communities, node.id)) {
      const key = `solo-${node.id}`
      buckets.set(key, [node.id])
    }
  })

  return Array.from(buckets.values())
}

const clusterLayout = (tier, parentLookup, overrides = {}) => {
  const sameCluster = (edge) => {
    const a = parentLookup.get(edge.source().id())
    const b = parentLookup.get(edge.target().id())
    return Boolean(a) && a === b
  }

  return {
    ...BASE_LAYOUT,
    name: "fcose",
    quality: "default",
    animate: false,
    randomize: true,
    uniformNodeDimensions: true,
    packComponents: true,
    numIter: tier === "small" ? 2500 : 1500,
    nodeRepulsion: 6000,
    idealEdgeLength: (edge) => (sameCluster(edge) ? 50 : 250),
    edgeElasticity: 0.45,
    nestingFactor: 0.4,
    gravity: 0.25,
    gravityRange: 3.8,
    gravityCompound: 1.0,
    gravityRangeCompound: 1.5,
    tile: true,
    tilingPaddingVertical: 10,
    tilingPaddingHorizontal: 10,
    ...overrides
  }
}

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
      "min-zoomed-font-size": 8,
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
    selector: "node.lod-mid",
    style: {
      "border-width": 1,
      "label": ""
    }
  },
  {
    selector: "node.lod-far",
    style: {
      "border-width": 0,
      "label": "",
      "width": 18,
      "height": 18
    }
  },
  {
    selector: "edge.lod-mid",
    style: {
      "curve-style": "straight",
      "line-style": "solid",
      "width": 1
    }
  },
  {
    selector: "edge.lod-far",
    style: {
      "curve-style": "haystack",
      "haystack-radius": 0,
      "line-style": "solid",
      "width": 1,
      "opacity": 0.45
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
  },
  {
    selector: "node.cluster-parent",
    style: {
      "background-opacity": 0,
      "background-color": "transparent",
      "border-width": 0,
      "border-opacity": 0,
      "label": "",
      "events": "no",
      "padding": 14,
      "shape": "round-rectangle",
      "z-compound-depth": "bottom",
      "width": "label",
      "height": "label",
      "min-zoomed-font-size": 9999
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

const buildParentLookup = (clusters) => {
  const lookup = new Map()

  clusters.forEach((memberIds, index) => {
    if (memberIds.length < MIN_CLUSTER_SIZE_FOR_PARENT) {
      return
    }

    const parentId = `${CLUSTER_PARENT_PREFIX}${index}`
    memberIds.forEach((id) => lookup.set(id, parentId))
  })

  return lookup
}

const toElements = (graph, parentLookup = new Map()) => {
  const parentIds = new Set(parentLookup.values())
  const parentNodes = Array.from(parentIds).map((parentId) => ({
    data: {id: parentId, isCluster: true},
    selectable: false,
    grabbable: false,
    classes: "cluster-parent"
  }))

  const nodes = (graph.nodes || []).map((node) => {
    const parent = parentLookup.get(node.id)
    return {
      data: {
        id: node.id,
        label: node.label,
        displayLabel: node.display_label || node.label,
        tooltipLabel: node.tooltip_label || node.label,
        tooltipSections: node.tooltip_sections || [],
        type: String(node.type),
        degree: node.degree || 0,
        sortKey: node.sort_key || node.id,
        ...(parent ? {parent} : {})
      },
      classes: (node.classes || []).join(" ")
    }
  })

  const edges = (graph.edges || []).map((edge) => ({
    data: {
      id: edge.id,
      source: edge.source,
      target: edge.target,
      linkType: edge.type || "sibling"
    }
  }))

  return [...parentNodes, ...nodes, ...edges]
}

const readGraphPayload = (el) => {
  try {
    const payload = JSON.parse(el.dataset.graph || "{}")
    return {
      mode: payload.mode || null,
      title: payload.title || null,
      selection: payload.selection || {},
      type_styles: payload.type_styles || DEFAULT_TYPE_STYLES,
      nodes: payload.nodes || [],
      edges: payload.edges || []
    }
  } catch (_error) {
    return {
      mode: null,
      title: null,
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
    this.rebuildClusters()
    this.cy = cytoscape({
      container: this.el,
      elements: toElements(this.graph, this.parentLookup),
      style: stylesForGraph(this.graph),
      minZoom: 0.3,
      maxZoom: 2.6,
      wheelSensitivity: 0.18,
      textureOnViewport: true,
      hideEdgesOnViewport: true,
      hideLabelsOnViewport: true,
      motionBlur: false,
      pixelRatio: "auto",
      renderer: {
        name: "canvas",
        webgl: true,
        webglDebug: false
      }
    })

    this.lodLevel = null
    this.lodFrame = null

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

    this.cy.on("zoom", () => this.scheduleLodUpdate())

    this.bindFilterControls()
    this.applyLayout(true)
    this.applyTypeFilter()
    this.syncFilterControls()
    this.applyLod()

    this.handleEvent("update_graph", (payload) => {
      this.graph = {
        mode: payload.mode || null,
        title: payload.title || null,
        selection: payload.selection || {},
        type_styles: payload.type_styles || DEFAULT_TYPE_STYLES,
        nodes: payload.nodes || [],
        edges: payload.edges || []
      }
      this.typeVisibility = this.buildTypeVisibility(this.graph, this.typeVisibility)
      this.visibleTypes = this.visibleTypesForGraph(this.graph)
      this.rebuildClusters()
      this.cy.json({elements: toElements(this.graph, this.parentLookup)})
      this.cy.style(stylesForGraph(this.graph))
      this.hideTooltip()
      this.bindFilterControls()
      this.applyLayout(false)
      this.applyTypeFilter()
      this.syncFilterControls()
      this.lodLevel = null
      this.applyLod()
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
    this.rebuildClusters()
    this.cy.json({elements: toElements(nextGraph, this.parentLookup)})
    this.cy.style(stylesForGraph(nextGraph))
    this.hideTooltip()
    this.bindFilterControls()
    this.applyLayout(false)
    this.applyTypeFilter()
    this.syncFilterControls()
    this.lodLevel = null
    this.applyLod()
  },

  rebuildClusters() {
    const clusters = computeClusters(this.graph)
    this.clusters = clusters
    this.parentLookup = buildParentLookup(clusters)
  },

  applyLayout(isInitial) {
    const nodeCount = (this.graph.nodes || []).length

    if (nodeCount === 0) {
      return
    }

    const tier = sizeTier(nodeCount)

    const layout = this.cy.layout(
      clusterLayout(tier, this.parentLookup || new Map(), {
        animate: isInitial ? false : "end",
        animationDuration: 300
      })
    )
    layout.one("layoutstop", () => {
      this.enforceInitialZoom()
      this.applyLod()
    })
    layout.run()
  },

  enforceInitialZoom() {
    if (!this.cy) {
      return
    }

    if (this.cy.zoom() < INITIAL_ZOOM_FLOOR) {
      const visibleNodes = this.cy
        .nodes()
        .filter((node) => !node.data("isCluster") && !node.hasClass("is-filtered-out"))
      const target = visibleNodes.length > 0 ? visibleNodes : this.cy.nodes()
      this.cy.zoom({
        level: INITIAL_ZOOM_FLOOR,
        renderedPosition: {x: this.cy.width() / 2, y: this.cy.height() / 2}
      })

      if (target.length > 0) {
        this.cy.center(target)
      }
    }

    this.applyLod()
  },

  scheduleLodUpdate() {
    if (this.lodFrame) {
      return
    }

    this.lodFrame = window.requestAnimationFrame(() => {
      this.lodFrame = null
      this.applyLod()
    })
  },

  lodLevelForZoom(zoom) {
    if (zoom < LOD_FAR_THRESHOLD) return "far"
    if (zoom < LOD_MID_THRESHOLD) return "mid"
    return "near"
  },

  applyLod() {
    if (!this.cy) {
      return
    }

    const next = this.lodLevelForZoom(this.cy.zoom())

    if (next === this.lodLevel) {
      return
    }

    this.lodLevel = next

    this.cy.batch(() => {
      const targets = this.cy.elements().filter((el) => !el.data("isCluster"))
      targets.removeClass("lod-mid lod-far")

      if (next === "mid") {
        targets.addClass("lod-mid")
      } else if (next === "far") {
        targets.addClass("lod-far")
      }
    })
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
        if (node.data("isCluster")) {
          return
        }

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

    const visibleNodes = this.cy
      .nodes()
      .filter((node) => !node.data("isCluster") && !node.hasClass("is-filtered-out"))

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

    if (this.lodFrame) {
      window.cancelAnimationFrame(this.lodFrame)
      this.lodFrame = null
    }

    if (this.cy) {
      this.cy.destroy()
      this.cy = null
    }
  }
}
