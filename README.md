# Signals v1

Signals v1 온체인 아키텍처 구현 프로젝트.

기존 Tenet CLMSR v0 시스템을 기반으로 **모듈화된 아키텍처**와 **클린한 스토리지 레이아웃**을 목표로 재설계 중.

## 현재 상태

**Phase 2: Core + 모듈 스캐폴딩** 완료.
- Phase 3-0 complete: CLMSR math/LazyMulSegmentTree 포팅 + SDK/v0 parity · invariant · round-trip · e2e 테스트 `test/unit/clmsrParity.test.ts` 녹색.

- [x] Phase 0: 레포 부트스트랩 완료
- [x] Phase 1: Storage / Interface 정리
- [x] Phase 2: Core + 모듈 스캐폴딩
- [ ] Phase 3: v0 로직 포팅 (SDK parity/invariants in progress)
- [ ] Phase 4: Risk / Invariants 도입
- [ ] Phase 5: LP Vault / Backstop 통합
- [ ] Phase 6: 메인넷 준비

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
