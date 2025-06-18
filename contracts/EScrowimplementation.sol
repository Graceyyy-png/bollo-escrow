// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ============================================================================
// INTERFACES
// ============================================================================

interface IEscrow {
    enum EscrowState { Created, Funded, InProgress, Completed, Disputed, Cancelled }
    
    struct EscrowTerms {
        address buyer;
        address seller;
        address arbitrator;
        address token; // address(0) for ETH
        uint256 amount;
        uint256 deadline;
        string description;
        bytes32[] milestones;
    }
    
    event EscrowCreated(uint256 indexed escrowId, address buyer, address seller, uint256 amount);
    event EscrowFunded(uint256 indexed escrowId, uint256 amount);
    event EscrowCompleted(uint256 indexed escrowId, address recipient, uint256 amount);
    event EscrowDisputed(uint256 indexed escrowId, address disputer);
    event EscrowCancelled(uint256 indexed escrowId, address canceller);
    event MilestoneCompleted(uint256 indexed escrowId, bytes32 milestone);
}

interface IArbitrator {
    function resolveDispute(uint256 escrowId, address winner, uint256 buyerAmount, uint256 sellerAmount) external;
}

// ============================================================================
// LIBRARIES
// ============================================================================

library EscrowLib {
    using SafeERC20 for IERC20;
    
    function safeTransferETH(address to, uint256 amount) internal {
        require(address(this).balance >= amount, "Insufficient ETH balance");
        (bool success, ) = payable(to).call{value: amount}("");
        require(success, "ETH transfer failed");
    }
    
    function safeTransferToken(address token, address to, uint256 amount) internal {
        IERC20(token).safeTransfer(to, amount);
    }
    
    function calculateFee(uint256 amount, uint256 feePercentage) internal pure returns (uint256) {
        return (amount * feePercentage) / 10000; // basis points
    }
}

// ============================================================================
// MAIN ESCROW CONTRACT
// ============================================================================

