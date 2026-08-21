# Karma - developer entry points.
# Every target here is expected to work from a clean checkout with no paid services.

CONTRACTS := contracts
FIXTURE   := $(CONTRACTS)/test/fixtures/ratio_curve.json
PY        := .venv/bin/python

.PHONY: help build test test-sol test-v test-py parity-fixture parity fmt \
        snapshot clean anvil venv data model fixtures signer keygen \
        web web-sync web-install web-build web-check setup deploy-local \
        signer-local deploy-sepolia

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Compile the contracts
	cd $(CONTRACTS) && forge build

parity-fixture: ## Regenerate the Solidity/Python parity fixture from model/risk_curve.py
	python3 model/risk_curve.py --dump $(FIXTURE)

test: test-sol test-py ## Run every test, Solidity and Python

fixtures: ## Regenerate the cross-language signature fixture
	$(PY) -m signer.fixtures

test-sol: parity-fixture fixtures ## Run the Solidity test suite
	cd $(CONTRACTS) && forge test

test-v: parity-fixture ## Run the Solidity suite with traces on failure
	cd $(CONTRACTS) && forge test -vv

test-py: ## Run the Python test suite
	$(PY) -m pytest tests -q

venv: ## Create .venv and install Python dependencies
	python3 -m venv .venv
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -r requirements.txt

data: ## Regenerate the labelled bootstrap dataset (synthetic, clearly marked)
	$(PY) -m model.bootstrap_data

model: data ## Train the model and write model/artifacts/model_report.json
	$(PY) -m model.train

signer: ## Run the signer service on :8000
	$(PY) -m signer.cli serve

web-sync: build ## Regenerate the frontend's ABIs and addresses from Foundry output
	node scripts/sync-contracts.mjs

web-install: ## Install frontend dependencies
	cd web && npm install

web: web-sync ## Run the frontend dev server on :3000
	cd web && npm run dev

web-build: web-sync ## Production build of the frontend
	cd web && npm run build

web-check: ## Typecheck the frontend
	cd web && npx tsc --noEmit

keygen: ## Generate a development signer key
	$(PY) -m signer.cli keygen

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

# anvil's first two development accounts. These keys are published in anvil's
# own startup banner, secure nothing, and only ever touch a local chain.
LOCAL_DEPLOYER := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
LOCAL_SIGNER_KEY := 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
LOCAL_SIGNER_ADDR := 0x70997970C51812dc3A010C7d01b50e0d17dc79C8

setup: venv model web-install ## One-time setup: venv, dependencies, trained model
	@echo
	@echo "Setup complete. Next: run 'make anvil', then 'make deploy-local' in a second"
	@echo "terminal, then 'make signer' and 'make web'."

deploy-local: build ## Deploy to a running local anvil and sync the frontend
	cd $(CONTRACTS) && DEPLOYER_PRIVATE_KEY=$(LOCAL_DEPLOYER) 		MODEL_SIGNER_ADDRESS=$(LOCAL_SIGNER_ADDR) 		forge script script/Deploy.s.sol:Deploy 		--rpc-url http://127.0.0.1:8545 --broadcast
	node scripts/sync-contracts.mjs

signer-local: ## Run the signer against the local deployment, with the anvil dev key
	MODEL_SIGNER_PRIVATE_KEY=$(LOCAL_SIGNER_KEY) $(PY) -m signer.cli serve

deploy-sepolia: ## Deploy to Sepolia (needs .env: DEPLOYER_PRIVATE_KEY, MODEL_SIGNER_ADDRESS, SEPOLIA_RPC_URL)
	cd $(CONTRACTS) && forge script script/Deploy.s.sol:Deploy \
		--rpc-url $${SEPOLIA_RPC_URL} --broadcast --verify -vvvv
