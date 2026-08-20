# Checks

```bash
cd hardhat
pnpm install
pnpm exec hardhat test
# 33 Solidity (PredictHarness) + 2 node walks (desk.walk.ts)
```

What those walks prove:

- YES book 3 vs NO 1, feed 4100 vs target 4000 → settled YES, winner takes 4
- jammed HTTP three times → VOID, ticket of 2 returned

```bash
cd web
pnpm install
pnpm build
pnpm dev
# GET /api/oracle/eth  → { "price": 4100, "pair": "ETH-USD", ... }
```

Chain 1979 is optional. The announcement says local work counts when RPC is dark.
