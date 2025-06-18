const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Escrow", function () {
  let escrow, escrowFactory;
  let buyer, seller, arbiter, other;
  let amount;

  beforeEach(async function () {
    [buyer, seller, arbiter, other] = await ethers.getSigners();
    amount = ethers.utils.parseEther("1.0");

    const EscrowFactory = await ethers.getContractFactory("EscrowFactory");
    escrowFactory = await EscrowFactory.deploy();
    await escrowFactory.deployed();

    const createTx = await escrowFactory.connect(buyer).createEscrow(
      seller.address,
      arbiter.address,
      amount
    );
    const receipt = await createTx.wait();
    const escrowCreatedEvent = receipt.events?.find(e => e.event === 'EscrowCreated');
    const escrowAddress = escrowCreatedEvent?.args?.escrowAddress;

    const Escrow = await ethers.getContractFactory("Escrow");
    escrow = Escrow.attach(escrowAddress);
  });

  describe("Deployment", function () {
    it("Should set the correct buyer, seller, and arbiter", async function () {
      expect(await escrow.buyer()).to.equal(buyer.address);
      expect(await escrow.seller()).to.equal(seller.address);
      expect(await escrow.arbiter()).to.equal(arbiter.address);
    });

    it("Should set the correct amount and initial state", async function () {
      expect(await escrow.amount()).to.equal(amount);
      expect(await escrow.currentState()).to.equal(0);
    });
  });

  describe("Payment Deposit", function () {
    it("Should allow buyer to deposit correct amount", async function () {
      await expect(escrow.connect(buyer).depositPayment({ value: amount }))
        .to.emit(escrow, "PaymentDeposited")
        .withArgs(buyer.address, amount);
      
      expect(await escrow.currentState()).to.equal(1);
      expect(await escrow.getContractBalance()).to.equal(amount);
    });

    it("Should reject payment from non-buyer", async function () {
      await expect(
        escrow.connect(seller).depositPayment({ value: amount })
      ).to.be.revertedWith("Only buyer can call this");
    });

    it("Should reject incorrect payment amount", async function () {
      const wrongAmount = ethers.utils.parseEther("0.5");
      await expect(
        escrow.connect(buyer).depositPayment({ value: wrongAmount })
      ).to.be.revertedWith("Payment amount mismatch");
    });
  });

  describe("Agreements", function () {
    beforeEach(async function () {
      await escrow.connect(buyer).depositPayment({ value: amount });
    });

    it("Should allow parties to sign agreements", async function () {
      await expect(escrow.connect(buyer).signAgreement())
        .to.emit(escrow, "AgreementSigned")
        .withArgs(buyer.address);
      
      expect(await escrow.getAgreementStatus(buyer.address)).to.be.true;
      expect(await escrow.agreementCount()).to.equal(1);
    });

    it("Should not allow double signing", async function () {
      await escrow.connect(buyer).signAgreement();
      await expect(
        escrow.connect(buyer).signAgreement()
      ).to.be.revertedWith("Already signed agreement");
    });

    it("Should release funds when required agreements are met", async function () {
      const sellerInitialBalance = await seller.getBalance();
      
      await escrow.connect(buyer).signAgreement();
      await expect(escrow.connect(seller).signAgreement())
        .to.emit(escrow, "PaymentReleased")
        .withArgs(seller.address, amount);
      
      expect(await escrow.currentState()).to.equal(2);
      expect(await escrow.getContractBalance()).to.equal(0);
      
      const sellerFinalBalance = await seller.getBalance();
      expect(sellerFinalBalance.sub(sellerInitialBalance)).to.be.closeTo(amount, ethers.utils.parseEther("0.01"));
    });
  });

  describe("Delivery Confirmation", function () {
    beforeEach(async function () {
      await escrow.connect(buyer).depositPayment({ value: amount });
    });

    it("Should allow buyer to confirm delivery", async function () {
      await expect(escrow.connect(buyer).confirmDelivery())
        .to.emit(escrow, "AgreementSigned")
        .withArgs(buyer.address);
    });

    it("Should release funds when delivery is confirmed and seller agrees", async function () {
      await escrow.connect(buyer).confirmDelivery();
      await expect(escrow.connect(seller).signAgreement())
        .to.emit(escrow, "PaymentReleased")
        .withArgs(seller.address, amount);
      
      expect(await escrow.currentState()).to.equal(2);
    });
  });

  describe("Dispute Resolution", function () {
    beforeEach(async function () {
      await escrow.connect(buyer).depositPayment({ value: amount });
    });

    it("Should allow parties to raise disputes", async function () {
      await expect(escrow.connect(buyer).raiseDispute())
        .to.emit(escrow, "DisputeRaised")
        .withArgs(buyer.address);
    });

    it("Should allow arbiter to resolve dispute in favor of seller", async function () {
      await escrow.connect(buyer).raiseDispute();
      await expect(escrow.connect(arbiter).resolveDispute(true))
        .to.emit(escrow, "PaymentReleased")
        .withArgs(seller.address, amount);
      
      expect(await escrow.currentState()).to.equal(2);
    });

    it("Should allow arbiter to resolve dispute in favor of buyer", async function () {
      const buyerInitialBalance = await buyer.getBalance();
      
      await escrow.connect(seller).raiseDispute();
      await expect(escrow.connect(arbiter).resolveDispute(false))
        .to.emit(escrow, "EscrowCancelled");
      
      expect(await escrow.currentState()).to.equal(3);
    });
  });

  describe("Cancellation", function () {
    it("Should allow arbiter to cancel escrow before payment", async function () {
      await expect(escrow.connect(arbiter).cancelEscrow())
        .to.emit(escrow, "EscrowCancelled");
      
      expect(await escrow.currentState()).to.equal(3);
    });

    it("Should allow arbiter to cancel escrow after payment and refund buyer", async function () {
      await escrow.connect(buyer).depositPayment({ value: amount });
      
      await expect(escrow.connect(arbiter).cancelEscrow())
        .to.emit(escrow, "EscrowCancelled");
      
      expect(await escrow.currentState()).to.equal(3);
      expect(await escrow.getContractBalance()).to.equal(0);
    });
  });

  describe("Access Control", function () {
    it("Should reject unauthorized access", async function () {
      await expect(
        escrow.connect(other).depositPayment({ value: amount })
      ).to.be.revertedWith("Only buyer can call this");
      
      await escrow.connect(buyer).depositPayment({ value: amount });
      
      await expect(
        escrow.connect(other).signAgreement()
      ).to.be.revertedWith("Not authorized");
    });
  });

  describe("EscrowFactory", function () {
    it("Should create escrows and track them", async function () {
      const escrowCount = await escrowFactory.getEscrowCount();
      expect(escrowCount).to.be.greaterThan(0);
      
      const buyerEscrows = await escrowFactory.getUserEscrows(buyer.address);
      expect(buyerEscrows.length).to.be.greaterThan(0);
      
      const allEscrows = await escrowFactory.getAllEscrows();
      expect(allEscrows.length).to.equal(escrowCount);
    });
  });
});