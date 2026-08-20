// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Guarded} from "./Guarded.sol";
import {Attestation, Record, SCORE_TYPEHASH, EIP712_DOMAIN_TYPEHASH} from "./types/Attestation.sol";

/// @title  ScoreOracle
/// @notice The only way a credit score enters Karma.
///
/// @dev The whole protocol rests on one property: a score is worth nothing until this
///      contract has recovered an ECDSA signature over it from a registered model
///      signer. Everything below exists to close a specific way of faking that:
///
///        - EIP-712 domain binds chainId and address(this)  -> no cross-chain or
///          cross-deployment replay of an otherwise valid attestation.
///        - Per-wallet single-use nonce                     -> no replay of a stale score.
///        - expiry checked against block.timestamp          -> scores go stale by default.
///        - s forced into the lower half of the curve       -> no signature malleability.
///        - v restricted to {27, 28}                        -> no ecrecover quirks.
///        - ecrecover result checked against the signer set -> a tampered field recovers
///          some other address and reverts with BadSigner().
///
///      There is deliberately no owner function that writes a Record directly.
contract ScoreOracle is Guarded {
    error BadSigner();
    error BadSignatureLength();
    error BadSignatureV();
    error MalleableSignature();
    error AttestationExpired();
    error NonceAlreadyUsed();
    error ScoreOutOfRange();
    error StaleModelVersion();
    error NoAttestation();
    error ExpiryTooFar();
    error ZeroWallet();

    /// @dev secp256k1 group order / 2. Signatures with a higher `s` are the mirrored
    ///      twin of a valid one; accepting both would make the signature non-unique.
    uint256 private constant HALF_CURVE_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    uint16 public constant MIN_SCORE = 300;
    uint16 public constant MAX_SCORE = 900;

    /// @notice Upper bound on how long an attestation may stay valid.
    uint64 public constant MAX_ATTESTATION_TTL = 7 days;

    string public constant DOMAIN_NAME = "Karma";
    string public constant DOMAIN_VERSION = "1";

    uint256 private immutable _cachedChainId;
    bytes32 private immutable _cachedDomainSeparator;

    /// @notice Addresses whose signatures the protocol accepts as model output.
    mapping(address => bool) public isModelSigner;
    /// @notice Oldest model version still accepted. Retires a compromised model.
    uint32 public minModelVersion;

    mapping(address => Record) private _records;
    mapping(address => mapping(uint256 => bool)) private _usedNonce;

    event ModelSignerSet(address indexed signer, bool allowed);
    event MinModelVersionSet(uint32 version);
    event AttestationStored(
        address indexed wallet,
        address indexed signer,
        uint16 score,
        uint32 modelVersion,
        bytes32 featureHash,
        uint64 expiry,
        uint256 nonce
    );

    constructor(address guardian_, address initialModelSigner) Guarded(guardian_) {
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
        if (initialModelSigner != address(0)) {
            isModelSigner[initialModelSigner] = true;
            emit ModelSignerSet(initialModelSigner, true);
        }
    }

    // ------------------------------------------------------------ EIP-712

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        // Rebuild if we have been forked onto another chain: the cached separator
        // would otherwise keep validating signatures meant for the original chain.
        return block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(DOMAIN_NAME)),
                keccak256(bytes(DOMAIN_VERSION)),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice The exact 32 bytes a model signer signs. Exposed so the UI can show the
    ///         digest it is about to submit rather than asking anyone to trust it.
    function hashAttestation(Attestation calldata a) public view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR(), _structHash(a)));
    }

    function _structHash(Attestation calldata a) private pure returns (bytes32) {
        return
            keccak256(abi.encode(SCORE_TYPEHASH, a.wallet, a.score, a.modelVersion, a.featureHash, a.expiry, a.nonce));
    }

    // ------------------------------------------------------------ verification

    /// @notice Recover the signer of `signature` over `a` without touching storage.
    /// @dev Same code path as submitAttestation, so a UI static-call surfaces exactly
    ///      the error the real transaction would revert with.
    function recoverAttestationSigner(Attestation calldata a, bytes calldata signature) public view returns (address) {
        return _recover(hashAttestation(a), signature);
    }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) revert BadSignatureLength();

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        if (uint256(s) > HALF_CURVE_ORDER) revert MalleableSignature();
        if (v != 27 && v != 28) revert BadSignatureV();

        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0)) revert BadSigner();
        return recovered;
    }

    /// @notice Verify a signed score and store it. Callable by anyone: the signature,
    ///         not the sender, is the authority.
    function submitAttestation(Attestation calldata a, bytes calldata signature) external whenNotPaused {
        if (a.wallet == address(0)) revert ZeroWallet();
        if (a.score < MIN_SCORE || a.score > MAX_SCORE) revert ScoreOutOfRange();
        if (a.expiry <= block.timestamp) revert AttestationExpired();
        if (a.expiry > block.timestamp + MAX_ATTESTATION_TTL) revert ExpiryTooFar();
        if (a.modelVersion < minModelVersion) revert StaleModelVersion();
        if (_usedNonce[a.wallet][a.nonce]) revert NonceAlreadyUsed();

        address signer = _recover(hashAttestation(a), signature);
        if (!isModelSigner[signer]) revert BadSigner();

        _usedNonce[a.wallet][a.nonce] = true;
        _records[a.wallet] = Record({
            score: a.score,
            modelVersion: a.modelVersion,
            expiry: a.expiry,
            issuedAt: uint64(block.timestamp),
            signer: signer,
            featureHash: a.featureHash
        });

        emit AttestationStored(a.wallet, signer, a.score, a.modelVersion, a.featureHash, a.expiry, a.nonce);
    }

    // ------------------------------------------------------------ reads

    /// @notice Score for `wallet`, or revert. LendingPool.borrow uses this and nothing else.
    function requireValidScore(address wallet) external view returns (uint16) {
        Record memory rec = _records[wallet];
        if (rec.expiry == 0) revert NoAttestation();
        if (rec.expiry <= block.timestamp) revert AttestationExpired();
        if (rec.modelVersion < minModelVersion) revert StaleModelVersion();
        return rec.score;
    }

    /// @notice Non-reverting read for UIs.
    function scoreOf(address wallet) external view returns (uint16 score, bool valid) {
        Record memory rec = _records[wallet];
        valid = rec.expiry > block.timestamp && rec.modelVersion >= minModelVersion;
        score = rec.score;
    }

    function attestationOf(address wallet) external view returns (Record memory) {
        return _records[wallet];
    }

    function isNonceUsed(address wallet, uint256 nonce) external view returns (bool) {
        return _usedNonce[wallet][nonce];
    }

    // ------------------------------------------------------------ governance

    function setModelSigner(address signer, bool allowed) external onlyOwner {
        if (signer == address(0)) revert ZeroWallet();
        isModelSigner[signer] = allowed;
        emit ModelSignerSet(signer, allowed);
    }

    /// @notice Retire every model version below `version`. Existing stored records at a
    ///         retired version stop satisfying requireValidScore immediately.
    function setMinModelVersion(uint32 version) external onlyOwner {
        minModelVersion = version;
        emit MinModelVersionSet(version);
    }
}
