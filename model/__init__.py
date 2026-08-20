"""Karma credit model.

Public surface used by the signer service and the tests:

    from model.features import FEATURES, feature_vector, feature_hash
    from model.scoring import probability_to_score, KarmaModel
    from model.risk_curve import ratio_bps
"""

__all__ = ["features", "scoring", "risk_curve", "dataset", "bootstrap_data"]

MODEL_VERSION = 1
