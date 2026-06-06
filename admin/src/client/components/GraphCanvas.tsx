import { useEffect, useRef } from "react";
import cytoscape from "cytoscape";
import type { GraphPayload } from "../lib/api";
import { colorForType } from "../lib/format";

interface Props {
  data: GraphPayload | undefined;
  focusId?: string;
  selectedId?: string | null;
  onSelect?: (id: string) => void;
  height?: number;
}

function displayLabel(label: string) {
  const clean = label.replace(/\s+/g, " ").trim();
  if (!clean) return "(untitled)";

  const clipped =
    clean.length > 48 ? `${clean.slice(0, 45).trimEnd()}...` : clean;
  const words = clipped.split(" ");
  const lines: string[] = [];
  let current = "";

  for (const word of words) {
    const next = current ? `${current} ${word}` : word;
    if (next.length <= 20) {
      current = next;
      continue;
    }
    if (current) lines.push(current);
    current = word;
    if (lines.length === 2) break;
  }

  if (current && lines.length < 3) lines.push(current);
  if (words.join(" ").length > lines.join(" ").length) {
    lines[lines.length - 1] = `${lines[lines.length - 1].replace(/\.+$/, "").trimEnd()}...`;
  }

  return lines.join("\n");
}

export function GraphCanvas({
  data,
  focusId,
  selectedId,
  onSelect,
  height = 520,
}: Props) {
  const ref = useRef<HTMLDivElement | null>(null);
  const cyRef = useRef<cytoscape.Core | null>(null);

  useEffect(() => {
    if (!ref.current || !data) return;
    if (cyRef.current) cyRef.current.destroy();

    const cy = cytoscape({
      container: ref.current,
      elements: [
        ...data.nodes.map((n) => ({
          data: {
            id: n.id,
            label: displayLabel(n.label),
            fullLabel: n.label,
            type: n.node_type,
            isFocus: n.id === focusId,
            isSelected: n.id === selectedId,
          },
        })),
        ...data.edges.map((e) => ({
          data: {
            id: e.id,
            source: e.source,
            target: e.target,
            label: e.edge_type,
            category: edgeCategory(e),
            isAdjacentToSelected:
              selectedId === e.source || selectedId === e.target,
          },
        })),
      ],
      style: [
        {
          selector: "node",
          style: {
            label: "data(label)",
            color: "#eef1f8",
            "font-size": 11,
            "font-weight": 500,
            "text-valign": "bottom",
            "text-halign": "center",
            "text-margin-y": 12,
            "text-wrap": "wrap",
            "text-max-width": "130px",
            "text-background-color": "#070a12",
            "text-background-opacity": 0.9,
            "text-background-padding": "4px",
            "text-outline-color": "#070a12",
            "text-outline-width": 2,
            "min-zoomed-font-size": 6,
            "background-color": (ele: cytoscape.NodeSingular) =>
              colorForType(ele.data("type")),
            width: 22,
            height: 22,
            "border-width": 2,
            "border-color": "#0a0b0f",
            "z-index": 10,
          },
        },
        {
          selector: "node[?isFocus]",
          style: {
            width: 36,
            height: 36,
            "border-color": "#d8b948",
            "border-width": 3,
            color: "#ffffff",
            "font-weight": 700,
            "font-size": 14,
            "text-max-width": "190px",
            "z-index": 20,
          },
        },
        {
          selector: "node[?isSelected]",
          style: {
            "border-color": "#5ee0ff",
            "border-width": 4,
            color: "#ffffff",
            "font-weight": 700,
            "z-index": 30,
          },
        },
        {
          selector: "edge",
          style: {
            "curve-style": "bezier",
            "target-arrow-shape": "triangle",
            "line-color": "#303645",
            "target-arrow-color": "#303645",
            width: 1.2,
            opacity: 0.8,
          },
        },
        {
          selector: 'edge[category = "provenance"]',
          style: {
            "line-style": "dashed",
            "line-color": "#5d6376",
            "target-arrow-color": "#5d6376",
            opacity: 0.65,
          },
        },
        {
          selector: 'edge[category = "classification"]',
          style: {
            "line-style": "dashed",
            "line-color": "#d8b948",
            "target-arrow-color": "#d8b948",
            opacity: 0.75,
          },
        },
        {
          selector: 'edge[category = "knowledge"]',
          style: {
            "line-color": "#5ee0ff",
            "target-arrow-color": "#5ee0ff",
            opacity: 0.85,
          },
        },
        {
          selector: "edge[?isAdjacentToSelected]",
          style: {
            width: 2.4,
            opacity: 1,
            "z-index": 15,
          },
        },
        {
          selector: "node:active, node:selected",
          style: {
            "overlay-color": "#d8b948",
            "overlay-opacity": 0.2,
          },
        },
      ],
      layout: {
        name: "cose",
        animate: false,
        fit: true,
        randomize: true,
        idealEdgeLength: () => (data.nodes.length > 20 ? 220 : 170),
        nodeRepulsion: () => 70000,
        edgeElasticity: () => 70,
        gravity: 0.08,
        numIter: 3000,
        padding: 70,
        nodeDimensionsIncludeLabels: true,
        nodeOverlap: 28,
        componentSpacing: 160,
      } as cytoscape.LayoutOptions,
      minZoom: 0.2,
      maxZoom: 2.5,
      wheelSensitivity: 0.2,
    });

    if (cy.elements().length) cy.fit(cy.elements(), 80);

    cy.on("tap", "node", (evt) => {
      const id = evt.target.id();
      onSelect?.(id);
    });
    cyRef.current = cy;
    return () => {
      cy.destroy();
      cyRef.current = null;
    };
  }, [data, focusId, onSelect, selectedId]);

  return (
    <div
      ref={ref}
      className="w-full rounded-xl border border-[color:var(--color-line)] bg-[color:var(--color-surface)] grid-tile"
      style={{ height }}
    />
  );
}

function edgeCategory(edge: GraphPayload["edges"][number]) {
  const reason =
    edge.properties && typeof edge.properties.reason_type === "string"
      ? edge.properties.reason_type
      : null;
  if (reason === "provenance" || edge.edge_type === "contains_item") return "provenance";
  if (reason === "classification_proposal" || edge.edge_type === "reviewed_under") {
    return "classification";
  }
  return "knowledge";
}
