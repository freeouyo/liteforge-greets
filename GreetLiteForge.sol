// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * @title  GreetLiteForge
 * @author ChainGreets (chaingreets.xyz)
 * @notice On-chain GM / GN greetings with streak tracking and optional zkLTC tip,
 *         built for the LiteForge Hackathon on LitVM — Litecoin's first EVM rollup.
 *
 * @dev    Deployed on LitVM (Arbitrum Orbit / Nitro stack).
 *         Compiler : Solidity 0.8.35, EVM default (cancun)
 *         Chain ID : 4441 (0x1159)
 *         Native token : zkLTC
 *         RPC : https://liteforge.rpc.caldera.xyz/http
 *         Explorer : https://liteforge.explorer.caldera.xyz
 *
 *         Arbitrum Orbit compatibility notes:
 *         - No EIP-1559 (maxFeePerGas / maxPriorityFeePerGas).
 *           Callers must use legacy gasPrice transactions.
 *         - Recommended gasPrice : 0x989680 (0.1 Gwei).
 *         - Always fetch the pending nonce from the RPC before sending
 *           to avoid "wrong msgIdx" sequencer reverts.
 *
 * ─────────────────────────────────────────────────────────────────
 * FEATURES
 * ─────────────────────────────────────────────────────────────────
 *  • gm(string message) payable
 *      Send a Good Morning with an optional tip in zkLTC.
 *      A protocol fee (adjustable by owner) is forwarded to the collector.
 *      Limited to once per UTC day per address.
 *      Consecutive daily GMs increment the onchain streak counter.
 *
 *  • gn(string message) payable
 *      Same mechanic for Good Night.
 *
 *  • Streak logic
 *      dayIndex = block.timestamp / 86400  (UTC day, integer)
 *      If lastDay[sender] == today - 1  → streak incremented.
 *      If lastDay[sender] == today       → revert (already greeted today).
 *      Otherwise                         → streak resets to 1.
 *      GM and GN have independent streak counters.
 *
 *  • Protocol fee
 *      fee is set at deploy to 0.000123 zkLTC, adjustable by owner via setFee().
 *      msg.value must be >= fee.
 *      The fee is forwarded to collector immediately (checks-effects-interactions).
 *      Any amount above fee is held in the contract as a tip, withdrawable by owner.
 *
 *  • Pause / Unpause
 *      Owner can pause the contract to block all gm() / gn() calls.
 *      Useful for maintenance or emergency situations.
 *
 *  • 2-step ownership transfer
 *      Owner proposes a new owner → new owner must explicitly accept.
 *      Prevents accidental transfer to a wrong or unreachable address.
 *
 *  • Reentrancy guard
 *      All state-mutating external functions are protected against reentrancy.
 *
 *  • View helpers
 *      getGmStreak(address)  → current GM streak
 *      getGnStreak(address)  → current GN streak
 *      canGm(address)        → true if address has not GM'd today
 *      canGn(address)        → true if address has not GN'd today
 *      getStats(address)     → (gmCount, gnCount, gmStreak, gnStreak)
 *
 * ─────────────────────────────────────────────────────────────────
 * EVENTS
 * ─────────────────────────────────────────────────────────────────
 *  GM(address indexed sender, string message, uint256 streak, uint256 tip, uint256 dayIndex)
 *  GN(address indexed sender, string message, uint256 streak, uint256 tip, uint256 dayIndex)
 *  FeeUpdated(uint256 oldFee, uint256 newFee)
 *  CollectorUpdated(address indexed oldCollector, address indexed newCollector)
 *  Paused(address indexed by)
 *  Unpaused(address indexed by)
 *  OwnershipTransferProposed(address indexed currentOwner, address indexed proposedOwner)
 *  OwnershipTransferred(address indexed previousOwner, address indexed newOwner)
 *  Withdrawn(address indexed to, uint256 amount)
 */
