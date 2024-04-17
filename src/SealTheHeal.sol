pragma solidity ^0.8.13;

import {MarketAPI} from "../lib/filecoin-solidity/contracts/v0.8/MarketAPI.sol";
import {CommonTypes} from "../lib/filecoin-solidity/contracts/v0.8/types/CommonTypes.sol";
import {MarketTypes} from "../lib/filecoin-solidity/contracts/v0.8/types/MarketTypes.sol";
import {Actor} from "../lib/filecoin-solidity/contracts/v0.8/utils/Actor.sol";
import {Misc} from "../lib/filecoin-solidity/contracts/v0.8/utils/Misc.sol";

/*
abi encode calls using cast calldata "<stub>" [param,param...]

example 
cast calldata "addCID(bytes,uint256)" 000181e203922020c8a491097fa5272f2d7586685f3ea081e129bb820d6322248d67832c4f601d3c 128
out
0xd4a0cd0a000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000028000181e203922020c8a491097fa5272f2d7586685f3ea081e129bb820d6322248d67832c4f601d3c000000000000000000000000000000000000000000000000
*/

/* 
Contract Usage
    Step   |   Who   |    What is happening  |   Why 
    ------------------------------------------------
    Deploy | contract owner   | contract owner deploys address is owner who can call addCID  | create contract setting up rules to follow
    AddCID | data pinners     | set up cids that the contract will incentivize in deals      | add request for a deal in the filecoin network, "store data" function
    Fund   | contract funders |  add FIL to the contract to later by paid out by deal        | ensure the deal actually gets stored by providing funds for bounty hunter and (indirect) storage provider
    Claim  | bounty hunter    | claim the incentive to complete the cycle                    | pay back the bounty hunter for doing work for the contract

*/

// USERS BE AWARE: reward is given all at once and every time to the original SP and any repairer. 
// Do not use this until the WTF above is rectified.
contract SealTheHeal {

    mapping(bytes => uint) public cidToPriceSet;
    mapping(bytes => uint64) public cidToDealSet;
    mapping(bytes => uint) public cidSizes;

    address public owner;
    address constant CALL_ACTOR_ID = 0xfe00000000000000000000000000000000000005;
    uint64 constant DEFAULT_FLAG = 0x00000000;
    uint64 constant METHOD_SEND = 0;
    int256 constant EX_DEAL_EXPIRED = 32;
    int64 constant UNSPECIFIED = - 1;

    constructor() {
        owner = msg.sender;
    }

    function fund(uint64 unused) public payable {}

    function addPieceCID(bytes calldata cidraw, uint size, uint reward) public {
        require(msg.sender == owner);
        require(reward > 0);

        cidToPriceSet[cidraw] = reward;
        cidSizes[cidraw] = size;
    }

    function hasDeal(bytes memory cidraw) internal view returns (bool) {
        return cidToDealSet[cidraw] != 0;
    }

    function authorizeDeal(bytes memory cidraw, uint size, uint64 deal_id) internal {
        require(cidToPriceSet[cidraw] > 0, "cid must be added before authorizing");
        require(cidSizes[cidraw] == size, "data size must match expected");
        require(!hasDeal(cidraw), "deal failed policy check: cid has already been stored");
        require(isDealLive(deal_id), "deal is not activated");

        cidToDealSet[cidraw] = deal_id;
    }

    function authorizeRepair(bytes memory cidraw, uint64 repair_deal_id) internal {
        // Price has to be there because it is checked at the time of making deal by authorizeData.
        require(hasDeal(cidraw), "deal failed policy check: cid has already been stored");

        // TODO update comments below.
        // Retrieve the state of previous deal for cidraw.
        // Note that we only need to check the exit code from the actor call, because the termination epoch that may be
        // returned  by GetDealActivationReturn is ephemeral. A deal is only deemed expired once the actor call explicitly
        // exits with EX_DEAL_EXPIRED.
        uint64 prev_deal_id = cidToDealSet[cidraw];
        (int256 exit_code, MarketTypes.GetDealActivationReturn memory activation) = MarketAPI.getDealActivation(prev_deal_id);

        // TODO comment about the or case.
        require(exit_code == EX_DEAL_EXPIRED || CommonTypes.ChainEpoch.unwrap(activation.terminated) > UNSPECIFIED, "previous deal has not expired yet");
        cidToDealSet[cidraw] = repair_deal_id;
    }

    function claim_bounty(uint64 deal_id) public {
        (int256 exit_code, MarketTypes.GetDealDataCommitmentReturn memory commitmentRet) = MarketAPI.getDealDataCommitment(deal_id);
        require(exit_code == 0, "cannot get deal data commitment");

        authorizeDeal(commitmentRet.data, commitmentRet.size, deal_id);

        // get dealer (bounty hunter client)
        (int256 dc_exit_code, uint64 client_id) = MarketAPI.getDealClient(deal_id);
        require(dc_exit_code == 0, "cannot get client ID");

        // send reward to client 
        send(client_id, cidToPriceSet[commitmentRet.data]);
    }

    function claim_repair(uint64 repair_deal_id) public {

        // TODO make the UX smoother for the case where a CID has no deal but claim repair is called.

        (int256 exit_code, MarketTypes.GetDealDataCommitmentReturn memory commitmentRet) = MarketAPI.getDealDataCommitment(repair_deal_id);
        require(exit_code == 0, "cannot get deal data commitment");

        authorizeRepair(commitmentRet.data, repair_deal_id);

        // get dealer (bounty hunter client)
        (int256 dc_exit_code, uint64 client_id) = MarketAPI.getDealClient(repair_deal_id);
        require(dc_exit_code == 0, "cannot get client ID");

        // TODO give proportional reward and parameterise repair reward proportion.
        // TODO add public calls to check if a cid needs more funds for repair to be facilitated.
        // send reward to client 
        send(client_id, cidToPriceSet[commitmentRet.data]);
    }

    function isDealLive(uint64 deal_id) internal view returns (bool) {
        (int256 exit_code, MarketTypes.GetDealActivationReturn memory activation) = MarketAPI.getDealActivation(deal_id);

        // TODO update this comment
        // Check that the deal is activated. A deal is active when:
        // 1) the actor call exits with code 0, i.e. the deal is live, and
        // 2) activation epoch is not -1, i.e. there is an activation epoch.
        //
        // Note that we do not need to check whether the termination epoch is set, because termination 
        // epoch is irrelevant. Meaning, a deal is not expired until it is signalled explicitly by the 
        // actor exit code.
        return exit_code == 0 && CommonTypes.ChainEpoch.unwrap(activation.activated) != UNSPECIFIED && CommonTypes.ChainEpoch.unwrap(activation.terminated) == UNSPECIFIED;
    }

    // send reward to client, i.e. dealer.
    function send(uint64 actorID, uint reward) internal {
        bytes memory emptyParams = "";
        delete emptyParams;
        // TODO review if static_call value should be false.
        Actor.callByID(CommonTypes.FilActorId.wrap(actorID), METHOD_SEND, Misc.NONE_CODEC, emptyParams, reward, false);
    }
}
