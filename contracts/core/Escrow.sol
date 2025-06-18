// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Escrow {
    enum State { AWAITING_PAYMENT, AWAITING_DELIVERY, COMPLETE, CANCELLED }
    
    address payable public buyer;
    address payable public seller;
    address payable public arbiter;
    uint256 public amount;
    State public currentState;
    
    mapping(address => bool) public agreements;
    uint256 public agreementCount;
    uint256 public requiredAgreements;
    
    event PaymentDeposited(address buyer, uint256 amount);
    event DeliveryConfirmed(address buyer);
    event PaymentReleased(address seller, uint256 amount);
    event DisputeRaised(address party);
    event EscrowCancelled();
    event AgreementSigned(address party);
    
    modifier onlyBuyer() {
        require(msg.sender == buyer, "Only buyer can call this");
        _;
    }
    
    modifier onlySeller() {
        require(msg.sender == seller, "Only seller can call this");
        _;
    }
    
    modifier onlyArbiter() {
        require(msg.sender == arbiter, "Only arbiter can call this");
        _;
    }
    
    modifier inState(State _state) {
        require(currentState == _state, "Invalid state");
        _;
    }
    
    modifier onlyParties() {
        require(msg.sender == buyer || msg.sender == seller || msg.sender == arbiter, "Not authorized");
        _;
    }
    
    constructor(
        address payable _buyer,
        address payable _seller,
        address payable _arbiter,
        uint256 _amount
    ) {
        buyer = _buyer;
        seller = _seller;
        arbiter = _arbiter;
        amount = _amount;
        currentState = State.AWAITING_PAYMENT;
        requiredAgreements = 2;
    }
    
    function depositPayment() external payable onlyBuyer inState(State.AWAITING_PAYMENT) {
        require(msg.value == amount, "Payment amount mismatch");
        currentState = State.AWAITING_DELIVERY;
        emit PaymentDeposited(buyer, msg.value);
    }
    
    function signAgreement() external onlyParties {
        require(!agreements[msg.sender], "Already signed agreement");
        require(currentState == State.AWAITING_DELIVERY, "Invalid state for agreement");
        
        agreements[msg.sender] = true;
        agreementCount++;
        
        emit AgreementSigned(msg.sender);
        
        if (agreementCount >= requiredAgreements) {
            _releaseFunds();
        }
    }
    
    function confirmDelivery() external onlyBuyer inState(State.AWAITING_DELIVERY) {
        if (!agreements[buyer]) {
            agreements[buyer] = true;
            agreementCount++;
            emit AgreementSigned(buyer);
        }
        
        if (agreementCount >= requiredAgreements) {
            _releaseFunds();
        } else {
            emit DeliveryConfirmed(buyer);
        }
    }
    
    function _releaseFunds() internal {
        require(currentState == State.AWAITING_DELIVERY, "Invalid state");
        currentState = State.COMPLETE;
        seller.transfer(amount);
        emit PaymentReleased(seller, amount);
    }
    
    function raiseDispute() external onlyParties inState(State.AWAITING_DELIVERY) {
        emit DisputeRaised(msg.sender);
    }
    
    function resolveDispute(bool releaseFunds) external onlyArbiter inState(State.AWAITING_DELIVERY) {
        if (releaseFunds) {
            currentState = State.COMPLETE;
            seller.transfer(amount);
            emit PaymentReleased(seller, amount);
        } else {
            currentState = State.CANCELLED;
            buyer.transfer(amount);
            emit EscrowCancelled();
        }
    }
    
    function cancelEscrow() external onlyArbiter {
        require(currentState == State.AWAITING_PAYMENT || currentState == State.AWAITING_DELIVERY, "Cannot cancel");
        currentState = State.CANCELLED;
        
        if (address(this).balance > 0) {
            buyer.transfer(address(this).balance);
        }
        
        emit EscrowCancelled();
    }
    
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    function getAgreementStatus(address party) external view returns (bool) {
        return agreements[party];
    }
    
    function getAllAgreements() external view returns (bool buyerAgreed, bool sellerAgreed, bool arbiterAgreed) {
        return (agreements[buyer], agreements[seller], agreements[arbiter]);
    }
}