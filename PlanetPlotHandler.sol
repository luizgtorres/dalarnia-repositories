// krippilippa
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "interfaces/IPlanetPlot.sol";
import "interfaces/IResources.sol";
import "interfaces/IResourceTracker.sol";

contract PlanetPlotHandler is AccessControl, Pausable{

    bytes32 public constant RESOURCES_HANDLER = keccak256("RESOURCES_HANDLER");
    bytes32 public constant GAME_PAUSER = keccak256("GAME_PAUSER");
    bytes32 public constant GAME_CONTROL = keccak256("GAME_CONTROL");
    bytes32 public constant PLANET_PLOT_CREATOR = keccak256("PLANET_PLOT_CREATOR");

    IERC20 public DAR;
    IPlanetPlot public planetPlot;
    IResources public resources; 
    IResourceTracker public resourceTracker;
    address private MoDTaxAccount;
    address private serverPubKey;
    
    uint private taxRate;
    uint public plotOwnerRentRate;
    uint public playerMinRent;
    uint public fixedRent;
    uint public replenishCooldown = 6 hours;

    uint public maxDigsInOneTx = 5;
    uint public maxOpenDigs = 10;

    uint public miningSafetyCap = 1000;

    mapping(address => uint) public addressIsRenting;
    mapping(address => uint) public internalNonce;
    mapping(uint => uint) public plotCooldown;

    event Rent(address indexed renter, address indexed plotOwner, uint plotId, uint nrOfDigs);
    event CloseRentAndMint (address renter, uint digsClosed);

    constructor (IResources _resources, IERC20 _DAR, IPlanetPlot _planetPlot, address _MoDTaxAccount, uint8 _taxRate, IResourceTracker _resourceTracker) {
        resources = _resources;
        DAR = _DAR;
        planetPlot = _planetPlot;
        MoDTaxAccount = _MoDTaxAccount;
        taxRate = _taxRate;
        resourceTracker = _resourceTracker;
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    modifier isResourcesHandler(){
        require(hasRole(RESOURCES_HANDLER, msg.sender),"Tx not from resourcesHandler");
        _;
    }

    modifier isGameController(){
        require(hasRole(GAME_CONTROL, msg.sender),"GAME_CONTROL required");
        _;
    }

    modifier isPlanetPlotCreator(){
        require(hasRole(PLANET_PLOT_CREATOR, msg.sender),"PLANET_PLOT_CREATOR ROLE required");
        _;
    }

    modifier isGamePauser(){
        require(hasRole(GAME_PAUSER, msg.sender),"GAME_PAUSER required");
        _;
    }

    function createPlanet(uint _sideLength, uint _planetId) public isPlanetPlotCreator(){
        IPlanetPlot(planetPlot).createPlanet(_sideLength, _planetId);
    }

    function mintPlotRegion( address _to, uint _planetId, uint _region) public isPlanetPlotCreator(){
        IPlanetPlot(planetPlot).mintPlotRegion(_to, _planetId, _region);
    }

    function openRentPlot(
        uint _tokenId, 
        uint8 _digsToOpen, 
        uint _currentRent,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) public whenNotPaused(){
        bytes memory message = abi.encode(msg.sender, _tokenId, _digsToOpen, internalNonce[msg.sender]);
        bytes memory prefix = "\x19Ethereum Signed Message:\n128";
        bytes32 m = keccak256(abi.encodePacked(prefix, message));
        require(ecrecover(m, _v, _r, _s) == serverPubKey, "Signature invalid");

        require(_digsToOpen <= maxDigsInOneTx && _digsToOpen > 0, "An address can not open this many digs in on tx");
        require((addressIsRenting[msg.sender]+_digsToOpen) <= maxOpenDigs, "Address can not open this amount of digs until closing previous digs");
        (address owner, uint left, uint rent, bool open) = IPlanetPlot(planetPlot).rentInfo(_tokenId);
        require(left >= _digsToOpen, "This amount of digs not available on plot");

        internalNonce[msg.sender]++;

        if(msg.sender != owner){
            require(open, "Plot owner is not allowing rents at this time");

            uint rentToPay;

            if (fixedRent != 0){
                require(fixedRent == _currentRent, "WARNING: Rent mis-match");
                rentToPay = fixedRent * _digsToOpen;
            }else{
                require(rent == _currentRent, "WARNING: Rent mis-match");
                rentToPay = rent * _digsToOpen;
            }

            uint tax = (rentToPay * taxRate)/100;

            IERC20(DAR).transferFrom(msg.sender, MoDTaxAccount, tax);
            IERC20(DAR).transferFrom(msg.sender, owner, rentToPay - tax);
        } else {
            if(plotOwnerRentRate > 0){
                require(plotOwnerRentRate == _currentRent, "WARNING: Rent mis-match");
                IERC20(DAR).transferFrom(msg.sender, MoDTaxAccount, plotOwnerRentRate * _digsToOpen);
            }
        }

        require(IPlanetPlot(planetPlot).openRentPlot(msg.sender, _tokenId, _digsToOpen), "Could not rent");
        addressIsRenting[msg.sender] = addressIsRenting[msg.sender] + _digsToOpen;
        emit Rent(msg.sender, owner, _tokenId, _digsToOpen);
    }

    function closeRentAndMint(
        address _renter,
        uint[] memory _resources, 
        uint[] memory _amounts,
        uint _digsToClose,
        bytes memory _prefix,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) public whenNotPaused(){
        for (uint256 i = 0; i < _amounts.length; i++) {
            require(_amounts[i] <= miningSafetyCap, "Warning: mined resource amount overflow");
        }
        bytes memory message = abi.encode(_renter, _resources, _amounts, _digsToClose, internalNonce[_renter]);
        bytes32 m = keccak256(abi.encodePacked(_prefix, message));
        require(ecrecover(m, _v, _r, _s) == serverPubKey, "Signature invalid");

        internalNonce[_renter]++;
        closeRentPlot(_renter, _digsToClose);
        IResourceTracker(resourceTracker).addToBalanceBatch(_renter, _resources, _amounts);
        IResources(resources).mintBatch(_renter, _resources, _amounts);
        
        emit CloseRentAndMint(_renter, _digsToClose);
    }

    function closeRentPlot(address _renter, uint _nrToClose) internal whenNotPaused(){
        require(_nrToClose > 0, "Can not close 0 digs");
        require(addressIsRenting[_renter] >= _nrToClose, "Address does not have this many rents open");
        addressIsRenting[_renter] = addressIsRenting[_renter] - _nrToClose;
    }

    function setPlotRent(uint _tokenId, uint _rent) public whenNotPaused(){
        require(_rent >= playerMinRent);
        IPlanetPlot(planetPlot).setPlotRent(msg.sender, _tokenId, _rent);
    }

    function setPlotOpen(uint _tokenId, bool _open) public whenNotPaused(){
        IPlanetPlot(planetPlot).setPlotOpen(msg.sender, _tokenId, _open);
    }

    function replenishPlot(uint _tokenId, uint _digs) external isResourcesHandler() whenNotPaused() returns (bool) {
        require(plotCooldown[_tokenId] + replenishCooldown < block.timestamp, "Plot in cooldown");
        IPlanetPlot(planetPlot).replenishPlot(_tokenId, _digs);
        plotCooldown[_tokenId] = block.timestamp;
        return true;
    }

    function upgradePlotMax(uint _tokenId, uint _newMax) external isResourcesHandler() whenNotPaused() returns (bool) {
        IPlanetPlot(planetPlot).upgradePlotMax(_tokenId, _newMax);
        return true;
    }

    function setPlayerPlanetPass(address _renter, uint[] memory _planetIds) external isResourcesHandler() whenNotPaused(){
        IPlanetPlot(planetPlot).setPlayerPlanetPass(_renter, _planetIds);
    }

    function setFreePlanetPass(uint _planetId, bool _isFreePass) public isGameController(){
        IPlanetPlot(planetPlot).setFreePlanetPass(_planetId, _isFreePass);
    }

    function updateTaxAccount(address _MoDTaxAccount) public isGameController(){
        MoDTaxAccount = _MoDTaxAccount;
    }

    function updateTaxRate(uint8 _taxRate) public isGameController(){
        require(_taxRate < 100);
        taxRate = _taxRate;
    }

    function updatePlotOwnerRentRate(uint _plotOwnerRentRate) public isGameController(){
        plotOwnerRentRate = _plotOwnerRentRate;
    }

    function updateCoolDown(uint _replenishCoolDown) public isGameController(){
        replenishCooldown = _replenishCoolDown;
    }

    function updatePlayerMinRent(uint _playerMinRent) public isGameController(){
        playerMinRent = _playerMinRent;
    }

    function updateMiningSafetyCap(uint _miningSafetyCap) public isGameController(){
        miningSafetyCap = _miningSafetyCap;
    }

    function updateFixedRent(uint _fixedRent) public isGameController(){
        fixedRent = _fixedRent;
    }

    function updateDigLimits(uint8 _maxOpenDigs, uint8 _maxDigsInOneTx) public isGameController(){
        require(_maxOpenDigs > 0 && _maxDigsInOneTx > 0 && _maxDigsInOneTx <= _maxOpenDigs);
        maxOpenDigs = _maxOpenDigs;
        maxDigsInOneTx = _maxDigsInOneTx;
    }

    function updateServer (address _serverPubKey) public isGameController(){
        serverPubKey = _serverPubKey;
    }

    function portOverDigs (address[] calldata _player, uint[] calldata _digsOpen) external isGameController() whenPaused() {
        require(_player.length == _digsOpen.length);
        for (uint256 i = 0; i < _player.length; i++) {
            addressIsRenting[_player[i]] = _digsOpen[i];
        }
    }

    function updateResourceTracker(IResourceTracker _resourceTracker) public isGameController(){
        resourceTracker = _resourceTracker;
    }

    function updateAutoReplenish (uint _digsPerTimeUnit, uint _replenishTimeUnit) public isGameController(){
        IPlanetPlot(planetPlot).updateAutoReplenish(_digsPerTimeUnit, _replenishTimeUnit);
    }
    function pauseHandler() public isGamePauser(){
        _pause();
    }
    function unpauseHandler() public isGamePauser(){
        _unpause();
    }
}
