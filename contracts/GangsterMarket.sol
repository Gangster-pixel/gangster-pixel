// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

interface IGangsterVaultLite {
    function transferNonce(uint256 id) external view returns (uint256);
    function operatorAllowed(address op) external view returns (bool);
    function approvalEpoch(address owner) external view returns (uint256);
}

/// @title GangsterMarket - non-custodial on-chain listings priced in BNB
/// @notice The NFT stays in the seller's wallet (still the seller's avatar, still earning dividends); the market only records
///   listings and, on purchase, transfers the NFT as an allow-listed operator.
///   A listing becomes invalid when: the NFT changes hands (vault.transferNonce changes) / the seller revokes the approval
///   (vault.approvalEpoch changes) / the seller calls cancelAll (sellerEpoch changes) / the owner changes / the approval is gone.
///   Revoking and re-approving never revives an old listing.
contract GangsterMarket is Ownable2Step, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;

    struct Listing {
        address seller;
        uint96 price;         // wei (max 7.9e28, more than enough)
        uint64 nonce;         // vault.transferNonce at listing time
        uint64 approvalEpoch; // vault.approvalEpoch(seller) at listing time
        uint64 sellerEpoch;   // sellerEpoch[seller] at listing time
        uint16 feeBps;        // fee rate at listing time; a sale uses min(listing rate, current rate)
    }

    uint256 public constant MAX_FEE_BPS = 500; // hard cap 5%
    IERC721 public immutable NFT;
    IGangsterVaultLite public immutable VAULT;

    address public treasury;
    uint256 public feeBps;
    uint256 public accruedFees; // fees the treasury could not receive, held here until withdrawFees
    mapping(uint256 => Listing) public listings;
    mapping(address => uint64) public sellerEpoch; // +1 on cancelAll, voiding all of that seller's listings
    EnumerableSet.UintSet private _listed;
    uint256 public totalVolume;
    uint256 public totalFees;

    event Listed(uint256 indexed id, address indexed seller, uint256 price);
    event Cancelled(uint256 indexed id, address indexed seller);
    event CancelledAll(address indexed seller, uint64 epoch);
    event Sold(uint256 indexed id, address indexed seller, address indexed buyer, uint256 price, uint256 fee);
    event FeeUpdated(uint256 feeBps);
    event TreasuryUpdated(address indexed treasury);
    event FeeAccrued(uint256 amount);
    event FeesWithdrawn(address indexed treasury, uint256 amount);

    error NotSeller();
    error NotListed(uint256 id);
    error StaleListing(uint256 id);
    error WrongPrice(uint256 expected, uint256 got);
    error FeeTooHigh();
    error ZeroAddress();
    error BadPrice();
    error NotApproved();
    error TransferFailed();
    error NothingToClaim();
    error Forbidden();

    constructor(address nft_, address treasury_, uint256 feeBps_, address owner_) Ownable(owner_) {
        if (nft_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        NFT = IERC721(nft_);
        VAULT = IGangsterVaultLite(nft_);
        treasury = treasury_;
        feeBps = feeBps_;
    }

    // ---------------------------------------------------------------- views
    function listedCount() external view returns (uint256) { return _listed.length(); }

    /// @notice Paginated listing ids (including stale ones; front ends / CLIs filter with isActive)
    function listedIds(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _listed.length();
        if (offset >= n) return ids;
        uint256 end = offset + limit > n ? n : offset + limit;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) ids[i - offset] = _listed.at(i);
    }

    function isActive(uint256 id) public view returns (bool) {
        return _active(id, true);
    }

    /// @dev With checkOperator = false the market's own allow-list status is ignored: while the market is temporarily
    ///      de-listed its listings are only paused and must not be cleared by others as stale
    function _active(uint256 id, bool checkOperator) internal view returns (bool) {
        Listing memory l = listings[id];
        if (l.seller == address(0)) return false;
        if (uint64(VAULT.transferNonce(id)) != l.nonce) return false;
        if (uint64(VAULT.approvalEpoch(l.seller)) != l.approvalEpoch) return false;
        if (sellerEpoch[l.seller] != l.sellerEpoch) return false;
        // ownerOf reverts for burned ids, so wrap it
        try NFT.ownerOf(id) returns (address o) {
            if (o != l.seller) return false;
        } catch { return false; }
        if (checkOperator && !VAULT.operatorAllowed(address(this))) return false; // market removed from the vault allow-list -> nothing is active, so buyers do not fail on-chain
        return NFT.isApprovedForAll(l.seller, address(this)); // only setApprovalForAll counts: a single-token approve could be revoked and re-granted to revive an old listing
    }

    // ---------------------------------------------------------------- user actions
    /// @notice List or re-price. Requires setApprovalForAll(market, true). To delist use cancel / cancelAll; revoking the approval only pauses listings.
    function list(uint256 id, uint96 price) external nonReentrant {
        if (price == 0) revert BadPrice();
        if (NFT.ownerOf(id) != msg.sender) revert NotSeller();
        if (!NFT.isApprovedForAll(msg.sender, address(this))) revert NotApproved();
        listings[id] = Listing({
            seller: msg.sender,
            price: price,
            nonce: uint64(VAULT.transferNonce(id)),
            approvalEpoch: uint64(VAULT.approvalEpoch(msg.sender)),
            sellerEpoch: sellerEpoch[msg.sender],
            feeBps: uint16(feeBps)
        });
        _listed.add(id);
        emit Listed(id, msg.sender, price);
    }

    function cancel(uint256 id) external nonReentrant {
        Listing memory l = listings[id];
        if (l.seller == address(0)) revert NotListed(id);
        // the seller, or anyone once the listing is stale, may clear it
        if (l.seller != msg.sender && _active(id, false)) revert NotSeller();
        delete listings[id];
        _listed.remove(id);
        emit Cancelled(id, l.seller);
    }

    /// @notice Void all of the caller's listings in one tx (records stay in _listed; anyone can clean them up with cancel)
    function cancelAll() external {
        sellerEpoch[msg.sender] += 1;
        emit CancelledAll(msg.sender, sellerEpoch[msg.sender]);
    }

    /// @notice Buy: msg.value must equal the listed price; the fee goes to the treasury, the rest to the seller, the NFT to the buyer
    function buy(uint256 id) external payable nonReentrant {
        Listing memory l = listings[id];
        if (l.seller == address(0)) revert NotListed(id);
        if (!isActive(id)) revert StaleListing(id);
        if (msg.value != l.price) revert WrongPrice(l.price, msg.value);

        delete listings[id];
        _listed.remove(id);

        uint256 bps = feeBps < l.feeBps ? feeBps : l.feeBps; // a later fee increase does not apply; a decrease does
        uint256 fee = (uint256(l.price) * bps) / 10_000;
        uint256 toSeller = l.price - fee;
        totalVolume += l.price;
        totalFees += fee;

        NFT.transferFrom(l.seller, msg.sender, id); // the vault guard checks the buyer is allowed to receive here
        _pay(l.seller, toSeller);
        _payTreasury(fee);
        emit Sold(id, l.seller, msg.sender, l.price, fee);
    }

    /// @notice Pay accrued fees to the treasury. Callable by anyone.
    function withdrawFees() external nonReentrant {
        uint256 amount = accruedFees;
        if (amount == 0) revert NothingToClaim();
        accruedFees = 0;
        _pay(treasury, amount);
        emit FeesWithdrawn(treasury, amount);
    }

    // ---------------------------------------------------------------- owner
    function setFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = bps;
        emit FeeUpdated(bps);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0) || t == address(this)) revert ZeroAddress();
        treasury = t;
        emit TreasuryUpdated(t);
    }

    function renounceOwnership() public view override onlyOwner {
        revert Forbidden();
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev A treasury that refuses payment must not make the buyer's purchase fail: accrue and withdraw later
    function _payTreasury(uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = treasury.call{value: amount, gas: 50_000}("");
        if (!ok) {
            accruedFees += amount;
            emit FeeAccrued(amount);
        }
    }
}
