import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { concatHex, keccak256 } from "viem";
import { allocate, assertConserved, propagate, deriveWeights, toAmounts } from "./allocate.ts";
import { SCALE, bradleyTerry } from "./bt.ts";
import { depths, findCycles, graphHash, reachable, type Graph } from "./graph.ts";
import { judgmentsDigest, type Judgment } from "./judgments.ts";
import { leafHash } from "./merkle.ts";
import { buildResult, stringify, type Config } from "./result.ts";

const data = resolve(dirname(fileURLToPath(import.meta.url)), "../../data");
const read = <T>(n: string): T => JSON.parse(readFileSync(resolve(data, n), "utf8"));
const graph = read<Graph>("graph.json");
const judgments = read<Judgment[]>("judgments.json");
const cfg = read<Config>("config.json");
const POT = BigInt(cfg.pot);
const name = (id: number) => graph.packages.find((p) => p.id === id)!.name;

// ---------------------------------------------------------------- the sample, pinned to its expected output

test("the published sample reproduces its committed result byte for byte", () => {
  const committed = readFileSync(resolve(data, "result.json"), "utf8");
  assert.equal(stringify(buildResult(graph, judgments, cfg)), committed);
});

test("sample graph is at least three levels deep and contains a cycle", () => {
  assert.ok(Math.max(...depths(graph).values()) >= 3);
  const cycles = findCycles(graph);
  assert.ok(cycles.length >= 1);
  assert.deepEqual(cycles[0], [8, 9], "eth-rpc and abi-codec depend on each other");
});

// ---------------------------------------------------------------- conservation

test("payouts add up to the pot exactly, with no dust recipient", () => {
  const a = allocate(graph, judgments, cfg.jurors, POT);
  assertConserved(a.amounts, POT);
  let s = 0n;
  for (const v of a.shares.values()) s += v;
  assert.equal(s, SCALE);
});

test("awkward pots still add up exactly (largest-remainder rounding)", () => {
  for (const pot of [0n, 1n, 7n, 16n, 17n, 999_999_999_999_999_999n, 10n ** 30n + 12345n]) {
    const a = allocate(graph, judgments, cfg.jurors, pot);
    assertConserved(a.amounts, pot);
  }
});

test("rounding remainder goes to the largest fractional parts, ties to the lower id", () => {
  const shares = new Map<number, bigint>([[0, SCALE / 3n], [1, SCALE / 3n], [2, SCALE - 2n * (SCALE / 3n)]]);
  const out = toAmounts(shares, 10n);
  assert.equal([...out.values()].reduce((x, y) => x + y, 0n), 10n);
  assert.deepEqual([...out.values()], [3n, 3n, 4n]);
});

test("the conservation check aborts when the total is off", () => {
  assert.throws(() => assertConserved([5n, 4n], 10n), /does not conserve/);
});

// ---------------------------------------------------------------- not a one-level splitter

test("dependencies of dependencies are paid, all the way down", () => {
  const a = allocate(graph, judgments, cfg.jurors, POT);
  const deepest = [...depths(graph)].filter(([, d]) => d >= 3).map(([id]) => id);
  assert.ok(deepest.length > 0);
  for (const id of deepest) assert.ok(a.amounts.get(id)! > 0n, `${name(id)} (level >= 3) got nothing`);
  for (const id of reachable(graph)) assert.ok(a.amounts.get(id)! > 0n, `${name(id)} got nothing`);
});

test("value that circles a cycle terminates and the loop members are both paid", () => {
  const a = allocate(graph, judgments, cfg.jurors, POT);
  assert.ok(a.rounds < 200);
  assert.ok(a.amounts.get(8)! > 0n && a.amounts.get(9)! > 0n);
});

