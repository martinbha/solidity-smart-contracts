## ERC-6551 token-bound accounts

The ERC-6551 example gives each profile NFT a deterministic smart-contract
account. `ERC6551Registry` deploys the standard ERC-1167 proxy bytecode with an
immutable token tuple appended to it, so the address can be calculated before
deployment. `TokenBoundAccount` reads that tuple from its proxy code and looks
up the NFT's current owner whenever authority is checked. Transferring the NFT
therefore transfers control of every asset in its account without moving those
assets individually.

The account accepts ETH and safe ERC-721 transfers, can call contracts and send
assets, and increments `state` after every successful call. It rejects any call
that would make it directly own its controlling NFT. Longer ownership cycles
across multiple token-bound accounts remain an application-level concern, as
described by ERC-6551.

Run the complete local demonstration:

```shell
anvil
./utils/nft/erc6551/deploy_6551.sh
```

The script funds a profile's account with ETH and ERC-20 tokens, transfers the
profile from Alice to Bob, proves Alice immediately loses execution access, and
has Bob send both assets from the same account.

## EIP-7702 batch delegation

`BatchDelegate` gives an EOA an atomic multicall surface while preserving the
EOA's address, balance, and signing key. EIP-7702 executes the implementation
in the account's context, so downstream contracts see the EOA as `msg.sender`
and value-bearing calls spend the EOA's ETH.

The delegate only accepts self-calls. A transaction signed by the delegated
account can execute a batch, while an unrelated caller cannot exercise the
account's authority. If any sub-call fails, the whole batch rolls back.
Delegation persists until the account replaces or clears it, so only designate
code that has been reviewed and whose storage layout remains compatible with
the account's existing delegated state.

Run the local demonstration:

```shell
anvil --hardfork prague
./utils/accounts/eip7702/deploy_7702.sh
```

The script deploys the implementation, authorizes it for an Anvil EOA, executes
an ERC-20 approval and transfer in one transaction, and verifies the account's
delegation designator, allowance, and balances.

## EIP-1153 transient storage

The transient-storage examples use state that is shared across calls in one
transaction and automatically discarded at transaction end:

- `TransientReentrancyGuard` implements a conventional reset-after-call guard
  with Solidity's `transient` storage location.
- `StorageReentrancyGuard` provides an equivalent persistent-storage baseline
  for direct gas comparisons.
- `FlashAccountant` opens one callback lock, lets the locker take ERC-20 assets,
  tracks each debt in a derived `tstore` slot, and reverts the whole session
  unless every token debt is repaid exactly.

The flash-accounting lock rejects nested sessions, but a contract may open a
new session after the previous one settles and closes, including later in the
same transaction. Only the current callback contract can take or settle
assets. The accountant verifies its exact balance decrease and increase, so an
unexpected sender fee or fee-on-transfer repayment reverts the session.

Run the live demonstration on a local EVM with EIP-1153 support:

```shell
anvil --hardfork osaka
./utils/evm/transient/deploy_transient.sh
```

The script verifies a settled session, confirms an unsettled session reverts,
and prints transient-versus-storage guard gas estimates. The Foundry test also
prints a reproducible comparison with `forge test --match-test
test_transientGuardCostsLessGasThanStorageGuard -vv`.

## Optimistic oracle

The optimistic-oracle example turns truth into a bonded challenge game. An
asserter posts a fixed ERC-20 bond and chooses a value. If nobody disputes it
before the deadline, anyone can settle that value and return the bond through
the pull-payment ledger. A disputer posts the same bond and sends the claim to
the resolver; whichever side matches the resolved truth receives both bonds.

`OptimisticOracle` verifies exact token movement and exposes escrowed and
withdrawable totals so its solvency can be checked continuously. The stateful
invariant tests randomly assert, dispute, settle, resolve, withdraw, and advance
time while proving that no bonded value is created or lost. `InsurancePool`
demonstrates a consumer that pays only the named policyholder and only after
the corresponding claim resolves true.

The resolver is a trusted address in this teaching implementation. A
production design can replace that decision point with token-holder voting or
another decentralized verification mechanism without changing the optimistic
undisputed path.

Run both the undisputed insurance payout and disputed-resolution flows locally:

```shell
anvil
./utils/oracle/deploy_oracle.sh
```

The script verifies early payout rejection, challenge-window settlement, the
insurance payout, resolver-only dispute handling, winner-takes-both bond
accounting, and the oracle's final zero balance.

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
