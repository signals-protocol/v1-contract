# Signals v1

Signals v1 온체인 아키텍처 구현 프로젝트.

기존 Tenet CLMSR v0 시스템을 기반으로 **모듈화된 아키텍처**와 **클린한 스토리지 레이아웃**을 목표로 재설계 중.

## 현재 상태

**Phase 1: Storage / Interface 정리** 진행 중

- [x] Phase 0: 레포 부트스트랩 완료
- [ ] Phase 1: Storage / Interface 정리
- [ ] Phase 2: Core + 모듈 스캐폴딩
- [ ] Phase 3: v0 로직 포팅
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
│   │   └── storage/
│   │       └── SignalsCoreStorage.sol    # Core 스토리지 레이아웃
│   ├── interfaces/
│   │   ├── ISignalsCore.sol              # Core 인터페이스
│   │   └── ISignalsPosition.sol          # Position 인터페이스
│   ├── lib/
│   │   └── LazyMulSegmentTree.sol        # 세그먼트 트리 라이브러리
│   ├── modules/                          # (예정) 모듈들
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
