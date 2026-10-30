import { SCALE, bradleyTerry, type Comparison } from "./bt.ts";
import { byId, depths, findCycles, reachable, validateGraph, type Graph } from "./graph.ts";
import { countable, type Judgment } from "./judgments.ts";

/** Hard cap on propagation rounds. The run must reach zero in-flight value well before this, or it aborts. */
export const MAX_ROUNDS = 10000;

export interface ParentWeights {
  parent: number;
  items: { id: number; weight: bigint }[]; // the package itself first, then its dependencies by id
  comparisons: { a: number; b: number; aWins: number; bWins: number; ties: number; jurors: string[] }[];
  judgmentsUsed: number;
}
export interface Allocation {
  shares: Map<number, bigint>; // each package's share of the pot, summing to exactly SCALE
  edgeFlow: Map<string, bigint>; // "parent>dep" -> share passed down that edge in total
  rounds: number;
  weights: Map<number, ParentWeights>;
  amounts: Map<number, bigint>; // wei per package, summing to exactly the pot
  cycles: number[][];
  unreachable: number[];
  ignoredJudgments: number;
}

/** The jury's judgments become, for every package with dependencies, how much it keeps and how it splits the rest. */
export function deriveWeights(g: Graph, judgments: Judgment[], jurors: string[]): { weights: Map<number, ParentWeights>; ignored: number } {
  const pk = byId(g);
  const itemsOf = (p: number) => {
    const pkg = pk.get(p);
    return pkg && pkg.deps.length ? [p, ...[...pkg.deps].sort((a, b) => a - b)] : undefined;
  };
  const used = countable(judgments, jurors, itemsOf);
  const weights = new Map<number, ParentWeights>();
  for (const pkg of [...g.packages].sort((a, b) => a.id - b.id)) {
    const items = itemsOf(pkg.id);
    if (!items) continue;
    const mine = used.filter((j) => j.parent === pkg.id);
    const comps: Comparison[] = mine.map((j) => ({ a: j.a, b: j.b, outcome: j.outcome }));
    const w = bradleyTerry(items, comps);
    const pairs = new Map<string, ParentWeights["comparisons"][number]>();
    for (const j of mine) {
      const lo = Math.min(j.a, j.b), hi = Math.max(j.a, j.b), key = `${lo}:${hi}`;
      const row = pairs.get(key) ?? { a: lo, b: hi, aWins: 0, bWins: 0, ties: 0, jurors: [] };
      const winner = j.outcome === 2 ? -1 : j.outcome === 0 ? j.a : j.b;
      if (winner === -1) row.ties++;
      else if (winner === lo) row.aWins++;
      else row.bWins++;
      row.jurors.push(j.juror.toLowerCase());
      pairs.set(key, row);
    }
    weights.set(pkg.id, {
      parent: pkg.id,
      items: items.map((id) => ({ id, weight: w.get(id)! })),
      comparisons: [...pairs.values()].sort((x, y) => x.a - y.a || x.b - y.b),
      judgmentsUsed: mine.length,
    });
  }
  return { weights, ignored: judgments.length - used.length };
}

/**
 * Water flows down the graph. The root starts with the whole pot (SCALE). In each round every package
 * keeps its jury-derived share of what reached it and passes the rest to its dependencies in their
 * jury-derived proportions. Cycles are fine: value that goes round a loop keeps shrinking, because every
 * package keeps a positive share each time, and the integer maths floors it to zero in finitely many rounds.
 * Termination does not rely on that argument alone: the loop has a hard cap and aborts if it is hit.
 * Rounding stays inside the system: whatever the passing amounts floor away is kept by the passing package,
 * so shares always sum to exactly SCALE.
 */
export function propagate(g: Graph, weights: Map<number, ParentWeights>) {
  const kept = new Map<number, bigint>(g.packages.map((p) => [p.id, 0n]));
  const edgeFlow = new Map<string, bigint>();
  let inflow = new Map<number, bigint>([[g.root, SCALE]]);
  let rounds = 0;
  while (inflow.size) {
    if (++rounds > MAX_ROUNDS) throw new Error(`propagation did not settle within ${MAX_ROUNDS} rounds`);
    const next = new Map<number, bigint>();
    for (const [id, amount] of [...inflow].sort((x, y) => x[0] - y[0])) {
      const pw = weights.get(id);
      if (!pw) {
        kept.set(id, kept.get(id)! + amount);
        continue;
      }
      let passed = 0n;
      for (const it of pw.items.slice(1)) {
        const part = (amount * it.weight) / SCALE;
        if (part === 0n) continue;
        passed += part;
        next.set(it.id, (next.get(it.id) ?? 0n) + part);
        const key = `${id}>${it.id}`;
        edgeFlow.set(key, (edgeFlow.get(key) ?? 0n) + part);
      }
      kept.set(id, kept.get(id)! + (amount - passed));
    }
    inflow = next;
  }
  return { kept, edgeFlow, rounds };
}

/**
 * Turns shares into wei. Floors every package's cut, then hands the leftover wei one at a time to the
 * packages with the largest fractional remainders (ties broken by lower id). No dust recipient exists:
 * the total is the pot exactly, and the function throws if it is not.
 */
export function toAmounts(shares: Map<number, bigint>, pot: bigint): Map<number, bigint> {
  const ids = [...shares.keys()].sort((a, b) => a - b);
  const amounts = new Map<number, bigint>();
  const rem: { id: number; r: bigint }[] = [];
  let total = 0n;
  for (const id of ids) {
    const num = pot * shares.get(id)!;
    const a = num / SCALE;
    amounts.set(id, a);
    total += a;
    rem.push({ id, r: num % SCALE });
  }
  let left = pot - total;
  rem.sort((x, y) => (x.r === y.r ? x.id - y.id : x.r > y.r ? -1 : 1));
  for (let i = 0; left > 0n; i++, left--) amounts.set(rem[i].id, amounts.get(rem[i].id)! + 1n);
  assertConserved(amounts, pot);
  return amounts;
}

export function assertConserved(amounts: Map<number, bigint> | Iterable<bigint>, pot: bigint): void {
  let sum = 0n;
  for (const v of amounts instanceof Map ? amounts.values() : amounts) sum += v;
  if (sum !== pot) throw new Error(`allocation does not conserve the pot: ${sum} != ${pot}`);
}

export function allocate(g: Graph, judgments: Judgment[], jurors: string[], pot: bigint): Allocation {
  validateGraph(g);
  const { weights, ignored } = deriveWeights(g, judgments, jurors);
  const { kept, edgeFlow, rounds } = propagate(g, weights);
  let totalShares = 0n;
  for (const v of kept.values()) totalShares += v;
  if (totalShares !== SCALE) throw new Error(`shares do not sum to 1: ${totalShares}`);
  const reach = reachable(g);
  return {
    shares: kept,
    edgeFlow,
    rounds,
    weights,
    amounts: toAmounts(kept, pot),
    cycles: findCycles(g),
    unreachable: g.packages.filter((p) => !reach.has(p.id)).map((p) => p.id),
    ignoredJudgments: ignored,
  };
}

export { depths };
