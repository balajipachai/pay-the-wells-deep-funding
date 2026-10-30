import { encodeAbiParameters, keccak256 } from "viem";

export interface Judgment {
  juror: string;
  /** the package whose dependencies are being compared; `a` or `b` equal to `parent` means the package itself */
  parent: number;
  a: number;
  b: number;
  /** 0 = a mattered more, 1 = b mattered more, 2 = about equal */
  outcome: 0 | 1 | 2;
}

/** Same chaining as the contract: digest = keccak256(abi.encode(prev, juror, parent, a, b, outcome)). */
export function judgmentsDigest(js: Judgment[]): `0x${string}` {
  let d: `0x${string}` = `0x${"00".repeat(32)}`;
  for (const j of js) {
    d = keccak256(
      encodeAbiParameters(
        [{ type: "bytes32" }, { type: "address" }, { type: "uint16" }, { type: "uint16" }, { type: "uint16" }, { type: "uint8" }],
        [d, j.juror as `0x${string}`, j.parent, j.a, j.b, j.outcome],
      ),
    );
  }
  return d;
}

/**
 * Applies the counting rules, the same ones for everyone, so no one chooses which judgments count:
 *  - the juror must be on the juror list,
 *  - both items must belong to the parent's item set (the parent itself or one of its dependencies),
 *  - each juror's answer for a pair counts once (the first one on record), whichever way round it is written.
 */
export function countable(js: Judgment[], jurors: string[], itemsOf: (parent: number) => number[] | undefined): Judgment[] {
  const allowed = new Set(jurors.map((a) => a.toLowerCase()));
  const seen = new Set<string>();
  const out: Judgment[] = [];
  for (const j of js) {
    if (!allowed.has(j.juror.toLowerCase())) continue;
    const items = itemsOf(j.parent);
    if (!items || !items.includes(j.a) || !items.includes(j.b) || j.a === j.b) continue;
    const key = `${j.juror.toLowerCase()}:${j.parent}:${Math.min(j.a, j.b)}:${Math.max(j.a, j.b)}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(j);
  }
  return out;
}
