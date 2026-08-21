// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Guarded} from "./Guarded.sol";
import {Attestation, Record, SCORE_TYPEHASH, EIP712_DOMAIN_TYPEHASH} from "./types/Attestation.sol";

/// @title ScoreOracle
/// @notice Cryptographically verified AI credit-score oracle with signer quorum and model provenance.
contract ScoreOracle is Guarded {
    error BadSigner(); error BadSignatureLength(); error BadSignatureV(); error MalleableSignature();
    error AttestationExpired(); error NonceAlreadyUsed(); error ScoreOutOfRange(); error StaleModelVersion();
    error NoAttestation(); error ExpiryTooFar(); error ZeroWallet(); error InvalidQuorum();
    error DuplicateSigner(); error ModelMetadataRequired(); error InvalidModelMetadata();

    uint256 private constant HALF_CURVE_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
    uint16 public constant MIN_SCORE = 300;
    uint16 public constant MAX_SCORE = 900;
    uint64 public constant MAX_ATTESTATION_TTL = 7 days;
    uint8 public constant MAX_SIGNERS_PER_ATTESTATION = 8;
    string public constant DOMAIN_NAME = "Karma";
    string public constant DOMAIN_VERSION = "1";

    uint256 private immutable _cachedChainId;
    bytes32 private immutable _cachedDomainSeparator;
    mapping(address => bool) public isModelSigner;
    uint8 public requiredSignerCount = 1;
    uint32 public minModelVersion;
    bool public modelMetadataRequired;

    struct ModelMetadata { bytes32 modelHash; bytes32 datasetHash; bytes32 featureSchemaHash; uint64 registeredAt; bool active; }
    mapping(uint32 => ModelMetadata) public modelMetadata;
    mapping(address => Record) private _records;
    mapping(address => mapping(uint256 => bool)) private _usedNonce;

    event ModelSignerSet(address indexed signer, bool allowed);
    event RequiredSignerCountSet(uint8 count);
    event MinModelVersionSet(uint32 version);
    event ModelMetadataSet(uint32 indexed version, bytes32 modelHash, bytes32 datasetHash, bytes32 featureSchemaHash, bool active);
    event ModelMetadataRequirementSet(bool required);
    event AttestationStored(address indexed wallet, address indexed signer, uint16 score, uint32 modelVersion, bytes32 featureHash, uint64 expiry, uint256 nonce);

    constructor(address guardian_, address initialModelSigner) Guarded(guardian_) {
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
        if (initialModelSigner != address(0)) { isModelSigner[initialModelSigner] = true; emit ModelSignerSet(initialModelSigner, true); }
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) { return block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator(); }
    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256(bytes(DOMAIN_NAME)), keccak256(bytes(DOMAIN_VERSION)), block.chainid, address(this)));
    }
    function hashAttestation(Attestation calldata a) public view returns (bytes32) { return keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR(), _structHash(a))); }
    function _structHash(Attestation calldata a) private pure returns (bytes32) { return keccak256(abi.encode(SCORE_TYPEHASH, a.wallet, a.score, a.modelVersion, a.featureHash, a.expiry, a.nonce)); }
    function recoverAttestationSigner(Attestation calldata a, bytes calldata signature) public view returns (address) { return _recover(hashAttestation(a), signature); }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) revert BadSignatureLength();
        bytes32 r; bytes32 s; uint8 v;
        assembly { r := calldataload(signature.offset) s := calldataload(add(signature.offset, 32)) v := byte(0, calldataload(add(signature.offset, 64))) }
        if (uint256(s) > HALF_CURVE_ORDER) revert MalleableSignature();
        if (v != 27 && v != 28) revert BadSignatureV();
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0)) revert BadSigner();
        return recovered;
    }

    function submitAttestation(Attestation calldata a, bytes calldata signature) external whenNotPaused {
        bytes[] memory signatures = new bytes[](1); signatures[0] = signature; _submit(a, signatures);
    }

    function submitAttestationQuorum(Attestation calldata a, bytes[] calldata signatures) external whenNotPaused {
        if (signatures.length > MAX_SIGNERS_PER_ATTESTATION) revert InvalidQuorum();
        _submit(a, signatures);
    }

    function _submit(Attestation calldata a, bytes[] memory signatures) private {
        if (a.wallet == address(0)) revert ZeroWallet();
        if (a.score < MIN_SCORE || a.score > MAX_SCORE) revert ScoreOutOfRange();
        if (a.expiry <= block.timestamp) revert AttestationExpired();
        if (a.expiry > block.timestamp + MAX_ATTESTATION_TTL) revert ExpiryTooFar();
        if (a.modelVersion < minModelVersion) revert StaleModelVersion();
        if (_usedNonce[a.wallet][a.nonce]) revert NonceAlreadyUsed();
        ModelMetadata memory meta = modelMetadata[a.modelVersion];
        if (modelMetadataRequired && (!meta.active || meta.modelHash == bytes32(0))) revert ModelMetadataRequired();
        if (signatures.length != requiredSignerCount) revert InvalidQuorum();

        bytes32 digest = hashAttestation(a);
        address primarySigner;
        address[] memory recovered = new address[](signatures.length);
        for (uint256 i = 0; i < signatures.length; ++i) {
            address signer = _recover(digest, signatures[i]);
            if (!isModelSigner[signer]) revert BadSigner();
            for (uint256 j = 0; j < i; ++j) if (recovered[j] == signer) revert DuplicateSigner();
            recovered[i] = signer;
            if (i == 0) primarySigner = signer;
        }

        _usedNonce[a.wallet][a.nonce] = true;
        _records[a.wallet] = Record({score: a.score, modelVersion: a.modelVersion, expiry: a.expiry, issuedAt: uint64(block.timestamp), signer: primarySigner, featureHash: a.featureHash});
        emit AttestationStored(a.wallet, primarySigner, a.score, a.modelVersion, a.featureHash, a.expiry, a.nonce);
    }

    function requireValidScore(address wallet) external view returns (uint16) {
        Record memory rec = _records[wallet];
        if (rec.expiry == 0) revert NoAttestation();
        if (rec.expiry <= block.timestamp) revert AttestationExpired();
        if (rec.modelVersion < minModelVersion) revert StaleModelVersion();
        ModelMetadata memory meta = modelMetadata[rec.modelVersion];
        if (modelMetadataRequired && (!meta.active || meta.modelHash == bytes32(0))) revert ModelMetadataRequired();
        return rec.score;
    }

    function scoreOf(address wallet) external view returns (uint16 score, bool valid) {
        Record memory rec = _records[wallet];
        valid = rec.expiry > block.timestamp && rec.modelVersion >= minModelVersion;
        if (modelMetadataRequired) valid = valid && modelMetadata[rec.modelVersion].active && modelMetadata[rec.modelVersion].modelHash != bytes32(0);
        score = rec.score;
    }
    function attestationOf(address wallet) external view returns (Record memory) { return _records[wallet]; }
    function isNonceUsed(address wallet, uint256 nonce) external view returns (bool) { return _usedNonce[wallet][nonce]; }

    function setModelSigner(address signer, bool allowed) external onlyOwner { if (signer == address(0)) revert ZeroWallet(); isModelSigner[signer] = allowed; emit ModelSignerSet(signer, allowed); }
    function setRequiredSignerCount(uint8 count) external onlyOwner { if (count == 0 || count > MAX_SIGNERS_PER_ATTESTATION) revert InvalidQuorum(); requiredSignerCount = count; emit RequiredSignerCountSet(count); }
    function registerModelVersion(uint32 version, bytes32 modelHash, bytes32 datasetHash, bytes32 featureSchemaHash, bool active) external onlyOwner {
        if (version == 0 || modelHash == bytes32(0) || featureSchemaHash == bytes32(0)) revert InvalidModelMetadata();
        modelMetadata[version] = ModelMetadata(modelHash, datasetHash, featureSchemaHash, uint64(block.timestamp), active);
        emit ModelMetadataSet(version, modelHash, datasetHash, featureSchemaHash, active);
    }
    function setModelMetadataRequired(bool required) external onlyOwner { modelMetadataRequired = required; emit ModelMetadataRequirementSet(required); }
    function setMinModelVersion(uint32 version) external onlyOwner { minModelVersion = version; emit MinModelVersionSet(version); }
}
