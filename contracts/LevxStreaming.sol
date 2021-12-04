// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.3;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./MerkleProof.sol";

contract LevxStreaming is Ownable, MerkleProof {
    using SafeERC20 for IERC20;

    uint256 constant STREAMING_PERIOD = 180 days;

    enum AuthType {
        ETHEREUM,
        SIGNED_ID
    }

    struct Distribution {
        AuthType authType;
        uint32 deadline;
        address wallet;
    }

    struct Streaming {
        address recipient;
        uint32 startedAt;
        uint256 amountTotal;
        uint256 amountStreamed;
    }

    address public immutable levx;
    mapping(bytes32 => Distribution) public distributionOf;
    mapping(bytes32 => Streaming) public streamingOf;

    event Add(bytes32 indexed merkleRoot, AuthType authType, uint32 deadline, address indexed wallet);
    event Start(bytes32 indexed hash, bytes32 indexed merkleRoot, address indexed recipient, uint256 amount);
    event Claim(bytes32 indexed hash, address indexed recipient, uint256 amount);

    constructor(address _levx) {
        levx = _levx;
    }

    function add(
        bytes32 merkleRoot,
        AuthType authType,
        uint32 deadline,
        address wallet
    ) external onlyOwner {
        require(block.timestamp < deadline, "LEVX: INVALID_DEADLINE");
        require(wallet != address(0), "LEVX: INVALID_WALLET");

        Distribution storage distribution = distributionOf[merkleRoot];
        require(distribution.wallet == address(0), "LEVX: DUPLICATE_ROOT");
        distribution.authType = authType;
        distribution.deadline = deadline;
        distribution.wallet = wallet;

        emit Add(merkleRoot, authType, deadline, wallet);
    }

    function start(
        bytes32 merkleRoot,
        bytes32[] calldata merkleProof,
        bytes memory data
    ) external {
        Distribution storage distribution = distributionOf[merkleRoot];
        address wallet = distribution.wallet;
        require(wallet != address(0), "LEVX: INVALID_ROOT");

        uint32 _now = uint32(block.timestamp);
        require(_now < distribution.deadline, "LEVX: EXPIRED");

        (uint256 amount, bytes32 leaf) = _parseData(distribution.authType, data);
        require(amount > 0, "LEVX: INVALID_AMOUNT");
        require(verify(merkleRoot, leaf, merkleProof), "LEVX: INVALID_PROOF");

        bytes32 hash = keccak256(abi.encodePacked(merkleRoot, leaf));
        Streaming storage streaming = streamingOf[hash];
        require(streaming.startedAt == 0, "LEVX: ALREADY_STARTED");
        streaming.startedAt = _now;
        streaming.recipient = msg.sender;
        streaming.amountTotal = amount;

        IERC20(levx).safeTransferFrom(wallet, address(this), amount);

        emit Start(hash, merkleRoot, msg.sender, amount);
    }

    function _parseData(AuthType authType, bytes memory data) internal view returns (uint256 amount, bytes32 leaf) {
        if (authType == AuthType.ETHEREUM) {
            amount = abi.decode(data, (uint256));
            leaf = keccak256(abi.encodePacked(msg.sender, amount));
        } else {
            (string memory id, uint256 _amount, uint8 v, bytes32 r, bytes32 s) = abi.decode(
                data,
                (string, uint256, uint8, bytes32, bytes32)
            );
            require(bytes(id).length > 0, "LEVX: INVALID_ID");

            amount = _amount;
            leaf = keccak256(abi.encodePacked(id, amount));
            require(ECDSA.recover(ECDSA.toEthSignedMessageHash(leaf), v, r, s) == owner(), "LEVX: UNAUTHORIZED");
        }
    }

    function claim(bytes32 hash) external {
        Streaming storage streaming = streamingOf[hash];
        require(streaming.recipient == msg.sender, "LEVX: FORBIDDEN");

        uint256 amount = _amountStreamed(streaming);
        uint256 pending = amount - streaming.amountStreamed;
        streaming.amountStreamed = amount;

        IERC20(levx).safeTransfer(msg.sender, pending);

        emit Claim(hash, msg.sender, pending);
    }

    function pendingAmount(bytes32 hash) external view returns (uint256) {
        Streaming storage streaming = streamingOf[hash];
        return _amountStreamed(streaming) - streaming.amountStreamed;
    }

    function _amountStreamed(Streaming storage streaming) internal view returns (uint256) {
        uint256 duration = block.timestamp - streaming.startedAt;
        if (duration > STREAMING_PERIOD) duration = STREAMING_PERIOD;
        return (streaming.amountTotal * duration) / STREAMING_PERIOD;
    }
}
