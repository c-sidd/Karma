// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {Guardian} from "../../src/Guardian.sol";
import {RiskParams} from "../../src/RiskParams.sol";
import {ScoreOracle} from "../../src/ScoreOracle.sol";
import {Attestation} from "../../src/types/Attestation.sol";

/// @notice Shared deployment and attestation-signing helpers.
abstract contract KarmaFixture is Test {
    /// @dev secp256k1 group order, for building the mirrored (malleable) twin of a signature.
    uint256 internal constant CURVE_ORDER =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    Guardian internal guardian;
    RiskParams internal riskParams;
    ScoreOracle internal oracle;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    address internal modelSigner;
    uint256 internal modelSignerPk;
    address internal rogueSigner;
    uint256 internal rogueSignerPk;

    uint256 private _nonceCounter;

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        (modelSigner, modelSignerPk) = makeAddrAndKey("modelSigner");
        (rogueSigner, rogueSignerPk) = makeAddrAndKey("rogueSigner");

        guardian = new Guardian(owner);
        riskParams = new RiskParams(address(guardian));
        oracle = new ScoreOracle(address(guardian), modelSigner);
    }

    // ------------------------------------------------------------ attestations

    function _nextNonce() internal returns (uint256) {
        return ++_nonceCounter;
    }

    function buildAttestation(address wallet, uint16 score) internal returns (Attestation memory) {
        return Attestation({
            wallet: wallet,
            score: score,
            modelVersion: 1,
            featureHash: keccak256(abi.encodePacked("features", wallet, score)),
            expiry: uint64(block.timestamp + 1 days),
            nonce: _nextNonce()
        });
    }

    /// @dev Build the signature before arming vm.expectRevert: this reads the digest
    ///      from the oracle, and that call would otherwise absorb the expectation.
    function sign(uint256 pk, Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, oracle.hashAttestation(a));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The other valid-looking signature for the same message: s mirrored across
    ///      the curve order with v flipped. ecrecover accepts it; ScoreOracle must not.
    function malleate(bytes memory signature) internal pure returns (bytes memory) {
        require(signature.length == 65, "sig length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        bytes32 flippedS = bytes32(CURVE_ORDER - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        return abi.encodePacked(r, flippedS, flippedV);
    }

    /// @notice Build, sign and submit a valid attestation for `wallet`.
    function attest(address wallet, uint16 score) internal returns (Attestation memory a) {
        a = buildAttestation(wallet, score);
        oracle.submitAttestation(a, sign(modelSignerPk, a));
    }
}
