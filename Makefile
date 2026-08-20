# Karma - developer entry points.

CONTRACTS := contracts

.PHONY: help build test test-v fmt snapshot clean anvil

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Compile the contracts
	cd $(CONTRACTS) && forge build

test: ## Run the test suite
	cd $(CONTRACTS) && forge test

test-v: ## Run the test suite with traces on failure
	cd $(CONTRACTS) && forge test -vv

fmt: ## Format Solidity
	cd $(CONTRACTS) && forge fmt

snapshot: ## Write a gas snapshot
	cd $(CONTRACTS) && forge snapshot

clean: ## Remove build artifacts
	cd $(CONTRACTS) && forge clean

anvil: ## Run a local chain on :8545
	anvil
