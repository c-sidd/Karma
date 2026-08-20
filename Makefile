# Karma - developer entry points.
# Every target here is expected to work from a clean checkout with no paid services.

CONTRACTS := contracts
FIXTURE   := $(CONTRACTS)/test/fixtures/ratio_curve.json

.PHONY: help build test test-v parity-fixture parity fmt snapshot clean anvil

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Compile the contracts
	cd $(CONTRACTS) && forge build

parity-fixture: ## Regenerate the Solidity/Python parity fixture from model/risk_curve.py
	python3 model/risk_curve.py --dump $(FIXTURE)

test: parity-fixture ## Run the full test suite (regenerates the parity fixture first)
	cd $(CONTRACTS) && forge test

test-v: parity-fixture ## Run the full test suite with traces on failure
	cd $(CONTRACTS) && forge test -vv

parity: parity-fixture ## Assert Solidity and Python price every score identically
	cd $(CONTRACTS) && forge test --match-path "test/RiskParamsParity.t.sol" -vv

fmt: ## Format Solidity
	cd $(CONTRACTS) && forge fmt

snapshot: parity-fixture ## Write a gas snapshot
	cd $(CONTRACTS) && forge snapshot

clean: ## Remove build artifacts
	cd $(CONTRACTS) && forge clean

anvil: ## Run a local chain on :8545
	anvil
