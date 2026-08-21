// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Guarded} from "./Guarded.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IRiskParams} from "./interfaces/IRiskParams.sol";
import {IScoreOracle} from "./interfaces/IScoreOracle.sol";

/// @title LendingPool
/// @notice Single-collateral, single-debt-asset pool priced by credit score.
contract LendingPool is Guarded {
    error ZeroAmount(); error InsufficientCollateral(); error InsufficientLiquidity(); error BorrowCapExceeded();
    error NothingBorrowed(); error NotLiquidatable(); error CloseFactorExceeded(); error Reentrancy();
    error TransferFailed(); error RateTooHigh(); error InsufficientReserves(); error InvalidPrice(); error ZeroSeizure();

    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;
    uint256 public constant CLOSE_FACTOR_BPS = 5_000;
    uint256 public constant MAX_RATE_PER_SECOND_WAD = uint256(1e18) / 365 days;

    IERC20 public immutable collateralAsset;
    IERC20 public immutable debtAsset;
    uint256 private immutable _collateralUnit;
    uint256 private immutable _debtUnit;
    IScoreOracle public immutable scoreOracle;
    IRiskParams public immutable riskParams;
    IPriceOracle public priceOracle;

    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) private _scaledDebtOf;
    uint256 public totalScaledDebt;
    uint256 public borrowIndex = WAD;
    uint64 public lastAccrualTime;
    uint256 public ratePerSecondWad = uint256(5e16) / 365 days;
    uint256 public maxBorrowPerWallet;
    uint256 public liquidationBonusBps = 500;
    uint256 private _entered;

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint16 score, uint256 ratioBps);
    event Repaid(address indexed user, address indexed payer, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 repaid, uint256 seized);
    event Funded(uint256 amount); event Defunded(uint256 amount); event RateSet(uint256 ratePerSecondWad);
    event BorrowCapSet(uint256 maxBorrowPerWallet); event PriceOracleSet(address oracle); event LiquidationBonusSet(uint256 bonusBps);

    modifier nonReentrant() { if (_entered == 1) revert Reentrancy(); _entered = 1; _; _entered = 0; }

    constructor(address guardian_, address collateralAsset_, address debtAsset_, address scoreOracle_, address riskParams_, address priceOracle_, uint256 maxBorrowPerWallet_) Guarded(guardian_) {
        if (collateralAsset_ == address(0) || debtAsset_ == address(0) || scoreOracle_ == address(0) || riskParams_ == address(0) || priceOracle_ == address(0)) revert ZeroAddress();
        collateralAsset = IERC20(collateralAsset_); debtAsset = IERC20(debtAsset_);
        _collateralUnit = 10 ** IERC20(collateralAsset_).decimals(); _debtUnit = 10 ** IERC20(debtAsset_).decimals();
        scoreOracle = IScoreOracle(scoreOracle_); riskParams = IRiskParams(riskParams_); priceOracle = IPriceOracle(priceOracle_);
        maxBorrowPerWallet = maxBorrowPerWallet_; lastAccrualTime = uint64(block.timestamp);
    }

    function accrue() public {
        uint256 dt = block.timestamp - lastAccrualTime; if (dt == 0) return;
        if (totalScaledDebt != 0 && ratePerSecondWad != 0) borrowIndex += (borrowIndex * ratePerSecondWad * dt) / WAD;
        lastAccrualTime = uint64(block.timestamp);
    }
    function currentBorrowIndex() public view returns (uint256) {
        uint256 dt = block.timestamp - lastAccrualTime;
        if (dt == 0 || totalScaledDebt == 0 || ratePerSecondWad == 0) return borrowIndex;
        return borrowIndex + (borrowIndex * ratePerSecondWad * dt) / WAD;
    }

    function depositCollateral(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount(); collateralOf[msg.sender] += amount; _pull(collateralAsset, msg.sender, amount); emit CollateralDeposited(msg.sender, amount);
    }
    function withdrawCollateral(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount(); accrue(); uint256 balance = collateralOf[msg.sender]; if (amount > balance) revert InsufficientCollateral();
        uint256 remaining = balance - amount; uint256 debt = debtOf(msg.sender);
        if (debt != 0) { uint256 ratioBps = _borrowRatioBpsOrWorst(msg.sender); if (_debtUsd(debt) * ratioBps > _collateralUsd(remaining) * BPS) revert InsufficientCollateral(); }
        collateralOf[msg.sender] = remaining; _push(collateralAsset, msg.sender, amount); emit CollateralWithdrawn(msg.sender, amount);
    }
    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount(); accrue(); uint16 score = scoreOracle.requireValidScore(msg.sender); uint256 ratioBps = riskParams.collateralRatioBps(score);
        uint256 newDebt = debtOf(msg.sender) + amount; if (newDebt > maxBorrowPerWallet) revert BorrowCapExceeded();
        if (_debtUsd(newDebt) * ratioBps > _collateralUsd(collateralOf[msg.sender]) * BPS) revert InsufficientCollateral();
        if (amount > debtAsset.balanceOf(address(this))) revert InsufficientLiquidity();
        uint256 scaledDelta = _divUp(amount * WAD, borrowIndex); _scaledDebtOf[msg.sender] += scaledDelta; totalScaledDebt += scaledDelta;
        _push(debtAsset, msg.sender, amount); emit Borrowed(msg.sender, amount, score, ratioBps);
    }
    function repay(address onBehalfOf, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount(); accrue(); uint256 debt = debtOf(onBehalfOf); if (debt == 0) revert NothingBorrowed();
        uint256 paid = amount > debt ? debt : amount; _burnDebt(onBehalfOf, paid, debt); _pull(debtAsset, msg.sender, paid); emit Repaid(onBehalfOf, msg.sender, paid);
    }

    function liquidate(address user, uint256 repayAmount) external nonReentrant whenNotPaused {
        if (repayAmount == 0) revert ZeroAmount(); accrue(); uint256 debt = debtOf(user); if (debt == 0) revert NothingBorrowed();
        if (!isLiquidatable(user)) revert NotLiquidatable();
        // Round the close factor up so very small debts can still be liquidated.
        uint256 maxRepay = (debt * CLOSE_FACTOR_BPS + BPS - 1) / BPS;
        if (repayAmount > maxRepay) revert CloseFactorExceeded();
        uint256 collateralPrice = _price(address(collateralAsset));
        uint256 seize = (_debtUsd(repayAmount) * (BPS + liquidationBonusBps) * _collateralUnit) / (BPS * collateralPrice);
        uint256 posted = collateralOf[user]; if (seize > posted) seize = posted; if (seize == 0) revert ZeroSeizure();
        _burnDebt(user, repayAmount, debt); collateralOf[user] = posted - seize;
        _pull(debtAsset, msg.sender, repayAmount); _push(collateralAsset, msg.sender, seize); emit Liquidated(user, msg.sender, repayAmount, seize);
    }

    function debtOf(address user) public view returns (uint256) { uint256 scaled = _scaledDebtOf[user]; if (scaled == 0) return 0; return _divUp(scaled * currentBorrowIndex(), WAD); }
    function scaledDebtOf(address user) external view returns (uint256) { return _scaledDebtOf[user]; }
    function currentRatioBps(address user) public view returns (uint256) { uint256 debt = debtOf(user); if (debt == 0) return type(uint256).max; return (_collateralUsd(collateralOf[user]) * BPS) / _debtUsd(debt); }
    function maxBorrowable(address user) external view returns (uint256) {
        (uint16 score, bool valid) = scoreOracle.scoreOf(user); if (!valid) return 0; uint256 ratioBps = riskParams.collateralRatioBps(score);
        uint256 capacityUsd = (_collateralUsd(collateralOf[user]) * BPS) / ratioBps; uint256 debtUsd = _debtUsd(debtOf(user)); if (capacityUsd <= debtUsd) return 0;
        uint256 debtPrice = _price(address(debtAsset)); uint256 headroom = ((capacityUsd - debtUsd) * _debtUnit) / debtPrice; uint256 cap = maxBorrowPerWallet; uint256 debt = debtOf(user);
        uint256 capHeadroom = debt >= cap ? 0 : cap - debt; if (headroom > capHeadroom) headroom = capHeadroom; uint256 liquidity = debtAsset.balanceOf(address(this)); return headroom > liquidity ? liquidity : headroom;
    }
    function isLiquidatable(address user) public view returns (bool) { uint256 debt = debtOf(user); if (debt == 0) return false; return currentRatioBps(user) < _liquidationRatioBpsOrWorst(user); }
    function liquidationDistanceBps(address user) external view returns (uint256) { uint256 debt = debtOf(user); if (debt == 0) return type(uint256).max; uint256 current = currentRatioBps(user); uint256 threshold = _liquidationRatioBpsOrWorst(user); return current <= threshold ? 0 : current - threshold; }
    function availableLiquidity() external view returns (uint256) { return debtAsset.balanceOf(address(this)); }
    function totalDebt() external view returns (uint256) { return _divUp(totalScaledDebt * currentBorrowIndex(), WAD); }

    function fund(uint256 amount) external onlyOwner { if (amount == 0) revert ZeroAmount(); _pull(debtAsset, msg.sender, amount); emit Funded(amount); }
    function defund(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount(); accrue(); uint256 balance = debtAsset.balanceOf(address(this));
        uint256 outstandingPrincipal = (totalScaledDebt * WAD) / borrowIndex;
        if (amount > balance || balance - amount < outstandingPrincipal) revert InsufficientReserves();
        _push(debtAsset, msg.sender, amount); emit Defunded(amount);
    }
    function setRatePerSecondWad(uint256 rate) external onlyOwner { if (rate > MAX_RATE_PER_SECOND_WAD) revert RateTooHigh(); accrue(); ratePerSecondWad = rate; emit RateSet(rate); }
    function setMaxBorrowPerWallet(uint256 cap) external onlyOwner { maxBorrowPerWallet = cap; emit BorrowCapSet(cap); }
    function setPriceOracle(address oracle) external onlyOwner { if (oracle == address(0)) revert ZeroAddress(); priceOracle = IPriceOracle(oracle); emit PriceOracleSet(oracle); }
    function setLiquidationBonusBps(uint256 bonusBps) external onlyOwner { if (bonusBps > 2_000) revert RateTooHigh(); liquidationBonusBps = bonusBps; emit LiquidationBonusSet(bonusBps); }

    function _burnDebt(address user, uint256 paid, uint256 currentDebt) private {
        uint256 scaled = _scaledDebtOf[user]; uint256 scaledDelta = paid >= currentDebt ? scaled : (paid * WAD) / borrowIndex;
        if (scaledDelta > scaled) scaledDelta = scaled; _scaledDebtOf[user] = scaled - scaledDelta; totalScaledDebt -= scaledDelta;
    }
    function _borrowRatioBpsOrWorst(address user) private view returns (uint256) { (uint16 score, bool valid) = scoreOracle.scoreOf(user); return valid ? riskParams.collateralRatioBps(score) : riskParams.worstCaseRatioBps(); }
    function _liquidationRatioBpsOrWorst(address user) private view returns (uint256) { (uint16 score, bool valid) = scoreOracle.scoreOf(user); return valid ? riskParams.liquidationRatioBps(score) : riskParams.worstCaseLiquidationRatioBps(); }
    function _price(address asset) private view returns (uint256) { uint256 price = priceOracle.priceOf(asset); if (price == 0) revert InvalidPrice(); return price; }
    function _collateralUsd(uint256 amount) private view returns (uint256) { return (amount * _price(address(collateralAsset))) / _collateralUnit; }
    function _debtUsd(uint256 amount) private view returns (uint256) { return (amount * _price(address(debtAsset))) / _debtUnit; }
    function _divUp(uint256 a, uint256 b) private pure returns (uint256) { return a == 0 ? 0 : (a - 1) / b + 1; }
    function _pull(IERC20 token, address from, uint256 amount) private { _check(address(token), abi.encodeCall(IERC20.transferFrom, (from, address(this), amount))); }
    function _push(IERC20 token, address to, uint256 amount) private { if (amount == 0) return; _check(address(token), abi.encodeCall(IERC20.transfer, (to, amount))); }
    function _check(address token, bytes memory data) private { (bool ok, bytes memory ret) = token.call(data); if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed(); }
}
