// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Guarded} from "./Guarded.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IRiskParams} from "./interfaces/IRiskParams.sol";
import {IScoreOracle} from "./interfaces/IScoreOracle.sol";

/// @title  LendingPool
/// @notice Single-collateral, single-debt-asset pool priced by credit score.
///
/// @dev The load-bearing line in this contract is in borrow():
///
///          uint16 score = scoreOracle.requireValidScore(msg.sender);
///
///      requireValidScore reverts unless ScoreOracle holds a record it produced by
///      recovering a registered model signer's ECDSA signature. There is no other
///      way into the ratio lookup, no owner override, no default score, and no
///      branch that prices a loan when that call fails.
///
///      Health checks outside borrow() (withdrawCollateral, liquidate) fall back to
///      the worst ratio on the curve when an attestation is missing or expired.
///      Falling back conservatively is safe there; falling back at all in borrow()
///      would not be, because it would let an unscored wallet borrow.
///
///      Out of scope for M1, deliberately: lender-side share accounting. Liquidity is
///      funded by the owner via fund(); accrued interest stays in the pool as reserves.
contract LendingPool is Guarded {
    error ZeroAmount();
    error InsufficientCollateral();
    error InsufficientLiquidity();
    error BorrowCapExceeded();
    error NothingBorrowed();
    error NotLiquidatable();
    error CloseFactorExceeded();
    error Reentrancy();
    error TransferFailed();
    error RateTooHigh();

    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;
    uint256 public constant PRICE_SCALE = 1e8;
    /// @notice Fraction of a position a single liquidation may repay.
    uint256 public constant CLOSE_FACTOR_BPS = 5_000;
    /// @notice Ceiling on the governable borrow rate: 100% APR.
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
    uint256 public ratePerSecondWad = uint256(5e16) / 365 days; // 5% APR
    uint256 public maxBorrowPerWallet;
    uint256 public liquidationBonusBps = 500; // 5%

    uint256 private _entered;

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint16 score, uint256 ratioBps);
    event Repaid(address indexed user, address indexed payer, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 repaid, uint256 seized);
    event Funded(uint256 amount);
    event Defunded(uint256 amount);
    event RateSet(uint256 ratePerSecondWad);
    event BorrowCapSet(uint256 maxBorrowPerWallet);
    event PriceOracleSet(address oracle);
    event LiquidationBonusSet(uint256 bonusBps);

    modifier nonReentrant() {
        if (_entered == 1) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(
        address guardian_,
        address collateralAsset_,
        address debtAsset_,
        address scoreOracle_,
        address riskParams_,
        address priceOracle_,
        uint256 maxBorrowPerWallet_
    ) Guarded(guardian_) {
        if (
            collateralAsset_ == address(0) || debtAsset_ == address(0) || scoreOracle_ == address(0)
                || riskParams_ == address(0) || priceOracle_ == address(0)
        ) revert ZeroAddress();

        collateralAsset = IERC20(collateralAsset_);
        debtAsset = IERC20(debtAsset_);
        _collateralUnit = 10 ** IERC20(collateralAsset_).decimals();
        _debtUnit = 10 ** IERC20(debtAsset_).decimals();
        scoreOracle = IScoreOracle(scoreOracle_);
        riskParams = IRiskParams(riskParams_);
        priceOracle = IPriceOracle(priceOracle_);
        maxBorrowPerWallet = maxBorrowPerWallet_;
        lastAccrualTime = uint64(block.timestamp);
    }

    // ------------------------------------------------------------ interest

    /// @dev Linear accrual over the elapsed period. Not continuously compounded:
    ///      simpler to reason about and to mirror off-chain, and the difference is
    ///      immaterial at testnet rates.
    function accrue() public {
        uint256 dt = block.timestamp - lastAccrualTime;
        if (dt == 0) return;
        if (totalScaledDebt != 0 && ratePerSecondWad != 0) {
            borrowIndex += (borrowIndex * ratePerSecondWad * dt) / WAD;
        }
        lastAccrualTime = uint64(block.timestamp);
    }

    /// @notice Borrow index as it would stand right now, without writing storage.
    function currentBorrowIndex() public view returns (uint256) {
        uint256 dt = block.timestamp - lastAccrualTime;
        if (dt == 0 || totalScaledDebt == 0 || ratePerSecondWad == 0) return borrowIndex;
        return borrowIndex + (borrowIndex * ratePerSecondWad * dt) / WAD;
    }

    // ------------------------------------------------------------ user actions

    function depositCollateral(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        collateralOf[msg.sender] += amount;
        _pull(collateralAsset, msg.sender, amount);
        emit CollateralDeposited(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        accrue();

        uint256 balance = collateralOf[msg.sender];
        if (amount > balance) revert InsufficientCollateral();
        uint256 remaining = balance - amount;

        uint256 debt = debtOf(msg.sender);
        if (debt != 0) {
            // Conservative on purpose: an expired attestation prices the check at the
            // worst ratio on the curve rather than letting collateral walk out.
            uint256 ratioBps = _borrowRatioBpsOrWorst(msg.sender);
            if (_debtUsd(debt) * ratioBps > _collateralUsd(remaining) * BPS) {
                revert InsufficientCollateral();
            }
        }

        collateralOf[msg.sender] = remaining;
        _push(collateralAsset, msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    /// @notice Borrow `amount` of the debt asset against deposited collateral.
    /// @dev Reverts with ScoreOracle.NoAttestation() / AttestationExpired() /
    ///      StaleModelVersion() for any wallet without a live verified score.
    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        accrue();

        // The only source of a score. No fallback, no override.
        uint16 score = scoreOracle.requireValidScore(msg.sender);
        uint256 ratioBps = riskParams.collateralRatioBps(score);

        uint256 newDebt = debtOf(msg.sender) + amount;
        if (newDebt > maxBorrowPerWallet) revert BorrowCapExceeded();
        if (_debtUsd(newDebt) * ratioBps > _collateralUsd(collateralOf[msg.sender]) * BPS) {
            revert InsufficientCollateral();
        }
        if (amount > debtAsset.balanceOf(address(this))) revert InsufficientLiquidity();

        uint256 scaledDelta = _divUp(amount * WAD, borrowIndex);
        _scaledDebtOf[msg.sender] += scaledDelta;
        totalScaledDebt += scaledDelta;

        _push(debtAsset, msg.sender, amount);
        emit Borrowed(msg.sender, amount, score, ratioBps);
    }

    function repay(address onBehalfOf, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        accrue();

        uint256 debt = debtOf(onBehalfOf);
        if (debt == 0) revert NothingBorrowed();

        uint256 paid = amount > debt ? debt : amount;
        _burnDebt(onBehalfOf, paid, debt);
        _pull(debtAsset, msg.sender, paid);
        emit Repaid(onBehalfOf, msg.sender, paid);
    }

    /// @notice Repay part of an unhealthy position and seize collateral at a bonus.
    function liquidate(address user, uint256 repayAmount) external nonReentrant whenNotPaused {
        if (repayAmount == 0) revert ZeroAmount();
        accrue();

        uint256 debt = debtOf(user);
        if (debt == 0) revert NothingBorrowed();
        if (!isLiquidatable(user)) revert NotLiquidatable();
        if (repayAmount > (debt * CLOSE_FACTOR_BPS) / BPS) revert CloseFactorExceeded();

        uint256 seize = (_debtUsd(repayAmount) * (BPS + liquidationBonusBps) * _collateralUnit)
            / (BPS * _price(address(collateralAsset)));

        uint256 posted = collateralOf[user];
        if (seize > posted) seize = posted;

        _burnDebt(user, repayAmount, debt);
        collateralOf[user] = posted - seize;

        _pull(debtAsset, msg.sender, repayAmount);
        _push(collateralAsset, msg.sender, seize);
        emit Liquidated(user, msg.sender, repayAmount, seize);
    }

    // ------------------------------------------------------------ views

    function debtOf(address user) public view returns (uint256) {
        uint256 scaled = _scaledDebtOf[user];
        if (scaled == 0) return 0;
        return _divUp(scaled * currentBorrowIndex(), WAD);
    }

    function scaledDebtOf(address user) external view returns (uint256) {
        return _scaledDebtOf[user];
    }

    /// @notice Collateralisation of `user` in bps. type(uint256).max when debt-free.
    function currentRatioBps(address user) public view returns (uint256) {
        uint256 debt = debtOf(user);
        if (debt == 0) return type(uint256).max;
        return (_collateralUsd(collateralOf[user]) * BPS) / _debtUsd(debt);
    }

    /// @notice Largest additional borrow `user` could take right now, in debt units.
    /// @dev Returns 0 rather than reverting when there is no valid attestation, so a
    ///      UI can render the state without a try/catch.
    function maxBorrowable(address user) external view returns (uint256) {
        (uint16 score, bool valid) = scoreOracle.scoreOf(user);
        if (!valid) return 0;
        uint256 ratioBps = riskParams.collateralRatioBps(score);
        uint256 capacityUsd = (_collateralUsd(collateralOf[user]) * BPS) / ratioBps;
        uint256 debtUsd = _debtUsd(debtOf(user));
        if (capacityUsd <= debtUsd) return 0;

        uint256 headroom = ((capacityUsd - debtUsd) * _debtUnit) / _price(address(debtAsset));
        uint256 cap = maxBorrowPerWallet;
        uint256 debt = debtOf(user);
        uint256 capHeadroom = debt >= cap ? 0 : cap - debt;
        if (headroom > capHeadroom) headroom = capHeadroom;

        uint256 liquidity = debtAsset.balanceOf(address(this));
        return headroom > liquidity ? liquidity : headroom;
    }

    function isLiquidatable(address user) public view returns (bool) {
        uint256 debt = debtOf(user);
        if (debt == 0) return false;
        return currentRatioBps(user) < _liquidationRatioBpsOrWorst(user);
    }

    /// @notice Distance to liquidation in bps: current ratio minus the liquidation
    ///         ratio. Negative distance is reported as 0, i.e. already liquidatable.
    function liquidationDistanceBps(address user) external view returns (uint256) {
        uint256 debt = debtOf(user);
        if (debt == 0) return type(uint256).max;
        uint256 current = currentRatioBps(user);
        uint256 threshold = _liquidationRatioBpsOrWorst(user);
        return current <= threshold ? 0 : current - threshold;
    }

    function availableLiquidity() external view returns (uint256) {
        return debtAsset.balanceOf(address(this));
    }

    function totalDebt() external view returns (uint256) {
        return _divUp(totalScaledDebt * currentBorrowIndex(), WAD);
    }

    // ------------------------------------------------------------ governance

    function fund(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        _pull(debtAsset, msg.sender, amount);
        emit Funded(amount);
    }

    function defund(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        _push(debtAsset, msg.sender, amount);
        emit Defunded(amount);
    }

    function setRatePerSecondWad(uint256 rate) external onlyOwner {
        if (rate > MAX_RATE_PER_SECOND_WAD) revert RateTooHigh();
        accrue();
        ratePerSecondWad = rate;
        emit RateSet(rate);
    }

    function setMaxBorrowPerWallet(uint256 cap) external onlyOwner {
        maxBorrowPerWallet = cap;
        emit BorrowCapSet(cap);
    }

    function setPriceOracle(address oracle) external onlyOwner {
        if (oracle == address(0)) revert ZeroAddress();
        priceOracle = IPriceOracle(oracle);
        emit PriceOracleSet(oracle);
    }

    function setLiquidationBonusBps(uint256 bonusBps) external onlyOwner {
        if (bonusBps > 2_000) revert RateTooHigh();
        liquidationBonusBps = bonusBps;
        emit LiquidationBonusSet(bonusBps);
    }

    // ------------------------------------------------------------ internals

    function _burnDebt(address user, uint256 paid, uint256 currentDebt) private {
        uint256 scaled = _scaledDebtOf[user];
        uint256 scaledDelta = paid >= currentDebt ? scaled : (paid * WAD) / borrowIndex;
        if (scaledDelta > scaled) scaledDelta = scaled;
        _scaledDebtOf[user] = scaled - scaledDelta;
        totalScaledDebt -= scaledDelta;
    }

    function _borrowRatioBpsOrWorst(address user) private view returns (uint256) {
        (uint16 score, bool valid) = scoreOracle.scoreOf(user);
        return valid ? riskParams.collateralRatioBps(score) : riskParams.worstCaseRatioBps();
    }

    function _liquidationRatioBpsOrWorst(address user) private view returns (uint256) {
        (uint16 score, bool valid) = scoreOracle.scoreOf(user);
        return valid ? riskParams.liquidationRatioBps(score) : riskParams.worstCaseLiquidationRatioBps();
    }

    function _price(address asset) private view returns (uint256) {
        return priceOracle.priceOf(asset);
    }

    /// @return USD value scaled to PRICE_SCALE (1e8).
    function _collateralUsd(uint256 amount) private view returns (uint256) {
        return (amount * _price(address(collateralAsset))) / _collateralUnit;
    }

    function _debtUsd(uint256 amount) private view returns (uint256) {
        return (amount * _price(address(debtAsset))) / _debtUnit;
    }

    function _divUp(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _pull(IERC20 token, address from, uint256 amount) private {
        _check(address(token), abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
    }

    function _push(IERC20 token, address to, uint256 amount) private {
        if (amount == 0) return;
        _check(address(token), abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    /// @dev Tolerates tokens that return nothing instead of a bool.
    function _check(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
