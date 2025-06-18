// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

// ============================================================================
// MULTI-SIGNATURE ARBITRATOR
// ============================================================================

contract MultiSigArbitrator is AccessControl, ReentrancyGuard, EIP712 {
    using ECDSA for bytes32;
    
    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    bytes32 private constant RESOLUTION_TYPEHASH = keccak256(
        "DisputeResolution(uint256 escrowId,address winner,uint256 buyerAmount,uint256 sellerAmount,uint256 nonce,uint256 deadline)"
    );
    
    struct DisputeResolution {
        uint256 escrowId;
        address winner;
        uint256 buyerAmount;
        uint256 sellerAmount;
        uint256 nonce;
        uint256 deadline;
    }
    
    uint256 public requiredSignatures;
    uint256 public arbitratorCount;
    mapping(address => bool) public isArbitrator;
    mapping(uint256 => uint256) public nonces;
    mapping(uint256 => bool) public resolvedDisputes;
    
    event ArbitratorAdded(address arbitrator);
    event ArbitratorRemoved(address arbitrator);
    event RequiredSignaturesChanged(uint256 newRequirement);
    event DisputeResolved(uint256 indexed escrowId, address winner, uint256 buyerAmount, uint256 sellerAmount);
    
    modifier onlyArbitrator() {
        require(hasRole(ARBITRATOR_ROLE, msg.sender), "Not an arbitrator");
        _;
    }
    
    constructor(
        address[] memory _arbitrators,
        uint256 _requiredSignatures,
        string memory _name,
        string memory _version
    ) EIP712(_name, _version) {
        require(_arbitrators.length > 0, "No arbitrators provided");
        require(_requiredSignatures > 0 && _requiredSignatures <= _arbitrators.length, "Invalid signature requirement");
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        
        for (uint256 i = 0; i < _arbitrators.length; i++) {
            require(_arbitrators[i] != address(0), "Invalid arbitrator address");
            require(!isArbitrator[_arbitrators[i]], "Duplicate arbitrator");
            
            isArbitrator[_arbitrators[i]] = true;
            _grantRole(ARBITRATOR_ROLE, _arbitrators[i]);
        }
        
        arbitratorCount = _arbitrators.length;
        requiredSignatures = _requiredSignatures;
    }
    
    function resolveDisputeWithSignatures(
        DisputeResolution calldata resolution,
        bytes[] calldata signatures
    ) external nonReentrant {
        require(signatures.length >= requiredSignatures, "Insufficient signatures");
        require(resolution.deadline >= block.timestamp, "Resolution expired");
        require(!resolvedDisputes[resolution.escrowId], "Dispute already resolved");
        require(resolution.nonce == nonces[resolution.escrowId], "Invalid nonce");
        
        bytes32 structHash = keccak256(abi.encode(
            RESOLUTION_TYPEHASH,
            resolution.escrowId,
            resolution.winner,
            resolution.buyerAmount,
            resolution.sellerAmount,
            resolution.nonce,
            resolution.deadline
        ));
        
        bytes32 hash = _hashTypedDataV4(structHash);
        
        address[] memory signers = new address[](signatures.length);
        uint256 validSignatures = 0;
        
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = hash.recover(signatures[i]);
            require(hasRole(ARBITRATOR_ROLE, signer), "Invalid arbitrator signature");
            
            // Check for duplicate signers
            bool duplicate = false;
            for (uint256 j = 0; j < validSignatures; j++) {
                if (signers[j] == signer) {
                    duplicate = true;
                    break;
                }
            }
            
            if (!duplicate) {
                signers[validSignatures] = signer;
                validSignatures++;
            }
        }
        
        require(validSignatures >= requiredSignatures, "Insufficient unique signatures");
        
        resolvedDisputes[resolution.escrowId] = true;
        nonces[resolution.escrowId]++;
        
        emit DisputeResolved(resolution.escrowId, resolution.winner, resolution.buyerAmount, resolution.sellerAmount);
        
        // Call the escrow contract to execute the resolution
        // This would typically call back to the escrow contract
        // Implementation depends on the specific escrow contract interface
    }
    
    function addArbitrator(address arbitrator) external onlyRole(ADMIN_ROLE) {
        require(arbitrator != address(0), "Invalid arbitrator address");
        require(!isArbitrator[arbitrator], "Already an arbitrator");
        
        isArbitrator[arbitrator] = true;
        _grantRole(ARBITRATOR_ROLE, arbitrator);
        arbitratorCount++;
        
        emit ArbitratorAdded(arbitrator);
    }
    
    function removeArbitrator(address arbitrator) external onlyRole(ADMIN_ROLE) {
        require(isArbitrator[arbitrator], "Not an arbitrator");
        require(arbitratorCount > requiredSignatures, "Cannot remove arbitrator below requirement");
        
        isArbitrator[arbitrator] = false;
        _revokeRole(ARBITRATOR_ROLE, arbitrator);
        arbitratorCount--;
        
        emit ArbitratorRemoved(arbitrator);
    }
    
    function setRequiredSignatures(uint256 _requiredSignatures) external onlyRole(ADMIN_ROLE) {
        require(_requiredSignatures > 0 && _requiredSignatures <= arbitratorCount, "Invalid signature requirement");
        requiredSignatures = _requiredSignatures;
        
        emit RequiredSignaturesChanged(_requiredSignatures);
    }
    
    function getResolutionHash(DisputeResolution calldata resolution) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            RESOLUTION_TYPEHASH,
            resolution.escrowId,
            resolution.winner,
            resolution.buyerAmount,
            resolution.sellerAmount,
            resolution.nonce,
            resolution.deadline
        ));
        
        return _hashTypedDataV4(structHash);
    }
}

