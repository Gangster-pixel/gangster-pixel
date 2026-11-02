// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title GangsterDistributor - per-round Merkle distribution of trading-tax dividends (BNB)
/// @notice The team settles periodically: it snapshots every NFT holder and tier in the Vault at a chosen block, weights them
///         Soldier 100 / Captain 480 / Boss 2400 (Captain +20%, Boss +50% per unit), computes each address's BNB share,
///         publishes the round file (anyone can recompute it), and funds the Merkle root together with the round's BNB.
///         Holders claim with a proof; after EXPIRY, unclaimed BNB can be swept back to the treasury by the owner (rules are on-chain).
///         The contract does not compute snapshots; it only guarantees: each round's funds are isolated, each address claims once
///         against the root, and funds can be recovered only after expiry.
contract GangsterDistributor is Ownable2Step, ReentrancyGuard {
    // snapshot weights (the off-chain settlement uses these three numbers; recorded on-chain for verification)
    uint256 public constant WEIGHT_SOLDIER = 100;
    uint256 public constant WEIGHT_CAPTAIN = 480;
    uint256 public constant WEIGHT_BOSS = 2400;

    struct Round {
        bytes32 root;         // Merkle root; leaf = keccak256(bytes.concat(keccak256(abi.encode(roundId, account, amount))))
        uint256 total;        // BNB funded for this round
        uint256 claimed;      // BNB claimed so far
        uint64 snapshotBlock; // snapshot block
        uint64 fundedAt;
        uint64 expiry;        // after this, claims stop and the owner may sweep
        bool swept;
        string uri;           // round file location (ipfs:// or https://); holders read their amount and proof from it
    }

    uint256 public immutable EXPIRY; // claim window per round (seconds)
    address public immutable VAULT;  // snapshot source, informational only

    address public treasury;
    Round[] private _rounds;
    mapping(uint256 => mapping(address => bool)) public claimed;
    uint256 public totalFunded;
    uint256 public totalClaimed;
    uint256 public totalSwept;

    event RoundFunded(uint256 indexed roundId, bytes32 root, uint256 total, uint64 snapshotBlock, uint64 expiry, string uri);
    event Claimed(uint256 indexed roundId, address indexed account, uint256 amount);
    event Swept(uint256 indexed roundId, uint256 amount);
    event TreasuryUpdated(address indexed treasury);

    error ZeroAddress();
    error ZeroAmount();
    error NoSuchRound(uint256 id);
    error RoundExpired(uint256 id);
    error RoundNotExpired(uint256 id);
    error AlreadyClaimed(uint256 id);
    error BadProof(uint256 id);
    error AlreadySwept(uint256 id);
    error TransferFailed();
    error Forbidden();
    error LengthMismatch();
    error WrongRound(uint256 expected, uint256 actual);
    error BadSnapshot(uint64 snapshotBlock);
    error RoundInsufficient(uint256 id);

    constructor(address vault_, address treasury_, uint256 expiry_, address owner_) Ownable(owner_) {
        if (vault_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (expiry_ == 0 || expiry_ > 365 days) revert ZeroAmount(); // claim window between 1 second and 1 year
        VAULT = vault_;
        treasury = treasury_;
        EXPIRY = expiry_;
    }

    // ---------------------------------------------------------------- views
    function roundCount() external view returns (uint256) { return _rounds.length; }

    function round(uint256 id) external view returns (Round memory) {
        if (id >= _rounds.length) revert NoSuchRound(id);
        return _rounds[id];
    }

    /// @notice Whether this address can claim this round (valid proof, not claimed, not expired)
    function claimable(uint256 id, address account, uint256 amount, bytes32[] calldata proof) external view returns (bool) {
        if (id >= _rounds.length) return false;
        Round storage r = _rounds[id];
        if (amount == 0 || block.timestamp > r.expiry || claimed[id][account]) return false;
        if (r.claimed + amount > r.total) return false;
        return MerkleProof.verify(proof, r.root, _leaf(id, account, amount));
    }

    // ---------------------------------------------------------------- owner
    /// @notice Open a round: send its BNB together with the root, the snapshot block and the round file location
    function fund(bytes32 root, uint64 snapshotBlock, string calldata uri, uint256 expectedId) external payable onlyOwner returns (uint256 id) {
        if (msg.value == 0) revert ZeroAmount();
        if (root == bytes32(0)) revert ZeroAddress();
        id = _rounds.length;
        if (expectedId != id) revert WrongRound(expectedId, id); // the round id is part of every leaf; a wrong id would invalidate every proof
        if (snapshotBlock == 0 || snapshotBlock > block.number) revert BadSnapshot(snapshotBlock);
        if (bytes(uri).length == 0) revert ZeroAddress(); // the round file is required: holders need it for their amount and proof
        uint64 expiry = uint64(block.timestamp + EXPIRY);
        _rounds.push(Round({root: root, total: msg.value, claimed: 0, snapshotBlock: snapshotBlock,
                           fundedAt: uint64(block.timestamp), expiry: expiry, swept: false, uri: uri}));
        totalFunded += msg.value;
        emit RoundFunded(id, root, msg.value, snapshotBlock, expiry, uri);
    }

    /// @notice After expiry, send the unclaimed balance back to the treasury
    function sweep(uint256 id) external onlyOwner nonReentrant {
        if (id >= _rounds.length) revert NoSuchRound(id);
        Round storage r = _rounds[id];
        if (block.timestamp <= r.expiry) revert RoundNotExpired(id);
        if (r.swept) revert AlreadySwept(id);
        r.swept = true;
        uint256 amount = r.total - r.claimed;
        totalSwept += amount;
        if (amount != 0) _pay(treasury, amount);
        emit Swept(id, amount);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0) || t == address(this)) revert ZeroAddress();
        treasury = t;
        emit TreasuryUpdated(t);
    }

    function renounceOwnership() public view override onlyOwner {
        revert Forbidden();
    }

    // ---------------------------------------------------------------- holders
    /// @notice Claim one round; anyone may claim on behalf of `account`, the BNB is always paid to `account`
    function claim(uint256 id, address account, uint256 amount, bytes32[] calldata proof) public nonReentrant {
        _claim(id, account, amount, proof);
    }

    /// @notice Claim several rounds at once
    function claimMany(uint256[] calldata ids, address account, uint256[] calldata amounts, bytes32[][] calldata proofs) external nonReentrant {
        if (ids.length != amounts.length || ids.length != proofs.length) revert LengthMismatch();
        for (uint256 i = 0; i < ids.length; i++) {
            _claim(ids[i], account, amounts[i], proofs[i]);
        }
    }

    // ---------------------------------------------------------------- internal
    function _claim(uint256 id, address account, uint256 amount, bytes32[] calldata proof) internal {
        if (id >= _rounds.length) revert NoSuchRound(id);
        if (account == address(0) || amount == 0) revert ZeroAmount();
        Round storage r = _rounds[id];
        if (block.timestamp > r.expiry) revert RoundExpired(id);
        if (claimed[id][account]) revert AlreadyClaimed(id);
        if (!MerkleProof.verify(proof, r.root, _leaf(id, account, amount))) revert BadProof(id);
        if (r.claimed + amount > r.total) revert RoundInsufficient(id); // the tree is cut to `total`; even a faulty tree cannot touch other rounds' funds
        claimed[id][account] = true;
        r.claimed += amount;
        totalClaimed += amount;
        _pay(account, amount);
        emit Claimed(id, account, amount);
    }

    function _leaf(uint256 id, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(id, account, amount))));
    }

    function _pay(address to, uint256 amount) internal {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
