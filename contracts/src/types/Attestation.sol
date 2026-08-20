// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice The payload a Karma model signer attests to.
/// @dev    Field order here is normative: it must match SCORE_TYPEHASH exactly,
///         and must match the ordering used by the Python signer.
struct Attestation {
    address wallet; // subject of the score; must equal the account being priced
    uint16 score; // 300..900, inclusive
    uint32 modelVersion; // monotonically increasing; retired versions are rejected
    bytes32 featureHash; // keccak256 over the canonical feature vector encoding
    uint64 expiry; // unix seconds; strictly greater than block.timestamp at submit
    uint256 nonce; // per-wallet, single use
}

/// @dev Evaluated at compile time. Never hardcode this as a literal: the string is
///      the single source of truth shared with the Python signer.
bytes32 constant SCORE_TYPEHASH = keccak256(
    "ScoreAttestation(address wallet,uint16 score,uint32 modelVersion,bytes32 featureHash,uint64 expiry,uint256 nonce)"
);

/// @dev keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
bytes32 constant EIP712_DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

/// @notice What the oracle keeps after a successful verification.
struct Record {
    uint16 score;
    uint32 modelVersion;
    uint64 expiry;
    uint64 issuedAt;
    address signer; // which registered model signer produced it
    bytes32 featureHash;
}
