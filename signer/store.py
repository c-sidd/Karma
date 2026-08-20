"""Where issued attestations are kept between the two endpoints.

In memory, bounded, and lost on restart. That is the right trade for a
prototype: the attestation is not the source of truth, the chain is. Losing
this store costs a re-score, nothing more. A production deployment would put
this in Postgres, mostly so nonce issuance survives a restart.
"""

from __future__ import annotations

import threading
from collections import OrderedDict

from eth_utils import to_checksum_address


class AttestationStore:
    def __init__(self, max_entries: int = 2_000):
        self._lock = threading.Lock()
        self._items: OrderedDict = OrderedDict()
        self._max_entries = max_entries

    def put(self, address: str, payload: dict) -> None:
        key = to_checksum_address(address)
        with self._lock:
            self._items[key] = payload
            self._items.move_to_end(key)
            while len(self._items) > self._max_entries:
                self._items.popitem(last=False)

    def get(self, address: str) -> dict | None:
        with self._lock:
            return self._items.get(to_checksum_address(address))

    def issued_nonces(self, address: str) -> set:
        item = self.get(address)
        return {item["attestation"]["nonce"]} if item else set()

    def __len__(self) -> int:
        with self._lock:
            return len(self._items)