// ============================================================================
// ESCROW REGISTRY
// ============================================================================

contract EscrowRegistry is AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    
    struct EscrowInfo {
        address escrowAddress;
        address creator;
        uint256 createdAt;
        bool isActive;
    }
    
    mapping(address => EscrowInfo) public escrowInfo;
    mapping(address => address[]) public userEscrows;
    address[] public allEscrows;
    
    event EscrowRegistered(address indexed escrow, address indexed creator);
    event EscrowDeactivated(address indexed escrow);
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }
    
    function registerEscrow(address escrow, address creator) external onlyRole(FACTORY_ROLE) {
        require(escrow != address(0), "Invalid escrow address");
        require(creator != address(0), "Invalid creator address");
        require(escrowInfo[escrow].escrowAddress == address(0), "Escrow already registered");
        
        escrowInfo[escrow] = EscrowInfo({
            escrowAddress: escrow,
            creator: creator,
            createdAt: block.timestamp,
            isActive: true
        });
        
        userEscrows[creator].push(escrow);
        allEscrows.push(escrow);
        
        emit EscrowRegistered(escrow, creator);
    }
    
    function deactivateEscrow(address escrow) external onlyRole(ADMIN_ROLE) {
        require(escrowInfo[escrow].isActive, "Escrow not active");
        escrowInfo[escrow].isActive = false;
        emit EscrowDeactivated(escrow);
    }
    
    function isValidEscrow(address escrow) external view returns (bool) {
        return escrowInfo[escrow].isActive;
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

// ============================================================================
// EMERGENCY PAUSE CONTRACT
// ============================================================================

contract EmergencyPause is AccessControl {
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    bool public globalPause;
    mapping(address => bool) public contractPaused;
    mapping(address => uint256) public pauseTimestamp;
    
    uint256 public constant MAX_PAUSE_DURATION = 7 days;
    
    event GlobalPauseToggled(bool paused);
    event ContractPauseToggled(address indexed contractAddr, bool paused);
    event EmergencyActivated(address indexed caller, string reason);
    
    modifier whenNotGloballyPaused() {
        require(!globalPause, "Globally paused");
        _;
    }
    
    modifier whenContractNotPaused(address contractAddr) {
        require(!contractPaused[contractAddr], "Contract paused");
        _;
    }
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }
    
    function toggleGlobalPause() external onlyRole(EMERGENCY_ROLE) {
        globalPause = !globalPause;
        emit GlobalPauseToggled(globalPause);
    }
    
    function toggleContractPause(address contractAddr) external onlyRole(EMERGENCY_ROLE) {
        require(contractAddr != address(0), "Invalid contract address");
        
        contractPaused[contractAddr] = !contractPaused[contractAddr];
        
        if (contractPaused[contractAddr]) {
            pauseTimestamp[contractAddr] = block.timestamp;
        } else {
            pauseTimestamp[contractAddr] = 0;
        }
        
        emit ContractPauseToggled(contractAddr, contractPaused[contractAddr]);
    }
    
    function emergencyStop(string calldata reason) external onlyRole(EMERGENCY_ROLE) {
        globalPause = true;
        emit EmergencyActivated(msg.sender, reason);
        emit GlobalPauseToggled(true);
    }
    
    function forceUnpause(address contractAddr) external onlyRole(ADMIN_ROLE) {
        require(contractPaused[contractAddr], "Contract not paused");
        require(
            block.timestamp > pauseTimestamp[contractAddr] + MAX_PAUSE_DURATION,
            "Pause duration not exceeded"
        );
        
        contractPaused[contractAddr] = false;
        pauseTimestamp[contractAddr] = 0;
        
        emit ContractPauseToggled(contractAddr, false);
    }
    
    function isPaused(address contractAddr) external view returns (bool) {
        return globalPause || contractPaused[contractAddr];
    }
}

// ============================================================================
// ORACLE INTEGRATION CONTRACT
// ============================================================================

