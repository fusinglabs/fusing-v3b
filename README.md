# fusi.ng V3b

The second V3 stack (29 September 2026).

Solidity smart contracts of [fusi.ng](https://fusi.ng), a token launchpad on Ethereum built on Uniswap V4. Ethereum mainnet only.

- Website: https://fusi.ng
- Docs and ABIs: https://fusi.ng/docs#tech
- X: https://x.com/fusi_ng
- Telegram: https://t.me/fusi_ng

## Deployed contracts (Ethereum mainnet)

| Role | Address | Contract | Source status |
| --- | --- | --- | --- |
| autoLpModule | [`0x9B3eBe89BE0d2eB20B6F46AB3A3a7AD402669d7B`](https://etherscan.io/address/0x9B3eBe89BE0d2eB20B6F46AB3A3a7AD402669d7B) | AutoLpModule | verified on Etherscan |
| burnModule | [`0xfC1D7a3A8af5B1f39bCD4a775279B9B2DE4dc1b1`](https://etherscan.io/address/0xfC1D7a3A8af5B1f39bCD4a775279B9B2DE4dc1b1) | BurnModule | verified on Etherscan |
| factory | [`0x12E0B74FA72280aCf7748391D9B7D7695715825b`](https://etherscan.io/address/0x12E0B74FA72280aCf7748391D9B7D7695715825b) | FusingLaunchFactory | verified on Etherscan |
| feeConverter | [`0x70Ada1bb9EC0cf8D67A0E2be4a9EFC0D943FF528`](https://etherscan.io/address/0x70Ada1bb9EC0cf8D67A0E2be4a9EFC0D943FF528) | FusingFeeConverter | verified on Etherscan |
| feeEscrow | [`0xBB935800c64DAA1B00bf50bB8D097972f8022EA8`](https://etherscan.io/address/0xBB935800c64DAA1B00bf50bB8D097972f8022EA8) | FusingFeeEscrow | verified on Etherscan |
| feeHook | [`0xd4e721aDe3C33d308428Be4aF123567A32aC60c0`](https://etherscan.io/address/0xd4e721aDe3C33d308428Be4aF123567A32aC60c0) | FusingFeeHook | verified on Etherscan |
| fuseVault | [`0x9BdC70AD51ea0093c399cbc720D6a448b9772a94`](https://etherscan.io/address/0x9BdC70AD51ea0093c399cbc720D6a448b9772a94) | FuseVault | verified on Etherscan |
| handlesModule | [`0x7fCe66C20fd1a2Dc303dC92c5f8812ed2C21BD0F`](https://etherscan.io/address/0x7fCe66C20fd1a2Dc303dC92c5f8812ed2C21BD0F) | HandlesModule | verified on Etherscan |
| launchDeployer | [`0x84F3237CDAfe397694839Cf8D4A850dF32147680`](https://etherscan.io/address/0x84F3237CDAfe397694839Cf8D4A850dF32147680) | FusingLaunchDeployer | verified on Etherscan |
| leanDeployer | [`0x5dd4C68Af38c0947c2589b8B74eE84648e9dfb5C`](https://etherscan.io/address/0x5dd4C68Af38c0947c2589b8B74eE84648e9dfb5C) | FusingLeanDeployer | verified on Etherscan |
| locker | [`0x3490fF94267fbfa1a6EEE93E1bC7487A2a4D6407`](https://etherscan.io/address/0x3490fF94267fbfa1a6EEE93E1bC7487A2a4D6407) | FusingLaunchLocker | verified on Etherscan |
| positionMinter | [`0x8b042ffa7e4F70fB4F678836e04b76CCD8BA5B97`](https://etherscan.io/address/0x8b042ffa7e4F70fB4F678836e04b76CCD8BA5B97) | FusingPositionMinter | verified on Etherscan |
| quotePricer | [`0x2C893B77bd95Be2F6Eacce202A245C15E9A7C1db`](https://etherscan.io/address/0x2C893B77bd95Be2F6Eacce202A245C15E9A7C1db) | FusingQuotePricer | verified on Etherscan |
| referenceRegistry | [`0x7393A33492Eae9bcaAe9e9cCe855512d44951B9B`](https://etherscan.io/address/0x7393A33492Eae9bcaAe9e9cCe855512d44951B9B) | FusingReferenceRegistry | verified on Etherscan |
| router | [`0xcCf13e907726AF155AAf2Aa7A7EF8a46634bfFD6`](https://etherscan.io/address/0xcCf13e907726AF155AAf2Aa7A7EF8a46634bfFD6) | FusingRouter | verified on Etherscan |
| stockDesk | [`0x8ef51726BD30AA39A946fF866A0aF6FE39c70365`](https://etherscan.io/address/0x8ef51726BD30AA39A946fF866A0aF6FE39c70365) |  | not verified |
| tokenLock | [`0x8AbEd3488d1692d775CfB5938B5A516871B7368b`](https://etherscan.io/address/0x8AbEd3488d1692d775CfB5938B5A516871B7368b) | FusingTokenLock | verified on Etherscan |
| walletsModule | [`0x1E66F4d7D2fc99E27196bfF0E8028D0E31711Fd5`](https://etherscan.io/address/0x1E66F4d7D2fc99E27196bfF0E8028D0E31711Fd5) | WalletsModule | verified on Etherscan |

## Source note

Every file here is exactly the source verified on Etherscan for the contracts above. Where two contracts in this stack were compiled from different revisions of the same file, the second revision is kept under `variants/<role>/`. Third-party libraries (Uniswap V4, OpenZeppelin and others) are not included; their exact versions are part of each contract's verified bundle on Etherscan.

Compiler: solc 0.8.26. Exact compiler settings are in each verified contract on Etherscan.

## License

MIT, as declared in each file's SPDX header.
