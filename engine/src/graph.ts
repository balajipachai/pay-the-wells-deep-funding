import { keccak256, toBytes } from "viem";

export interface Pkg {
  id: number;
  name: string;
  payout: string;
  deps: number[];
}
export interface Graph {
  root: number;
  packages: Pkg[];
}

/** Stable JSON: packages sorted by id, deps sorted. The graph's commitment is keccak256 of this string. */
export function canonicalGraph(g: Graph): string {
  const packages = [...g.packages]
    .sort((a, b) => a.id - b.id)
    .map((p) => ({ id: p.id, name: p.name, payout: p.payout.toLowerCase(), deps: [...p.deps].sort((a, b) => a - b) }));
  return JSON.stringify({ root: g.root, packages });
}
export const graphHash = (g: Graph): `0x${string}` => keccak256(toBytes(canonicalGraph(g)));

export function validateGraph(g: Graph): void {
  const ids = new Set<number>();
  for (const p of g.packages) {
    if (!Number.isInteger(p.id) || p.id < 0 || p.id > 65535) throw new Error(`bad package id ${p.id}`);
    if (ids.has(p.id)) throw new Error(`duplicate package id ${p.id}`);
    ids.add(p.id);
    if (!/^0x[0-9a-fA-F]{40}$/.test(p.payout)) throw new Error(`package ${p.id} has a bad payout address`);
  }
  if (!ids.has(g.root)) throw new Error("root is not a package");
  for (const p of g.packages) {
    if (new Set(p.deps).size !== p.deps.length) throw new Error(`package ${p.id} lists a dependency twice`);
    for (const d of p.deps) {
      if (!ids.has(d)) throw new Error(`package ${p.id} depends on unknown package ${d}`);
      if (d === p.id) throw new Error(`package ${p.id} depends on itself`);
    }
  }
}

export const byId = (g: Graph): Map<number, Pkg> => new Map(g.packages.map((p) => [p.id, p]));

/** Packages reachable from the root. Iterative with a visited set, so cycles cannot loop forever. */
export function reachable(g: Graph): Set<number> {
  const pk = byId(g);
  const seen = new Set<number>([g.root]);
  const stack = [g.root];
  while (stack.length) {
    const id = stack.pop()!;
    for (const d of pk.get(id)!.deps) {
      if (!seen.has(d)) {
        seen.add(d);
        stack.push(d);
      }
    }
  }
  return seen;
}

/** Shortest distance from the root, by breadth-first search with a visited set. */
export function depths(g: Graph): Map<number, number> {
  const pk = byId(g);
  const depth = new Map<number, number>([[g.root, 0]]);
  const queue = [g.root];
  for (let i = 0; i < queue.length; i++) {
    const id = queue[i];
    for (const d of pk.get(id)!.deps) {
      if (!depth.has(d)) {
        depth.set(d, depth.get(id)! + 1);
        queue.push(d);
      }
    }
  }
  return depth;
}

/** Groups of packages that depend on each other in a loop (strongly connected components of size > 1). */
export function findCycles(g: Graph): number[][] {
  const pk = byId(g);
  let counter = 0;
  const index = new Map<number, number>(), low = new Map<number, number>(), onStack = new Set<number>();
  const stack: number[] = [], out: number[][] = [];
  const strong = (v: number): void => {
    index.set(v, counter);
    low.set(v, counter++);
    stack.push(v);
    onStack.add(v);
    for (const w of pk.get(v)!.deps) {
      if (!index.has(w)) {
        strong(w);
        low.set(v, Math.min(low.get(v)!, low.get(w)!));
      } else if (onStack.has(w)) low.set(v, Math.min(low.get(v)!, index.get(w)!));
    }
    if (low.get(v) === index.get(v)) {
      const comp: number[] = [];
      let w: number;
      do {
        w = stack.pop()!;
        onStack.delete(w);
        comp.push(w);
      } while (w !== v);
      if (comp.length > 1) out.push(comp.sort((a, b) => a - b));
    }
  };
  for (const p of [...g.packages].sort((a, b) => a.id - b.id)) if (!index.has(p.id)) strong(p.id);
  return out.sort((a, b) => a[0] - b[0]);
}
