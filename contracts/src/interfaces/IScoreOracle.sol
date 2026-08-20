// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Attestation, Record} from "../types/Attestation.sol";

interface IScoreOracle {
    function submitAttestation(Attestation calldata a, bytes calldata signature) external;
    function hashAttestation(Attestation calldata a) external view returns (bytes32);
    function recoverAttestationSigner(Attestation calldata a, bytes calldata signature) external view returns (address);
    function requireValidScore(address wallet) external view returns (uint16);
    function scoreOf(address wallet) external view returns (uint16 score, bool valid);
    function attestationOf(address wallet) external view returns (Record memory);
    function isModelSigner(address signer) external view returns (bool);
    function isNonceUsed(address wallet, uint256 nonce) external view returns (bool);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
