import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Deploys the V2 final reward ledger.
 *
 * The governed module registry and SETTLEMENT registration are supplied by the
 * canonical deployment because this module must not manufacture authority.
 */
const FinalRewardAllocatorModule = buildModule("FinalRewardAllocatorModule", (m) => {
  const registry = m.getParameter("moduleRegistry");
  const maxRecipients = m.getParameter("maxRecipients", 64n);
  const allocator = m.contract("FinalRewardAllocator", [registry, maxRecipients]);

  return { allocator };
});

export default FinalRewardAllocatorModule;
