// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ContractSignerValidation} from "./libraries/ContractSignerValidation.sol";

/**
 * @title MetaTxExample
 * @notice Demonstrates secure meta-transaction handling with replay attack protection
 * @dev Implements EIP-2771 for trusted forwarder pattern and EIP-712 for typed data signing
 */
contract MetaTxExample is ERC2771Context, EIP712 {
    using ECDSA for bytes32;
    using ContractSignerValidation for address;

    // ============ Type Hashes ============
    
    bytes32 public constant TRANSFER_TYPEHASH = keccak256(
        "Transfer(address from,address to,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    // ============ State ============

    /// @notice Nonces for replay protection per address
    mapping(address => uint256) public nonces;

    /// @notice Tracks used signatures to prevent replay across chains
    mapping(bytes32 => bool) public usedSignatures;

    // ============ Events ============

    event TransferExecuted(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 nonce
    );

    event NonceIncremented(address indexed user, uint256 newNonce);

    // ============ Errors ============

    error InvalidSignature();
    error SignatureExpired();
    error SignatureAlreadyUsed();
    error InvalidNonce();
    error TransferFailed();

    // ============ Constructor ============

    /**
     * @param trustedForwarder Address of the trusted meta-transaction forwarder
     */
    constructor(address trustedForwarder)
        ERC2771Context(trustedForwarder)
        EIP712("MetaTxExample", "1")
    {}

    // ============ Override Functions ============

    // Override to preserve original sender identity
    function _msgSender() internal view override(ERC2771Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    function _msgData() internal view override(ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    // ============ External Functions ============

    /**
     * @notice Get the current nonce for an address
     * @param user The user address
     * @return The current nonce
     */
    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    /**
     * @notice Get the domain separator for this contract
     * @return The domain separator
     */
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Execute a transfer via meta-transaction with signature verification
        * @dev Accepts ECDSA signatures from EOAs and bounded ERC-1271 responses from contract `from` accounts.
     * @param from The sender address
     * @param to The recipient address
     * @param amount The amount to transfer
     * @param deadline Signature expiration timestamp
     * @param signature The EIP-712 signature
     */
    function executeTransfer(
        address from,
        address to,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external {
        // Verify deadline
        require(block.timestamp <= deadline, "Signature expired");
        if (signature.length > 65) revert InvalidSignature();

        // Get current nonce
        uint256 currentNonce = nonces[from];

        // Build the struct hash for EIP-712
        bytes32 structHash = keccak256(abi.encode(
            TRANSFER_TYPEHASH,
            from,
            to,
            amount,
            currentNonce,
            deadline
        ));

        // Get the digest
        bytes32 digest = _hashTypedDataV4(structHash);

        // Check for replay
        require(!usedSignatures[digest], "Signature already used");

        // Recover signer from signature
        if (from.code.length == 0) {
            require(digest.recover(signature) == from, "Invalid signature");
        } else {
            require(from.isValidContractSignature(digest, signature), "Invalid signature");
        }

        // Mark signature as used
        usedSignatures[digest] = true;

        // Increment nonce
        nonces[from]++;

        // Execute transfer logic
        _executeTransfer(from, to, amount);

        // Emit events
        emit TransferExecuted(from, to, amount, currentNonce);
        emit NonceIncremented(from, nonces[from]);
    }

    /**
     * @notice Example function using meta-transactions (ERC2771 pattern)
     * @param to The recipient address
     * @param amount The amount to transfer
     * @dev This uses the ERC2771Context to get the real sender
     */
    function transfer(address to, uint256 amount) external {
        address sender = _msgSender();
        _executeTransfer(sender, to, amount);
        emit TransferExecuted(sender, to, amount, nonces[sender]++);
    }

    // ============ Internal Functions ============

    /**
     * @notice Internal transfer execution
     * @param from The sender address
     * @param to The recipient address
     * @param amount The amount to transfer
     * @dev Placeholder for actual transfer logic
     */
    function _executeTransfer(address from, address to, uint256 amount) internal {
        // Validate inputs
        require(from != address(0), "Invalid sender");
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");

        // Placeholder for actual transfer logic
        // In a real implementation, this would interact with an ERC20 token or similar
        // For this example, we just validate the parameters
    }
}
