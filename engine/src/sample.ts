import { getAddress, keccak256, toBytes } from "viem";
import type { Graph } from "./graph.ts";
import type { Config } from "./result.ts";
import type { Judgment } from "./judgments.ts";

/** The story: Kavya's event app and everything it stands on. Ids are stable; payout addresses are placeholders. */
const rows: [number, string, number[]][] = [
  [0, "devcon-event-app", [1, 2, 3, 4]],
  [1, "qr-ticketing (solo developer, Pune)", [5, 6]],
  [2, "i18n-hindi", [7]],
  [3, "wallet-connect-wrapper", [8, 7]],
  [4, "ui-kit", [7, 11]],
  [5, "qr-encode", [12]],
  [6, "image-decode", [12]],
  [7, "i18n-core", [13]],
  [8, "eth-rpc", [9, 10]],
  [9, "abi-codec", [14, 8]], // abi-codec depends back on eth-rpc: the cycle eth-rpc -> abi-codec -> eth-rpc
  [10, "http-client", [15]],
  [11, "css-utils", []],
  [12, "bitstream", []],
  [13, "intl-polyfill", []],
  [14, "bigint-utils", []],
  [15, "url-parse", []],
];
const placeholder = (name: string) => getAddress("0x" + keccak256(toBytes("payout:" + name)).slice(-40));

export const sampleGraph = (): Graph => ({
  root: 0,
  packages: rows.map(([id, name, deps]) => ({ id, name, payout: placeholder(name), deps })),
});

/** Anvil's first five accounts act as the five jurors in the sample. */
export const SAMPLE_JURORS = [
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
  "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
  "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
];

export const sampleConfig = (): Config => ({
  contract: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  pot: "10000000000000000000",
  jurors: SAMPLE_JURORS,
});

/**
 * What the sample jury believes, as relative importance for each parent's own work and each dependency.
 * Jurors do not see these numbers; they answer noisy pairwise questions drawn from them (seeded, so the
 * committed judgments are reproducible). Only the judgments reach the engine.
 */
const belief: Record<number, Record<number, number>> = {
  0: { 0: 3, 1: 6, 2: 2, 3: 3, 4: 2 },
  1: { 1: 5, 5: 2, 6: 2 },
  2: { 2: 6, 7: 3 },
  3: { 3: 3, 8: 4, 7: 1 },
  4: { 4: 4, 7: 2, 11: 1 },
  5: { 5: 3, 12: 2 },
  6: { 6: 3, 12: 2 },
  7: { 7: 4, 13: 2 },
  8: { 8: 3, 9: 3, 10: 2 },
  9: { 9: 3, 14: 2, 8: 1 },
  10: { 10: 4, 15: 2 },
};

function mulberry32(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function sampleJudgments(): Judgment[] {
  const rnd = mulberry32(20261031);
  const out: Judgment[] = [];
  for (const juror of SAMPLE_JURORS) {
    for (const [p, vals] of Object.entries(belief)) {
      const parent = Number(p), items = Object.keys(vals).map(Number);
      for (let i = 0; i < items.length; i++) {
        for (let j = i + 1; j < items.length; j++) {
          if (rnd() > 0.85) continue; // not every juror answers every question
          const [x, y] = rnd() < 0.5 ? [items[i], items[j]] : [items[j], items[i]];
          const px = vals[x] / (vals[x] + vals[y]);
          const outcome = rnd() < 0.08 ? 2 : rnd() < px ? 0 : 1;
          out.push({ juror, parent, a: x, b: y, outcome: outcome as 0 | 1 | 2 });
        }
      }
    }
  }
  return out;
}
