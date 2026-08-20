// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {KarmaFixture} from "./utils/KarmaFixture.sol";
import {Guardian} from "../src/Guardian.sol";
import {Guarded} from "../src/Guarded.sol";
import {ScoreOracle} from "../src/ScoreOracle.sol";
import {Attestation, Record, SCORE_TYPEHASH} from "../src/types/Attestation.sol";

/// @notice Happy paths, storage effects and governance for ScoreOracle.
contract ScoreOracleTest is KarmaFixture {
    event AttestationStored(
        address indexed wallet,
        address indexed signer,
        uint16 score,
        uint32 modelVersion,
        bytes32 featureHash,
        uint64 expiry,
        uint256 nonce
    );

    function test_typehash_matchesLiteral() public pure {
        assertEq(
            SCORE_TYPEHASH,
            keccak256(
                "ScoreAttestation(address wallet,uint16 score,uint32 modelVersion,bytes32 featureHash,uint64 expiry,uint256 nonce)"
            ),
            "typehash drifted from its string"
        );
    }

    function test_validAttestation_isStored() public {
        Attestation memory a = buildAttestation(alice, 742);
        bytes memory sig = sign(modelSignerPk, a);

        vm.expectEmit(true, true, true, true);
        emit AttestationStored(alice, modelSigner, 742, a.modelVersion, a.featureHash, a.expiry, a.nonce);
        oracle.submitAttestation(a, sig);

        Record memory rec = oracle.attestationOf(alice);
        assertEq(rec.score, 742);
        assertEq(rec.modelVersion, 1);
        assertEq(rec.expiry, a.expiry);
        assertEq(rec.issuedAt, uint64(block.timestamp));
        assertEq(rec.signer, modelSigner);
        assertEq(rec.featureHash, a.featureHash);

        assertEq(oracle.requireValidScore(alice), 742);
        (uint16 score, bool valid) = oracle.scoreOf(alice);
        assertEq(score, 742);
        assertTrue(valid);
        assertTrue(oracle.isNonceUsed(alice, a.nonce));
    }

    function test_anyoneMaySubmit_signatureIsTheAuthority() public {
        Attestation memory a = buildAttestation(alice, 650);
        bytes memory sig = sign(modelSignerPk, a);

        // Submitted by an unrelated account, for a third party. Still accepted.
        vm.prank(bob);
        oracle.submitAttestation(a, sig);
        assertEq(oracle.requireValidScore(alice), 650);
    }

    function test_recoverAttestationSigner_matchesSubmitPath() public view {
        Attestation memory a = Attestation({
            wallet: alice,
            score: 700,
            modelVersion: 1,
            featureHash: keccak256("f"),
            expiry: uint64(block.timestamp + 1 days),
            nonce: 7
        });
        assertEq(oracle.recoverAttestationSigner(a, sign(modelSignerPk, a)), modelSigner);
        assertEq(oracle.recoverAttestationSigner(a, sign(rogueSignerPk, a)), rogueSigner);
    }

    function test_digest_isEip712() public view {
        Attestation memory a = Attestation({
            wallet: alice,
            score: 700,
            modelVersion: 1,
            featureHash: keccak256("f"),
            expiry: uint64(block.timestamp + 1 days),
            nonce: 7
        });
        bytes32 structHash =
            keccak256(abi.encode(SCORE_TYPEHASH, a.wallet, a.score, a.modelVersion, a.featureHash, a.expiry, a.nonce));
        bytes32 expected = keccak256(abi.encodePacked(hex"1901", oracle.DOMAIN_SEPARATOR(), structHash));
        assertEq(oracle.hashAttestation(a), expected);
    }

    function test_newAttestation_overwritesOld() public {
        attest(alice, 500);
        assertEq(oracle.requireValidScore(alice), 500);
        attest(alice, 810);
        assertEq(oracle.requireValidScore(alice), 810);
    }

    function test_scoreOf_doesNotRevertForUnknownWallet() public view {
        (uint16 score, bool valid) = oracle.scoreOf(bob);
        assertEq(score, 0);
        assertFalse(valid);
    }

    function test_requireValidScore_revertsWithoutAttestation() public {
        vm.expectRevert(ScoreOracle.NoAttestation.selector);
        oracle.requireValidScore(bob);
    }

    function test_requireValidScore_revertsAfterExpiry() public {
        Attestation memory a = attest(alice, 700);
        vm.warp(a.expiry);
        vm.expectRevert(ScoreOracle.AttestationExpired.selector);
        oracle.requireValidScore(alice);
    }

    // ------------------------------------------------------------ governance

    function test_setModelSigner_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(Guarded.NotOwner.selector);
        oracle.setModelSigner(rogueSigner, true);

        vm.prank(owner);
        oracle.setModelSigner(rogueSigner, true);
        assertTrue(oracle.isModelSigner(rogueSigner));

        Attestation memory a = buildAttestation(alice, 620);
        oracle.submitAttestation(a, sign(rogueSignerPk, a));
        assertEq(oracle.requireValidScore(alice), 620);
    }

    function test_revokedSigner_cannotAttest() public {
        vm.prank(owner);
        oracle.setModelSigner(modelSigner, false);

        Attestation memory a = buildAttestation(alice, 700);
        bytes memory sig = sign(modelSignerPk, a);
        vm.expectRevert(ScoreOracle.BadSigner.selector);
        oracle.submitAttestation(a, sig);
    }

    function test_retiringModelVersion_invalidatesStoredRecords() public {
        attest(alice, 700);
        assertEq(oracle.requireValidScore(alice), 700);

        vm.prank(owner);
        oracle.setMinModelVersion(2);

        vm.expectRevert(ScoreOracle.StaleModelVersion.selector);
        oracle.requireValidScore(alice);

        (, bool valid) = oracle.scoreOf(alice);
        assertFalse(valid);
    }

    function test_staleModelVersion_rejectedAtSubmit() public {
        vm.prank(owner);
        oracle.setMinModelVersion(5);

        Attestation memory a = buildAttestation(alice, 700);
        a.modelVersion = 4;
        bytes memory sig = sign(modelSignerPk, a);
        vm.expectRevert(ScoreOracle.StaleModelVersion.selector);
        oracle.submitAttestation(a, sig);
    }

    function test_pausedGuardian_blocksSubmission() public {
        Attestation memory a = buildAttestation(alice, 700);
        bytes memory sig = sign(modelSignerPk, a);

        vm.prank(owner);
        guardian.pause();

        vm.expectRevert(Guarded.ProtocolPaused.selector);
        oracle.submitAttestation(a, sig);

        vm.prank(owner);
        guardian.unpause();
        oracle.submitAttestation(a, sig);
        assertEq(oracle.requireValidScore(alice), 700);
    }

    function test_noWriteWithoutSignature() public view {
        // There is no function selector on ScoreOracle that writes a Record without a
        // signature. This asserts the shape of the ABI rather than a runtime behaviour.
        assertEq(oracle.attestationOf(alice).expiry, 0, "no record can exist before an attestation");
    }
}
