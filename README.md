# Signals v1

Signals v1 온체인 아키텍처 구현 프로젝트.

기존 Tenet CLMSR v0 시스템을 기반으로 **모듈화된 아키텍처**와 **클린한 스토리지 레이아웃**을 목표로 재설계 중.

## Current status

- Phase 3 (v0 parity + modularization) is complete: CLMSR math/LazyMulSegmentTree ported, Trade/Lifecycle/Oracle/Position modules wired, SDK/v0 parity tests green, deployment/upgrade scripts for citrea dev/prod present. RangeFactorApplied-style events are removed; tree internals are private implementation details.
- Phase 3-H hardening: added fuzz/slippage/settlement chunk/upgrade/access guards; on-chain ↔ SDK parity kept at ≤1e-6 WAD / ≤1 μUSDC.
- Next: Phase 4 Risk hooks while keeping parity tests green.

## 설계 목표

1. 얇은 업그레이더블 Core + delegate 모듈 구조
2. 24KB 코드 사이즈 제한 안정적 회피
3. v1 기준 클린한 Storage layout
4. Risk / Vault / Backstop 확장 가능한 설계

## 프로젝트 구조

```
signals-v1/
├── contracts/
│   ├── core/
│   │   └── SignalsCore.sol              # Core 스켈레톤(UUPS + delegate stubs)
│   │   └── storage/
│   │       └── SignalsCoreStorage.sol    # Core 스토리지 레이아웃
│   ├── interfaces/
│   │   ├── ISignalsCore.sol              # Core 인터페이스
│   │   └── ISignalsPosition.sol          # Position 인터페이스
│   ├── lib/
│   │   └── LazyMulSegmentTree.sol        # 세그먼트 트리 라이브러리
│   ├── modules/
│   │   ├── TradeModule.sol               # delegate-only 스켈레톤
│   │   ├── MarketLifecycleModule.sol     # 정산 청크 이벤트 선언 포함 스켈레톤
│   │   └── OracleModule.sol              # delegate-only 스켈레톤
│   ├── errors/
│   │   └── ModuleErrors.sol              # NotDelegated 등 공통 에러
│   └── position/
│       └── SignalsPositionStorage.sol    # Position 스토리지 레이아웃
├── test/
│   ├── unit/
│   ├── integration/
│   └── e2e/
├── plan.md                               # 상세 마이그레이션 플랜
└── README.md
```

## 설치 및 빌드

```bash
# 의존성 설치
yarn install

# 컴파일
yarn compile
```

## 문서

- [plan.md](./plan.md) - 상세 아키텍처 및 마이그레이션 플랜

## 라이선스

MIT