contract Escrow is IEscrow, ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;
    using EscrowLib for address;

    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    uint256 private constant MAX_FEE_PERCENTAGE = 1000; // 10% max fee
    uint256 private constant DISPUTE_TIMEOUT = 30 days;
    
    uint256 public escrowCounter;
    uint256 public feePercentage = 250; // 2.5% default fee
    address public feeRecipient;
    
    mapping(uint256 => EscrowTerms) public escrows;
    mapping(uint256 => EscrowState) public escrowStates;
    mapping(uint256 => mapping(bytes32 => bool)) public completedMilestones;
    mapping(uint256 => uint256) public disputeTimestamp;
    mapping(uint256 => address) public disputeInitiator;
    
    // Security: Track user escrow counts to prevent spam
    mapping(address => uint256) public userEscrowCount;
    uint256 public constant MAX_ESCROWS_PER_USER = 100;
    
    modifier onlyEscrowParty(uint256 escrowId) {
        EscrowTerms memory terms = escrows[escrowId];
        require(
            msg.sender == terms.buyer || 
            msg.sender == terms.seller || 
            hasRole(ARBITRATOR_ROLE, msg.sender),
            "Not authorized for this escrow"
        );
        _;
    }
    
    modifier onlyValidEscrow(uint256 escrowId) {
        require(escrowId < escrowCounter, "Escrow does not exist");
        _;
    }
    
    modifier onlyActiveEscrow(uint256 escrowId) {
        require(
            escrowStates[escrowId] != EscrowState.Completed &&
            escrowStates[escrowId] != EscrowState.Cancelled,
            "Escrow is not active"
        );
        _;
    }

    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }
    
    // ============================================================================
    // ESCROW CREATION AND FUNDING
    // ============================================================================
    
    function createEscrow(
        address _seller,
        address _arbitrator,
        address _token,
        uint256 _amount,
        uint256 _deadline,
        string calldata _description,
        bytes32[] calldata _milestones
    ) external payable nonReentrant whenNotPaused returns (uint256) {
        require(_seller != address(0), "Invalid seller address");
        require(_seller != msg.sender, "Buyer cannot be seller");
        require(_amount > 0, "Amount must be greater than 0");
        require(_deadline > block.timestamp, "Deadline must be in future");
        require(userEscrowCount[msg.sender] < MAX_ESCROWS_PER_USER, "Max escrows exceeded");
        
        uint256 escrowId = escrowCounter++;
        
        EscrowTerms memory terms = EscrowTerms({
            buyer: msg.sender,
            seller: _seller,
            arbitrator: _arbitrator,
            token: _token,
            amount: _amount,
            deadline: _deadline,
            description: _description,
            milestones: _milestones
        });
        
        escrows[escrowId] = terms;
        escrowStates[escrowId] = EscrowState.Created;
        userEscrowCount[msg.sender]++;
        
        // Auto-fund if ETH is sent
        if (_token == address(0) && msg.value > 0) {
            require(msg.value == _amount, "ETH amount mismatch");
            _fundEscrow(escrowId);
        }
        
        emit EscrowCreated(escrowId, msg.sender, _seller, _amount);
        return escrowId;
    }
    
    function fundEscrow(uint256 escrowId) 
        external 
        payable 
        nonReentrant 
        onlyValidEscrow(escrowId) 
        whenNotPaused 
    {
        EscrowTerms memory terms = escrows[escrowId];
        require(msg.sender == terms.buyer, "Only buyer can fund");
        require(escrowStates[escrowId] == EscrowState.Created, "Escrow already funded");
        
        if (terms.token == address(0)) {
            require(msg.value == terms.amount, "Incorrect ETH amount");
        } else {
            require(msg.value == 0, "No ETH should be sent for token escrow");
            IERC20(terms.token).safeTransferFrom(msg.sender, address(this), terms.amount);
        }
        
        _fundEscrow(escrowId);
    }
    
    function _fundEscrow(uint256 escrowId) internal {
        escrowStates[escrowId] = EscrowState.Funded;
        emit EscrowFunded(escrowId, escrows[escrowId].amount);
    }
    
    // ============================================================================
    // MILESTONE AND COMPLETION
    // ============================================================================
    
    function completeMilestone(uint256 escrowId, bytes32 milestone) 
        external 
        onlyValidEscrow(escrowId) 
        onlyActiveEscrow(escrowId)
        whenNotPaused 
    {
        EscrowTerms memory terms = escrows[escrowId];
        require(msg.sender == terms.seller, "Only seller can complete milestones");
        require(escrowStates[escrowId] == EscrowState.Funded, "Escrow not funded");
        require(!completedMilestones[escrowId][milestone], "Milestone already completed");
        
        // Verify milestone exists in the original terms
        bool milestoneExists = false;
        for (uint256 i = 0; i < terms.milestones.length; i++) {
            if (terms.milestones[i] == milestone) {
                milestoneExists = true;
                break;
            }
        }
        require(milestoneExists, "Invalid milestone");
        
        completedMilestones[escrowId][milestone] = true;
        emit MilestoneCompleted(escrowId, milestone);
        
        // Check if all milestones are completed
        if (_allMilestonesCompleted(escrowId)) {
            escrowStates[escrowId] = EscrowState.InProgress;
        }
    }
    
    function completeEscrow(uint256 escrowId) 
        external 
        nonReentrant 
        onlyValidEscrow(escrowId) 
        onlyActiveEscrow(escrowId)
        whenNotPaused 
    {
        EscrowTerms memory terms = escrows[escrowId];
        require(
            msg.sender == terms.buyer || 
            (msg.sender == terms.seller && _allMilestonesCompleted(escrowId)),
            "Not authorized to complete"
        );
        require(
            escrowStates[escrowId] == EscrowState.Funded || 
            escrowStates[escrowId] == EscrowState.InProgress,
            "Invalid state for completion"
        );
        
        _releaseToSeller(escrowId);
    }
    
    function _releaseToSeller(uint256 escrowId) internal {
        EscrowTerms memory terms = escrows[escrowId];
        uint256 fee = EscrowLib.calculateFee(terms.amount, feePercentage);
        uint256 sellerAmount = terms.amount - fee;
        
        escrowStates[escrowId] = EscrowState.Completed;
        
        if (terms.token == address(0)) {
            EscrowLib.safeTransferETH(terms.seller, sellerAmount);
            if (fee > 0) {
                EscrowLib.safeTransferETH(feeRecipient, fee);
            }
        } else {
            EscrowLib.safeTransferToken(terms.token, terms.seller, sellerAmount);
            if (fee > 0) {
                EscrowLib.safeTransferToken(terms.token, feeRecipient, fee);
            }
        }
        
        emit EscrowCompleted(escrowId, terms.seller, sellerAmount);
    }
    
    // ============================================================================
    // DISPUTE RESOLUTION
    // ============================================================================
    
    function initiateDispute(uint256 escrowId) 
        external 
        onlyValidEscrow(escrowId) 
        onlyEscrowParty(escrowId)
        onlyActiveEscrow(escrowId)
        whenNotPaused 
    {
        require(escrowStates[escrowId] == EscrowState.Funded, "Can only dispute funded escrows");
        require(disputeTimestamp[escrowId] == 0, "Dispute already initiated");
        
        EscrowTerms memory terms = escrows[escrowId];
        require(terms.arbitrator != address(0), "No arbitrator assigned");
        
        escrowStates[escrowId] = EscrowState.Disputed;
        disputeTimestamp[escrowId] = block.timestamp;
        disputeInitiator[escrowId] = msg.sender;
        
        emit EscrowDisputed(escrowId, msg.sender);
    }
    
    function resolveDispute(
        uint256 escrowId, 
        address winner, 
        uint256 buyerAmount, 
        uint256 sellerAmount
    ) external onlyValidEscrow(escrowId) whenNotPaused {
        EscrowTerms memory terms = escrows[escrowId];
        require(msg.sender == terms.arbitrator, "Only assigned arbitrator");
        require(escrowStates[escrowId] == EscrowState.Disputed, "Not in dispute");
        require(buyerAmount + sellerAmount <= terms.amount, "Invalid distribution");
        
        escrowStates[escrowId] = EscrowState.Completed;
        
        if (terms.token == address(0)) {
            if (buyerAmount > 0) EscrowLib.safeTransferETH(terms.buyer, buyerAmount);
            if (sellerAmount > 0) EscrowLib.safeTransferETH(terms.seller, sellerAmount);
        } else {
            if (buyerAmount > 0) EscrowLib.safeTransferToken(terms.token, terms.buyer, buyerAmount);
            if (sellerAmount > 0) EscrowLib.safeTransferToken(terms.token, terms.seller, sellerAmount);
        }
        
        emit EscrowCompleted(escrowId, winner, winner == terms.buyer ? buyerAmount : sellerAmount);
    }
    
    // ============================================================================
    // CANCELLATION AND REFUNDS
    // ============================================================================
    
    function cancelEscrow(uint256 escrowId) 
        external 
        nonReentrant 
        onlyValidEscrow(escrowId) 
        onlyActiveEscrow(escrowId)
        whenNotPaused 
    {
        EscrowTerms memory terms = escrows[escrowId];
        require(
            msg.sender == terms.buyer || 
            msg.sender == terms.seller ||
            block.timestamp > terms.deadline,
            "Not authorized to cancel"
        );
        
        // Only allow cancellation if not funded or if deadline passed
        require(
            escrowStates[escrowId] == EscrowState.Created || 
            block.timestamp > terms.deadline ||
            (escrowStates[escrowId] == EscrowState.Disputed && 
             block.timestamp > disputeTimestamp[escrowId] + DISPUTE_TIMEOUT),
            "Cannot cancel at this time"
        );
        
        escrowStates[escrowId] = EscrowState.Cancelled;
        
        // Refund if escrow was funded
        if (escrowStates[escrowId] != EscrowState.Created) {
            if (terms.token == address(0)) {
                EscrowLib.safeTransferETH(terms.buyer, terms.amount);
            } else {
                EscrowLib.safeTransferToken(terms.token, terms.buyer, terms.amount);
            }
        }
        
        emit EscrowCancelled(escrowId, msg.sender);
    }
    
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================
    
    function getEscrowDetails(uint256 escrowId) 
        external 
        view 
        onlyValidEscrow(escrowId) 
        returns (EscrowTerms memory, EscrowState) 
    {
        return (escrows[escrowId], escrowStates[escrowId]);
    }
    
    function getMilestoneStatus(uint256 escrowId, bytes32 milestone) 
        external 
        view 
        onlyValidEscrow(escrowId) 
        returns (bool) 
    {
        return completedMilestones[escrowId][milestone];
    }
    
    function _allMilestonesCompleted(uint256 escrowId) internal view returns (bool) {
        EscrowTerms memory terms = escrows[escrowId];
        if (terms.milestones.length == 0) return true;
        
        for (uint256 i = 0; i < terms.milestones.length; i++) {
            if (!completedMilestones[escrowId][terms.milestones[i]]) {
                return false;
            }
        }
        return true;
    }
    
    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================
    
    function setFeePercentage(uint256 _feePercentage) external onlyRole(ADMIN_ROLE) {
        require(_feePercentage <= MAX_FEE_PERCENTAGE, "Fee too high");
        feePercentage = _feePercentage;
    }
    
    function setFeeRecipient(address _feeRecipient) external onlyRole(ADMIN_ROLE) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;
    }
    
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    function emergencyWithdraw(address token, uint256 amount) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (token == address(0)) {
            EscrowLib.safeTransferETH(msg.sender, amount);
        } else {
            EscrowLib.safeTransferToken(token, msg.sender, amount);
        }
    }
}

