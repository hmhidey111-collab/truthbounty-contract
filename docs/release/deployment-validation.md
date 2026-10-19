# Deployment Validation

## Purpose

This document defines the deployment verification steps required before a production release.

## Automated Validation

The deployment verification script validates:

- Contract deployment addresses
- Token configuration
- Oracle configuration
- Staking configuration
- Claims configuration
- Migration manager verification

## Configuration Binding (Pre-Broadcast)

Before the first transaction of a deployment batch is broadcast, the configuration must be
bound through `DeploymentConfigBinder`. The binding explicitly captures:

- Chain ID (must match the binder's immutable `boundChainId` and the live `block.chainId`)
- Release ID
- Configuration checksum
- Broadcaster address (must be explicitly authorized)
- Nonce plan (`nonceStart`, `nonceCount`)
- Expiry timestamp

Validation completes before the first transaction. Configurations cannot be replayed
across chain or release. Errors reveal no secret material.

## Manual Validation

Operators should additionally verify:

- Governance ownership
- Treasury ownership
- Role assignments
- Upgrade permissions
- Emergency controls
- Network configuration
- Deployment artifacts

## Release Requirement

Deployment validation must complete successfully before any release candidate progresses to
governance approval or mainnet deployment.
