/**
 * Bradley-Terry weights from pairwise judgments, in exact integer arithmetic.
 *
 * Why Bradley-Terry: each judgment is a noisy "which mattered more?" answer between two items. BT models
 * P(i beats j) = w_i / (w_i + w_j) and finds the weights that best explain all the answers together, so
 * a win over a strong item counts for more than a win over a weak one, and sparse or uneven comparison
 * coverage still yields one consistent scale. Simple win-counting cannot do either.
 *
 * Weights are fitted by the MM algorithm (Hunter 2004): w_i <- W_i / sum_j n_ij / (w_i + w_j), where W_i
 * is i's total wins and n_ij the comparisons between i and j. A tie counts as half a win each way.
 *
 * A weak prior (one half-win each way for every pair) keeps every weight positive and finite even when an
 * item has never won, and makes an item nobody compared come out equal to the others. It matters little
 * once real judgments exist.
 *
 * Everything is BigInt fixed point (SCALE = 1e18) with a fixed iteration count, so every machine gets
 * bit-identical output.
 */
export const SCALE = 10n ** 18n;
export const BT_ITERATIONS = 1000;
export interface Comparison {
  a: number;
  b: number;
  /** 0 = a mattered more, 1 = b mattered more, 2 = about equal */
  outcome: 0 | 1 | 2;
}

/** Returns each item's weight, summing to exactly SCALE. */
export function bradleyTerry(items: number[], comps: Comparison[]): Map<number, bigint> {
  const k = items.length;
  const pos = new Map(items.map((id, i) => [id, i]));
  // Units are half-wins: a win is 2, a tie is 1 for each side, the prior is 1 for each side.
  const wins = new Array<bigint>(k).fill(0n);
  const n: bigint[][] = Array.from({ length: k }, () => new Array<bigint>(k).fill(0n));
  const add = (i: number, j: number, wi: bigint, wj: bigint) => {
    wins[i] += wi;
    wins[j] += wj;
    n[i][j] += wi + wj;
    n[j][i] += wi + wj;
  };
  for (let i = 0; i < k; i++) for (let j = i + 1; j < k; j++) add(i, j, 1n, 1n);
  for (const c of comps) {
    const i = pos.get(c.a), j = pos.get(c.b);
    if (i === undefined || j === undefined) throw new Error(`comparison ${c.a} vs ${c.b} involves an item outside [${items}]`);
    if (c.outcome === 0) add(i, j, 2n, 0n);
    else if (c.outcome === 1) add(i, j, 0n, 2n);
    else add(i, j, 1n, 1n);
  }
  if (k === 1) return new Map([[items[0], SCALE]]);

  let w = new Array<bigint>(k).fill(SCALE / BigInt(k));
  for (let it = 0; it < BT_ITERATIONS; it++) {
    const next = new Array<bigint>(k);
    let sum = 0n;
    for (let i = 0; i < k; i++) {
      let den = 0n; // sum_j n_ij / (x_i + x_j), scaled by SCALE
      for (let j = 0; j < k; j++) if (j !== i) den += (n[i][j] * SCALE * SCALE) / (w[i] + w[j]);
      next[i] = (wins[i] * SCALE * SCALE) / den;
      sum += next[i];
    }
    // normalise to SCALE; the last item absorbs the integer rounding so the total is exact
    let acc = 0n;
    for (let i = 0; i < k - 1; i++) {
      next[i] = (next[i] * SCALE) / sum;
      acc += next[i];
    }
    next[k - 1] = SCALE - acc;
    w = next;
  }
  return new Map(items.map((id, i) => [id, w[i]]));
}
