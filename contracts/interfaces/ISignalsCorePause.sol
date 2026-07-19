// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISignalsCorePause {
    function paused() external view returns (bool);
}