test("a tight cycle with a heavily skewed jury still terminates", () => {
  const g: Graph = {
    root: 0,
    packages: [
      { id: 0, name: "root", payout: "0x0000000000000000000000000000000000000001", deps: [1] },
      { id: 1, name: "a", payout: "0x0000000000000000000000000000000000000002", deps: [2] },
      { id: 2, name: "b", payout: "0x0000000000000000000000000000000000000003", deps: [1] },
    ],
  };
  const jurors = ["0x00000000000000000000000000000000000000aa"];
  const js: Judgment[] = [];
  // every juror says the dependency matters far more than the package itself, as hard as they can
  for (let i = 0; i < 1; i++) {
    js.push({ juror: jurors[0], parent: 1, a: 2, b: 1, outcome: 0 }, { juror: jurors[0], parent: 2, a: 1, b: 2, outcome: 0 });
  }
  const a = allocate(g, js, jurors, 10n ** 18n);
  assertConserved(a.amounts, 10n ** 18n);
  assert.ok(a.rounds < 10000);
});

test("a package nobody reaches from the root gets nothing", () => {
  const g: Graph = { ...graph, packages: [...graph.packages, { id: 99, name: "orphan", payout: "0x00000000000000000000000000000000000000ff", deps: [] }] };
  const a = allocate(g, judgments, cfg.jurors, POT);
  assert.equal(a.amounts.get(99), 0n);
  assert.deepEqual(a.unreachable, [99]);
  assertConserved(a.amounts, POT);
});

// ---------------------------------------------------------------- the judgments really feed the result

test("keep-shares come from the jury, not from a typed-in number", () => {
  const app = (js: Judgment[]) => deriveWeights(graph, js, cfg.jurors).weights.get(0)!.items[0].weight;
  const deps = [1, 2, 3, 4];
  const jury = cfg.jurors;
  const lean = (selfWins: boolean): Judgment[] =>
    jury.flatMap((juror) => deps.map((d) => ({ juror, parent: 0, a: 0, b: d, outcome: (selfWins ? 0 : 1) as 0 | 1 })));
  assert.ok(app(lean(true)) > app(lean(false)) * 5n, "the app keeps far more when the jury says its own work mattered more");
});

test("changing a single judgment changes the published root", () => {
  const base = buildResult(graph, judgments, cfg).root;
  const tweaked = judgments.map((j, i) => (i === 0 ? { ...j, outcome: (j.outcome === 0 ? 1 : 0) as 0 | 1 | 2 } : j));
  assert.notEqual(buildResult(graph, tweaked, cfg).root, base);
});

test("the order judgments arrived in does not change the payouts", () => {
  const shuffled = [...judgments].reverse();
  const a = buildResult(graph, judgments, cfg), b = buildResult(graph, shuffled, cfg);
  assert.equal(a.root, b.root);
  assert.notEqual(a.judgmentsDigest, b.judgmentsDigest, "the digest is order-sensitive, the result is not");
});

test("judgments from outside the jury, non-edges and repeat answers are not counted", () => {
  const stranger = "0x00000000000000000000000000000000000000ee";
  const extra: Judgment[] = [
    { juror: stranger, parent: 0, a: 0, b: 1, outcome: 0 }, // not a juror
    { juror: cfg.jurors[0], parent: 0, a: 11, b: 12, outcome: 0 }, // neither is an item of parent 0
    { juror: cfg.jurors[0], parent: 0, a: 0, b: 0, outcome: 0 }, // an item against itself
    { juror: cfg.jurors[0], parent: 11, a: 11, b: 12, outcome: 0 }, // leaf packages have no dependencies to compare
  ];
  const first = judgments.find((j) => j.parent === 0)!;
  extra.push({ ...first, a: first.b, b: first.a, outcome: (first.outcome === 2 ? 2 : first.outcome === 0 ? 1 : 0) as 0 | 1 | 2 }, first); // same pair again, either way round
  const a = buildResult(graph, judgments, cfg), b = buildResult(graph, [...judgments, ...extra], cfg);
  assert.equal(b.root, a.root);
  assert.equal(b.judgmentCount - b.judgmentsCounted, extra.length);
});

// ---------------------------------------------------------------- the weighting method

