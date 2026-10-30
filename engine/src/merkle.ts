import { concatHex, encodeAbiParameters, getAddress, keccak256 } from "viem";

export interface Leaf {
  recipient: string;
  amount: bigint;
}

/**
 * Mirrors the contract: keccak256(keccak256(abi.encode(contractAddress, recipient, amount))).
 * The double hash stops a leaf from being passed off as an inner node; the contract address in the
 * preimage stops a tree built for one deployment from being replayed on another.
 */
export const leafHash = (contract: string, l: Leaf): `0x${string}` =>
  keccak256(keccak256(encodeAbiParameters([{ type: "address" }, { type: "address" }, { type: "uint256" }], [contract as `0x${string}`, l.recipient as `0x${string}`, l.amount])));

const pair = (a: `0x${string}`, b: `0x${string}`) => (a.toLowerCase() < b.toLowerCase() ? keccak256(concatHex([a, b])) : keccak256(concatHex([b, a])));

export function buildTree(contract: string, leaves: Leaf[]) {
  const sorted = [...leaves].sort((x, y) => (x.recipient.toLowerCase() < y.recipient.toLowerCase() ? -1 : 1));
  let level = sorted.map((l) => leafHash(contract, l));
  const layers = [level];
  while (level.length > 1) {
    const next: `0x${string}`[] = [];
    for (let i = 0; i < level.length; i += 2) next.push(i + 1 < level.length ? pair(level[i], level[i + 1]) : level[i]);
    layers.push(next);
    level = next;
  }
  const root = layers.at(-1)![0];
  const proofs: Record<string, `0x${string}`[]> = {};
  sorted.forEach((l, index) => {
    const proof: `0x${string}`[] = [];
    let idx = index;
    for (const layer of layers.slice(0, -1)) {
      const sib = idx ^ 1;
      if (sib < layer.length) proof.push(layer[sib]);
      idx = Math.floor(idx / 2);
    }
    const check = proof.reduce((h, p) => pair(h, p), layers[0][index]);
    if (check !== root) throw new Error(`self-check failed for ${l.recipient}`);
    proofs[getAddress(l.recipient)] = proof;
  });
  return { root, proofs, sorted };
}
