// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Minimal placeholder to share storage layout between core and modules.
library LazyMulSegmentTree {
    struct Tree {
        uint256 root;
        mapping(uint256 => uint256) values;
        mapping(uint256 => uint256) lazy;
    }
}