contract EscrowOracle is AccessControl {
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    struct OracleData {
        uint256 value;
        uint256 timestamp;
        bool isValid;
    }
    
    mapping(bytes32 => OracleData) public oracleData;
    mapping(address => bool) public authorizedOracles;
    
    uint256 public constant DATA_VALIDITY_PERIOD = 1 hours;
    
    event OracleDataUpdated(bytes32 indexed key, uint256 value, address oracle);
    event OracleAuthorized(address indexed oracle);
    event OracleRevoked(address indexed oracle);
    
    modifier onlyAuthorizedOracle() {
        require(authorizedOracles[msg.sender] || hasRole(ORACLE_ROLE, msg.sender), "Not authorized oracle");
        _;
    }
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
    }
    
    function updateData(bytes32 key, uint256 value) external onlyAuthorizedOracle {
        oracleData[key] = OracleData({
            value: value,
            timestamp: block.timestamp,
            isValid: true
        });
        
        emit OracleDataUpdated(key, value, msg.sender);
    }
    
    function getData(bytes32 key) external view returns (uint256 value, bool isValid) {
        OracleData memory data = oracleData[key];
        
        bool stillValid = data.isValid && 
                         (block.timestamp - data.timestamp <= DATA_VALIDITY_PERIOD);
        
        return (data.value, stillValid);
    }
    
    function authorizeOracle(address oracle) external onlyRole(ADMIN_ROLE) {
        require(oracle != address(0), "Invalid oracle address");
        authorizedOracles[oracle] = true;
        emit OracleAuthorized(oracle);
    }
    
    function revokeOracle(address oracle) external onlyRole(ADMIN_ROLE) {
        authorizedOracles[oracle] = false;
        emit OracleRevoked(oracle);
    }
    
    function invalidateData(bytes32 key) external onlyRole(ADMIN_ROLE) {
        oracleData[key].isValid = false;
    }
}

// ============================================================================
// ESCROW WITH ORACLE INTEGRATION
// ============================================================================

contract OracleEscrow is Escrow {
    EscrowOracle public oracle;
    
    struct OracleCondition {
        bytes32 dataKey;
        uint256 targetValue;
        bool greaterThan; // true for >=, false for <=
    }
    
    mapping(uint256 => OracleCondition) public oracleConditions;
    mapping(uint256 => bool) public hasOracleCondition;
    
    event OracleConditionSet(uint256 indexed escrowId, bytes32 dataKey, uint256 targetValue, bool greaterThan);
    event OracleConditionMet(uint256 indexed escrowId, bytes32 dataKey, uint256 actualValue);
    
    constructor(address _feeRecipient, address _oracle) Escrow(_feeRecipient) {
        require(_oracle != address(0), "Invalid oracle address");
        oracle = EscrowOracle(_oracle);
    }
    
    function setOracleCondition(
        uint256 escrowId,
        bytes32 dataKey,
        uint256 targetValue,
        bool greaterThan
    ) external onlyValidEscrow(escrowId) {
        EscrowTerms memory terms = escrows[escrowId];
        require(msg.sender == terms.buyer || msg.sender == terms.seller, "Not authorized");
        require(escrowStates[escrowId] == EscrowState.Created, "Cannot set condition after funding");
        
        oracleConditions[escrowId] = OracleCondition({
            dataKey: dataKey,
            targetValue: targetValue,
            greaterThan: greaterThan
        });
        
        hasOracleCondition[escrowId] = true;
        
        emit OracleConditionSet(escrowId, dataKey, targetValue, greaterThan);
    }
    
    function checkOracleCondition(uint256 escrowId) public view returns (bool) {
        if (!hasOracleCondition[escrowId]) {
            return true; // No condition means it's always met
        }
        
        OracleCondition memory condition = oracleConditions[escrowId];
        (uint256 actualValue, bool isValid) = oracle.getData(condition.dataKey);
        
        if (!isValid) {
            return false; // Invalid data means condition is not met
        }
        
        if (condition.greaterThan) {
            return actualValue >= condition.targetValue;
        } else {
            return actualValue <= condition.targetValue;
        }
    }
    
    function completeEscrowWithOracle(uint256 escrowId) 
        external 
        nonReentrant 
        onlyValidEscrow(escrowId) 
        onlyActiveEscrow(escrowId)
        whenNotPaused 
    {
        require(checkOracleCondition(escrowId), "Oracle condition not met");
        
        if (hasOracleCondition[escrowId]) {
            OracleCondition memory condition = oracleConditions[escrowId];
            (uint256 actualValue, ) = oracle.getData(condition.dataKey);
            emit OracleConditionMet(escrowId, condition.dataKey, actualValue);
        }
        
        // Call the parent completeEscrow function
        this.completeEscrow(escrowId);
    }
}