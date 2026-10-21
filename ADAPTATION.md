# V1 compatibility adaptation and V2 handoff

This candidate supersedes the rejected mint/freeze/pause/bootstrap mechanics of
commit `028d37769edce6e38324182b8909392a9852af16` and the limited follow-up
`94d78364e3efcf5fa5c7ccf8f3727f2abf6b1085`. The owner explicitly requested the
IMD-compatible fixes while retaining the core V1 game and future V2 handoff.
Platform admission is pending. This document does not claim a public deployment.

## Preserved game rules

Ten crews, the 95/5 initial LP/airdrop allocation, fixed daily cutoffs, one VRF
outcome per round, nine eliminations, 75% loser conversion across survivors,
pro-rata treasure rewards, LP redistribution, bounded buybacks, team fees,
permissionless timeout recovery and the 30-day final claim window remain.
The game modules use ordinary CALL. There is no proxy or delegatecall route.

## Removed capabilities and their replacements

| IMD adaptation rule | Source change | Observable consequence |
| --- | --- | --- |
| No post-launch token minting | Every crew token mints its entire finite reserve once in its constructor. The hook releases separately tracked reserve for the existing conversions and LP reinforcements. No external mint selector exists. | ERC20 totalSupply includes the unused reserve. It is not circulating supply. Eligibility excludes all protocol custodians. Untouched reserve is burned when that crew exits or the game closes. |
| No holder freezes or confiscation | ERC20 transfers have no hook callback; only the token holder can burn its own balance. | Transfers remain possible at cutoff, after elimination and after finale. Dead crew tokens confer no new game rights. Official game pools still enforce the published round/alive rules. |
| Preserve cutoff ownership without freezing | Tokens record balance/supply history; the ledger reads strictly before each original scheduled cutoff. | A transfer or burn exactly at cutoff or after a known result cannot move or duplicate that round's entitlement. Token materialization waits during resolution; ETH claims remain available under their existing rules. |
| No owner pause | The pause state, selector and checks are removed. | The owner cannot halt live gameplay. Fixed cutoffs and deterministic VRF timeout recovery remain. |
| Constructor configuration without later initialization | Tokens, hook, ledger and dependencies receive final bindings in their constructors. Fixed CREATE child addresses break circular dependencies; the hook uses a mined CREATE2 address. Crew names/symbols are derived internally from crew ID, so deployed child constructors also use only static arguments. | No initialize/configure/bindAccounting/setExcluded selector is present in the new hook/token/ledger route. Later transactions create complete applications; the initial four factories alone do not mean the game is live. |
| Empty-chain constructor simulation | Constructors use only supplied values, hashes and pure address derivation. Live dependency checks run before seeding/use. | Factories and children can be constructed before dependent code exists. Missing/mismatched dependencies prevent economic activation. |

The reserve proof is in `src/game/MugiReserveMath.sol`: with initial allocation
I and M=int128.max, 10I+100M covers the bounded nine-round origin supply and
conversion rounding. Claims consume existing backing; they do not release a
second reserve allocation. Unused reserve can never be withdrawn or migrated.

## V1 to V2 remains possible

V2 is a separate implementation and admission/deployment task. V1 may be launched
with a zero future target. After ordinary V1 finale, the owner selects a deployed
receiver once using `migrateToV2`. If a nonzero target was constructor-pinned,
only that target is accepted. The receiver implements
`receiveV1Finale(uint8,address,uint256)` and is funded atomically with available
finale ETH and survivor inventory.

Before this handoff, finale removes the last V4 position, freezes final accounting
at its original cutoff and burns unused survivor reserve. Migration subtracts
reserved player ETH and team ETH, and subtracts earned-token escrow from survivor
inventory. Player token/ETH claims remain in V1 through their published window.
A rejecting receiver rolls back the migration flag and both asset transfers.
Emergency closure retains its player refund path and does not migrate to V2.

This is protocol-fund continuity, not an automatic 1:1 holder-token conversion.
V2 chooses and funds its own token supply. The current actual V2 receiver allows
V1 funds to arrive before its token is configured; activation is separate.