contract GreetLiteForge {

    // ─── Constants ──────────────────────────────────────────────

    /// @notice Maximum allowed fee the owner can set (safety cap).
    ///         0.01 zkLTC — prevents owner from setting an abusive fee.
    uint256 public constant MAX_FEE = 0.01 ether;

    /// @notice Maximum message length in bytes.
    uint256 public constant MAX_MESSAGE_LENGTH = 280;

    // ─── State ──────────────────────────────────────────────────

    /// @notice Current owner of the contract.
    address public owner;

    /// @notice Pending owner in the 2-step ownership transfer process.
    ///         Zero address means no transfer is pending.
    address public pendingOwner;

    /// @notice Collector address receiving the protocol fee on every GM/GN.
    address public collector;

    /// @notice Protocol fee in wei forwarded to collector on each GM or GN.
    ///         Default: 0.000123 zkLTC. Adjustable by owner within [0, MAX_FEE].
    uint256 public fee;

    /// @notice Whether the contract is paused (gm/gn calls are blocked).
    bool public paused;

    /// @dev Reentrancy lock.
    bool private _locked;

    // GM state per address
    mapping(address => uint256) public lastGmDay;   // UTC day of last GM
    mapping(address => uint256) public gmStreak;    // current consecutive GM streak
    mapping(address => uint256) public gmCount;     // lifetime GM count

    // GN state per address
    mapping(address => uint256) public lastGnDay;   // UTC day of last GN
    mapping(address => uint256) public gnStreak;    // current consecutive GN streak
    mapping(address => uint256) public gnCount;     // lifetime GN count

    // ─── Events ─────────────────────────────────────────────────

    event GM(
        address indexed sender,
        string  message,
        uint256 streak,
        uint256 tip,
        uint256 dayIndex
    );

    event GN(
        address indexed sender,
        string  message,
        uint256 streak,
        uint256 tip,
        uint256 dayIndex
    );

    /// @dev Emitted when the owner updates the protocol fee.
    event FeeUpdated(uint256 oldFee, uint256 newFee);

    /// @dev Emitted when the owner updates the collector address.
    event CollectorUpdated(address indexed oldCollector, address indexed newCollector);

    /// @dev Emitted when the contract is paused.
    event Paused(address indexed by);

    /// @dev Emitted when the contract is unpaused.
    event Unpaused(address indexed by);

    /// @dev Emitted when a new owner is proposed (step 1 of 2-step transfer).
    event OwnershipTransferProposed(address indexed currentOwner, address indexed proposedOwner);

    /// @dev Emitted when the proposed owner accepts ownership (step 2).
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @dev Emitted when the owner withdraws accumulated tips.
    event Withdrawn(address indexed to, uint256 amount);

    // ─── Modifiers ───────────────────────────────────────────────

    /// @dev Restricts function to the current owner.
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    /// @dev Blocks execution when the contract is paused.
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    /// @dev Simple reentrancy guard — mutex lock.
    modifier nonReentrant() {
        require(!_locked, "Reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    // ─── Constructor ─────────────────────────────────────────────

    /**
     * @param _collector  Address that will receive the protocol fee.
     *                    Set to 0xcA96369a4D186887c88867d3bA9239DD679f1547 on deploy.
     */
    constructor(address _collector) {
        require(_collector != address(0), "Zero collector address");
        owner     = msg.sender;
        collector = _collector;
        fee       = 0.000123 ether;   // default protocol fee: 0.000123 zkLTC
    }

    // ─── Core functions ──────────────────────────────────────────

    /**
     * @notice Send a Good Morning on-chain.
     * @dev    - One GM per address per UTC day (enforced on-chain).
     *         - Streak increments if previous GM was exactly yesterday; resets otherwise.
     *         - msg.value must be >= fee. Fee is forwarded to collector immediately.
     *         - Any msg.value above fee is held as a tip, withdrawable by owner.
     *         - Follows checks-effects-interactions pattern to prevent reentrancy.
     * @param  message  Optional text (max 280 chars). Pass "" for no message.
     */
    function gm(string calldata message) external payable whenNotPaused nonReentrant {
        // ── Checks ──
        require(msg.value >= fee, "Insufficient fee");
        require(bytes(message).length <= MAX_MESSAGE_LENGTH, "Message too long");

        uint256 today = block.timestamp / 86400;
        uint256 last  = lastGmDay[msg.sender];
        require(last != today, "Already GM'd today");

        // ── Effects ──
        if (last == today - 1) {
            gmStreak[msg.sender] += 1;
        } else {
            gmStreak[msg.sender] = 1;
        }
        lastGmDay[msg.sender] = today;
        gmCount[msg.sender]  += 1;

        uint256 tip = msg.value - fee;

        emit GM(msg.sender, message, gmStreak[msg.sender], tip, today);

        // ── Interactions ──
        if (fee > 0) {
            (bool ok, ) = collector.call{value: fee}("");
            require(ok, "Fee transfer failed");
        }
    }

    /**
     * @notice Send a Good Night on-chain.
     * @dev    - One GN per address per UTC day (enforced on-chain).
     *         - Streak increments if previous GN was exactly yesterday; resets otherwise.
     *         - msg.value must be >= fee. Fee is forwarded to collector immediately.
     *         - Any msg.value above fee is held as a tip, withdrawable by owner.
     *         - Follows checks-effects-interactions pattern to prevent reentrancy.
     * @param  message  Optional text (max 280 chars). Pass "" for no message.
     */
    function gn(string calldata message) external payable whenNotPaused nonReentrant {
        // ── Checks ──
        require(msg.value >= fee, "Insufficient fee");
        require(bytes(message).length <= MAX_MESSAGE_LENGTH, "Message too long");

        uint256 today = block.timestamp / 86400;
        uint256 last  = lastGnDay[msg.sender];
        require(last != today, "Already GN'd today");

        // ── Effects ──
        if (last == today - 1) {
            gnStreak[msg.sender] += 1;
        } else {
            gnStreak[msg.sender] = 1;
        }
        lastGnDay[msg.sender] = today;
        gnCount[msg.sender]  += 1;

        uint256 tip = msg.value - fee;

        emit GN(msg.sender, message, gnStreak[msg.sender], tip, today);

        // ── Interactions ──
        if (fee > 0) {
            (bool ok, ) = collector.call{value: fee}("");
            require(ok, "Fee transfer failed");
        }
    }

    // ─── View helpers ────────────────────────────────────────────

    /**
     * @notice Returns the current GM streak for a given address.
     * @param  user  Address to query.
     * @return Current consecutive GM streak (0 if never GM'd).
     */
    function getGmStreak(address user) external view returns (uint256) {
        return gmStreak[user];
    }

    /**
     * @notice Returns the current GN streak for a given address.
     * @param  user  Address to query.
     * @return Current consecutive GN streak (0 if never GN'd).
     */
    function getGnStreak(address user) external view returns (uint256) {
        return gnStreak[user];
    }

    /**
     * @notice Returns true if the address has not GM'd today (UTC).
     * @param  user  Address to check.
     * @return True if a gm() call would succeed right now.
     */
    function canGm(address user) external view returns (bool) {
        return lastGmDay[user] != block.timestamp / 86400;
    }

    /**
     * @notice Returns true if the address has not GN'd today (UTC).
     * @param  user  Address to check.
     * @return True if a gn() call would succeed right now.
     */
    function canGn(address user) external view returns (bool) {
        return lastGnDay[user] != block.timestamp / 86400;
    }

    /**
     * @notice Returns aggregated stats for a given address in one call.
     * @param  user  Address to query.
     * @return totalGm          Lifetime GM count.
     * @return totalGn          Lifetime GN count.
     * @return currentGmStreak  Current consecutive GM streak.
     * @return currentGnStreak  Current consecutive GN streak.
     */
    function getStats(address user)
        external
        view
        returns (
            uint256 totalGm,
            uint256 totalGn,
            uint256 currentGmStreak,
            uint256 currentGnStreak
        )
    {
        return (gmCount[user], gnCount[user], gmStreak[user], gnStreak[user]);
    }

    // ─── Owner — fee & collector management ─────────────────────

    /**
     * @notice Update the protocol fee.
     * @dev    Fee must be between 0 and MAX_FEE (0.01 zkLTC).
     *         Setting fee to 0 disables the fee entirely.
     * @param  newFee  New fee amount in wei.
     */
    function setFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_FEE, "Exceeds MAX_FEE (0.01 zkLTC)");
        emit FeeUpdated(fee, newFee);
        fee = newFee;
    }

    /**
     * @notice Update the collector address.
     * @param  newCollector  New collector address (must be non-zero).
     */
    function setCollector(address newCollector) external onlyOwner {
        require(newCollector != address(0), "Zero address");
        emit CollectorUpdated(collector, newCollector);
        collector = newCollector;
    }

    // ─── Owner — pause / unpause ─────────────────────────────────

    /**
     * @notice Pause the contract — blocks all gm() and gn() calls.
     * @dev    Use in case of emergency or maintenance.
     */
    function pause() external onlyOwner {
        require(!paused, "Already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause the contract — re-enables gm() and gn() calls.
     */
    function unpause() external onlyOwner {
        require(paused, "Not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ─── Owner — 2-step ownership transfer ──────────────────────

    /**
     * @notice Step 1 — Propose a new owner.
     * @dev    The current owner nominates a candidate. No transfer happens yet.
     *         Call acceptOwnership() from the proposed address to complete.
     * @param  newOwner  Address of the proposed new owner.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        require(newOwner != owner, "Already owner");
        pendingOwner = newOwner;
        emit OwnershipTransferProposed(owner, newOwner);
    }

    /**
     * @notice Step 2 — Accept ownership.
     * @dev    Must be called by the address set in pendingOwner.
     *         Completes the 2-step ownership transfer.
     */
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner        = pendingOwner;
        pendingOwner = address(0);
    }

    /**
     * @notice Cancel a pending ownership transfer.
     * @dev    Only callable by the current owner.
     */
    function cancelOwnershipTransfer() external onlyOwner {
        require(pendingOwner != address(0), "No pending transfer");
        pendingOwner = address(0);
    }

    // ─── Owner — tip withdrawal ──────────────────────────────────

    /**
     * @notice Withdraw all accumulated zkLTC tips to the owner address.
     * @dev    Tips = amounts sent above the protocol fee, held in this contract.
     *         Uses nonReentrant guard and checks-effects-interactions pattern.
     */
    function withdraw() external onlyOwner nonReentrant {
        uint256 bal = address(this).balance;
        require(bal > 0, "Nothing to withdraw");
        emit Withdrawn(owner, bal);
        (bool ok, ) = owner.call{value: bal}("");
        require(ok, "Transfer failed");
    }

    // ─── Fallback ────────────────────────────────────────────────

    /// @dev Accept plain zkLTC transfers (e.g. direct tips sent to contract address).
    receive() external payable {}
}
