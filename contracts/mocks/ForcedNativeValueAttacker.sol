// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ForcedNativeValueAttacker
 * @notice Adversarial fixture that forces native currency onto an arbitrary address (V2-SC-153).
 * @dev The transfer is performed by a contract that self-destructs in the very transaction that
 *      created it, which is the only construction that still moves the balance under EIP-6780
 *      (post-Cancun) semantics. Because the value is credited by the EVM and not by a call to the
 *      recipient, it works even when the recipient rejects every plain transfer in its
 *      `receive`/`fallback` hooks — which is exactly how the protocol's "forced ETH is inert"
 *      property has to be exercised.
 *      Test-only fixture: never deployed to a network.
 */
contract ForcedNativeValueAttacker {
    /// @notice Emitted after the forced transfer completes.
    /// @param target Recipient of the forced balance.
    /// @param amount Forced amount in wei.
    event NativeValueForced(address indexed target, uint256 amount);

    /// @notice Forcibly transfers `msg.value` wei onto `target`, bypassing its receive hooks.
    /// @param target Recipient of the forced balance.
    function forceNativeValue(address payable target) external payable {
        new SelfDestructingNativeValueSource{value: msg.value}(target);
        emit NativeValueForced(target, msg.value);
    }
}

/**
 * @title SelfDestructingNativeValueSource
 * @dev Created and destroyed inside a single transaction so that the whole balance is credited to
 *      `target` regardless of whether `target` accepts plain transfers.
 */
contract SelfDestructingNativeValueSource {
    /// @param target Recipient of the forced balance.
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}