## Explicit remaining trust and admission limits

- A zero V2 target retains owner discretion over the final receiver. One-shot
  migration protects reserved claims, but does not constrain that receiver's
  later use of protocol funds or promise holder redemption.
- Constructor inputs still select the external VRF coordinator/subscription,
  airdrop attestor and IMD verifier signer. No mock service is a launch parameter.
  Hook dependencies are fixed at construction; factory provenance and external
  service settings must be checked against the published deployment graph.
- Four manifest contracts create nineteen disclosed application descendants in
  later transactions. IMD must admit that application-creation flow and the
  official pool/claim timing rules. Do not infer admission from compilation or
  an accepted audit report.
- V2's present constructor/configuration path has not been adapted or admitted
  by this V1 change. The narrow handoff interface is preserved and tested.
- There is no explorer source verification and no direct-deployment fallback.

See `docs/IMD_CONSTRUCTOR_DEPLOYMENT.md` for creation order and deterministic
bindings, and `docs/validation/compatible/VALIDATION.md` for current test evidence.
Earlier audit/validation documents describe their historical source pins only.

## Packaging review of 2026-10-22 (contracts-only manifest)

This pass packaged the exact reviewed source for the four-factory `evm_contracts`
launch and reproduced the imported audit of commit `9901dc7`. Outcome: **no
Solidity source changed**. Every file under `src/` is byte-identical to the
reviewed candidate, so the raw hook creation-code pin, compiler settings
(0.8.26, Cancun, optimizer 200, via IR, bytecode hash none), authorities and
the disclosed 4-factory/19-descendant graph are unchanged. The manifest in
`launch.json` is the one the request carries: four owner-bound factories in
order, each with the single static owner `0x20714d50f4675c366de30b603728a90ddddb240f`.
No explorer source verification is requested or performed.

### Audit findings reproduced against this tree

| Finding | Reproduced? | Action in this pass |
| --- | --- | --- |
| Medium: zero V2 pin lets the owner route finale ETH and survivor inventory to any code-bearing receiver, including one forwarding to the owner | Yes. `migrateToV2` checks only `Finalized`, not-yet-migrated and `target.code.length != 0` when the constructor pin is zero. | Preserved: the request specifies "a zero constructor target allows the owner to choose a future receiver; a nonzero pin is enforced". Recorded here as an owner trust assumption and proven by `testOrdinaryFinaleResidualStaysOwnerGatedAndZeroPinAcceptsAnyReceiver` in `test/imd/lifecycle/MugiCompatibilityHandoff.t.sol`. A reviewed nonzero pin in the hook tuple removes this discretion at hook creation. |
| Medium: `finalize()` records no reward round for surviving-crew holders; the removed survivor LP principal, its treasure, own-buyback budget and unallocated dust have only the owner-only `migrateToV2` exit, with no deadline or permissionless fallback | Yes. After the 30-day sweep only `ledger.reservedEth()` reaches the community treasury; the residual stays until the owner migrates. | Preserved: the request defines the finale as "retains player token backing and reserved player/team ETH, then permits an owner-only one-shot atomic handoff of only available inventory/ETH". The final round's LP ETH is therefore V2 continuity funding, not a holder distribution, and the same test proves it. If the owner key is lost that residual is unrecoverable. Adding a time-bounded permissionless fallback is a source change outside this packaging pass and would alter the pinned hook code; it is listed as an open design decision for the requester before the five child transactions. |
| Medium: planned hook constants set `teamTreasury == communityTreasury == owner` | Yes, in `hook-constructor.json` only; Solidity accepts equal addresses. | Disclosed, not changed. The launch rules send any treasury share the brief does not name to the owner, and the brief names no community wallet, so a different address would be a stand-in. With these constants expired player claims, emergency unallocated shares and team fees all land in the owner wallet; the hook comment "neither can be redirected to owner" describes the immutable binding, not a distinct beneficiary. Recorded in `hook-constructor.json` `disclosures`. The requester may supply a distinct community address before the hook tuple is encoded. |
| Low: excluding the PoolManager singleton strips cutoff eligibility from holders who LP a crew token in any third-party Uniswap v4 pool | Yes by construction. `MugiIMDLedger` subtracts `balanceBefore(manager)`; v4 keeps every pool's tokens in that one singleton. | Preserved and disclosed: the official pools hold about 95% of each initial allocation inside the same singleton, so counting the manager would hand most rewards to the protocol's own LP. Only wallet (and non-v4 contract) balances earn; tokens in any v4 pool, official or not, do not. |
| Low: the four-factory gas-headroom test metered 26,942 gas because forge does not charge creation costs for `new` issued by the test contract | Yes. A scratch probe showed 3,515 gas for `new MugiV1IMDDeploymentFactory` inside the test and 12,261,935 gas for the same four creations through a separate contract. | Fixed in `test/imd/MugiV1IMDDeploymentFactory.t.sol`: the batch now runs by CREATE2 inside `FactoryBatchProbe`, asserts the metered gas is at least the EIP-170/EIP-3860/CREATE2 floor, and estimates the launch transaction (execution + all-nonzero calldata + 21k + 1M factory bookkeeping) at about 14.67M gas, below 16,777,216. `docs/IMD_CONSTRUCTOR_DEPLOYMENT.md` no longer calls the old number a conservative bound. The deployer's simulation of the real ProjectFactory call remains authoritative. |
| Info: every swap in all ten official pools reverts from each round cutoff until settlement completes, while wallet transfers continue | Yes. `beforeSwap` calls `_requireLive`. | Disclosed below under "Official-pool gates". No change. |
| Info: scope and checks performed | Not a defect. | Local re-run recorded in README. The protected opcode scan was rehearsed in a scratch test over the four CREATE2-deployed factory runtimes: no reachable DELEGATECALL, CALLCODE or SELFDESTRUCT. |

