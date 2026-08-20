# Note

I got stuck on the Scheduler callback being **revert-free**.

If `onScheduledResolve` reverts on a bad HTTP envelope, `attempts` never
increments and the market cannot become VOID. Decode goes through
`try this.decodeHttpResponse` so garbage bytes become a recorded miss.
Only `msg.sender != Scheduler` is allowed to revert.

A compile snag: HTTP stub fallback cannot be `payable` if tests cast the
precompile address to the stub type. jq stub fallback cannot be `view`.
Both are plain `fallback()` now. `pnpm exec hardhat test` then went green.
