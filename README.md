# Uniswap V2 Protocol

A consolidated Foundry project containing the full Uniswap V2 protocol — core contracts, periphery contracts, and a complete Forge test suite ported from the original Waffle/TypeScript specs.

## Repository Layout

```
src/
├── core/                          # UniswapV2Factory, UniswapV2Pair, UniswapV2ERC20
│   ├── interfaces/
│   ├── libraries/                 # Math, SafeMath, UQ112x112
│   └── test/                     # Minimal ERC20 for testing
└── periphery/                     # UniswapV2Router01, UniswapV2Router02, UniswapV2Migrator
    ├── examples/                  # ExampleFlashSwap, ExampleOracleSimple,
    │                              # ExampleSlidingWindowOracle, ExampleComputeLiquidityValue,
    │                              # ExampleSwapToPrice
    ├── interfaces/
    ├── libraries/                 # UniswapV2Library, UniswapV2OracleLibrary,
    │                              # UniswapV2LiquidityMathLibrary
    └── test/                      # WETH9, DeflatingERC20, RouterEventEmitter

test/
├── core/                          # UniswapV2ERC20, UniswapV2Factory, UniswapV2Pair,
│                                  # UniswapV2Router (Router01 + Router02 + FOT tokens)
└── periphery/                     # ExampleFlashSwap, ExampleOracleSimple,
    │                              # ExampleSlidingWindowOracle, ExampleComputeLiquidityValue,
    │                              # ExampleSwapToPrice, UniswapV2Migrator
    └── helpers/
        └── MockUniswapV1.sol      # Solidity mock of the Uniswap V1 Vyper AMM

lib/
├── forge-std/                     # foundry-rs/forge-std @ v1.15.0
└── uniswap-solidity-lib/          # aegis-finance/uniswap-solidity-lib @ 19ca8f7
```

## Dependencies

| Library | Source | Commit |
|---------|--------|--------|
| `forge-std` | [foundry-rs/forge-std](https://github.com/foundry-rs/forge-std) | v1.15.0 |
| `@uniswap/lib` | [aegis-finance/uniswap-solidity-lib](https://github.com/aegis-finance/uniswap-solidity-lib) | `19ca8f7` |

## Remappings

```
@uniswap/lib          → lib/uniswap-solidity-lib/
@uniswap/v2-core/contracts → src/core/
@uniswap/v2-periphery/ → src/periphery/
forge-std/            → lib/forge-std/src/
```

## Solidity Versions

| Component | Version |
|-----------|---------|
| Core contracts | `=0.5.16` |
| Periphery contracts | `=0.6.6` |
| Forge tests | `^0.8.13` |

## Usage

### Setup

```shell
git clone --recurse-submodules https://github.com/aegis-finance/uniswap-v2-protocol
```

### Build

```shell
forge build
```

### Test

```shell
forge test
```

121 tests across 11 suites — all passing (0 failed, 0 skipped).

| Suite | Tests |
|-------|-------|
| `UniswapV2ERC20` | 8 |
| `UniswapV2Factory` | 8 |
| `UniswapV2Pair` | 19 |
| `UniswapV2Router` (Router01 + Router02 + FOT) | 30 |
| `ExampleFlashSwap` | 2 |
| `ExampleOracleSimple` | 1 |
| `ExampleSlidingWindowOracle` | 18 |
| `ExampleComputeLiquidityValue` | 24 |
| `ExampleSwapToPrice` | 8 |
| `UniswapV2Migrator` | 1 |
| `Counter` | 2 |

### Gas Snapshots

```shell
forge snapshot
```

### Verbose test output

```shell
forge test -vvv
```

### Run a single test

```shell
forge test --match-test testFuzz_swapInvariant -vvvv
```

## Key Implementation Notes

- **INIT_CODE_HASH** in `src/periphery/libraries/UniswapV2Library.sol` is set to the locally-compiled `UniswapV2Pair` bytecode hash. If pair bytecode changes, recompute with `forge inspect UniswapV2Pair bytecode | cast keccak` and update line 24.
- **Flash swaps** and **V1 migration** tests use `MockUniswapV1.sol` — a Solidity reimplementation of the original Vyper AMM — to avoid depending on pre-compiled Vyper artifacts.
- **Fee-on-transfer** token tests use `DeflatingERC20` from `src/periphery/test/`.

## References

- [Uniswap V2 Core](https://github.com/Uniswap/v2-core)
- [Uniswap V2 Periphery](https://github.com/Uniswap/v2-periphery)
- [Foundry Book](https://book.getfoundry.sh/)
