import { BaseError, ContractFunctionRevertedError } from "viem";

/**
 * Pull the contract's own error name out of a viem failure.
 *
 * The verification panel's whole argument depends on showing `BadSigner()`
 * rather than "execution reverted", so this walks the error chain for the
 * decoded custom error and falls back to something honest if it is not there.
 */
export type DecodedRevert = {
  errorName: string | null;
  args: readonly unknown[];
  message: string;
};

export function decodeRevert(error: unknown): DecodedRevert {
  if (error instanceof BaseError) {
    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      const name = reverted.data?.errorName ?? null;
      return {
        errorName: name,
        args: reverted.data?.args ?? [],
        message: name ? `${name}()` : reverted.shortMessage,
      };
    }
    return { errorName: null, args: [], message: error.shortMessage || error.message };
  }
  if (error instanceof Error) {
    return { errorName: null, args: [], message: error.message };
  }
  return { errorName: null, args: [], message: String(error) };
}

/** True when the user dismissed the wallet prompt, which is not a failure. */
export function isUserRejection(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /user rejected|denied transaction|user denied/i.test(message);
}
