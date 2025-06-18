// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Escrow.sol";
import "./EscrowRegistry.sol";

contract Arbitrator {
    struct DisputeCase {
        address escrowAddress;
        address complainant;
        address respondent;
        string complainantEvidence;
        string respondentEvidence;
        uint256 createdAt;
        uint256 deadline;
        DisputeStatus status;
        string resolution;
        bool buyerFavor;
    }
    
    struct ArbiterProfile {
        string name;
        string specialty;
        uint256 feePercentage;
        uint256 totalCases;
        uint256 resolvedCases;
        uint256 rating;
        uint256 ratingCount;
        bool isActive;
        uint256 responseTime;
        string[] certifications;
    }
    
    enum DisputeStatus {
        PENDING,
        EVIDENCE_COLLECTION,
        UNDER_REVIEW,
        RESOLVED,
        APPEALED,
        CLOSED
    }
    
    mapping(uint256 => DisputeCase) public disputes;
    mapping(address => ArbiterProfile) public arbiterProfiles;
    mapping(address => uint256[]) public arbiterCases;
    mapping(address => uint256[]) public userDisputes;
    mapping(uint256 => address) public caseArbiters;
    mapping(address => uint256) public arbiterEarnings;
    mapping(uint256 => mapping(address => bool)) public evidenceSubmitted;
    
    uint256 public nextDisputeId;
    uint256 public standardFee;
    uint256 public evidenceDeadline;
    uint256 public reviewDeadline;
    address public registry;
    address public owner;
    
    event DisputeCreated(
        uint256 indexed disputeId,
        address indexed escrow,
        address indexed complainant,
        address respondent,
        address arbiter
    );
    
    event EvidenceSubmitted(
        uint256 indexed disputeId,
        address indexed submitter,
        string evidence
    );
    
    event DisputeResolved(
        uint256 indexed disputeId,
        address indexed arbiter,
        bool buyerFavor,
        string resolution
    );
    
    event ArbiterRegistered(address indexed arbiter, string name, string specialty);
    event ArbiterRated(address indexed arbiter, uint256 rating, address ratedBy);
    event FeeCollected(address indexed arbiter, uint256 amount, uint256 disputeId);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this");
        _;
    }
    
    modifier onlyActiveArbiter() {
        require(arbiterProfiles[msg.sender].isActive, "Arbiter not active");
        _;
    }
    
    modifier onlyAssignedArbiter(uint256 disputeId) {
        require(caseArbiters[disputeId] == msg.sender, "Not assigned arbiter");
        _;
    }
    
    modifier onlyDisputeParties(uint256 disputeId) {
        DisputeCase memory dispute = disputes[disputeId];
        require(
            msg.sender == dispute.complainant || 
            msg.sender == dispute.respondent ||
            caseArbiters[disputeId] == msg.sender,
            "Not authorized"
        );
        _;
    }
    
    constructor(address _registry) {
        owner = msg.sender;
        registry = _registry;
        nextDisputeId = 1;
        standardFee = 0.01 ether;
        evidenceDeadline = 7 days;
        reviewDeadline = 3 days;
    }
    
    function registerArbiter(
        string memory name,
        string memory specialty,
        uint256 feePercentage,
        string[] memory certifications
    ) external {
        require(bytes(name).length > 0, "Name required");
        require(feePercentage <= 1000, "Fee cannot exceed 10%");
        require(!arbiterProfiles[msg.sender].isActive, "Already registered");
        
        arbiterProfiles[msg.sender] = ArbiterProfile({
            name: name,
            specialty: specialty,
            feePercentage: feePercentage,
            totalCases: 0,
            resolvedCases: 0,
            rating: 0,
            ratingCount: 0,
            isActive: true,
            responseTime: 0,
            certifications: certifications
        });
        
        emit ArbiterRegistered(msg.sender, name, specialty);
    }
    
    function updateArbiterProfile(
        string memory name,
        string memory specialty,
        uint256 feePercentage
    ) external onlyActiveArbiter {
        require(feePercentage <= 1000, "Fee cannot exceed 10%");
        
        ArbiterProfile storage profile = arbiterProfiles[msg.sender];
        profile.name = name;
        profile.specialty = specialty;
        profile.feePercentage = feePercentage;
    }
    
    function deactivateArbiter() external onlyActiveArbiter {
        arbiterProfiles[msg.sender].isActive = false;
    }
    
    function createDispute(
        address escrowAddress,
        address respondent,
        address preferredArbiter,
        string memory evidence
    ) external payable {
        require(msg.value >= standardFee, "Insufficient dispute fee");
        require(arbiterProfiles[preferredArbiter].isActive, "Arbiter not active");
        
        Escrow escrow = Escrow(escrowAddress);
        require(
            msg.sender == escrow.buyer() || msg.sender == escrow.seller(),
            "Only escrow parties can create disputes"
        );
        
        uint256 disputeId = nextDisputeId++;
        
        disputes[disputeId] = DisputeCase({
            escrowAddress: escrowAddress,
            complainant: msg.sender,
            respondent: respondent,
            complainantEvidence: evidence,
            respondentEvidence: "",
            createdAt: block.timestamp,
            deadline: block.timestamp + evidenceDeadline,
            status: DisputeStatus.EVIDENCE_COLLECTION,
            resolution: "",
            buyerFavor: false
        });
        
        caseArbiters[disputeId] = preferredArbiter;
        arbiterCases[preferredArbiter].push(disputeId);
        userDisputes[msg.sender].push(disputeId);
        userDisputes[respondent].push(disputeId);
        
        arbiterProfiles[preferredArbiter].totalCases++;
        evidenceSubmitted[disputeId][msg.sender] = true;
        
        emit DisputeCreated(disputeId, escrowAddress, msg.sender, respondent, preferredArbiter);
        emit EvidenceSubmitted(disputeId, msg.sender, evidence);
    }
    
    function submitEvidence(uint256 disputeId, string memory evidence) external onlyDisputeParties(disputeId) {
        DisputeCase storage dispute = disputes[disputeId];
        require(dispute.status == DisputeStatus.EVIDENCE_COLLECTION, "Evidence period closed");
        require(block.timestamp <= dispute.deadline, "Evidence deadline passed");
        require(!evidenceSubmitted[disputeId][msg.sender], "Evidence already submitted");
        
        if (msg.sender == dispute.respondent) {
            dispute.respondentEvidence = evidence;
        }
        
        evidenceSubmitted[disputeId][msg.sender] = true;
        
        emit EvidenceSubmitted(disputeId, msg.sender, evidence);
        
        if (evidenceSubmitted[disputeId][dispute.complainant] && 
            evidenceSubmitted[disputeId][dispute.respondent]) {
            dispute.status = DisputeStatus.UNDER_REVIEW;
            dispute.deadline = block.timestamp + reviewDeadline;
        }
    }
    
    function resolveDispute(
        uint256 disputeId,
        bool buyerFavor,
        string memory resolution
    ) external onlyAssignedArbiter(disputeId) {
        DisputeCase storage dispute = disputes[disputeId];
        require(
            dispute.status == DisputeStatus.UNDER_REVIEW || 
            dispute.status == DisputeStatus.EVIDENCE_COLLECTION,
            "Cannot resolve at this stage"
        );
        
        dispute.status = DisputeStatus.RESOLVED;
        dispute.buyerFavor = buyerFavor;
        dispute.resolution = resolution;
        
        address arbiter = caseArbiters[disputeId];
        ArbiterProfile storage profile = arbiterProfiles[arbiter];
        profile.resolvedCases++;
        
        Escrow escrow = Escrow(dispute.escrowAddress);
        escrow.resolveDispute(buyerFavor);
        
        uint256 fee = (escrow.amount() * profile.feePercentage) / 10000;
        arbiterEarnings[arbiter] += fee;
        
        if (registry != address(0)) {
            EscrowRegistry(registry).reportDispute(dispute.escrowAddress);
        }
        
        emit DisputeResolved(disputeId, arbiter, buyerFavor, resolution);
        emit FeeCollected(arbiter, fee, disputeId);
    }
    
    function rateArbiter(address arbiter, uint256 rating) external {
        require(rating >= 1 && rating <= 5, "Rating must be between 1-5");
        require(arbiterProfiles[arbiter].isActive, "Arbiter not active");
        
        bool hasInteracted = false;
        uint256[] memory cases = arbiterCases[arbiter];
        
        for (uint256 i = 0; i < cases.length; i++) {
            DisputeCase memory dispute = disputes[cases[i]];
            if (dispute.complainant == msg.sender || dispute.respondent == msg.sender) {
                hasInteracted = true;
                break;
            }
        }
        
        require(hasInteracted, "No interaction with this arbiter");
        
        ArbiterProfile storage profile = arbiterProfiles[arbiter];
        uint256 totalRating = profile.rating * profile.ratingCount + rating;
        profile.ratingCount++;
        profile.rating = totalRating / profile.ratingCount;
        
        emit ArbiterRated(arbiter, rating, msg.sender);
    }
    
    function withdrawEarnings() external onlyActiveArbiter {
        uint256 earnings = arbiterEarnings[msg.sender];
        require(earnings > 0, "No earnings to withdraw");
        
        arbiterEarnings[msg.sender] = 0;
        payable(msg.sender).transfer(earnings);
    }
    
    function extendDeadline(uint256 disputeId, uint256 additionalTime) external onlyAssignedArbiter(disputeId) {
        DisputeCase storage dispute = disputes[disputeId];
        require(dispute.status != DisputeStatus.RESOLVED, "Dispute already resolved");
        
        dispute.deadline += additionalTime;
    }
    
    function closeDispute(uint256 disputeId) external onlyAssignedArbiter(disputeId) {
        DisputeCase storage dispute = disputes[disputeId];
        require(dispute.status == DisputeStatus.RESOLVED, "Dispute not resolved");
        
        dispute.status = DisputeStatus.CLOSED;
    }
    
    function escalateDispute(uint256 disputeId) external onlyOwner {
        DisputeCase storage dispute = disputes[disputeId];
        require(dispute.status == DisputeStatus.RESOLVED, "Dispute not resolved");
        
        dispute.status = DisputeStatus.APPEALED;
    }
    
    function setStandardFee(uint256 newFee) external onlyOwner {
        standardFee = newFee;
    }
    
    function setDeadlines(uint256 evidenceTime, uint256 reviewTime) external onlyOwner {
        evidenceDeadline = evidenceTime;
        reviewDeadline = reviewTime;
    }
    
    function emergencyWithdraw() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }
    
    function getDispute(uint256 disputeId) external view returns (DisputeCase memory) {
        return disputes[disputeId];
    }
    
    function getArbiterProfile(address arbiter) external view returns (ArbiterProfile memory) {
        return arbiterProfiles[arbiter];
    }
    
    function getArbiterCases(address arbiter) external view returns (uint256[] memory) {
        return arbiterCases[arbiter];
    }
    
    function getUserDisputes(address user) external view returns (uint256[] memory) {
        return userDisputes[user];
    }
    
    function getArbiterEarnings(address arbiter) external view returns (uint256) {
        return arbiterEarnings[arbiter];
    }
    
    function getDisputesByStatus(DisputeStatus status) external view returns (uint256[] memory) {
        uint256[] memory results = new uint256[](nextDisputeId);
        uint256 count = 0;
        
        for (uint256 i = 1; i < nextDisputeId; i++) {
            if (disputes[i].status == status) {
                results[count] = i;
                count++;
            }
        }
        
        uint256[] memory filteredResults = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            filteredResults[i] = results[i];
        }
        
        return filteredResults;
    }
    
    function getArbiterStats(address arbiter) external view returns (
        uint256 totalCases,
        uint256 resolvedCases,
        uint256 rating,
        uint256 earnings,
        uint256 successRate
    ) {
        ArbiterProfile memory profile = arbiterProfiles[arbiter];
        uint256 successRate = profile.totalCases > 0 ? 
            (profile.resolvedCases * 100) / profile.totalCases : 0;
        
        return (
            profile.totalCases,
            profile.resolvedCases,
            profile.rating,
            arbiterEarnings[arbiter],
            successRate
        );
    }
    
    function isEvidenceSubmitted(uint256 disputeId, address party) external view returns (bool) {
        return evidenceSubmitted[disputeId][party];
    }
}