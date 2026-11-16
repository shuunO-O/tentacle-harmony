import { GraphNode, GraphRelationship, GraphSummary, GraphData } from './Types';
import { GraphScene } from './GraphScene';
import { WheelSlot, wheelPosition, wheelSlots } from './GraphWheel';

/** One shared snapshot, including indexes; rebuilding a page does not rebuild the graph. */
export class GraphSnapshot {
  summary: GraphSummary;
  nodes: GraphNode[];
  relationships: GraphRelationship[];
  updatedAt: number = Date.now();
  private byId: Map<string, GraphNode> = new Map();
  private edges: Map<string, GraphRelationship[]> = new Map();
  private adjacent: Map<string, Set<string>> = new Map();
  private ordered: Map<string, string[]> = new Map();
  private filtered: Map<string, string[]> = new Map();
  private pairs: Map<string, GraphRelationship[]> = new Map();
  private scenes: Map<string, GraphScene> = new Map();
  private missingEdges: number = 0;

  constructor(summary: GraphSummary, graph: GraphData) {
    this.summary = summary;
    this.nodes = graph.nodes;
    this.relationships = graph.relationships;
    for (const node of this.nodes) { this.byId.set(node.id, node); this.adjacent.set(node.id, new Set()); }
    for (const edge of this.relationships) {
      this.addEdge(edge.source, edge);
      if (edge.target !== edge.source) { this.addEdge(edge.target, edge); }
      if (!this.byId.has(edge.source) || !this.byId.has(edge.target)) { this.missingEdges++; continue; }
      if (edge.source !== edge.target) { this.adjacent.get(edge.source)!.add(edge.target); this.adjacent.get(edge.target)!.add(edge.source); }
      const key = this.pairKey(edge.source, edge.target);
      if (!this.pairs.has(key)) { this.pairs.set(key, []); } this.pairs.get(key)!.push(edge);
    }
  }

  private addEdge(id: string, edge: GraphRelationship): void {
    let list = this.edges.get(id);
    if (list === undefined) { list = []; this.edges.set(id, list); }
    list.push(edge);
  }

  findNode(id: string): GraphNode | null { return this.byId.get(id) ?? null; }
  nodeRelations(id: string): GraphRelationship[] { return this.edges.get(id) ?? []; }
  private pairKey(a: string, b: string): string { return JSON.stringify(a < b ? [a, b] : [b, a]); }
  visualization(centerId: string = '', index: number = 0, labels?: string[]): GraphScene {
    const allowed = labels === undefined ? null : new Set(labels);
    let center = this.findNode(centerId);
    if (center === null || allowed !== null && !allowed.has(center.label)) {
      center = null;
      for (const node of this.nodes) {
        if (allowed !== null && !allowed.has(node.label)) { continue; }
        const degree = this.adjacent.get(node.id)?.size ?? 0;
        const best = center === null ? -1 : this.adjacent.get(center.id)?.size ?? 0;
        if (center === null || node.label === 'Person' && center.label !== 'Person' ||
          (node.label === 'Person') === (center.label === 'Person') && (degree > best || degree === best && node.id < center.id)) { center = node; }
      }
    }
    const id = center?.id ?? '';
    const labelsKey = allowed === null ? null : Array.from(allowed).sort();
    const scopeKey = JSON.stringify([id, labelsKey]);
    let candidates = this.filtered.get(scopeKey);
    if (candidates === undefined) {
      let neighbors = this.ordered.get(id);
      if (neighbors === undefined) {
        neighbors = Array.from(this.adjacent.get(id) ?? []);
        neighbors.sort((a: string, b: string) => (this.adjacent.get(b)?.size ?? 0) - (this.adjacent.get(a)?.size ?? 0) || a.localeCompare(b));
        this.ordered.set(id, neighbors);
      }
      candidates = neighbors.filter((next: string) => allowed === null || allowed.has(this.byId.get(next)!.label));
      this.filtered.set(scopeKey, candidates);
      if (this.filtered.size > 16) { this.filtered.delete(this.filtered.keys().next().value!); }
    }
    const current = Math.round(wheelPosition(index, candidates.length)) % Math.max(1, candidates.length);
    const slots = wheelSlots(current, candidates.length);
    const key = JSON.stringify([id, current, labelsKey]);
    const cached = this.scenes.get(key);
    if (cached !== undefined) { this.scenes.delete(key); this.scenes.set(key, cached); return cached; }
    const slotCandidates: string[] = candidates;
    const ids = new Set(slots.map((slot: WheelSlot) => slotCandidates[slot.index]));
    const nodes: GraphNode[] = [];
    if (center !== null) { nodes.push(center); ids.add(id); }
    for (const next of ids) { if (next !== id) { nodes.push(this.byId.get(next)!); } }
    // At most 8 displayed nodes => at most 36 pair lookups, independent of hub degrees.
    const selected: GraphRelationship[] = []; const visibleIds = Array.from(ids);
    for (let a = 0; a < visibleIds.length; a++) {
      for (let b = a; b < visibleIds.length; b++) {
        for (const edge of this.pairs.get(this.pairKey(visibleIds[a], visibleIds[b])) ?? []) { selected.push(edge); }
      }
    }
    const scene = new GraphScene(nodes, selected, id);
    scene.neighborTotal = candidates.length; scene.wheelIndex = current;
    for (const slot of slots) { const node = scene.find(candidates[slot.index]); if (node !== null) { node.wheelIndex = slot.index; node.wheelOffset = slot.offset; } }
    scene.totalNodes = this.byId.size; scene.totalRelationships = this.relationships.length; scene.missingEdges = this.missingEdges;
    this.scenes.set(key, scene);
    while (this.scenes.size > 8) { this.scenes.delete(this.scenes.keys().next().value!); }
    return scene;
  }
}
