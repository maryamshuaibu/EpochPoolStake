# EpochPoolStake

A Stacks blockchain smart contract system for pooled staking with epoch-based rewards and governance.

## Overview

This project implements three main contracts:

- **EpochPoolStake**: Core staking contract that handles STX deposits and mints stSTX tokens
- **EpochRewardsDistributor**: Manages reward distribution for staked STX
- **EpochGovernance**: Provides governance functionality based on stake weight

## Contract Features

### EpochPoolStake
- Stake STX and receive stSTX tokens
- Unstake with cooldown period
- Delegation support
- Epoch-based rewards
- Emergency pause mechanism

### EpochRewardsDistributor
- Secure reward distribution
- Epoch management
- Share-based calculations

### EpochGovernance
- Proposal creation and voting
- Stake-weighted voting power
- Proposal status tracking

## Development Environment

- Clarity version: 3
- Stacks epoch: 3.1

## Project Structure
```
├── contracts/
│   ├── EpochPoolStake.clar
│   ├── EpochRewardsDistributor.clar
│   └── EpochGovernance.clar
├── tests/
│   ├── EpochPoolStake.test.ts
│   ├── EpochRewardsDistributor.test.ts
│   └── EpochGovernance.test.ts
└── settings/
    └── Devnet.toml
```

## Testing

Run tests using:
```bash
npm test
```

For detailed reports:
```bash
npm run test:report
```

## Contract Deployment

The project uses Clarinet for development and testing. Contracts should be deployed in the following order:

1. EpochPoolStake
2. EpochRewardsDistributor
3. EpochGovernance

## Development Tools

- Clarinet
- Vitest for testing
- TypeScript for test files