### Official-pool gates are not ERC20 freezes

The ten crew tokens never consult the hook: `transfer`, `transferFrom` and
`burn` work in every phase, including at a cutoff, after elimination and after
the finale, and third-party pools keep working. Separately, the hook's own ten
Uniswap v4 pools enforce the published game timing: from `nextCutoff` until the
final `settleRound` batch, and in every phase other than `Live`, a swap through
an official pool reverts with `InvalidState`; dead crews' pools also hold no
liquidity after `_beginSettlement`. The halt length depends on when
`requestElimination` and `settleRound` are called and on VRF latency (up to the
seven-day timeout before permissionless recovery). Token reward materialization
and buyback approval share the same `Live`-before-cutoff gate; ETH claims only
require a phase after `Setup` and before claim expiry. These are venue rules on
protocol-owned liquidity, not holder restrictions.

### Changes in this pass

| File | Change | Reason |
| --- | --- | --- |
| `test/imd/MugiV1IMDDeploymentFactory.t.sol` | `FactoryBatchProbe` and a rewritten `testFactoryCreationBatchHasConservativeGasHeadroom` | Reproduced low finding: metered creation cost must include code deposit. |
| `test/imd/lifecycle/MugiCompatibilityHandoff.t.sol` | `ForwardingSink` and `testOrdinaryFinaleResidualStaysOwnerGatedAndZeroPinAcceptsAnyReceiver` | Makes the two preserved medium findings verifiable rather than asserted. |
| `hook-constructor.json` | `disclosures` entries | Treasury/owner coincidence and zero V2 pin consequences for the live tuple. |
| `docs/IMD_CONSTRUCTOR_DEPLOYMENT.md` | Gas sentence | The old assertion did not measure creation cost. |
| `README.md`, this file, `inventory.json` | Review record and refreshed file hashes | Packaging. |

No file under `src/`, `foundry.toml`, `remappings`, `lib/` or `launch.json` changed.

## Official rules checked

- [Contract adaptation](https://api.imd.fun/reads/skill/adapt-contract-project)
- [Contracts-only launch](https://api.imd.fun/reads/skill/evm-contracts-launch)

The no-initialization rule is addressed by constructor-complete children, not by
hiding descendants. Admission still needs IMD review of the disclosed graph.
