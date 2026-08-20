"""Building, signing and encoding a Karma attestation.

The typed-data definition here is the Python half of the contract in
contracts/src/types/Attestation.sol. If the two ever disagree, every signature
this service produces is rejected on chain - which is the failure mode we want,
and which contracts/test/CrossLanguageSignature.t.sol pins down by verifying a
signature produced here against the real contract.
"""

from __future__ import annotations

import secrets
import time
from dataclasses import asdict, dataclass

from eth_abi import encode as abi_encode
from eth_account import Account
from eth_account.messages import encode_typed_data
from eth_utils import keccak, to_checksum_address

DOMAIN_NAME = "Karma"
DOMAIN_VERSION = "1"

#: Must match SCORE_TYPEHASH's field order in Attestation.sol exactly.
SCORE_ATTESTATION_TYPE = [
    {"name": "wallet", "type": "address"},
    {"name": "score", "type": "uint16"},
    {"name": "modelVersion", "type": "uint32"},
    {"name": "featureHash", "type": "bytes32"},
    {"name": "expiry", "type": "uint64"},
    {"name": "nonce", "type": "uint256"},
]

EIP712_DOMAIN_TYPE = [
    {"name": "name", "type": "string"},
    {"name": "version", "type": "string"},
    {"name": "chainId", "type": "uint256"},
    {"name": "verifyingContract", "type": "address"},
]

SUBMIT_SIGNATURE = "submitAttestation((address,uint16,uint32,bytes32,uint64,uint256),bytes)"

#: secp256k1n / 2. Signatures above this are the mirrored twin and ScoreOracle
#: rejects them, so we assert rather than hope.
HALF_CURVE_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0


@dataclass(frozen=True)
class Attestation:
    wallet: str
    score: int
    modelVersion: int
    featureHash: str
    expiry: int
    nonce: int

    def as_dict(self) -> dict:
        return asdict(self)

    def as_message(self) -> dict:
        return {
            "wallet": to_checksum_address(self.wallet),
            "score": int(self.score),
            "modelVersion": int(self.modelVersion),
            "featureHash": bytes.fromhex(self.featureHash.removeprefix("0x")),
            "expiry": int(self.expiry),
            "nonce": int(self.nonce),
        }


def domain(chain_id: int, verifying_contract: str) -> dict:
    return {
        "name": DOMAIN_NAME,
        "version": DOMAIN_VERSION,
        "chainId": int(chain_id),
        "verifyingContract": to_checksum_address(verifying_contract),
    }


def build(
    wallet: str,
    score: int,
    model_version: int,
    feature_hash: str,
    ttl_seconds: int,
    now: int | None = None,
    nonce: int | None = None,
) -> Attestation:
    issued = int(now if now is not None else time.time())
    return Attestation(
        wallet=to_checksum_address(wallet),
        score=int(score),
        modelVersion=int(model_version),
        featureHash=feature_hash,
        expiry=issued + int(ttl_seconds),
        # 96 random bits. The contract enforces single use per wallet; this only
        # needs to avoid colliding with a nonce that wallet already spent.
        nonce=int(nonce if nonce is not None else secrets.randbits(96)),
    )


def typed_data(att: Attestation, chain_id: int, verifying_contract: str) -> dict:
    return {
        "types": {"EIP712Domain": EIP712_DOMAIN_TYPE, "ScoreAttestation": SCORE_ATTESTATION_TYPE},
        "primaryType": "ScoreAttestation",
        "domain": domain(chain_id, verifying_contract),
        "message": att.as_message(),
    }


def digest(att: Attestation, chain_id: int, verifying_contract: str) -> str:
    """The 32 bytes ScoreOracle.hashAttestation returns for this attestation."""
    signable = encode_typed_data(full_message=typed_data(att, chain_id, verifying_contract))
    # SignableMessage carries the domain separator and struct hash as body/header.
    return "0x" + keccak(b"\x19\x01" + signable.header + signable.body).hex()


def sign(att: Attestation, chain_id: int, verifying_contract: str, private_key: str) -> dict:
    """Sign and return the signature plus everything needed to check it."""
    signable = encode_typed_data(full_message=typed_data(att, chain_id, verifying_contract))
    signed = Account.sign_message(signable, private_key=private_key)

    if signed.s > HALF_CURVE_ORDER:
        # eth-account produces canonical low-s signatures, so this should be
        # unreachable. If it ever fires, the alternative is silently emitting
        # attestations the contract rejects with MalleableSignature().
        raise RuntimeError("signature has high s and would be rejected on chain")
    if signed.v not in (27, 28):
        raise RuntimeError(f"unexpected v={signed.v}; ScoreOracle accepts only 27 or 28")

    return {
        "signature": "0x" + signed.signature.hex().removeprefix("0x"),
        "signer": Account.from_key(private_key).address,
        "digest": "0x" + keccak(b"\x19\x01" + signable.header + signable.body).hex(),
        "domain_separator": "0x" + signable.header.hex(),
        "struct_hash": "0x" + signable.body.hex(),
        "v": signed.v,
        "r": hex(signed.r),
        "s": hex(signed.s),
    }


def recover(att: Attestation, chain_id: int, verifying_contract: str, signature: str) -> str:
    signable = encode_typed_data(full_message=typed_data(att, chain_id, verifying_contract))
    return Account.recover_message(signable, signature=bytes.fromhex(signature.removeprefix("0x")))


def calldata(att: Attestation, signature: str) -> str:
    """ABI-encoded call to ScoreOracle.submitAttestation, ready to broadcast."""
    selector = keccak(text=SUBMIT_SIGNATURE)[:4]
    args = abi_encode(
        ["(address,uint16,uint32,bytes32,uint64,uint256)", "bytes"],
        [
            (
                to_checksum_address(att.wallet),
                int(att.score),
                int(att.modelVersion),
                bytes.fromhex(att.featureHash.removeprefix("0x")),
                int(att.expiry),
                int(att.nonce),
            ),
            bytes.fromhex(signature.removeprefix("0x")),
        ],
    )
    return "0x" + (selector + args).hex()
