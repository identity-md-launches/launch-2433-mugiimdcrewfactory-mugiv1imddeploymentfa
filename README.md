# Mugi V1 IMD compatibility candidate

This source implements the authorized V1 compatibility redesign: constructor-only
finite token reserves, unrestricted wallet transfers with historical cutoff
accounting, no owner pause, and constructor-bound game dependencies. The core
nine-elimination game and future V2 protocol-fund handoff remain.

Read [ADAPTATION.md](ADAPTATION.md) for the exact changes, reserve supply effect,
preserved core rules and remaining trust/admission limits. Read
[the deployment graph](docs/IMD_CONSTRUCTOR_DEPLOYMENT.md) before preparing an IMD
launch. The four owner-bound factories and all nineteen descendants are disclosed.
The four-factory launch alone does not seed or activate the game.

```sh
forge build
forge test
python3 scripts/check-compatible-artifacts.py
```

Fork suites require `MUGI_IMD_MAINNET_FORK_RPC` and optionally
`MUGI_IMD_MAINNET_FORK_BLOCK`. Without the RPC they skip; local test success is
not a public deployment. Compiler settings and dependencies remain unchanged:
Solidity 0.8.26, Cancun, optimizer 200, via IR, bytecode hash none.

Final validation: **144 V1 tests and one separate actual-V2 integration test passed**.
See [the exact evidence and reproduction commands](docs/validation/compatible/VALIDATION.md).

Packaging review of 2026-10-22 (Foundry 1.8.4, no RPC): `forge build` passes and
`forge test` passes 142 tests with the two fork suites skipped; no Solidity source
changed. The imported audit findings, their reproduction and the resulting test and
documentation changes are listed in ADAPTATION.md under "Packaging review of
2026-10-22". The `check-compatible-artifacts.py` script needs a Python 3
interpreter, which this review machine did not have; its checks were not re-run here.

Revision of 2026-10-22 (reviewer findings): **Solidity source changed and must be
reviewed before deployment.** Settlement matched liquidity is now deferred when the
pool's spot tick is more than 488 ticks from the TWAP ending at the round cutoff,
and `abortPrelaunch` burns the unused reserve. The raw hook creation-code pin is now
`0x1cd53e485f1619d07454ecbfb17c53e45b8549b5bb500f4a4c66567cc38c626c` (24,923 B).
`forge build` and `forge test` pass: 146 tests, with the two fork suites skipped
when no RPC is set. With a mainnet RPC the three fork tests also pass. No new
tunable constant was introduced; the guard reuses the oracle's
`MAX_SPOT_DEVIATION_TICKS = 488` and `MIN_HISTORY = 15 minutes`. Only the first
cutoff is fixed at launch; each later cutoff is one day after the previous round's
final settlement batch. See ADAPTATION.md, "Revision of 2026-10-22".

Second revision of 2026-10-22 (reviewer finding `cbd2b1fb…`): **the price oracle
source changed and must be reviewed before deployment.** A pump held just over 15
minutes passed the guard above, because its reference started at the pump. The
settlement guard now uses the exact mean tick over the whole round ending at the
cutoff, from hourly checkpoints that swaps cannot evict. Buyback protection still
uses the 15-minute TWAP. The hook source, its creation-code pin
(`0x1cd53e48…c626c`, 24,923 B) and the main, crew and engine factories are
byte-identical. Only the oracle and `MugiIMDAccountingFactory` bytecode change.
New named constants in `MugiIMDPriceOracle`: `SETTLEMENT_WINDOW = 1 days`
(the round length), `CHECKPOINT_INTERVAL = 1 hours`, and 32 checkpoint slots.
`forge build` and `forge test` pass: 150 tests, with the two fork suites skipped
when no RPC is set. With a mainnet RPC the three fork tests also pass. See
ADAPTATION.md, "Second revision of 2026-10-22", for the residual properties: a pump
held for the whole round still passes, and a legitimate move of more than about 5%
from the round mean now defers that crew's matched share.

Source admission remains pending. Prior paid job
`6a953f2f-d28d-46cc-91a4-f348efed5c10` reviewed rejected source
`028d37769edce6e38324182b8909392a9852af16`, not this redesign. Historical reports
under `docs/validation` apply only to their recorded source pins.

V2 remains separate. Normal finale retires unused reserve and keeps player ETH
and token escrow in V1. A one-time V2 handoff sends only available protocol assets;
players can still claim in V1 during its 30-day window. V2 receives these funds
through its existing `receiveV1Finale` interface and launches independently.
No automatic holder-token swap is introduced.

No credentials/private RPC URLs belong in this repository. No explorer source
verification or public deployment is claimed by these documents.
