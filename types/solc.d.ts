/**
 * Minimal ambient declarations for the `solc` npm package (js-solc wrapper).
 * Only the surface used by scripts/generateStorageLayouts.ts is declared.
 */
declare module "solc" {
  export interface SolcBuild {
    version(): string;
    compile(input: string, callbacks?: unknown): string;
  }
  const solc: SolcBuild;
  export = solc;
}
