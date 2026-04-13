// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

/// @dev Minimal ERC20 interface used by V1 exchange token transfers
interface IERC20V1 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);

    function balanceOf(address) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @dev Mock Uniswap V1 Exchange that models the Vyper AMM formula.
 *      Implements addLiquidity, removeLiquidity, tokenToEthSwapInput,
 *      ethToTokenSwapInput and minimal ERC20 for LP tokens.
 */
contract MockUniswapV1Exchange {
    address public immutable token;

    // LP token accounting
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address _token) {
        token = _token;
    }

    receive() external payable {}

    // ------------------------------------------------------------------ LP ERC20
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    // ------------------------------------------------------------------ AMM helpers
    /// @dev Uniswap V1 getInputPrice formula (same as V2 with 0.3 % fee)
    function _getInputPrice(uint256 inputAmount, uint256 inputReserve, uint256 outputReserve)
        internal
        pure
        returns (uint256)
    {
        uint256 inputAmountWithFee = inputAmount * 997;
        uint256 numerator = inputAmountWithFee * outputReserve;
        uint256 denominator = inputReserve * 1000 + inputAmountWithFee;
        return numerator / denominator;
    }

    // ------------------------------------------------------------------ Liquidity
    /// @dev addLiquidity(min_liquidity, max_tokens, deadline) payable → liquidity_minted
    function addLiquidity(uint256, uint256 maxTokens, uint256) external payable returns (uint256 liquidityMinted) {
        uint256 ethReserve = address(this).balance - msg.value; // balance before this deposit
        uint256 tokenReserve = IERC20V1(token).balanceOf(address(this));

        uint256 tokenAmount;
        if (totalSupply == 0) {
            // Initial deposit: accept all provided tokens, LP = msg.value wei
            tokenAmount = maxTokens;
            liquidityMinted = msg.value;
        } else {
            // Proportional: tokenAmount rounded up (+1) to match Vyper behaviour
            tokenAmount = (msg.value * tokenReserve) / ethReserve + 1;
            require(tokenAmount <= maxTokens, "MockV1: EXCEED_MAX_TOKENS");
            liquidityMinted = (msg.value * totalSupply) / ethReserve;
        }

        require(IERC20V1(token).transferFrom(msg.sender, address(this), tokenAmount), "MockV1: TOKEN_TRANSFER_FAILED");
        totalSupply += liquidityMinted;
        balanceOf[msg.sender] += liquidityMinted;
    }

    /// @dev removeLiquidity(amount, min_eth, min_tokens, deadline) → (eth_amount, token_amount)
    function removeLiquidity(uint256 amount, uint256 minEth, uint256 minTokens, uint256)
        external
        returns (uint256 ethAmount, uint256 tokenAmount)
    {
        require(totalSupply > 0 && amount > 0, "MockV1: NO_LIQUIDITY");

        ethAmount = (address(this).balance * amount) / totalSupply;
        tokenAmount = (IERC20V1(token).balanceOf(address(this)) * amount) / totalSupply;

        require(ethAmount >= minEth, "MockV1: NOT_ENOUGH_ETH");
        require(tokenAmount >= minTokens, "MockV1: NOT_ENOUGH_TOKENS");

        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;

        payable(msg.sender).transfer(ethAmount);
        require(IERC20V1(token).transfer(msg.sender, tokenAmount), "MockV1: TOKEN_TRANSFER_FAILED");
    }

    // ------------------------------------------------------------------ Swaps
    /// @dev tokenToEthSwapInput(tokens_sold, min_eth, deadline) → eth_bought
    function tokenToEthSwapInput(uint256 tokensSold, uint256 minEth, uint256) external returns (uint256 ethBought) {
        uint256 tokenReserve = IERC20V1(token).balanceOf(address(this));
        ethBought = _getInputPrice(tokensSold, tokenReserve, address(this).balance);
        require(ethBought >= minEth, "MockV1: NOT_ENOUGH_ETH");
        require(IERC20V1(token).transferFrom(msg.sender, address(this), tokensSold), "MockV1: TOKEN_TRANSFER_FAILED");
        payable(msg.sender).transfer(ethBought);
    }

    /// @dev ethToTokenSwapInput(min_tokens, deadline) payable → tokens_bought
    function ethToTokenSwapInput(uint256 minTokens, uint256) external payable returns (uint256 tokensBought) {
        uint256 ethReserve = address(this).balance - msg.value; // pre-deposit ETH reserve
        uint256 tokenReserve = IERC20V1(token).balanceOf(address(this));
        tokensBought = _getInputPrice(msg.value, ethReserve, tokenReserve);
        require(tokensBought >= minTokens, "MockV1: NOT_ENOUGH_TOKENS");
        require(IERC20V1(token).transfer(msg.sender, tokensBought), "MockV1: TOKEN_TRANSFER_FAILED");
    }
}

/**
 * @dev Mock Uniswap V1 Factory that deploys MockUniswapV1Exchange instances.
 */
contract MockUniswapV1Factory {
    mapping(address => address) private _exchanges;

    /// @dev No-op for compatibility with code that calls initializeFactory(template)
    function initializeFactory(address) external {}

    function createExchange(address _token) external returns (address exchange) {
        require(_exchanges[_token] == address(0), "MockV1Factory: EXCHANGE_EXISTS");
        exchange = address(new MockUniswapV1Exchange(_token));
        _exchanges[_token] = exchange;
    }

    function getExchange(address _token) external view returns (address) {
        return _exchanges[_token];
    }
}