// ============================================================================
// ESCROW FACTORY
// ============================================================================

contract EscrowFactory is AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    address public escrowImplementation;
    address[] public allEscrows;
    mapping(address => address[]) public userEscrows;
    
    event EscrowDeployed(address indexed escrow, address indexed creator);
    
    constructor(address _escrowImplementation) {
        require(_escrowImplementation != address(0), "Invalid implementation");
        escrowImplementation = _escrowImplementation;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }
    
    function createEscrow(address feeRecipient) external returns (address) {
        // Deploy new escrow contract
        bytes memory bytecode = abi.encodePacked(
            type(Escrow).creationCode,
            abi.encode(feeRecipient)
        );
        
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, block.timestamp));
        address escrowAddress;
        
        assembly {
            escrowAddress := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        
        require(escrowAddress != address(0), "Escrow deployment failed");
        
        allEscrows.push(escrowAddress);
        userEscrows[msg.sender].push(escrowAddress);
        
        emit EscrowDeployed(escrowAddress, msg.sender);
        return escrowAddress;
    }
    
    function getUserEscrows(address user) external view returns (address[] memory) {
        return userEscrows[user];
    }
    
    function getAllEscrows() external view returns (address[] memory) {
        return allEscrows;
    }
    
    function getEscrowCount() external view returns (uint256) {
        return allEscrows.length;
    }
}