export const COMPARATOR = { gt: 0, gte: 1, lt: 2, lte: 3 } as const;
export const MARK = ["＞", "≥", "＜", "≤"] as const;
export const PHASE = ["OPEN", "CLOSED", "READING", "SETTLED", "VOID"] as const;
export const SIDE = ["—", "YES", "NO"] as const;

export const DEMO = {
  question: "Will ETH/USD print at least 4,000 when this desk settles?",
  jsonPath: ".price",
  target: 4000,
  comparator: "gte" as const,
  bettingSeconds: 180,
  resolveDelaySeconds: 60,
};
