pragma solidity ^0.4.18;

import "../zeppelin-solidity/contracts/ownership/Ownable.sol";
import "../zeppelin-solidity/contracts/math/SafeMath.sol";
import "./helpers/Drainable.sol";
import "./ADXExchangeInterface.sol";
import "../zeppelin-solidity/contracts/token/ERC20.sol";

contract ADXExchange is ADXExchangeInterface, Ownable, Drainable {
	string public name = "AdEx Exchange";

	ERC20 public token;

	// TODO: ensure every func mutates bid state and emits an event

	// TODO: the function to withdraw tokens should not allow to withdraw on-exchange balance

 	mapping (address => uint) balances;

 	// escrowed on bids
 	mapping (address => uint) onBids; 

	mapping (bytes32 => Bid) bids;
	mapping (bytes32 => BidState) bidStates;

	// TODO: some properties in the bid structure - achievedPoints/peers for example - are not used atm
	
	// TODO: keep bid state separately, because of canceling
	// An advertiser would be able to cancel their own bid (id is hash) when signing a message of the hash and calling the cancelBid() fn

	enum BidState { 
		DoesNotExist, // default state

		// There is no 'Open' state - the Open state is just a signed message that you're willing to place such a bid
		Accepted, // in progress

		// the following states MUST unlock the ADX amount (return to advertiser)
		// fail states
		Canceled,
		Expired,

		// success states
		Completed
	}

	struct Bid {
		// ADX reward amount
		uint amount;

		// Links on advertiser side
		address advertiser;
		bytes32 adUnit;

		// Links on publisher side
		address publisher;
		bytes32 adSlot;

		uint acceptedTime; // when was it accepted by a publisher

		// Requirements

		//RequirementType type;
		uint target; // how many impressions/clicks/conversions have to be done
		uint timeout;

		// Confirmations from both sides; any value other than 0 is vconsidered as confirm, but this should usually be an IPFS hash to a final report
		bytes32 publisherConfirmation;
		bytes32 advertiserConfirmation;
	}

	//
	// MODIFIERS
	//
	modifier onlyBidOwner(uint _bidId) {
		require(msg.sender == bids[_bidId].advertiser);
		_;
	}

	modifier onlyBidAceptee(uint _bidId) {
		require(msg.sender == bids[_bidId].publisher);
		_;
	}

	modifier onlyBidState(uint _bidId, BidState _state) {
		require(bids[_bidId].id != 0);
		require(bidStates[_bidId] == _state);
		_;
	}

	// Functions

	function ADXExchange(address _token)
	{
		token = ERC20(_token);
	}

	//
	// Bid actions
	// 

	// the bid is accepted by the publisher
	function acceptBid(address _advertiser, bytes32 _adunit, uint _target, uint _rewardAmount, uint _timeout, bytes32 _adslot, bytes32 v, bytes32 s, bytes32 r)
	{

		// TODO: Require: we verify the advertiser sig 
		// TODO; we verify advertiser's balance and we lock it down

		bytes32 bidId = keccak256(_advertiser, _adunit, _target, _rewardAmount, _timeout, nonce, this);

		Bid storage bid = bidsById[bidId];
		require(bidStates[bidId] == 0);

		require(didSign(advertiser, hash, v, s, r));
		require(publisher == msg.sender);

		bidStates[bidId] = BidState.Accepted;

		bid.target = _target;
		bid.amount = _rewardAmount;

		bid.timeout = _timeout;

		bid.advertiser = advertiser;
		bid.adUnit = _adunit;

		bid.publisher = msg.sender;
		bid.adSlot = _adslot;

		bids[bidId] = bid;

		onBids[advertiser] += _rewardAmount;
		require(token.transferFrom(advertiserWallet, address(this), _rewardAmount));

		// TODO: more things here
		LogBidAccepted(bidId, publisher, _slotId, adSlotIpfs, bid.acceptedTime, bid.publisherPeer);

	}

	// the bid is canceled by the advertiser
	// TODO: merge this and giveupBid
	function cancelBid(uint _bidId)
		onlyBidState(_bidId, BidState.Accepted)
	{
		require(bid.publisher == msg.sender || bid.advertiser == msg.sender);

		// TODO: if the bid is not accepted, allow only the advertiser to cancel it
		// if it's accepted, allow only the publisher to cancel it
	}


	// This can be done if a bid is accepted, but expired
	// This is essentially the protection from never settling on verification, or from publisher not executing the bid within a reasonable time
	function refundBid(bytes32 _bidId)
		onlyRegisteredAcc
		onlyBidOwner(_bidId)
		onlyBidState(_bidId, BidState.Accepted)
	{
		Bid storage bid = bids[_bidId];
		require(bid.timeout > 0); // you can't refund if you haven't set a timeout
		require(SafeMath.add(bid.acceptedTime, bid.timeout) < now);

		bidStates[bidId] = BidState.Expired;

		onBids[bid.advertiser] -= bid.amount;

		LogBidExpired(_bidId);
	}


	// both publisher and advertiser have to call this for a bid to be considered verified
	function verifyBid(bytes32 _bidId, bytes32 _report)
		onlyRegisteredAcc
		onlyBidState(_bidId, BidState.Accepted)
	{
		Bid storage bid = bids[_bidId];

		require(bid.publisher == msg.sender || bid.advertiser == msg.sender);

		if (bid.publisher == msg.sender) {
			require(! bid.publisherConfrimation);
			bid.publisherConfrimation = _report;
		}

		if (bid.advertiser == msg.sender) {
			require(! bid.advertiserConfirmation);
			bid.advertiserConfirmation = _report;
		}

		if (bid.advertiserConfirmation && bid.publisherConfrimation) {
			bidStates[_bidId] = BidState.Completed;

			onBids[bid.advertiser] -= bid.amount;
			balances[bid.advertiser] -= bid.amount;
			balances[bid.publisher] += bid.amount;

			// TODO: switch balances

			LogBidCompleted(_bidId, bid.advertiserConfirmation, bid.publisherConfrimation);
		}
	}

	//
	// Internal helpers
	//
	function didSign(address addr, bytes32 hash, uint8 v, bytes32 r, bytes32 s) 
		internal pure returns (bool) 
	{
		return ecrecover(keccak256("\x19Ethereum Signed Message:\n32", hash), v, r, s) == addr;
	}

	//
	// Public constant functions
	//
	function getBid(uint _bidId) 
		constant
		external
		returns (
			uint, uint, uint, uint, uint, 
			// advertiser (advertiser, ad unit, confiration)
			bytes32, bytes32, bytes32
			// publisher (publisher, ad slot, confirmation)
			bytes32, bytes32, bytes32
		)
	{
		var bid = bids[_bidId];
		return (
			uint(bidStates[_bidId]), bid.target, bid.timeout, bid.amount, bid.acceptedTime,
			bid.advertiser, bid.adUnit, bid.advertiserConfirmation,
			bid.publisher, bid.adSlot, bid.publisherConfrimation
		);
	}

	function getBalance(address _user)
		constant
		external
		returns (uint, uint)
	{
		return (balances[_user], onBids[_user]);
	}

	//
	// Events
	//

	// TODO
	event LogBidAccepted(uint bidId, address publisher, uint adslotId, bytes32 adslotIpfs, uint acceptedTime);

	event LogBidCanceled(uint bidId);
	event LogBidExpired(uint bidId);
	event LogBidCompleted(uint bidId, bytes32 advReport, bytes32 pubReport);
}
