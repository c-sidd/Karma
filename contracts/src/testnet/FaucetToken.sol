// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title  FaucetToken
/// @notice TESTNET ONLY. An ERC20 anyone can mint, so a Sepolia demo needs no
///         bridging and no faucet queue. Obviously worthless. Never deploy to
///         a network where the balances are supposed to mean anything.
contract FaucetToken {
    error FaucetLimit();

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public immutable faucetAmount;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 faucetAmount_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        faucetAmount = faucetAmount_;
    }

    /// @notice Mint the standard faucet amount to the caller.
    function drip() external {
        _mint(msg.sender, faucetAmount);
    }

    /// @notice Mint an arbitrary amount, capped so a fat finger cannot overflow supply.
    function mint(address to, uint256 amount) external {
        if (amount > faucetAmount * 1000) revert FaucetLimit();
        _mint(to, amount);
    }

    function _mint(address to, uint256 amount) private {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ERC20: allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private returns (bool) {
        require(balanceOf[from] >= amount, "ERC20: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