test("Bradley-Terry: 8-0 against a half-win prior gives the analytic ratio 17 to 1", () => {
  const w = bradleyTerry([1, 2], Array.from({ length: 8 }, () => ({ a: 1, b: 2, outcome: 0 as const })));
  const ratio = Number(w.get(1)! * 1000n / w.get(2)!) / 1000;
  assert.ok(Math.abs(ratio - 17) < 0.01, `ratio was ${ratio}`);
  assert.equal(w.get(1)! + w.get(2)!, SCALE);
});

test("Bradley-Terry: no judgments or all ties give equal weights", () => {
  for (const comps of [[], [{ a: 1, b: 2, outcome: 2 as const }, { a: 2, b: 3, outcome: 2 as const }]]) {
    const w = bradleyTerry([1, 2, 3], comps);
    const v = [...w.values()];
    assert.ok(v.every((x) => x > SCALE / 3n - 10n && x < SCALE / 3n + 10n));
  }
});

test("Bradley-Terry: a win over a strong item counts for more than a win over a weak one", () => {
  // 1 beats 2 and 2 beats 3, in equal numbers; BT must rank 1 > 2 > 3 with 1 further ahead than raw win counts say
  const comps = [
    ...Array.from({ length: 6 }, () => ({ a: 1, b: 2, outcome: 0 as const })),
    ...Array.from({ length: 6 }, () => ({ a: 2, b: 3, outcome: 0 as const })),
  ];
  const w = bradleyTerry([1, 2, 3], comps);
  assert.ok(w.get(1)! > w.get(2)! && w.get(2)! > w.get(3)!);
});

test("Bradley-Terry rejects a comparison between items it was not given", () => {
  assert.throws(() => bradleyTerry([1, 2], [{ a: 1, b: 3, outcome: 0 }]), /outside/);
});

test("Bradley-Terry weights are bit-for-bit repeatable", () => {
  const a = bradleyTerry([0, 1, 2, 3, 4], judgments.filter((j) => j.parent === 0).map((j) => ({ a: j.a, b: j.b, outcome: j.outcome })));
  const b = bradleyTerry([0, 1, 2, 3, 4], judgments.filter((j) => j.parent === 0).map((j) => ({ a: j.a, b: j.b, outcome: j.outcome })));
  assert.deepEqual([...a], [...b]);
});

// ---------------------------------------------------------------- commitments

test("each Merkle proof verifies against the root with an independent verifier", () => {
  const r = buildResult(graph, judgments, cfg);
  const pair = (a: `0x${string}`, b: `0x${string}`) => (a < b ? keccak256(concatHex([a, b])) : keccak256(concatHex([b, a])));
  for (const al of r.allocations) {
    let h = leafHash(cfg.contract, { recipient: al.recipient, amount: BigInt(al.amount) });
    for (const p of r.proofs[al.recipient]) h = pair(h, p);
    assert.equal(h, r.root, al.recipient);
  }
  assert.equal(r.allocations.reduce((s, a) => s + BigInt(a.amount), 0n), POT);
});

test("a tree built for one contract does not verify under another address", () => {
  const r = buildResult(graph, judgments, cfg);
  const other = buildResult(graph, judgments, { ...cfg, contract: "0x00000000000000000000000000000000000000c1" });
  assert.notEqual(r.root, other.root);
});

test("graph and judgment commitments are stable and sensitive", () => {
  assert.equal(graphHash(graph), graphHash({ ...graph, packages: [...graph.packages].reverse() }), "package order does not matter");
  const changed: Graph = { ...graph, packages: graph.packages.map((p) => (p.id === 15 ? { ...p, deps: [] } : p)) };
  assert.equal(graphHash(changed), graphHash(graph), "unchanged semantics, unchanged hash");
  const rewired: Graph = { ...graph, packages: graph.packages.map((p) => (p.id === 10 ? { ...p, deps: [] } : p)) };
  assert.notEqual(graphHash(rewired), graphHash(graph));
  assert.notEqual(judgmentsDigest(judgments.slice(1)), judgmentsDigest(judgments));
});

test("propagate keeps value inside the system round after round", () => {
  const { weights } = deriveWeights(graph, judgments, cfg.jurors);
  const { kept } = propagate(graph, weights);
  assert.equal([...kept.values()].reduce((x, y) => x + y, 0n), SCALE);
});
