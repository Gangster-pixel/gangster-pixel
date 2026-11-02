// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IAgentIdRegistry} from "./interfaces/IGangExternal.sol";

/// @dev The parts of GangVaultLaunchpad this vault uses (gang 2.0 vault pad, spec 2026-11-01).
interface IGangVaultPad {
    function vaultOf(address token) external view returns (address);
    function lockedOf(address token, address user) external view returns (uint256);
    function vaultLock(address token, address user, uint256 amount) external;
    function vaultRelease(address token, address user, uint256 amount) external;
}

/// @dev GangToken: true until graduation (then a plain ERC-20).
interface IGangToken {
    function locked() external view returns (bool);
}

/// @title GangsterVault - token-backed NFTs (Soldier / Captain / Boss)
/// @notice Every NFT holds a fixed amount of the project token (UNIT x units).
///   Soldier = 1 unit (mint by locking UNIT tokens); Captain = 4 units (craft by burning 4 units of NFTs); Boss = 16 units.
///   Burning any tier returns (10000 - burnKeepBps) / 10000 of the locked tokens (10% kept by default) for a fee of burnFeePerUnit x units BNB.
///   The kept tokens accumulate in retainedTokens; the owner can only send them to 0xdead (deflation), never withdraw them.
///   Only addresses holding a .ai Agent ID can mint / craft / receive (requireAgentRecipient can be turned off); when the owner
///   enables publicMintEnabled, ordinary wallets can take part too and pay publicFeePerUnit.
///   Contract addresses (other than EIP-7702 delegated accounts) can never mint / craft / receive unless allow-listed in contractRecipientAllowed.
///   Built-in ERC721-C style transfer guard: operators and contract recipients must be allow-listed (by default only the project market).
///   Dividends are not handled here: the outer-market tax is settled per round and paid by GangsterDistributor
///   (block snapshot + Merkle proofs).
///   Safety properties: revoking an approval bumps an epoch (old listings can never revive); fees that cannot be delivered are
///   accrued instead of blocking burns; the Agent ID check can be switched off if the registry breaks; EIP-7702 accounts are
///   treated as EOAs; removing an allow-list entry has a delay and an execution window; renouncing ownership is disabled.
contract GangsterVault is ERC721, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    // ---------------------------------------------------------------- constants / immutables
    uint8 public constant TIER_SOLDIER = 1;
    uint8 public constant TIER_CAPTAIN = 2;
    uint8 public constant TIER_BOSS = 3;
    uint256 public constant DISALLOW_DELAY = 2 days;  // delay before an allow-list removal can be executed
    uint256 public constant DISALLOW_WINDOW = 7 days; // a scheduled removal expires if not executed within this window

    uint256 public immutable UNIT;              // tokens per unit (18 decimals)
    IAgentIdRegistry public immutable AGENT_ID; // zero address = no check
    IGangVaultPad public immutable PAD;         // the launchpad the token is created on (createWithVault); moves tokens before graduation

    // ---------------------------------------------------------------- mutable parameters
    IERC20 public token;            // project token; set right after the token is created on PAD, changeable until the first mint, then locked
    address public treasury;        // fee recipient
    uint256 public mintFeePerUnit;  // mint / craft fee per unit (BNB); the owner can only lower it
    uint256 public burnFeePerUnit;  // burn fee per unit (BNB); the owner can only lower it
    uint256 public burnKeepBps;     // share of locked tokens kept on burn (bps); the owner can only lower it
    uint256 public retainedTokens;  // tokens kept from burns; the owner can only burn them to 0xdead
    bool public mintPaused;         // pauses mint / craft only; burns and transfers can never be paused (before graduation a burn needs an Agent ID, see burn)
    bool public publicMintEnabled;  // opens mint / craft / receive to wallets without an Agent ID (off by default)
    uint256 public publicFeePerUnit; // mint / craft fee per unit for non-agent wallets (BNB); the owner can only lower it
    bool public requireAgentRecipient = true; // recipients must be agents
    bool public agentCheckEnabled = true;     // master switch in case the Agent ID registry breaks (off = everyone passes)
    string public baseURI;
    string public contractURI;
    uint256 public accruedFees;     // fees the treasury could not receive; paid out later via withdrawFees

    // tier caps / per-wallet caps (0 = unlimited); a cap bounds the NFTs of that tier in existence: burning one, or
    // consuming it as a craft ingredient, frees its slot (mintedByTier = how many exist now, kept by name for the ABI)
    mapping(uint8 => uint256) public maxMintByTier;
    mapping(uint8 => uint256) public maxPerWalletByTier;
    mapping(uint8 => uint256) public mintedByTier;

    // NFT state
    uint256 public nextId = 1;
    uint256 private _burnedCount;
    uint256 public totalUnits;                        // units outstanding (tokens owed = totalUnits x UNIT + retainedTokens)
    mapping(uint256 => uint8) public tierOf;
    mapping(uint256 => bytes32) public seedOf;        // random artwork seed (all tiers); the seed -> artwork mapping lives off-chain
    mapping(uint256 => uint256) public transferNonce; // +1 on every transfer; the market uses it to void stale listings
    mapping(address => uint256) public approvalEpoch; // +1 on every revoked operator approval; the market uses it to void all of a seller's listings
    mapping(address => mapping(uint8 => uint256)) public balanceByTier;

    // guard allow-lists
    mapping(address => bool) public operatorAllowed;          // operators that may be approved / transfer on behalf of owners
    mapping(address => bool) public contractRecipientAllowed; // contract addresses that may receive NFTs
    mapping(address => uint256) public disallowAt;            // scheduled removal time

    // ---------------------------------------------------------------- events
    event TokenSet(address indexed token);
    event Minted(address indexed to, uint256 indexed id, uint8 tier, bytes32 seed, uint256 fee);
    event Crafted(address indexed by, uint256 indexed newId, uint8 tier, uint256[] burnedIds, uint256 fee);
    event Burned(address indexed by, uint256 indexed id, uint8 tier, uint256 tokensOut, uint256 fee);
    event FeesUpdated(uint256 mintFeePerUnit, uint256 burnFeePerUnit);
    event BurnKeepUpdated(uint256 bps);
    event Deflated(uint256 amount);
    event TreasuryUpdated(address indexed treasury);
    event FeeAccrued(uint256 amount);
    event FeesWithdrawn(address indexed treasury, uint256 amount);
    event MintPaused(bool paused);
    event PublicMint(bool enabled);
    event PublicFeeUpdated(uint256 publicFeePerUnit);
    event AgentRecipientRequired(bool required);
    event AgentCheckEnabled(bool enabled);
    event LimitsUpdated(uint8 tier, uint256 maxMint, uint256 maxPerWallet);
    event OperatorAllowed(address indexed op, bool allowed);
    event ContractRecipientAllowed(address indexed to, bool allowed);
    event DisallowScheduled(address indexed addr, uint256 at);
    event ApprovalEpochBumped(address indexed owner, uint256 epoch);

    error NotAgent(address who);
    error TokenNotSet();
    error TokenAlreadySet();
    error WrongFee(uint256 expected, uint256 got);
    error Paused();
    error TierSoldOut(uint8 tier);
    error WalletCap(uint8 tier);
    error BadTier();
    error BadIngredients();
    error NotOwnerOf(uint256 id);
    error OperatorNotAllowed(address op);
    error RecipientNotAllowed(address to);
    error OnlyDecrease();
    error NothingToClaim();
    error NotScheduled();
    error TooEarly(uint256 at);
    error Expired(uint256 at);
    error ZeroAddress();
    error TransferFailed();
    error Forbidden();
    error NotOrigin();    // mint / craft / burn must be called by the wallet that sent the tx (no contracts in between)
    error WrongToken();   // the token is not bound to this vault on PAD

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 unit_,
        address agentId_,
        address treasury_,
        uint256 mintFeePerUnit_,
        uint256 burnFeePerUnit_,
        uint256 maxCaptain_,
        uint256 maxBoss_,
        uint256 maxBossPerWallet_,
        uint256 burnKeepBps_,
        uint256 publicFeePerUnit_,
        address owner_, // explicit owner: when deployed through a CREATE2 proxy, msg.sender is the proxy
        address pad_    // GangVaultLaunchpad the token will be created on
    ) ERC721(name_, symbol_) Ownable(owner_) {
        if (pad_ == address(0)) revert ZeroAddress();
        PAD = IGangVaultPad(pad_);
        if (unit_ == 0 || treasury_ == address(0)) revert ZeroAddress();
        if (burnKeepBps_ >= 10_000) revert OnlyDecrease(); // keeping 100% would refund nothing
        burnKeepBps = burnKeepBps_;
        publicFeePerUnit = publicFeePerUnit_;
        UNIT = unit_;
        AGENT_ID = IAgentIdRegistry(agentId_);
        treasury = treasury_;
        mintFeePerUnit = mintFeePerUnit_;
        burnFeePerUnit = burnFeePerUnit_;
        maxMintByTier[TIER_CAPTAIN] = maxCaptain_;
        maxMintByTier[TIER_BOSS] = maxBoss_;
        maxPerWalletByTier[TIER_BOSS] = maxBossPerWallet_;
    }

    // ---------------------------------------------------------------- views
    /// @notice A reverting registry counts as "not an agent"; with agentCheckEnabled off everyone passes (fallback if the registry breaks)
    function isAgent(address a) public view returns (bool) {
        if (!agentCheckEnabled || address(AGENT_ID) == address(0)) return true;
        if (address(AGENT_ID).code.length == 0) return false; // try/catch cannot catch a decode failure on a code-less address
        try AGENT_ID.balanceOf(a) returns (uint256 n) {
            return n > 0;
        } catch {
            return false;
        }
    }

    /// @notice Whether a recipient counts as a contract. EIP-7702 delegated accounts (code = 0xef0100 || 20-byte address, 23 bytes) count as EOAs
    function isContractRecipient(address a) public view returns (bool) {
        uint256 size = a.code.length;
        if (size == 0) return false;
        if (size == 23) {
            bytes memory c = a.code;
            if (c[0] == 0xef && c[1] == 0x01 && c[2] == 0x00) return false;
        }
        return true;
    }

    // units per tier: Soldier 1 / Captain 4 / Boss 16
    function unitsOf(uint8 tier) public pure returns (uint256) {
        if (tier == TIER_SOLDIER) return 1;
        if (tier == TIER_CAPTAIN) return 4;
        if (tier == TIER_BOSS) return 16;
        revert BadTier();
    }

    // tokens locked in one NFT
    function lockedOf(uint256 id) external view returns (uint256) {
        _requireOwned(id);
        return UNIT * unitsOf(tierOf[id]);
    }

    // tokens returned if this NFT is burned now
    function refundOf(uint256 id) external view returns (uint256) {
        _requireOwned(id);
        uint256 locked = UNIT * unitsOf(tierOf[id]);
        return locked - (locked * burnKeepBps) / 10_000;
    }

    // highest tier held (for avatars), 0 = none
    function highestTier(address a) external view returns (uint8) {
        if (balanceByTier[a][TIER_BOSS] > 0) return TIER_BOSS;
        if (balanceByTier[a][TIER_CAPTAIN] > 0) return TIER_CAPTAIN;
        if (balanceByTier[a][TIER_SOLDIER] > 0) return TIER_SOLDIER;
        return 0;
    }

    function mintFee(uint8 tier) public view returns (uint256) { return mintFeePerUnit * unitsOf(tier); }
    /// @notice Fee an address pays to mint / craft this tier: agents pay mintFeePerUnit, non-agents pay publicFeePerUnit
    function mintFeeFor(address who, uint8 tier) public view returns (uint256) { return feePerUnitFor(who) * unitsOf(tier); }
    function feePerUnitFor(address who) public view returns (uint256) { return isAgent(who) ? mintFeePerUnit : publicFeePerUnit; }
    /// @notice Whether this address can mint / craft / receive right now
    function canParticipate(address who) public view returns (bool) { return publicMintEnabled || isAgent(who); }
    /// @notice Whether this address can receive an NFT right now (transfers, market purchases and mints all use this rule):
    ///         contracts must be allow-listed; the agent gate follows requireAgentRecipient and the public-mint switch
    function canReceive(address to) public view returns (bool) {
        if (isContractRecipient(to) && !contractRecipientAllowed[to]) return false;
        return !requireAgentRecipient || canParticipate(to);
    }
    function burnFee(uint8 tier) public view returns (uint256) { return burnFeePerUnit * unitsOf(tier); }

    function totalSupply() external view returns (uint256) {
        return nextId - 1 - _burnedCount;
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return bytes(baseURI).length == 0 ? "" : string.concat(baseURI, id.toString());
    }

    // ---------------------------------------------------------------- user actions
    /// @notice Lock UNIT x count tokens and mint `count` Soldiers; msg.value = fee per unit x count
    function mint(uint256 count) external payable nonReentrant returns (uint256 firstId) {
        if (address(token) == address(0)) revert TokenNotSet();
        if (mintPaused) revert Paused();
        if (!canParticipate(msg.sender)) revert NotAgent(msg.sender);
        if (isContractRecipient(msg.sender) && !contractRecipientAllowed[msg.sender]) revert RecipientNotAllowed(msg.sender); // no wrapper contracts, even when public mint is open
        if (msg.sender != tx.origin) revert NotOrigin(); // the pad requires it before graduation; kept always (also closes the constructor-time bypass)
        if (count == 0) revert BadIngredients();
        uint256 perUnit = feePerUnitFor(msg.sender);
        uint256 fee = perUnit * count;
        if (msg.value != fee) revert WrongFee(fee, msg.value);
        _checkTierLimit(TIER_SOLDIER, count);

        // pull tokens and check the amount actually received; fee-on-transfer tokens are rejected here
        uint256 amount = UNIT * count;
        uint256 before = token.balanceOf(address(this));
        if (_curveLive()) {
            // before graduation: the pad pulls the caller's tokens (allowance given to THIS vault) into the vault
            PAD.vaultLock(address(token), msg.sender, amount);
        } else {
            token.safeTransferFrom(msg.sender, address(this), amount);
        }
        if (token.balanceOf(address(this)) - before != amount) revert BadIngredients();

        firstId = nextId;
        for (uint256 i = 0; i < count; i++) {
            _mintTier(msg.sender, TIER_SOLDIER, perUnit);
        }
        _payTreasury(fee);
    }

    /// @notice Burn lower-tier NFTs to craft a higher tier: their units must add up exactly to the target, and every ingredient must be below the target tier
    function craft(uint8 targetTier, uint256[] calldata ids) external payable nonReentrant returns (uint256 newId) {
        if (address(token) == address(0)) revert TokenNotSet();
        if (mintPaused) revert Paused();
        if (!canParticipate(msg.sender)) revert NotAgent(msg.sender);
        if (isContractRecipient(msg.sender) && !contractRecipientAllowed[msg.sender]) revert RecipientNotAllowed(msg.sender);
        if (msg.sender != tx.origin) revert NotOrigin();
        if (targetTier != TIER_CAPTAIN && targetTier != TIER_BOSS) revert BadTier();
        uint256 need = unitsOf(targetTier);
        uint256 fee = feePerUnitFor(msg.sender) * need;
        if (msg.value != fee) revert WrongFee(fee, msg.value);
        _checkTierLimit(targetTier, 1);

        uint256 got;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (ownerOf(id) != msg.sender) revert NotOwnerOf(id); // a duplicated id reverts here on its second occurrence
            uint8 t = tierOf[id];
            if (t >= targetTier) revert BadIngredients();
            got += unitsOf(t);
            if (got > need) revert BadIngredients(); // too many ingredients: fail early to save gas
            _burnInternal(id);
        }
        if (got != need) revert BadIngredients();

        newId = _mintTier(msg.sender, targetTier, fee);
        emit Crafted(msg.sender, newId, targetTier, ids, fee);
        _payTreasury(fee);
    }

    /// @notice Burn an NFT and get (10000 - burnKeepBps) / 10000 of its locked tokens back; the rest stays for the owner to burn.
    ///         msg.value = burnFee(tier). Never pausable. Before graduation the pad pays the holder out, which requires the
    ///         holder to send the tx from their own wallet and to hold an Agent ID; after graduation it is a plain transfer.
    function burn(uint256 id) external payable nonReentrant returns (uint256 tokensOut) {
        if (ownerOf(id) != msg.sender) revert NotOwnerOf(id);
        if (msg.sender != tx.origin) revert NotOrigin();
        uint8 t = tierOf[id];
        uint256 fee = burnFeePerUnit * unitsOf(t);
        if (msg.value != fee) revert WrongFee(fee, msg.value);
        uint256 locked = UNIT * unitsOf(t);
        uint256 keep = (locked * burnKeepBps) / 10_000;
        tokensOut = locked - keep;
        retainedTokens += keep;
        _burnInternal(id);
        if (_curveLive()) {
            // before graduation: the pad pays the caller (tx sender, Agent ID) out of this vault, spending exactly this
            // one-off allowance, so no allowance is left behind (and none after graduation)
            token.forceApprove(address(PAD), tokensOut);
            PAD.vaultRelease(address(token), msg.sender, tokensOut);
        } else {
            token.safeTransfer(msg.sender, tokensOut);
        }
        emit Burned(msg.sender, id, t, tokensOut, fee);
        _payTreasury(fee);
    }

    /// @notice Pay accrued fees to the treasury (after it refused them or was changed). Callable by anyone.
    function withdrawFees() external nonReentrant {
        uint256 amount = accruedFees;
        if (amount == 0) revert NothingToClaim();
        accruedFees = 0;
        (bool ok, ) = treasury.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit FeesWithdrawn(treasury, amount);
    }

    // ---------------------------------------------------------------- owner
    /// @notice Set the project token right after it is created on PAD with createWithVault(..., this). Changeable until the
    ///         first NFT is minted (to fix a wrong address); locked once anyone has deposited, so the owner can never swap
    ///         the token backing existing NFTs
    function setToken(address token_) external onlyOwner {
        if (nextId != 1) revert TokenAlreadySet();
        if (token_ == address(0)) revert ZeroAddress();
        if (PAD.vaultOf(token_) != address(this)) revert WrongToken();
        token = IERC20(token_);
        emit TokenSet(token_);
    }

    /// @notice Send tokens kept from burns to 0xdead (deflation). The owner can only burn them, never withdraw them.
    function burnRetained() external onlyOwner nonReentrant returns (uint256 amount) {
        amount = retainedTokens;
        if (amount == 0) revert NothingToClaim();
        retainedTokens = 0;
        token.safeTransfer(address(0xdead), amount);
        emit Deflated(amount);
    }

    /// @notice Project tokens that back no NFT and are not in retainedTokens (sent here directly) can only be burned to 0xdead, never withdrawn
    function sweepSurplusToDead() external onlyOwner nonReentrant returns (uint256 amount) {
        uint256 owed = totalUnits * UNIT + retainedTokens;
        uint256 bal = token.balanceOf(address(this));
        if (bal <= owed) revert NothingToClaim();
        amount = bal - owed;
        token.safeTransfer(address(0xdead), amount);
        emit Deflated(amount);
    }

    /// @notice The burn keep ratio can only be lowered
    function setBurnKeepBps(uint256 bps) external onlyOwner {
        if (bps > burnKeepBps) revert OnlyDecrease();
        burnKeepBps = bps;
        emit BurnKeepUpdated(bps);
    }

    /// @notice Fees can only be lowered
    function setFees(uint256 mintFeePerUnit_, uint256 burnFeePerUnit_) external onlyOwner {
        if (mintFeePerUnit_ > mintFeePerUnit || burnFeePerUnit_ > burnFeePerUnit) revert OnlyDecrease();
        mintFeePerUnit = mintFeePerUnit_;
        burnFeePerUnit = burnFeePerUnit_;
        emit FeesUpdated(mintFeePerUnit_, burnFeePerUnit_);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0) || t == address(this)) revert ZeroAddress();
        treasury = t;
        emit TreasuryUpdated(t);
    }

    function setMintPaused(bool p) external onlyOwner { mintPaused = p; emit MintPaused(p); }
    /// @notice Open / close participation for ordinary wallets. When closed, existing non-agent holders can still hold, burn and
    ///         transfer to agents, but cannot mint / craft / receive
    function setPublicMintEnabled(bool e) external onlyOwner { publicMintEnabled = e; emit PublicMint(e); }
    /// @notice The non-agent fee can only be lowered
    function setPublicFee(uint256 perUnit) external onlyOwner { if (perUnit > publicFeePerUnit) revert OnlyDecrease(); publicFeePerUnit = perUnit; emit PublicFeeUpdated(perUnit); }
    function setRequireAgentRecipient(bool r) external onlyOwner { requireAgentRecipient = r; emit AgentRecipientRequired(r); }
    /// @notice Fallback if the Agent ID registry breaks (failed upgrade / paused): when off, mint / craft / receive skip the agent check
    function setAgentCheckEnabled(bool e) external onlyOwner { agentCheckEnabled = e; emit AgentCheckEnabled(e); }
    function setURIs(string calldata base, string calldata contractUri) external onlyOwner { baseURI = base; contractURI = contractUri; }

    /// @notice Tier caps can only be lowered (a set cap cannot be reset to 0 = unlimited) and never below what exists now; per-wallet caps can change freely
    ///         (note: lowering one takes effect immediately, so wallets at the cap can no longer receive that tier)
    function setLimits(uint8 tier, uint256 maxMint, uint256 maxPerWallet) external onlyOwner {
        unitsOf(tier);
        uint256 cur = maxMintByTier[tier];
        if (cur != 0 && (maxMint == 0 || maxMint > cur)) revert OnlyDecrease();
        if (maxMint != 0 && maxMint < mintedByTier[tier]) revert OnlyDecrease();
        maxMintByTier[tier] = maxMint;
        maxPerWalletByTier[tier] = maxPerWallet;
        emit LimitsUpdated(tier, maxMint, maxPerWallet);
    }

    /// @notice Allow-list: additions take effect immediately; removals must be scheduled, wait DISALLOW_DELAY, and be executed within
    ///         DISALLOW_WINDOW (the owner cannot freeze the market instantly, nor keep a pre-armed removal ready forever)
    function allowOperator(address op) external onlyOwner { operatorAllowed[op] = true; delete disallowAt[op]; emit OperatorAllowed(op, true); }
    function allowContractRecipient(address to) external onlyOwner { contractRecipientAllowed[to] = true; delete disallowAt[to]; emit ContractRecipientAllowed(to, true); }
    function scheduleDisallow(address addr) external onlyOwner { disallowAt[addr] = block.timestamp + DISALLOW_DELAY; emit DisallowScheduled(addr, disallowAt[addr]); }
    function executeDisallow(address addr) external onlyOwner {
        uint256 at = disallowAt[addr];
        if (at == 0) revert NotScheduled();
        if (block.timestamp < at) revert TooEarly(at);
        if (block.timestamp > at + DISALLOW_WINDOW) revert Expired(at);
        delete disallowAt[addr];
        operatorAllowed[addr] = false;
        contractRecipientAllowed[addr] = false;
        emit OperatorAllowed(addr, false);
        emit ContractRecipientAllowed(addr, false);
    }

    /// @notice Rescue other tokens sent here by mistake; the project token cannot be touched (it belongs to holders)
    function rescueToken(address t, uint256 amount) external onlyOwner {
        if (t == address(token)) revert BadIngredients();
        IERC20(t).safeTransfer(treasury, amount);
    }

    /// @notice Renouncing ownership is disabled (it would freeze allow-lists, fees and the treasury forever)
    function renounceOwnership() public view override onlyOwner {
        revert Forbidden();
    }

    // ---------------------------------------------------------------- transfer guard (ERC721-C style)
    function approve(address to, uint256 id) public override {
        if (to != address(0) && !operatorAllowed[to]) revert OperatorNotAllowed(to);
        super.approve(to, id);
    }

    /// @dev Revoking an operator bumps approvalEpoch: market listings record the epoch at listing time, so re-approving never revives them
    function setApprovalForAll(address op, bool approved) public override {
        if (approved && !operatorAllowed[op]) revert OperatorNotAllowed(op);
        if (!approved && isApprovedForAll(msg.sender, op)) { // revoking an operator that was never approved must not void listings
            approvalEpoch[msg.sender] += 1;
            emit ApprovalEpochBumped(msg.sender, approvalEpoch[msg.sender]);
        }
        super.setApprovalForAll(op, approved);
    }

    /// @dev Every mint / transfer / burn goes through here: guard + per-wallet cap + per-tier accounting
    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = _ownerOf(id);
        uint8 t = tierOf[id];
        if (t == 0 && from == address(0) && auth != address(0)) revert ERC721NonexistentToken(id); // transferring / burning a missing id: standard error instead of BadTier
        if (from != address(0) && to != address(0)) {
            // regular transfer: the owner may transfer directly, otherwise msg.sender must be an allow-listed operator
            if (msg.sender != from && !operatorAllowed[msg.sender]) revert OperatorNotAllowed(msg.sender);
            if (isContractRecipient(to) && !contractRecipientAllowed[to]) revert RecipientNotAllowed(to);
            if (requireAgentRecipient && !canParticipate(to)) revert NotAgent(to);
            transferNonce[id] += 1;
        }
        if (to != address(0)) {
            uint256 cap = maxPerWalletByTier[t];
            if (cap != 0 && balanceByTier[to][t] >= cap) revert WalletCap(t);
        }
        uint256 w = unitsOf(t);
        if (from != address(0)) balanceByTier[from][t] -= 1;
        if (to != address(0)) balanceByTier[to][t] += 1;
        if (from == address(0)) totalUnits += w;
        if (to == address(0)) totalUnits -= w;
        return super._update(to, id, auth);
    }

    // ---------------------------------------------------------------- internal
    /// @dev Before graduation the token is locked: tokens move only through the pad (vaultLock / vaultRelease).
    function _curveLive() internal view returns (bool) {
        return IGangToken(address(token)).locked();
    }

    function _mintTier(address to, uint8 tier, uint256 fee) internal returns (uint256 id) {
        id = nextId++;
        tierOf[id] = tier;
        mintedByTier[tier] += 1;
        // Random seed for every tier, so the mint order reveals nothing on-chain. The seed -> artwork mapping is kept off-chain,
        // so re-rolling a seed gains nothing.
        bytes32 seed = keccak256(abi.encodePacked(blockhash(block.number - 1), block.prevrandao, id, to, block.timestamp));
        seedOf[id] = seed;
        _mint(to, id);
        emit Minted(to, id, tier, seed, fee);
    }

    function _burnInternal(uint256 id) internal {
        _burnedCount += 1;
        mintedByTier[tierOf[id]] -= 1; // the slot goes back to the tier's cap
        _burn(id);
        delete tierOf[id];
        delete seedOf[id];
    }

    function _checkTierLimit(uint8 tier, uint256 count) internal view {
        uint256 cap = maxMintByTier[tier];
        if (cap != 0 && mintedByTier[tier] + count > cap) revert TierSoldOut(tier);
    }

    /// @dev Fees go straight to the treasury; if that fails (the contract refuses / runs out of gas) they are accrued so user mints / burns never fail
    function _payTreasury(uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = treasury.call{value: amount, gas: 50_000}(""); // gas-capped: a treasury contract must not make user burns expensive; anything more is accrued
        if (!ok) {
            accruedFees += amount;
            emit FeeAccrued(amount);
        }
    }
}
