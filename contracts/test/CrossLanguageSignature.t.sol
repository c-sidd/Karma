// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {Guardian} from "../src/Guardian.sol";
import {ScoreOracle} from "../src/ScoreOracle.sol";
import {Attestation} from "../src/types/Attestation.sol";

/// @notice Proves the Python signer and this contract agree byte for byte.
///
/// @dev Every other test in this repository signs with Foundry's own vm.sign,
///      which only ever shows that our Solidity agrees with our Solidity. This
///      one takes a signature produced by eth-account in
///      `python -m signer.fixtures` and puts it through the real submit path.
///
///      EIP-712 binds the verifying contract, so Python has to know the oracle's
///      address before it exists. Both sides derive it the same way: CREATE from
///      a fixed deployer at nonce 0. The first assertion below is that the two
///      derivations landed on the same address; if they did not, nothing after
///      it would mean anything.
///
///      Regenerate the fixture with `make fixtures` after any change to the
///      attestation struct, the typehash or the domain.
contract CrossLanguageSignatureTest is Test {
    string internal constant FIXTURE = "./test/fixtures/python_attestation.json";

    Guardian internal guardian;
    ScoreOracle internal oracle;

    string internal json;
    address internal signer;
    Attestation internal att;
    bytes internal signature;

    function setUp() public {
        json = vm.readFile(FIXTURE);

        vm.chainId(vm.parseJsonUint(json, ".chainId"));
        vm.warp(vm.parseJsonUint(json, ".issuedAt"));

        signer = vm.parseJsonAddress(json, ".signer");
        address deployer = vm.parseJsonAddress(json, ".deployer");

        // Guardian is deployed by the test contract, so the deployer's nonce is
        // untouched and the oracle lands exactly where Python predicted.
        guardian = new Guardian(address(this));

        vm.setNonce(deployer, uint64(vm.parseJsonUint(json, ".deployerNonce")));
        vm.prank(deployer);
        oracle = new ScoreOracle(address(guardian), signer);

        att = Attestation({
            wallet: vm.parseJsonAddress(json, ".wallet"),
            score: uint16(vm.parseJsonUint(json, ".score")),
            modelVersion: uint32(vm.parseJsonUint(json, ".modelVersion")),
            featureHash: vm.parseJsonBytes32(json, ".featureHash"),
            expiry: uint64(vm.parseJsonUint(json, ".expiry")),
            nonce: vm.parseJsonUint(json, ".nonce")
        });
        signature = vm.parseJsonBytes(json, ".signature");
    }

    function test_oracleLandedWherePythonPredicted() public view {
        assertEq(
            address(oracle),
            vm.parseJsonAddress(json, ".scoreOracle"),
            "CREATE address derivation disagrees; the rest of this file proves nothing"
        );
    }

    function test_domainSeparatorMatchesPython() public view {
        assertEq(oracle.DOMAIN_SEPARATOR(), vm.parseJsonBytes32(json, ".domainSeparator"));
    }

    function test_structHashMatchesPython() public view {
        // Recomputed from the digest so this does not just restate the fixture:
        // keccak(0x1901 || domainSeparator || structHash) must equal the digest.
        bytes32 structHash = vm.parseJsonBytes32(json, ".structHash");
        bytes32 expected = keccak256(
            abi.encodePacked(hex"1901", oracle.DOMAIN_SEPARATOR(), structHash)
        );
        assertEq(expected, vm.parseJsonBytes32(json, ".digest"));
    }

    function test_digestMatchesPython() public view {
        assertEq(oracle.hashAttestation(att), vm.parseJsonBytes32(json, ".digest"));
    }

    function test_recoversThePythonSigner() public view {
        assertEq(oracle.recoverAttestationSigner(att, signature), signer);
    }

    function test_pythonSignatureIsAcceptedOnChain() public {
        oracle.submitAttestation(att, signature);
        assertEq(oracle.requireValidScore(att.wallet), att.score);
        assertEq(oracle.attestationOf(att.wallet).signer, signer);
        assertEq(oracle.attestationOf(att.wallet).featureHash, att.featureHash);
    }

    function test_pythonCalldataIsAcceptedOnChain() public {
        // Not just the signature: the exact bytes the service hands the frontend.
        (bool ok,) = address(oracle).call(vm.parseJsonBytes(json, ".calldata"));
        assertTrue(ok, "calldata from the signer service reverted");
        assertEq(oracle.requireValidScore(att.wallet), att.score);
    }

    function test_pythonSignatureIsLowS() public view {
        bytes memory sig = signature;
        bytes32 s;
        assembly {
            s := mload(add(sig, 64))
        }
        assertLe(
            uint256(s),
            0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
            "python produced a malleable signature"
        );
    }

    function test_tamperingWithThePythonAttestationStillReverts() public {
        Attestation memory tampered = att;
        tampered.score = 900;
        vm.expectRevert(ScoreOracle.BadSigner.selector);
        oracle.submitAttestation(tampered, signature);
    }
}
