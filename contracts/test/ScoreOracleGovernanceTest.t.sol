// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {KarmaFixture} from "./utils/KarmaFixture.sol";
import {ScoreOracle} from "../src/ScoreOracle.sol";

contract ScoreOracleGovernanceTest is KarmaFixture {
    function test_quorumRejectsSingleSignerWhenTwoRequired() public {
        (address secondSigner, uint256 secondPk) = makeAddrAndKey("secondSigner");
        vm.prank(owner); oracle.setModelSigner(secondSigner, true);
        vm.prank(owner); oracle.setRequiredSignerCount(2);

        Attestation memory a = buildAttestation(alice, 800);
        bytes memory first = sign(modelSignerPk, a);
        vm.expectRevert(ScoreOracle.InvalidQuorum.selector);
        oracle.submitAttestation(a, first);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = first;
        signatures[1] = sign(secondPk, a);
        oracle.submitAttestationQuorum(a, signatures);
        assertEq(oracle.requireValidScore(alice), 800);
    }

    function test_quorumRejectsDuplicateSigner() public {
        (address secondSigner,) = makeAddrAndKey("secondSigner");
        vm.prank(owner); oracle.setModelSigner(secondSigner, true);
        vm.prank(owner); oracle.setRequiredSignerCount(2);
        Attestation memory a = buildAttestation(alice, 800);
        bytes memory first = sign(modelSignerPk, a);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = first; signatures[1] = first;
        vm.expectRevert(ScoreOracle.DuplicateSigner.selector);
        oracle.submitAttestationQuorum(a, signatures);
    }

    function test_modelMetadataCanBeRequired() public {
        bytes32 modelHash = keccak256("model-v1");
        bytes32 datasetHash = keccak256("dataset-v1");
        bytes32 schemaHash = keccak256("schema-v1");
        vm.prank(owner); oracle.registerModelVersion(1, modelHash, datasetHash, schemaHash, true);
        vm.prank(owner); oracle.setModelMetadataRequired(true);
        Attestation memory a = buildAttestation(alice, 800);
        oracle.submitAttestation(a, sign(modelSignerPk, a));
        assertEq(oracle.requireValidScore(alice), 800);
    }

    function test_metadataRequirementRejectsUnregisteredVersion() public {
        vm.prank(owner); oracle.setModelMetadataRequired(true);
        Attestation memory a = buildAttestation(alice, 800);
        vm.expectRevert(ScoreOracle.ModelMetadataRequired.selector);
        oracle.submitAttestation(a, sign(modelSignerPk, a));
    }
}
