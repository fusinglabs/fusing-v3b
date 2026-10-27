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
 *  Fusing V2 contracts. Every launch pays 1.1% per trade, 60% to the creator
 *  and 40% to the protocol, paid out in ETH. V2 puts the terms in the
 *  creator's hands: token limits, fee schedules, anti-sniper windows, holder
 *  rewards, five-way fee splits and the payout mode.
 */

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFusingFeeEscrow} from "./interfaces/ILaunchpadV2.sol";

/**
 * @title FusingFeeEscrow
 * @notice The ledger of claimable balances. In V3 the Fuse Vault's modules
 * credit it: the wallets module books a wallet's share to its claimable
 * balance, and the handles module books a share to an X account, keyed by
 * the keccak of the lower-cased handle. Whoever proves control of the
 * account collects it: after a login with X or Telegram, the fusi.ng attester signs
 * (handle, wallet, deadline), and `claimHandle` moves the balance into that
 * wallet's own ledger. The escrow holds no payout plan of its own; every
 * launch's fee configuration lives in the Vault.
 *
 * Crediting needs no permission. Native credits bring their own ETH and token
 * credits are pulled from the caller, so a stranger crediting the escrow can
 * only lose value, never take it. Token credits book the balance change that
 * actually landed.
 */
contract FusingFeeEscrow is IFusingFeeEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;


    error ZeroAddress();
    error NativeValueRequired();
    error InsufficientBalance(uint256 requested, uint256 available);
    error TransferFailed();
    error AttestationExpired(uint256 deadline);
    error BadAttestation();
    error NoAttester();

    event Credited(address indexed recipient, uint256 amount);
    event CreditedToken(address indexed recipient, address indexed token, uint256 amount);
    event CreditedHandle(bytes32 indexed handle, address indexed token, uint256 amount);
    event Claimed(address indexed recipient, uint256 amount);
    event ClaimedToken(address indexed recipient, address indexed token, uint256 amount);
    event HandleClaimed(bytes32 indexed handle, address indexed to, address indexed token, uint256 amount);
    event AttesterSet(address indexed attester);

    /// @dev The token ledgers file native ETH under the zero address.
    address private constant NATIVE = address(0);

    /// @notice The fusi.ng owner: the account that appoints the attester.
    address public immutable owner;
    /// @notice The key that signs proofs of X handle ownership. The owner can replace it.
    address public attester;

    mapping(address recipient => uint256 amount) private _nativeBalances;
    mapping(address recipient => mapping(address token => uint256 amount)) private _tokenBalances;
    /// @dev Per-handle balances, one entry per asset, with native ETH under address(0).
    mapping(bytes32 handle => mapping(address asset => uint256 amount)) private _handleBalances;

    error NotOwner();

    /// @dev Whoever deploys the escrow owns it; the escrow has to exist before the factory that depends on it.
    constructor() {
        owner = msg.sender;
    }

    // ---------------------------------------------------------------------
    // Fee credits
    // ---------------------------------------------------------------------

    /// @notice The V1 call: books the ETH sent with the call to `recipient`.
    function credit(address recipient) external payable {
        if (recipient == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert NativeValueRequired();
        _creditNative(recipient, msg.value);
    }

    /// @notice The V1 call: draws `amount` of `token` from the caller and books whatever actually landed.
    function creditToken(address recipient, address token, uint256 amount) external {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        uint256 received = _pull(token, amount);
        _creditToken(recipient, token, received);
    }

    function _creditAsset(address recipient, address asset, uint256 amount) private {
        if (asset == NATIVE) _creditNative(recipient, amount);
        else _creditToken(recipient, asset, amount);
    }

    function _creditNative(address recipient, uint256 amount) private {
        _nativeBalances[recipient] += amount;
        emit Credited(recipient, amount);
    }

    function _creditToken(address recipient, address token, uint256 amount) private {
        _tokenBalances[recipient][token] += amount;
        emit CreditedToken(recipient, token, amount);
    }

    function _pull(address token, uint256 amount) private returns (uint256 received) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - before;
    }

    // ---------------------------------------------------------------------
    // X handle claims
    // ---------------------------------------------------------------------

    /// @notice Sets the key whose signatures prove handle ownership. Owner only.
    /**
     * @notice Credits an X handle with `amount` of `asset` (ETH as msg.value,
     * an ERC-20 pulled from the caller). Permissionless, the way `credit`
     * is: whoever proves the handle through the attester claims it.
     */
    error HandleValueMismatch();
    error EmptyHandle();

    function creditHandle(bytes32 handle, address asset, uint256 amount) external payable {
        if (handle == bytes32(0)) revert EmptyHandle();
        uint256 got;
        if (asset == NATIVE) {
            if (msg.value != amount) revert HandleValueMismatch();
            got = msg.value;
        } else {
            if (msg.value != 0) revert HandleValueMismatch();
            got = _pull(asset, amount);
        }
        if (got == 0) return;
        _handleBalances[handle][asset] += got;
        emit CreditedHandle(handle, asset, got);
    }

    function setAttester(address attester_) external {
        if (msg.sender != owner) revert NotOwner();
        attester = attester_;
        emit AttesterSet(attester_);
    }

    /**
     * @notice The digest the attester signs to vouch that `wallet` controls
     * `handle` until `deadline`. It folds in the chain id and this contract's
     * address, so the same signature is useless anywhere else.
     */
    function attestationDigest(bytes32 handle, address wallet, uint256 deadline) public view returns (bytes32) {
        return keccak256(abi.encode("fusi.ng handle attestation", block.chainid, address(this), handle, wallet, deadline));
    }

    /**
     * @notice Transfers a handle's balance of `asset` (native under
     * address(0)) into the caller's own claimable ledger, provided the caller
     * presents an unexpired attestation of ownership. From there it is claimed
     * like any other balance.
     */
    function claimHandle(bytes32 handle, address asset, uint256 deadline, bytes calldata signature)
        external
        returns (uint256 amount)
    {
        if (attester == address(0)) revert NoAttester();
        if (block.timestamp > deadline) revert AttestationExpired(deadline);
        bytes32 digest =
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", attestationDigest(handle, msg.sender, deadline)));
        if (_recover(digest, signature) != attester) revert BadAttestation();

        amount = _handleBalances[handle][asset];
        if (amount == 0) return 0;
        _handleBalances[handle][asset] = 0;
        _creditAsset(msg.sender, asset, amount);
        emit HandleClaimed(handle, msg.sender, asset, amount);
    }

    /// @dev Bare ecrecover plus the high-s malleability guard; the OpenZeppelin copy we pin does not include ECDSA.
    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) revert BadAttestation();
        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) revert BadAttestation();
        if (v != 27 && v != 28) revert BadAttestation();
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadAttestation();
        return signer;
    }

    /**
     * @notice Computes the key a plan stores for a handle: keccak256 of
     * `<platform>:<handle>`, both lower-cased, the @ left off. Platforms are
     * "x" and "tg".
     *
     * The platform is part of the key on purpose. The same name exists on X
     * and on Telegram and is very often two different people, so a bare
     * handle hash would let whoever proves it on one platform collect fees a
     * creator meant for the other. Namespacing makes the two keys unrelated,
     * and the attester signs for exactly one of them after a login on that
     * platform.
     */
    function handleKey(string calldata platform, string calldata handle) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(_lower(bytes(platform)), ":", _lower(_stripAt(bytes(handle)))));
    }

    /**
     * @dev Drops one leading "@", because people write handles both ways and
     * the two spellings have to resolve to the same claim.
     *
     * This was missing and the absence was invisible: the attester and this
     * contract's own documentation both stated the at-sign was removed, and
     * only the code disagreed. A creator staging a handle written with the
     * at-sign would have accrued fees under a key the attester never signs
     * for, and the balance would have sat unclaimable with nothing to
     * indicate why.
     */
    function _stripAt(bytes memory b) private pure returns (bytes memory) {
        if (b.length == 0 || b[0] != 0x40) return b;
        bytes memory out = new bytes(b.length - 1);
        for (uint256 i = 1; i < b.length; i++) out[i - 1] = b[i];
        return out;
    }

    function _lower(bytes memory b) private pure returns (bytes memory) {
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return b;
    }

    function handleBalance(bytes32 handle, address asset) external view returns (uint256) {
        return _handleBalances[handle][asset];
    }

    // ---------------------------------------------------------------------
    // Claims (same as V1)
    // ---------------------------------------------------------------------

    function claim() external returns (uint256 amount) {
        return _claimNative(_nativeBalances[msg.sender]);
    }

    function claim(uint256 amount) external returns (uint256) {
        return _claimNative(amount);
    }

    function claimToken(address token) external returns (uint256 amount) {
        return _claimToken(token, _tokenBalances[msg.sender][token]);
    }

    function claimToken(address token, uint256 amount) external returns (uint256) {
        return _claimToken(token, amount);
    }

    function balanceOf(address recipient) external view returns (uint256) {
        return _nativeBalances[recipient];
    }

    function balanceOfToken(address recipient, address token) external view returns (uint256) {
        return _tokenBalances[recipient][token];
    }

    function _claimNative(uint256 amount) private nonReentrant returns (uint256) {
        uint256 available = _nativeBalances[msg.sender];
        if (amount > available) revert InsufficientBalance(amount, available);
        if (amount == 0) return 0;

        _nativeBalances[msg.sender] = available - amount;
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert TransferFailed();
        emit Claimed(msg.sender, amount);
        return amount;
    }

    function _claimToken(address token, uint256 amount) private nonReentrant returns (uint256) {
        uint256 available = _tokenBalances[msg.sender][token];
        if (amount > available) revert InsufficientBalance(amount, available);
        if (amount == 0) return 0;

        _tokenBalances[msg.sender][token] = available - amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit ClaimedToken(msg.sender, token, amount);
        return amount;
    }
}
