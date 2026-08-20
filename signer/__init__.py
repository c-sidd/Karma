"""Karma signer service.

Scores a wallet with the trained model, signs the result as an EIP-712
attestation, and hands back the exact calldata that submits it to ScoreOracle.

The private key lives in the environment and nowhere else. Nothing in this
package writes it to disk, logs it, or returns it over the API.
"""

__all__ = ["config", "attestation", "features_source", "store", "app"]
