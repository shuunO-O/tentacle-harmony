import { GraphNode, GraphRelationship } from './Types';
import { WHEEL_WINDOW } from './GraphWheel';
import { graphPreviewText } from './GraphTextLayout';


export class PlacedNode {
  raw: GraphNode;
  degree: number = 0;
  wheelIndex: number = 0;
  wheelOffset: number = 0;
  constructor(raw: GraphNode) {
    // Keep long event summaries/content outside ArkUI's observed scene and gesture path.
    this.raw = { id: raw.id, label: raw.label, name: graphPreviewText(graphNodeTitle(raw)) };
  }
}

/** One drawn connection retains all original relations, including both directions. */
export class PlacedEdge {
  raw: GraphRelationship;
  relations: GraphRelationship[] = [];
  source: PlacedNode;
  target: PlacedNode;
  offset: number = 0;
  forward: boolean = false;
  backward: boolean = false;
  constructor(raw: GraphRelationship, source: PlacedNode, target: PlacedNode) {
    this.raw = raw; this.source = source; this.target = target;
    this.offset = source === target ? 18 : 0;
    this.add(raw);
  }
  add(raw: GraphRelationship): void {
    this.relations.push(raw);
    if (raw.source === this.source.raw.id) { this.forward = true; } else { this.backward = true; }
  }
  title(): string {
    return this.raw.type + (this.relations.length > 1 ? ' +' + (this.relations.length - 1) : '');
  }
}

/** Only a bounded neighborhood is observed and drawn. Never runs whole-graph analysis. */
@Observed
export class GraphScene {
  nodes: PlacedNode[] = [];
  edges: PlacedEdge[] = [];
  centerId: string = '';
  missingEdges: number = 0;
  neighborTotal: number = 0;
  wheelIndex: number = 0;
  relationshipCount: number = 0;
  totalNodes: number = 0;
  totalRelationships: number = 0;
  private byId: Map<string, PlacedNode> = new Map();
  private adjacent: Map<string, Set<string>> = new Map();

  constructor(nodes: GraphNode[], edges: GraphRelationship[], centerId: string = '') {
    const center = nodes.find((node: GraphNode) => node.id === centerId) ?? nodes.find((node: GraphNode) => node.label === 'Person') ?? nodes[0];
    this.centerId = center?.id ?? '';
    const subset = center === undefined ? [] : [center].concat(nodes.filter((node: GraphNode) => node.id !== center.id).slice(0, WHEEL_WINDOW));
    for (const raw of subset) {
      if (this.byId.has(raw.id)) { continue; }
      const node = new PlacedNode(raw);
      this.byId.set(raw.id, node); this.adjacent.set(raw.id, new Set()); this.nodes.push(node);
    }
    const pairs: Map<string, PlacedEdge> = new Map();
    for (const raw of edges) {
      const a = this.byId.get(raw.source); const b = this.byId.get(raw.target);
      if (a === undefined || b === undefined) { this.missingEdges++; continue; }
      if (a !== b) { this.adjacent.get(raw.source)!.add(raw.target); this.adjacent.get(raw.target)!.add(raw.source); }
      const source = raw.source < raw.target ? a : b; const target = raw.source < raw.target ? b : a;
      const key = JSON.stringify([source.raw.id, target.raw.id]); const pair = pairs.get(key);
      if (pair === undefined) { const edge = new PlacedEdge(raw, source, target); pairs.set(key, edge); this.edges.push(edge); }
      else { pair.add(raw); }
      this.relationshipCount++;
    }
    for (const node of this.nodes) { node.degree = this.adjacent.get(node.raw.id)!.size; }
    const outer = this.nodes.filter((node: PlacedNode) => node.raw.id !== this.centerId);
    this.neighborTotal = outer.length;
  }
  find(id: string): PlacedNode | null { return this.byId.get(id) ?? null; }
  neighbors(id: string): Set<string> { return new Set<string>(this.adjacent.get(id) ?? []); }
}

export function graphNodeTitle(node: GraphNode): string {
  return node.name || node.summary || (node.id.startsWith('Event:') ? node.id.substring(6) : node.id);
}

export function graphNodeMatches(node: GraphNode, query: string): boolean {
  return (node.id + ' ' + (node.name ?? '') + ' ' + (node.type ?? '') + ' ' + (node.summary ?? '') + ' ' + (node.content ?? ''))
    .toLowerCase().includes(query.trim().toLowerCase());
}

export function graphNodeColor(label: string): string {
  const colors: Record<string, string> = { 'Concept': '#7FD6BA', 'Event': '#E9BB72', 'Person': '#B6A9EF', 'Location': '#E5A4BA' };
  return colors[label] ?? '#B9AE9F';
}

export function graphLabelTitle(label: string): string {
  const names: Record<string, string> = { 'Concept': '概念', 'Event': '事件', 'Person': '人物', 'Location': '地点' };
  return names[label] ?? label;
}

