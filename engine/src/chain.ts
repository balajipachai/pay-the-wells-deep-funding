import { createPublicClient, http, parseAbi, parseAbiItem } from "viem";
import type { Judgment } from "./judgments.ts";

const abi = parseAbi([
  "function jurorList() view returns (address[])",
  "function pot() view returns (uint256)",
  "function graphHash() view returns (bytes32)",
  "function judgmentsDigest() view returns (bytes32)",
  "function judgmentCount() view returns (uint256)",
  "function proposal() view returns (address proposer, bytes32 root, uint256 pot, uint256 proposedAt, uint256 openDisputes)",
]);
const judgmentEvent = parseAbiItem("event JudgmentSubmitted(address indexed juror, uint16 parent, uint16 a, uint16 b, uint8 outcome)");

/** Everything the engine needs, read from the deployed contract's own logs and state. */
export async function readChain(rpc: string, contract: string, fromBlock: bigint) {
  const client = createPublicClient({ transport: http(rpc) });
  const read = (functionName: any) => client.readContract({ address: contract as `0x${string}`, abi, functionName } as any) as Promise<any>;
  const latest = await client.getBlockNumber();
  const judgments: Judgment[] = [];
  for (let from = fromBlock; from <= latest; from += 40000n) {
    const to = from + 39999n > latest ? latest : from + 39999n;
    const logs = await client.getLogs({ address: contract as `0x${string}`, event: judgmentEvent, fromBlock: from, toBlock: to });
    for (const l of logs) judgments.push({ juror: l.args.juror!, parent: l.args.parent!, a: l.args.a!, b: l.args.b!, outcome: l.args.outcome as 0 | 1 | 2 });
  }
  const [jurors, pot, graphHash, digest, count, proposal] = await Promise.all([
    read("jurorList"), read("pot"), read("graphHash"), read("judgmentsDigest"), read("judgmentCount"), read("proposal"),
  ]);
  return { judgments, jurors: jurors as string[], pot: pot as bigint, graphHash: graphHash as string, digest: digest as string, count: count as bigint, proposal };
}
