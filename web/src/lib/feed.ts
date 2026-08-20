let n = 4100;
let t = Date.now();

export function readFeed() {
  return { price: n, pair: "ETH-USD", asOf: t, desk: "spot" };
}

export function writeFeed(v: number) {
  if (!Number.isFinite(v) || v < 0) throw new Error("bad print");
  n = Math.round(v);
  t = Date.now();
  return readFeed();
}
