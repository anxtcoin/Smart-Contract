// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract ANXT {
    address public owner;
    address public burnAddress; // The address where tokens are burned
    string public name = "ANXT";
    string public symbol = "ANXT";
    uint8 public decimals = 4;
    uint256 public totalSupply = 651000000 * (10**uint256(decimals)); // Total supply with 4 decimals
    uint256 public transactionFee = 100; // 0.01 ANXT with 4 decimals
    uint256 public minStakeAmount = 10000 * (10**decimals); // Minimum stake amount required to waive fees
    uint256 public dailyTransactionLimit = 20; // The number of transactions allowed without fees per day
    uint256 public maxHoldAndSellPercentage = 3 * 10**2; // 3% of the total supply with 2 decimals

    uint256 public constant SECONDS_IN_DAY = 86400;
    uint256 public constant SECONDS_IN_MONTH = 2592000; // Assuming 30 days in a month for simplicity
    uint256 public constant SECONDS_IN_YEAR = 31536000; // Assuming 365 days in a year for simplicity

    address public migrationContractAddress; // Address of the migration contract on another blockchain

    struct StakingOption {
        uint256 duration; // Duration in seconds
        uint256 apy; // Annual Percentage Yield in percentage (with 2 decimals)
    }

    StakingOption[] public stakingOptions;

    struct StakingDetail {
        uint256 amount;
        uint256 stakingTime;
        uint256 releaseTime;
    }

    mapping(address => StakingDetail) public stakingDetails;
    mapping(address => uint256) public stakedAmount;
    mapping(address => uint256) public lastTransactionTime;
    mapping(address => uint256) public dailyTransactionCount;
    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public isExempted;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Stake(address indexed holder, uint256 amount);
    event Unstake(address indexed holder, uint256 amount);
    event Blacklisted(address indexed target);
    event RemovedFromBlacklist(address indexed target);
    event Exempted(address indexed target);
    event RevokedExemption(address indexed target);
    event StakingRewardClaimed(address indexed holder, uint256 amount);
    event Mint(address indexed to, uint256 amount);
    event Migrated(address indexed account, uint256 amount); // Event to track the migration of tokens

    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can perform this action");
        _;
    }

    constructor() {
        owner = msg.sender;
        burnAddress = address(0xdead); // Set the burn address to an invalid address initially

        // Adding staking options with their durations and APYs
        stakingOptions.push(StakingOption(3 * SECONDS_IN_MONTH, 400)); // 3 months - 4% APY
        stakingOptions.push(StakingOption(6 * SECONDS_IN_MONTH, 500)); // 6 months - 5% APY
        stakingOptions.push(StakingOption(12 * SECONDS_IN_MONTH, 800)); // 12 months - 8% APY
        stakingOptions.push(StakingOption(2 * SECONDS_IN_YEAR, 900)); // 2 years - 9% APY
        stakingOptions.push(StakingOption(5 * SECONDS_IN_YEAR, 1200)); // 5 years - 12% APY
        stakingOptions.push(StakingOption(10 * SECONDS_IN_YEAR, 1500)); // 10 years - 15% APY
        stakingOptions.push(StakingOption(15 * SECONDS_IN_YEAR, 2100)); // 15 years - 21% APY

        balanceOf[msg.sender] = totalSupply;
    }

    // Mint new tokens (only the owner can call this function)
    function mint(address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Invalid address");
        require(_amount > 0, "Mint amount must be greater than zero");
        require(totalSupply + _amount <= 2**256 - 1, "Total supply exceeds maximum limit");

        totalSupply += _amount;
        balanceOf[_to] += _amount;

        emit Mint(_to, _amount);
        emit Transfer(address(0), _to, _amount);
    }

    // Function to set the address of the migration contract
    function setMigrationContract(address _migrationContractAddress) external onlyOwner {
        require(_migrationContractAddress != address(0), "Invalid migration contract address");
        migrationContractAddress = _migrationContractAddress;
    }

    // Function for users to initiate token migration to the target chain
    function migrateToTargetChain(uint256 _amount) external {
        require(migrationContractAddress != address(0), "Migration contract address not set");
        require(_amount > 0, "Migration amount must be greater than zero");
        require(balanceOf[msg.sender] >= _amount, "Insufficient balance for migration");

        balanceOf[msg.sender] -= _amount;
        totalSupply -= _amount;

        // Call the migration contract on the target blockchain to receive the tokens
        IMigrationContract(migrationContractAddress).receiveTokens(msg.sender, _amount);

        emit Migrated(msg.sender, _amount);
        emit Transfer(msg.sender, address(0), _amount); // Burn the tokens on this chain
    }

    function transfer(address _to, uint256 _value) external validateAddress(_to) returns (bool) {
        require(_to != address(0), "Invalid address");
        require(_value > 0, "Value must be greater than zero");
        require(balanceOf[msg.sender] >= _value, "Insufficient balance");

        // Check if the recipient is the burn address
        require(_to != burnAddress, "Cannot transfer tokens to the burn address");

        uint256 transferAmount = _value;
        uint256 fees = 0;

        if (stakedAmount[msg.sender] >= minStakeAmount) {
            // Holders staking above 10,000 ANXT are exempted from fees for 20 transactions per day
            if (dailyTransactionCount[msg.sender] >= dailyTransactionLimit) {
                revert("Transaction limit exceeded");
            }
        } else {
            // Holders staking below 10,000 ANXT are subject to fees and transaction count restrictions
            uint256 totalHoldAndSell = (balanceOf[msg.sender] - _value) * 10000 / totalSupply;
            if (!isExempted[msg.sender] && totalHoldAndSell + _value * 10000 / totalSupply > maxHoldAndSellPercentage) {
                require(balanceOf[msg.sender] >= _value + transactionFee, "Insufficient balance with fees");
                fees = transactionFee;
                balanceOf[msg.sender] -= _value + fees;
                balanceOf[address(this)] += fees; // Transfer the fees to a designated address (e.g., contract owner)
                emit Transfer(msg.sender, address(this), fees);
            } else {
                balanceOf[msg.sender] -= _value;
            }
        }

        balanceOf[_to] += transferAmount;
        emit Transfer(msg.sender, _to, transferAmount);

        if (lastTransactionTime[msg.sender] < block.timestamp - 1 days) {
            // Reset daily transaction count if it has been more than 24 hours
            dailyTransactionCount[msg.sender] = 0;
        }

        dailyTransactionCount[msg.sender]++;
        lastTransactionTime[msg.sender] = block.timestamp;

        return true;
    }

    function approve(address _spender, uint256 _value) external validateAddress(_spender) returns (bool) {
        require(_value > 0, "Value must be greater than zero");
        allowance[msg.sender][_spender] = _value;

        emit Approval(msg.sender, _spender, _value);
        return true;
    }

    function transferFrom(address _from, address _to, uint256 _value) external validateAddress(_from) validateAddress(_to) returns (bool) {
        require(_value > 0, "Value must be greater than zero");
        require(balanceOf[_from] >= _value, "Insufficient balance");
        require(allowance[_from][msg.sender] >= _value, "Allowance exceeded");

        // Check if the recipient is the burn address
        require(_to != burnAddress, "Cannot transfer tokens to the burn address");

        uint256 transferAmount = _value;
        uint256 fees = 0;

        if (stakedAmount[_from] >= minStakeAmount) {
            // Holders staking above 10,000 ANXT are exempted from fees for 20 transactions per day
            if (dailyTransactionCount[_from] >= dailyTransactionLimit) {
                revert("Transaction limit exceeded");
            }
        } else {
            // Holders staking below 10,000 ANXT are subject to fees and transaction count restrictions
            uint256 totalHoldAndSell = (balanceOf[_from] - _value) * 10000 / totalSupply;
            if (!isExempted[_from] && totalHoldAndSell + _value * 10000 / totalSupply > maxHoldAndSellPercentage) {
                require(balanceOf[_from] >= _value + transactionFee, "Insufficient balance with fees");
                fees = transactionFee;
                balanceOf[_from] -= _value + fees;
                balanceOf[address(this)] += fees; // Transfer the fees to a designated address (e.g., contract owner)
                emit Transfer(_from, address(this), fees);
            } else {
                balanceOf[_from] -= _value;
            }
        }

        balanceOf[_to] += transferAmount;
        allowance[_from][msg.sender] -= _value;

        emit Transfer(_from, _to, transferAmount);

        if (lastTransactionTime[_from] < block.timestamp - 1 days) {
            // Reset daily transaction count if it has been more than 24 hours
            dailyTransactionCount[_from] = 0;
        }

        dailyTransactionCount[_from]++;
        lastTransactionTime[_from] = block.timestamp;

        return true;
    }

    function stake(uint256 _amount, uint256 _optionIndex) external validateAddress(msg.sender) {
        require(_amount > 0, "Stake amount must be greater than zero");
        require(balanceOf[msg.sender] >= _amount, "Insufficient balance for staking");
        require(_optionIndex < stakingOptions.length, "Invalid staking option index");

        StakingOption memory option = stakingOptions[_optionIndex];
        uint256 stakeEndTime = block.timestamp + option.duration;

        balanceOf[msg.sender] -= _amount;
        stakedAmount[msg.sender] += _amount;

        stakingDetails[msg.sender] = StakingDetail(_amount, block.timestamp, stakeEndTime);

        emit Stake(msg.sender, _amount);
    }

    function unstake() external validateAddress(msg.sender) {
        require(stakedAmount[msg.sender] > 0, "No staked amount to unstake");
        require(block.timestamp >= stakingDetails[msg.sender].releaseTime + 7 * SECONDS_IN_DAY, "Unstaking not allowed before 7 days");
        require(balanceOf[msg.sender] >= stakedAmount[msg.sender], "Insufficient balance for unstaking");

        uint256 stakedAmountToUnstake = stakedAmount[msg.sender];
        uint256 reward = calculateStakingReward(msg.sender);

        stakedAmount[msg.sender] = 0;
        balanceOf[msg.sender] += stakedAmountToUnstake + reward;

        emit Unstake(msg.sender, stakedAmountToUnstake);
    }

    function calculateStakingReward(address _holder) public view returns (uint256) {
    StakingDetail storage detail = stakingDetails[_holder];
    require(detail.amount > 0, "No staking detail found");

    uint256 stakingDuration = block.timestamp - detail.stakingTime;
    uint256 apy = stakingOptions[findStakingOptionIndex(detail.releaseTime - detail.stakingTime)].apy;
    uint256 reward = (detail.amount * apy * stakingDuration) / (365 days * 10000);
    return reward;
}


    function findStakingOptionIndex(uint256 _duration) internal view returns (uint256) {
        for (uint256 i = 0; i < stakingOptions.length; i++) {
            if (stakingOptions[i].duration == _duration) {
                return i;
            }
        }
        revert("Staking option not found");
    }

    function addToBlacklist(address _target) external onlyOwner validateAddress(_target) {
        require(!isBlacklisted[_target], "Address is already blacklisted");
        isBlacklisted[_target] = true;
        emit Blacklisted(_target);
    }

    function removeFromBlacklist(address _target) external onlyOwner validateAddress(_target) {
        require(isBlacklisted[_target], "Address is not blacklisted");
        isBlacklisted[_target] = false;
        emit RemovedFromBlacklist(_target);
    }

    function approveExemption(address _target) external onlyOwner validateAddress(_target) {
        isExempted[_target] = true;
        emit Exempted(_target);
    }

    function revokeExemption(address _target) external onlyOwner validateAddress(_target) {
        isExempted[_target] = false;
        emit RevokedExemption(_target);
    }

    modifier validateAddress(address _addr) {
        require(_addr != address(0), "Invalid address");
        _;
    }
}

// Interface for the migration contract on the target blockchain
interface IMigrationContract {
    function receiveTokens(address _sender, uint256 _amount) external;
}
