# How this desk is wired

The contract is a **betting desk**. People write tickets (YES/NO). At a block chosen
when the market is filed, Ritual's Scheduler knocks. The knock is the only legal
wake-up.

Inside that one knock:

1. pick a TEE that advertised HTTP
2. GET the feed URL (`0x0801`)
3. jq a uint256 out of the JSON (`0x0803`)
4. compare to the frozen target
5. if the winning side is empty, void the book instead of dividing by zero

A transport miss is **not** a NO. Three misses void the book and tickets come back.

This fork also refuses loopback feeds (a TEE cannot fetch `localhost`), dust
tickets under `0.001` RITUAL, and jq paths that are only punctuation.

The UI is a paper desk, not a dark dashboard: file a market, seat the purse,
steer the wire, collect or return a ticket.
