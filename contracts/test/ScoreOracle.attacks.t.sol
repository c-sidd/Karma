// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {KarmaFixture} from "./utils/KarmaFixture.sol";
import {ScoreOracle} from "../src/ScoreOracle.sol";
import {Attestation} from "../src/types/Attestation.sol";

/// @notice Every way we know of to get an unsigned or wrongly-signed score into the
///         protocol, and the error each one hits. This file is the security claim.
contract ScoreOracleAttacksTest is KarmaFixture {
    // ---------------------------------------------------------- wrong signer

    function test_wrongSigner_reverts() public {
        Attestation memory a = buildAttestation(alice, 880);
        bytes memory sig = sign(rogueSignerPk, a);

        // The signature is cryptographically valid. It is simply not from a
        // registered model signer.
        assertEq(oracle.recoverAttestationSigner(a, sig), rogueSigner);
        assertFalse(oracle.isModelSigner(rogueSigner));

        vm.expectRevert(ScoreOracle.BadSigner.selector);
        oracle.submitAttestation(a, sig);
    }

    function test_selfSignedByVictim_reverts() public {
        (address self, uint256 selfPk) = makeAddrAndKey("aliceKey");
        Attestation memory a = buildAttestation(self, 900);
        bytes memory sig = sign(selfPk, a);

        vm.prank(self);
        vm.expectRevert(ScoreOracle.BadSigner.selector);
        oracle.submitAttestation(a, sig);
    }

    // ---------------------------------------------------------- tampering

    function test_tamperedScore_reverts() public {
        Attestation memory a = buildAttestation(alice, 500);
        bytes memory sig = sign(modelSignerPk, a);

        a.score = 900; // the field the borrower most wants to change
        vm.expectRevert(ScoreOracle.BadSigner.selector);
        oracle.submitAttestation(a, sig);
    }

    function test_tamperedWallet_reverts() public {
        Attestation memory a = buildAttestation(alice, 850);
        bytes memory sig = sign(modelSignerPk, a);

        a.wallet = bob; // steal someone else's good score
        vm.expectRevert(ScoreOracle.BadSigner.selector);
        oracle.submitAttestation(a, sig);
    }

    function test_tamperedFeatureHash_reverts() public {
        Attestation memory a = buildAttestation(alice, 700);
        bytes memory sig = sign(modelSignerPk, a);

        a.featureHash = keccak256("different features, same score");
        vm.expectRevert(ScoreOracle.BadSigner.selector);
        oracle.submitAttestation(a, sig);
    }

    function test_tamperedExpiry_reverts() public {
        Attestation memory a = buildAttestation(alice, 700);
        bytes memory sig = sign(modelSignerPk, a);

        a.expiry = uint64(block.timestamp + 2 days); // extend our own credit line
        vm.expectRevert(ScoreOracle.BadSigner.selector);
        oracle.submitAttestation(a, sig);
    }

    function test_tamperedModelVersion_reverts() public {
        Attestation memory a = buildAttestation(alice, 700);
        bytes memory sig = sign(modelSignerPk, a);

        a.modelVersion = 99;
        vm.expectRevert(ScoreOracle.BadSigner.selector);
        oracle.submitAttestation(a, sig);
    }

    function testFuzz_anyTamperedScore_reverts(uint16 tampered) public {
        tampered = uint16(bound(tampered, 300, 900));
        Attestation memory a = buildAttestation(alice, 400);
        bytes memory sig = sign(modelSignerPk, a);
        vm.assume(tampered != a.score);

        a.score = tampered;
        vm.expectRevert(ScoreOracle.BadSigner.selector);
        oracle.submitAttestation(a, sig);
    }

    // ---------------------------------------------------------- expiry

    function test_expiredAttestation_reverts() public {
        Attestation memory a = buildAttestation(alice, 700);
        bytes memory sig = sign(modelSignerPk, a);

        vm.warp(a.expiry);
        vm.expectRevert(ScoreOracle.AttestationExpired.selector);
        oracle.submitAttestation(a, sig);
    }

    function test_expiryInThePast_reverts() public {
        Attestation memory a = buildAttestation(alice, 700);
        a.expiry = uint64(block.timestamp - 1);
        bytes memory sig = sign(modelSignerPk, a);
        vm.expectRevert(ScoreOracle.AttestationExpired.selector);
        oracle.submitAttestation(a, sig);
    }

    function test_expiryBeyondMaxTtl_reverts() public {
        Attestation memory a = buildAttestation(alice, 700);
        a.expiry = uint64(block.timestamp + oracle.MAX_ATTESTATION_TTL() + 1);
        bytes memory sig = sign(modelSignerPk, a);
        vm.expectRevert(ScoreOracle.ExpiryTooFar.selector);
        oracle.submitAttestation(a, sig);
    }

    // ---------------------------------------------------------- replay

    function test_replayedNonce_reverts() public {
        Attestation memory a = buildAttestation(alice, 700);
        bytes memory sig = sign(modelSignerPk, a);
        oracle.submitAttestation(a, sig);

        vm.expectRevert(ScoreOracle.NonceAlreadyUsed.selector);
        oracle.submitAttestation(a, sig);
    }

    function test_replayedNonceAfterScoreDrop_reverts() public {
        // The real attack: keep a good old attestation, replay it once the model
        // has marked you down.
        Attestation memory good = buildAttestation(alice, 880);
        bytes memory goodSig = sign(modelSignerPk, good);
        oracle.submitAttestation(good, goodSig);

        vm.warp(block.timestamp + 12 hours);
        attest(alice, 420);
        assertEq(oracle.requireValidScore(alice), 420);

        vm.expectRevert(ScoreOracle.NonceAlreadyUsed.selector);
        oracle.submitAttestation(good, goodSig);
        assertEq(oracle.requireValidScore(alice), 420);
    }

    function test_nonceIsPerWallet() public {
        Attestation memory a = buildAttestation(alice, 700);
        oracle.submitAttestation(a, sign(modelSignerPk, a));

        // Same nonce value, different wallet: independent namespace, so this is fine.
        Attestation memory b = buildAttestation(bob, 700);
        b.nonce = a.nonce;
        oracle.submitAttestation(b, sign(modelSignerPk, b));

        assertTrue(oracle.isNonceUsed(alice, a.nonce));
        assertTrue(oracle.isNonceUsed(bob, a.nonce));
    }

    // ---------------------------------------------------------- malleability

    function test_malleableSignature_reverts() public {
        Attestation memory a = buildAttestation(alice, 700);
        bytes memory sig = sign(modelSignerPk, a);
        bytes memory twin = malleate(sig);

        // The twin recovers the same signer through raw ecrecover, which is exactly
        // why it has to be rejected explicitly rather than left to the recovery result.
        (bytes32 r, bytes32 s, uint8 v) = _split(twin);
        assertEq(ecrecover(oracle.hashAttestation(a), v, r, s), modelSigner);

        vm.expectRevert(ScoreOracle.MalleableSignature.selector);
        oracle.submitAttestation(a, twin);
    }

    function test_malleableSignature_cannotBypassNonce() public {
        Attestation memory a = buildAttestation(alice, 700);
        bytes memory sig = sign(modelSignerPk, a);
        oracle.submitAttestation(a, sig);

        // A second, differently-encoded signature over the same payload must not be a
        // second bite: the nonce check comes first, then malleability.
        vm.expectRevert(ScoreOracle.NonceAlreadyUsed.selector);
        oracle.submitAttestation(a, malleate(sig));
    }

    function test_badSignatureLength_reverts() public {
        Attestation memory a = buildAttestation(alice, 700);
        vm.expectRevert(ScoreOracle.BadSignatureLength.selector);
        oracle.submitAttestation(a, hex"deadbeef");

        bytes memory sig = sign(modelSignerPk, a);
        vm.expectRevert(ScoreOracle.BadSignatureLength.selector);
        oracle.submitAttestation(a, abi.encodePacked(sig, uint8(0)));
    }

    function test_badV_reverts() public {
        Attestation memory a = buildAttestation(alice, 700);
        (bytes32 r, bytes32 s,) = _split(sign(modelSignerPk, a));

        vm.expectRevert(ScoreOracle.BadSignatureV.selector);
        oracle.submitAttestation(a, abi.encodePacked(r, s, uint8(29)));

        vm.expectRevert(ScoreOracle.BadSignatureV.selector);
        oracle.submitAttestation(a, abi.encodePacked(r, s, uint8(0)));
    }

    function test_zeroSignature_reverts() public {
        Attestation memory a = buildAttestation(alice, 700);
        vm.expectRevert(ScoreOracle.BadSigner.selector);
        oracle.submitAttestation(a, abi.encodePacked(bytes32(0), bytes32(0), uint8(27)));
    }

    // ---------------------------------------------------------- domain binding

    function test_crossContractReplay_reverts() public {
        ScoreOracle twin = new ScoreOracle(address(guardian), modelSigner);
        assertTrue(oracle.DOMAIN_SEPARATOR() != twin.DOMAIN_SEPARATOR());

        Attestation memory a = buildAttestation(alice, 900);
        bytes memory sig = sign(modelSignerPk, a); // signed against `oracle`

        oracle.submitAttestation(a, sig);

        vm.expectRevert(ScoreOracle.BadSigner.selector);
        twin.submitAttestation(a, sig);
    }

    function test_crossChainReplay_reverts() public {
        Attestation memory a = buildAttestation(alice, 900);
        bytes memory sig = sign(modelSignerPk, a); // signed at chain id 31337

        vm.chainId(11_155_111); // same contract address, different chain
        assertEq(oracle.recoverAttestationSigner(a, sig) == modelSigner, false);

        vm.expectRevert(ScoreOracle.BadSigner.selector);
        oracle.submitAttestation(a, sig);
    }

    // ---------------------------------------------------------- range

    function test_scoreBelowRange_reverts() public {
        Attestation memory a = buildAttestation(alice, 299);
        bytes memory sig = sign(modelSignerPk, a);
        vm.expectRevert(ScoreOracle.ScoreOutOfRange.selector);
        oracle.submitAttestation(a, sig);
    }

    function test_scoreAboveRange_reverts() public {
        Attestation memory a = buildAttestation(alice, 901);
        bytes memory sig = sign(modelSignerPk, a);
        vm.expectRevert(ScoreOracle.ScoreOutOfRange.selector);
        oracle.submitAttestation(a, sig);
    }

    function test_zeroWallet_reverts() public {
        Attestation memory a = buildAttestation(address(0), 700);
        bytes memory sig = sign(modelSignerPk, a);
        vm.expectRevert(ScoreOracle.ZeroWallet.selector);
        oracle.submitAttestation(a, sig);
    }

    function testFuzz_outOfRangeScore_reverts(uint16 score) public {
        vm.assume(score < 300 || score > 900);
        Attestation memory a = buildAttestation(alice, score);
        bytes memory sig = sign(modelSignerPk, a);
        vm.expectRevert(ScoreOracle.ScoreOutOfRange.selector);
        oracle.submitAttestation(a, sig);
    }

    function _split(bytes memory sig) private pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }
}
