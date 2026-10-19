// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library DeploymentPreflight {
    error WrongChain(uint256 expectedChainId, uint256 actualChainId);
    error WrongDeployer(address expectedDeployer, address actualDeployer);
    error InsufficientBalance(address account, uint256 required, uint256 actual);
    error ZeroAddress(string label);
    error MissingTimelock(string context);
    error StaleArtifact(string artifactPath, bytes32 expectedHash, bytes32 actualHash);
    error IncompatibleModules(string context);

    function requireExpectedChainId(uint256 expectedChainId) internal view {
        if (block.chainid != expectedChainId) revert WrongChain(expectedChainId, block.chainid);
    }

    function requireDeployer(address expectedDeployer, address actualDeployer) internal pure {
        if (actualDeployer != expectedDeployer) revert WrongDeployer(expectedDeployer, actualDeployer);
    }

    function requireSufficientBalance(address account, uint256 minimumBalance) internal view {
        if (account.balance < minimumBalance) revert InsufficientBalance(account, minimumBalance, account.balance);
    }

    function requireNonZeroAddress(address value, string memory label) internal pure {
        if (value == address(0)) revert ZeroAddress(label);
    }

    function requireTimelock(address timelock, string memory context) internal pure {
        if (timelock == address(0)) revert MissingTimelock(context);
    }

    function requireArtifactFreshness(bytes32 actualArtifactHash, bytes32 expectedArtifactHash, string memory artifactPath)
        internal
        pure
    {
        if (expectedArtifactHash != bytes32(0) && actualArtifactHash != expectedArtifactHash) {
            revert StaleArtifact(artifactPath, expectedArtifactHash, actualArtifactHash);
        }
    }

    function requireCompatibleModules(address moduleA, address moduleB, address timelock) internal pure {
        requireNonZeroAddress(moduleA, "moduleA");
        requireNonZeroAddress(moduleB, "moduleB");
        requireTimelock(timelock, "module compatibility");
        if (moduleA == moduleB) revert IncompatibleModules("duplicate module addresses");
    }
}
