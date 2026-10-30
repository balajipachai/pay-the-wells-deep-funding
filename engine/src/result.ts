import { getAddress } from "viem";
import { allocate, assertConserved } from "./allocate.ts";
import { SCALE } from "./bt.ts";
import { byId, depths, graphHash, type Graph } from "./graph.ts";
import { judgmentsDigest, type Judgment } from "./judgments.ts";
import { buildTree } from "./merkle.ts";

export interface Config {
  /** the deployed contract; it is part of every Merkle leaf */
  contract: string;
  /** wei to distribute */
  pot: string;
  jurors: string[];
}

/** One deterministic function from (graph, judgments, config) to the full published result. */
export function buildResult(g: Graph, judgments: Judgment[], cfg: Config) {
  const pot = BigInt(cfg.pot);
  const a = allocate(g, judgments, cfg.jurors, pot);
  const pk = byId(g);
  const depth = depths(g);
  const ids = g.packages.map((p) => p.id).sort((x, y) => x - y);

  const packages = ids.map((id) => {
    const p = pk.get(id)!;
    const inflows: { from: number; share: string }[] = [];
    for (const [key, v] of a.edgeFlow) {
      const [from, to] = key.split(">").map(Number);
      if (to === id) inflows.push({ from, share: v.toString() });
    }
    inflows.sort((x, y) => x.from - y.from);
    return {
      id,
      name: p.name,
      payout: getAddress(p.payout),
      deps: [...p.deps].sort((x, y) => x - y),
      depth: depth.get(id) ?? null,
      isRoot: id === g.root,
      keptShare: a.shares.get(id)!.toString(),
      amount: a.amounts.get(id)!.toString(),
      inflows,
    };
  });

  const parents = [...a.weights.values()].map((w) => ({
    parent: w.parent,
    name: pk.get(w.parent)!.name,
    judgmentsUsed: w.judgmentsUsed,
    items: w.items.map((i) => ({ id: i.id, name: i.id === w.parent ? `${pk.get(i.id)!.name} (its own work)` : pk.get(i.id)!.name, weight: i.weight.toString() })),
    comparisons: w.comparisons,
  }));

  // One leaf per payout address: several packages owned by one address are paid together.
  const merged = new Map<string, { amount: bigint; packages: number[] }>();
  for (const p of packages) {
    const amt = BigInt(p.amount);
    if (amt === 0n) continue;
    const k = p.payout;
    const cur = merged.get(k) ?? { amount: 0n, packages: [] };
    cur.amount += amt;
    cur.packages.push(p.id);
    merged.set(k, cur);
  }
  assertConserved([...merged.values()].map((m) => m.amount), pot);
  const { root, proofs, sorted } = buildTree(cfg.contract, [...merged].map(([recipient, m]) => ({ recipient, amount: m.amount })));
  const allocations = sorted.map((l) => ({ recipient: getAddress(l.recipient), amount: l.amount.toString(), packages: merged.get(getAddress(l.recipient))!.packages }));

  return {
    version: 1,
    contract: getAddress(cfg.contract),
    pot: pot.toString(),
    scale: SCALE.toString(),
    graphHash: graphHash(g),
    judgmentCount: judgments.length,
    judgmentsCounted: judgments.length - a.ignoredJudgments,
    judgmentsDigest: judgmentsDigest(judgments),
    jurors: cfg.jurors.map(getAddress),
    cycles: a.cycles,
    propagationRounds: a.rounds,
    root,
    packages,
    parents,
    allocations,
    proofs,
  };
}

/** Stable text form, so two runs can be compared byte for byte. */
export const stringify = (o: unknown): string => JSON.stringify(o, null, 2) + "\n";
