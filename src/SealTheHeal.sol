pragma solidity ^0.8.13;

import {CommonTypes} from "../lib/filecoin-solidity/contracts/v0.8/types/CommonTypes.sol";
import {MarketAPI} from "../lib/filecoin-solidity/contracts/v0.8/MarketAPI.sol";
import {MarketTypes} from "../lib/filecoin-solidity/contracts/v0.8/types/MarketTypes.sol";
import {SendAPI} from "../lib/filecoin-solidity/contracts/v0.8/SendAPI.sol";

interface SealHealer {
    function setBounty(bytes calldata cid, uint256 size) external payable;

    function claimBounty(uint64 dealID) external;

    function bountyByPiece(bytes memory cid) external view returns (uint256);

    function dealByPiece(bytes memory cid) external view returns (uint64);

    function pieceBySize(bytes memory cid) external view returns (uint256);

    function pieceByIndex(uint256 index) external view returns (bytes memory);

    function pieceCount() external view returns (uint256);

    function owner() external view returns (address);
}

// implement dutch auction.
// https://en.wikipedia.org/wiki/Dutch_auction

// PoC Disclaimer: reward is given all at once and every time to the original SP and any repairer.
// Do not use this until the WTF above is rectified.
contract SealTheHeal is SealHealer {

    int256 constant internal EX_DEAL_EXPIRED = 32;
    int64 constant internal EPOCH_UNSPECIFIED = - 1;

    mapping(bytes => uint64) internal maxClaimsByPiece;

    mapping(bytes => uint256) public bountyByPiece;
    mapping(bytes => uint64) public dealByPiece;
    mapping(bytes => uint256) public pieceBySize;
    bytes[] public pieceByIndex;

    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function setBounty(bytes calldata cid, uint256 size, uint64 maxClaims) public payable {
        require(msg.sender == owner, "only the contract owner can set bounty");
        require(maxClaims > 0, "maximum number of claims must be larger than zero");
        require(size > 0, "piece size must be larger than zero");

        if (bountyByPiece[cid] == 0) {
            // There is no previous bounty.
            // * Require non-zero bounty, and
            // * Set the bounty.
            // * Update the list of pieces
            require(msg.value > 0, "bounty must be more than zero");
            bountyByPiece[cid] = msg.value;
            pieceByIndex.push(cid);
        } else if (msg.value > 0) {
            // Override the bounty, because:
            // * Bounty for piece already exists, and
            // * message value is larger than zero.
            bountyByPiece[cid] = msg.value;
        }

        pieceBySize[cid] = size;
        maxClaimsByPiece[cid] = maxClaims;
    }

    function claimBounty(uint64 dealID) public {
        (int256 exitCode, MarketTypes.GetDealDataCommitmentReturn memory commitment) =
                            MarketAPI.getDealDataCommitment(dealID);

        require(exitCode == 0, "cannot get deal data commitment");

        bytes memory cid = commitment.data;
        require(bountyByPiece[cid] > 0, "deal has no bounty");
        require(pieceBySize[cid] == commitment.size, "deal piece size does not match");

        if (dealByPiece[cid] == 0) {
            // There is no pre-existing deal for piece.
            // Check if dealID is active and if so give out the bounty 
            require(isDealLive(dealID), "deal must be live before claiming bounty");
        } else {
            uint64 currentDealID = dealByPiece[cid];
            require(isDealExpiredOrTerminated(currentDealID), "bounty already claimed");
        }
        reward(dealID, bountyByPiece[cid]);
        dealByPiece[cid] = dealID;
    }

    function pieceCount() external view returns (uint256) {
        return pieceByIndex.length;
    }

    function isDealLive(uint64 dealID) internal view returns (bool) {
        (int256 exitCode, MarketTypes.GetDealActivationReturn memory activation) = MarketAPI.getDealActivation(dealID);

        // TODO update this comment
        // Check that the deal is activated. A deal is active when:
        // 1) the actor call exits with code 0, i.e. the deal is live, and
        // 2) activation epoch is not -1, i.e. there is an activation epoch.
        //
        // Note that we do not need to check whether the termination epoch is set, because termination
        // epoch is irrelevant. Meaning, a deal is not expired until it is signalled explicitly by the
        // actor exit code.
        return exitCode == 0 && CommonTypes.ChainEpoch.unwrap(activation.activated) != EPOCH_UNSPECIFIED
            && CommonTypes.ChainEpoch.unwrap(activation.terminated) == EPOCH_UNSPECIFIED;
    }

    function isDealExpiredOrTerminated(uint64 dealID) internal view returns (bool) {
        (int256 exitCode, MarketTypes.GetDealActivationReturn memory activation) = MarketAPI.getDealActivation(dealID);

        // TODO comment about the "or" case.
        return exitCode == EX_DEAL_EXPIRED || CommonTypes.ChainEpoch.unwrap(activation.terminated) > EPOCH_UNSPECIFIED;
    }

    function reward(uint64 dealID, uint256 amount) internal {
        (int256 dcExitCode, uint64 clientID) = MarketAPI.getDealClient(dealID);
        require(dcExitCode == 0, "failed to get deal client to send reward");

        int256 sExitCode = SendAPI.send(CommonTypes.FilActorId.wrap(clientID), amount);
        require(sExitCode == 0, "failed to send reward to deal client");
    }
}
