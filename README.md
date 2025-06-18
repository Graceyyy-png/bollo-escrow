# Smart Contract Escrow System

A decentralized escrow system built with Solidity and Hardhat that holds funds between two parties and releases them when all set agreements are made.

## Features

- **Secure Fund Holding**: Funds are locked in the smart contract until conditions are met
- **Multi-Party Agreement System**: Requires agreement from buyer and seller (or buyer and arbiter)
- **Dispute Resolution**: Built-in arbitration mechanism
- **Factory Pattern**: Easy deployment of multiple escrow contracts
- **State Management**: Clear state transitions (Awaiting Payment → Awaiting Delivery → Complete/Cancelled)
- **Event Logging**: Comprehensive event emission for tracking

## Smart Contracts

### Escrow.sol
Main escrow contract that handles:
- Payment deposits
- Agreement signing
- Fund release
- Dispute resolution
- Cancellation

### EscrowFactory.sol
Factory contract for creating and managing multiple escrow instances:
- Creates new escrow contracts
- Tracks all escrows
- Maps user escrows

## Setup

1. Install dependencies:
```bash
npm install
```

2. Compile contracts:
```bash
npm run compile
```

3. Run tests:
```bash
npm run test
```

4. Start local blockchain:
```bash
npm run node
```

5. Deploy contracts:
```bash
npm run deploy:localhost
```

## Usage

### Creating an Escrow

1. Deploy the EscrowFactory contract
2. Call `createEscrow()` with seller address, arbiter address, and amount
3. The factory returns the new escrow contract address

### Escrow Workflow

1. **Payment Deposit**: Buyer deposits the agreed amount
2. **Agreement Signing**: Both parties sign agreements
3. **Fund Release**: When sufficient agreements are collected, funds are released to seller
4. **Dispute Resolution**: If disputes arise, arbiter can resolve them

### Key Functions

#### Buyer Functions
- `depositPayment()`: Deposit funds to start escrow
- `confirmDelivery()`: Confirm delivery and sign agreement
- `signAgreement()`: Sign agreement
- `raiseDispute()`: Raise a dispute

#### Seller Functions
- `signAgreement()`: Sign agreement
- `raiseDispute()`: Raise a dispute

#### Arbiter Functions
- `signAgreement()`: Sign agreement
- `resolveDispute(bool)`: Resolve dispute in favor of buyer or seller
- `cancelEscrow()`: Cancel the entire escrow
- `raiseDispute()`: Raise a dispute

### State Management

- `AWAITING_PAYMENT`: Initial state, waiting for buyer payment
- `AWAITING_DELIVERY`: Payment received, waiting for agreements
- `COMPLETE`: All agreements signed, funds released
- `CANCELLED`: Escrow cancelled, funds returned to buyer

## Testing

Run the comprehensive test suite:
```bash
npm run test
```

Tests cover:
- Contract deployment
- Payment deposits
- Agreement signing
- Fund release
- Dispute resolution
- Access control
- Factory functionality

## Network Deployment

### Local Network
```bash
npm run deploy:localhost
```

### Sepolia Testnet
```bash
npm run deploy:sepolia
```

Make sure to set environment variables:
- `SEPOLIA_URL`: Sepolia RPC URL
- `PRIVATE_KEY`: Deployer private key
- `ETHERSCAN_API_KEY`: For contract verification

## Security Considerations

- All funds are held securely in the contract
- Access control prevents unauthorized actions
- State management prevents invalid transitions
- Reentrancy protection through state checks
- Events provide transparent audit trail

## License

MIT