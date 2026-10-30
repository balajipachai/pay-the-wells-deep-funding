import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { depths, graphHash, validateGraph, type Graph } from "./graph.ts";
import { judgmentsDigest, type Judgment } from "./judgments.ts";
import { buildResult, stringify, type Config } from "./result.ts";
import { sampleConfig, sampleGraph, sampleJudgments } from "./sample.ts";
import { readChain } from "./chain.ts";

const dataDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../data");
const file = (n: string) => resolve(dataDir, n);
const load = <T>(n: string): T => JSON.parse(readFileSync(file(n), "utf8"));
const arg = (name: string) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
};

const [, , cmd] = process.argv;

function summary(r: ReturnType<typeof buildResult>, g: Graph) {
  const d = depths(g);
  console.log(`packages: ${g.packages.length}  deepest level: ${Math.max(...d.values())}  cycles: ${JSON.stringify(r.cycles)}`);
  console.log(`judgments: ${r.judgmentCount} on record, ${r.judgmentsCounted} counted  pot: ${r.pot} wei  rounds: ${r.propagationRounds}`);
  console.log(`graphHash        ${r.graphHash}\njudgmentsDigest  ${r.judgmentsDigest}\nroot             ${r.root}`);
}

if (cmd === "sample") {
  // Regenerates the committed sample inputs. The engine never reads this code, only the files it writes.
  writeFileSync(file("graph.json"), JSON.stringify(sampleGraph(), null, 2) + "\n");
  writeFileSync(file("judgments.json"), JSON.stringify(sampleJudgments(), null, 2) + "\n");
  writeFileSync(file("config.json"), JSON.stringify(sampleConfig(), null, 2) + "\n");
  console.log("wrote data/graph.json, data/judgments.json, data/config.json");
} else if (cmd === "compute" || cmd === "reproduce") {
  const chainRpc = arg("rpc"), contract = arg("contract");
  const g = load<Graph>(arg("graph") ?? "graph.json");
  validateGraph(g);
  let judgments: Judgment[], cfg: Config, out = arg("out") ?? "result.json";
  let onchain: Awaited<ReturnType<typeof readChain>> | undefined;
  if (chainRpc && contract) {
    // Same pipeline, but every input comes from the deployed contract instead of from committed files.
    const dep = existsSync(file("../frontend/deployment.json")) ? JSON.parse(readFileSync(file("../frontend/deployment.json"), "utf8")) : { deployBlock: 0 };
    onchain = await readChain(chainRpc, contract, BigInt(arg("from-block") ?? dep.deployBlock ?? 0));
    if (onchain.graphHash !== graphHash(g)) throw new Error(`data/graph.json does not match the graph committed on-chain (${graphHash(g)} vs ${onchain.graphHash})`);
    judgments = onchain.judgments;
    if (judgmentsDigest(judgments) !== onchain.digest) throw new Error("judgments read from logs do not match the contract's on-chain digest");
    cfg = { contract, pot: onchain.pot.toString(), jurors: onchain.jurors };
    out = arg("out") ?? "result.chain.json";
  } else {
    judgments = load<Judgment[]>("judgments.json");
    cfg = load<Config>("config.json");
  }
  const result = buildResult(g, judgments, cfg);
  const text = stringify(result);
  summary(result, g);
  if (cmd === "compute") {
    writeFileSync(file(out), text);
    console.log(`wrote data/${out}`);
  } else if (onchain) {
    const proposed = onchain.proposal.root as string;
    const same = proposed.toLowerCase() === result.root.toLowerCase();
    console.log(same ? `PASS: recomputed root equals the root proposed on-chain` : `FAIL: recomputed root differs from the proposed root (${proposed}). Raise a dispute.`);
    process.exit(same ? 0 : 1);
  } else {
    const committed = readFileSync(file(out), "utf8");
    const same = committed === text;
    console.log(same ? "PASS: re-running the published graph and judgments gives exactly the committed result" : "FAIL: the recomputed result differs from data/result.json");
    process.exit(same ? 0 : 1);
  }
} else {
  console.log("usage: node src/cli.ts <sample | compute | reproduce> [--rpc <url> --contract <addr> [--from-block <n>]] [--out file]");
  process.exit(1);
}
