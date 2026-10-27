// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
 *  fusi.ng  |  the Ethereum launchpad
 *  ----------------------------------
 *  Web:       https://fusi.ng
 *  X:         https://x.com/fusi_ng
 *  Telegram:  https://t.me/fusi_ng
 *  Docs:      https://fusi.ng/docs
 *
 *  Launched on fusi.ng. A fixed supply, minted once, into a Uniswap V4 pool
 *  whose liquidity is locked for ever. This contract is the whole token:
 *  no owner, no mint, no pause, no blacklist, no tax, no proxy, no upgrade,
 *  and not one address written into it. Trading fees are charged by the
 *  pool, not by the token, and are paid out through the Fuse Vault.
 */

/**
 * @title FusingTokenLean
 * @notice The plain fusi.ng launch token: an ERC-20 and nothing else.
 *
 * Deliberately contains no address of any kind. It has no `owner()`, and it
 * does not record the factory that launched it. That is not cosmetic: a
 * token carrying a hardcoded address is reported as having a hidden owner by
 * the scanners wallets and terminals embed, whether or not the address has
 * any power, and a launch that reads as "hidden owner" is dead on arrival
 * however clean its code. Six variants of this contract were deployed to
 * mainnet and checked to find that out; the one with no stored address is
 * the only one that came back clean. The factory that launched a token is
 * still knowable, from the factory's own launch record and its events.
 *
 * The name and symbol live in the code itself (up to 32 bytes each), so a
 * launch writes no strings to storage and the only state is balances and
 * allowances. Everything a launch can switch on (caps, a whitelist window,
 * holder rewards) belongs to the other token; a launch that uses none of it
 * deploys this one and pays for nothing it does not use.
 */
contract FusingTokenLean {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();
    error NameTooLong();

    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;
    bytes32 private immutable _name;
    bytes32 private immutable _symbol;
    uint8 private immutable _nameLength;
    uint8 private immutable _symbolLength;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, address supplyRecipient, uint256 supply) {
        if (supplyRecipient == address(0)) revert ZeroAddress();
        if (bytes(name_).length > 32 || bytes(symbol_).length > 32) revert NameTooLong();
        _name = bytes32(bytes(name_));
        _symbol = bytes32(bytes(symbol_));
        _nameLength = uint8(bytes(name_).length);
        _symbolLength = uint8(bytes(symbol_).length);
        totalSupply = supply;
        balanceOf[supplyRecipient] = supply;
        emit Transfer(address(0), supplyRecipient, supply);
    }

    function name() external view returns (string memory) {
        return _unpack(_name, _nameLength);
    }

    function symbol() external view returns (string memory) {
        return _unpack(_symbol, _symbolLength);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - value;
            }
        }
        _move(from, to, value);
        return true;
    }

    function _move(address from, address to, uint256 value) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value; // cannot overflow: the sum of balances is the fixed supply
        }
        emit Transfer(from, to, value);
    }

    function _unpack(bytes32 packed, uint8 length) private pure returns (string memory s) {
        s = new string(length);
        assembly {
            mstore(add(s, 32), packed)
        }
    }
}
