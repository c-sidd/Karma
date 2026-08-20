// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Guardian} from "../src/Guardian.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {RiskParams} from "../src/RiskParams.sol";
import {ScoreOracle} from "../src/ScoreOracle.sol";
import {StaticPriceOracle} from "../src/StaticPriceOracle.sol";
import {FaucetToken} from "../src/testnet/FaucetToken.sol";

/// @notice Deploys the whole protocol and writes the address book the frontend and the
///         signer service read.
///
///     forge script script/Deploy.s.sol:Deploy --rpc-url sepolia --broadcast --verify
///
/// Required env:
///     DEPLOYER_PRIVATE_KEY   funded Sepolia key
///     MODEL_SIGNER_ADDRESS   address of the key the signer service holds
/// Optional env:
///     PROTOCOL_OWNER         defaults to the deployer
///     POOL_SEED_USDC         debt-asset liquidity to seed, 6dp (default 1,000,000)
contract Deploy is Script {
    uint256 internal constant WETH_PRICE = 2_000e8;
    uint256 internal constant USDC_PRICE = 1e8;
    uint256 internal constant BORROW_CAP = 100_000e6;

    /// @dev Grouped into a struct because eight live addresses overflow the stack.
    struct Deployment {
        Guardian guardian;
        RiskParams riskParams;
        ScoreOracle scoreOracle;
        StaticPriceOracle priceOracle;
        LendingPool pool;
        FaucetToken weth;
        FaucetToken usdc;
        address modelSigner;
    }

    Deployment internal d;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address protocolOwner = vm.envOr("PROTOCOL_OWNER", deployer);

        d.modelSigner = vm.envAddress("MODEL_SIGNER_ADDRESS");
        require(d.modelSigner != address(0), "MODEL_SIGNER_ADDRESS unset");

        console2.log("deployer     ", deployer);
        console2.log("protocolOwner", protocolOwner);
        console2.log("modelSigner  ", d.modelSigner);
        console2.log("chainId      ", block.chainid);

        vm.startBroadcast(deployerPk);
        _deploy(deployer);
        _configure(deployer, protocolOwner);
        vm.stopBroadcast();

        _report();
    }

    /// @dev Deployed with the deployer as owner so this script can configure freely;
    ///      ownership is handed over at the end if a different owner was asked for.
    function _deploy(address deployer) private {
        d.guardian = new Guardian(deployer);
        d.riskParams = new RiskParams(address(d.guardian));
        d.scoreOracle = new ScoreOracle(address(d.guardian), d.modelSigner);
        d.priceOracle = new StaticPriceOracle(address(d.guardian));

        d.weth = new FaucetToken("Karma Test WETH", "kWETH", 18, 10 ether);
        d.usdc = new FaucetToken("Karma Test USDC", "kUSDC", 6, 10_000e6);

        d.pool = new LendingPool(
            address(d.guardian),
            address(d.weth),
            address(d.usdc),
            address(d.scoreOracle),
            address(d.riskParams),
            address(d.priceOracle),
            BORROW_CAP
        );
    }

    function _configure(address deployer, address protocolOwner) private {
        d.priceOracle.setPrice(address(d.weth), WETH_PRICE);
        d.priceOracle.setPrice(address(d.usdc), USDC_PRICE);

        uint256 seed = vm.envOr("POOL_SEED_USDC", uint256(1_000_000e6));
        d.usdc.mint(deployer, seed);
        d.usdc.approve(address(d.pool), seed);
        d.pool.fund(seed);

        if (protocolOwner != deployer) {
            d.guardian.transferOwnership(protocolOwner);
            console2.log("ownership offered to", protocolOwner);
            console2.log("call Guardian.acceptOwnership() from that address to complete");
        }
    }

    function _report() private {
        console2.log("Guardian         ", address(d.guardian));
        console2.log("RiskParams       ", address(d.riskParams));
        console2.log("ScoreOracle      ", address(d.scoreOracle));
        console2.log("StaticPriceOracle", address(d.priceOracle));
        console2.log("LendingPool      ", address(d.pool));
        console2.log("kWETH            ", address(d.weth));
        console2.log("kUSDC            ", address(d.usdc));
        console2.log("domainSeparator  ", vm.toString(d.scoreOracle.DOMAIN_SEPARATOR()));

        string memory key = "karma-deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "Guardian", address(d.guardian));
        vm.serializeAddress(key, "RiskParams", address(d.riskParams));
        vm.serializeAddress(key, "ScoreOracle", address(d.scoreOracle));
        vm.serializeAddress(key, "StaticPriceOracle", address(d.priceOracle));
        vm.serializeAddress(key, "LendingPool", address(d.pool));
        vm.serializeAddress(key, "collateralAsset", address(d.weth));
        vm.serializeAddress(key, "debtAsset", address(d.usdc));
        vm.serializeAddress(key, "modelSigner", d.modelSigner);
        string memory json = vm.serializeBytes32(key, "domainSeparator", d.scoreOracle.DOMAIN_SEPARATOR());

        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("wrote", path);
    }
}
