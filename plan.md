# Signals v1 온체인 아키텍처 & v0→v1 마이그레이션 플랜

본 문서는 기존 Tenet CLMSR v0 시스템을 기반으로 한 **Signals v1 온체인 아키텍처**와, v0에서 v1으로의 **구체적인 마이그레이션 플랜**을 정리한 작업 노트이다.
Core 컨트랙트의 이름은 최종적으로 **`SignalsCore`**(기존 안의 `SignalsMarketCore` 대신)를 사용한다.

Scope:
- Phase 0~3: Tenet CLMSR v0 동작 패리티 + 모듈화 (신규 기능 없음)
- Phase 4~5: whitepaper 상 Risk / Vault / Backstop 레이어를 v1 아키텍처 위에 통합
- Phase 6: 메인넷 V1 immutable 경계 및 업그레이드 정책 확정

---

## 0. 배경 및 목표

### 0-1. 기존 상황 (Tenet v0)

현재 Tenet에는 대략 다음 구조의 CLMSR 기반 시스템이 배포되어 있다.

- `CLMSRMarketCore`

  - 트레이드/정산 로직 + 스토리지 + 관리 로직이 한 컨트랙트에 응집

- `CLMSRMarketManager`

  - 일부 라이프사이클/오라클/정산 관련 기능

- `CLMSRPosition`

  - ERC721 포지션 토큰
  - v0에서 이미 `DEPRECATED`된 필드가 다수 포함

이 구조는 다음과 같은 문제가 있다.

- Solc 24KB 코드 사이즈 제한에 근접/침범
- Core에 비즈니스 로직·스토리지·관리 로직이 혼합 → 업그레이드 리스크 증가
- Risk/Vault/Backstop 등 whitepaper 상 확장 포인트를 끼워 넣기 어렵다
- v0의 스토리지가 지저분하고, 앞으로 canonical layout로 가져가기에 적절치 않다

### 0-2. Signals v1 설계 목표

Signals v1의 온체인 설계 목표는 다음과 같다.

1. **얇은 업그레이더블 Core + delegate 모듈 구조**
2. **24KB 코드 사이즈 제한 안정적으로 회피**
3. **Storage layout을 v1 기준으로 클린하게 재설계** (앞으로의 기준점)
4. **Risk / Vault / Backstop 등 메커니즘을 자연스럽게 확장 가능하게 설계**
5. 메인넷 Signals V1 시점에는

   - 가격/정산 메커니즘 계층은 사실상 **immutable**에 가깝게 고정
   - Config/파라미터/리스크 한도/Oracle provider 등은 **governance를 통해 조정 가능**

### 0-3. 마이그레이션 원칙 & 가드레일

이 마이그레이션의 목표는 **동일 동작을 유지한 채 모듈화**하는 것이다. 트레이더·포지션·PnL 관점에서 Signals v1은 Tenet v0와 동일하게 동작해야 하며, 그 과정에서 아키텍처와 스토리지 레이아웃을 더 깔끔하게 만든다.

이를 지키기 위한 원칙은 다음과 같다.

1. **v1에서는 외부 인터페이스와 스토리지 레이아웃을 동결**

   - v1에서 “동결”로 취급하는 항목:
     - FE/SDK에 노출되는 공개 인터페이스
       - `ICLMSRMarketCore` / `ISignalsCore` (함수 시그니처)
       - `ICLMSRPosition` / `ISignalsPosition` (포지션 뷰 API)
     - 업그레이드 안정성을 가져야 하는 스토리지 레이아웃
       - `SignalsCoreStorage` (market/tree/oracle state의 canonical 레이아웃)
       - `SignalsPosition` 스토리지 레이아웃
   - v1 내부에서는 gap을 지키며 새 필드를 추가할 수 있으나, 기존 필드를 삭제하거나 재배치하지 않는다.

2. **세이프티넷 없는 구조 변경 금지**

   - “큰 구조 이동을 먼저” 하는 일을 하지 않는다.
   - CLMSR 수학, 세그먼트 트리, 트레이드 플로우처럼 비평범한 영역에서는 항상 다음 순서를 따른다:

     > 이해·문서화 → 테스트·회귀 하네스 → 로컬 리팩토링 → 구조 분리

   - 구체적으로:
     - 먼저 invariant와 SDK ↔ 온체인 매핑을 문서화한다.
     - 이후 동작을 고정하는 테스트(특히 SDK 패리티)를 추가한다.
     - 그 다음에야 헬퍼 추출, 라이브러리/모듈 이동, 파일/모듈 경계 변경을 수행한다.

3. **v0를 실행 가능한 스펙으로 사용**

   - Tenet v0를 기준 구현으로 취급한다.
   - 단, Mechanism Layer semantics(백서+SDK)와 v0 구현이 충돌할 경우 v0를 버그로 간주하고 v1에서 수정한다. v0 패리티는 백서/SDK에 부합하는 부분에 한해 요구한다.
   - 동작이 의심스러울 때는
     - v0 코드나 SDK로 기대값을 도출하고,
     - v1에 회귀 테스트를 추가한 뒤,
     - 테스트가 통과할 때까지 리팩토링한다.

4. **작고 리뷰 가능한 단계로 진행**

   - 하나의 phase나 PR에서 “아키텍처+리팩토링+최적화”를 동시에 시도하지 않는다.
   - 특히:
     - Phase 3는 **동작 동일성 + 깨끗한 분리**에 집중하며,
     - 가스 최적화는 동작이 고정된 이후 별도 phase에서 진행한다.

5. **암묵적 동작 대신 명시적 invariant**

   - 코어 수학/CLMSR 로직에 대해 명시적으로 기록한다:
     - 어떤 값이 >0/비영/단조여야 하는지,
     - 반올림 규칙(유저 debit=ceil, credit=floor),
     - 어떤 조합이 반드시 revert되어야 하는지.
   - 관련 코드를 건드릴 때마다
     - invariant 문서,
     - 이를 검증하는 테스트를 함께 업데이트한다.

6. **언어 규율**

   - 코드베이스 내 주석과 용어는 모두 영어로만 작성하며, 코드/인라인 문서에서 한글 사용을 금지한다(일관성 유지 목적).

### 0-4. Signals v1 온체인에서의 세 레벨 정의

이 문서 전체의 설계/마이그레이션 판단 기준으로 다음 세 레벨을 고정한다.

1) Mechanism Layer (사실상 immutable core semantics)
- 바뀌면 "Signals가 아닌 다른 프로토콜"이 되는 부분:
  - CLMSR 비용/가격 함수 (C(q)=α ln Z(q), Z(q)=Σ e^{qi/α}, pi=∂C/∂qi)
  - OutcomeSpec / tick semantics ([L, U, s, d], toTick(x), clamp 규칙)
  - Market-Cycle batch 회계 invariants (Vault (N, S, P), P=N/S, 일간 P&L Lt, fee Ft, grant Gt, deposit/withdraw 수식)
  - Settlement state machine (Trading → SettlementOpen → PendingOps → FinalizedPrimary/Secondary, Tset/Δsettle/Δops/Δclaim 타임게이트)
  - 토큰 의미:
    - LP: Vault N_t에 대한 비례 청구권을 나타내는 ERC-4626 share
    - Position: 1회성 claim NFT (ERC-721)

- 이 레이어는 v1에서 **업그레이드로 바꾸지 않는다는 가정** 아래 설계한다.
   - Solidity 기준으로는 주로
     - `SignalsCoreStorage` (canonical storage layout)
     - 메커니즘 라이브러리 (`CLMSRMathLib`, `VaultAccountingLib`, `SettlementLib` 등)
     - 코어 토큰 컨트랙트 의미 (`SignalsLPShare`, `SignalsPosition`)
     - Safety α bound 수식:
       - `α_base,t = (pwc * E_t) / (s_safe * ln n)` (V1에서는 E_t = N_{t-1}을 사용, 일반 prior 기반 E_ent(q0)는 향후 확장으로 남김)
       - `DD_t := 1 − P_t / P_peak`, `α_limit,t = max{0, α_base,t * (1 − k · DD_t)}`
       - 어떤 Config/Depth policy를 쓰더라도 on-chain RiskModule이 `α_t ≤ α_limit,t`를 강제

2) Config / Performance Layer (업그레이드/파라미터 조정 대상)
- α, k, pwc/pdd, Dlag, fee rate, fee waterfall 비율
- OutcomeSpec 템플릿, market 스케줄
- depth squeeze/expand 정책, drawdown limit, per-market exposure limit
- Fee / Fee Waterfall: trading/settlement fee rates, fee waterfall ratios, on-chain FeePolicy contracts implementing them

- Solidity 기준으로는 주로
  - 별도 UUPS/Ownable `SignalsConfig`(또는 세트) 컨트랙트에 파라미터를 저장하고 Core에는 Config 주소만 둔다.
  - 모듈은 파라미터를 직접 보관하지 않고 `config.getSafetyParams(marketId)`/`config.getFeePolicy(marketId)` 같은 뷰를 통해 읽기만 한다.
  - `RiskModule`, `LPVaultModule`에서 읽는 정책 값
  - 모듈 구현 자체(트레이드/라이프사이클/리스크 정책)
  에 해당하며, proxy/모듈 교체로 변경 가능하다.

3) Off-chain / Ops Layer
- Secondary settlement rule
- prior 추정 로직, Treasury LOLR 개입 정책
- 온체인 설계 문서에서는 다루되, 스마트 컨트랙트의 스코프 밖 항목으로 취급한다.

이 세 레벨 정의를 기준으로 이후 챕터(1~6)의 설계/업그레이드 정책을 일관되게 맞춘다.

---

## 1. Signals v1 타겟 아키텍처

### 1-1. 레이어 구조 개요

이 아키텍처는 0-4에서 정의한 세 레벨을 Solidity 컴포넌트로 매핑한 결과이며 다음 원칙을 따른다.

- Mechanism Layer의 수학/회계/상태머신은 가능한 한 **라이브러리+스토리지** 조합으로 고정한다.
- `SignalsCore`는 Mechanism storage + routing + access control만 맡고, 비즈니스 로직/헬퍼는 갖지 않는다.
- `*Module` 들은 Config/Policy 계층으로, delegatecall을 통해 Core storage를 조작하며 교체 가능하다.
- LP/Vault, Risk, Oracle 역시 각각 별도 모듈로 설계하되, 그 안에서 사용하는 메커니즘 수식은 라이브러리로 고정한다.

1. **Entry Core (업그레이더블, 얇게 유지)**

   - 컨트랙트: `SignalsCore`
   - 역할:

     - 전체 **단일 스토리지 소스** 보유 (`SignalsCoreStorage`)
     - 업그레이드 권한, pause, owner 등 “관리” 책임
     - 외부 엔드포인트(예: `openPosition`, `closePosition`)는 **얇은 stub**만 가지며, 실제 로직은 모듈로 delegatecall
     - 각 모듈 주소를 저장하고 `_delegate(module)` 유틸리티 제공

   - 구조:

     - `UUPSUpgradeable` proxy에 연결되는 **유일한 진입점** 컨트랙트
     - 비즈니스 로직은 최대한 모듈로 이관

2. **Execution / Lifecycle 모듈 (delegate 전용, 필요시 교체)**
   `SignalsCore`에서 delegatecall로 호출되는 모듈들:

   - `MarketLifecycleModule`
     - v0의 `CLMSRMarketManager` 역할 + 코어 라이프사이클
     - 주요 책임:
       - `createMarket`, `closeMarket`, `failMarket`, `reopenMarket`, `setMarketActive`, `updateMarketTiming`
       - Settlement state machine 구동 (Trading → SettlementOpen → PendingOps → Finalized)
       - 정산 시 CLMSR maker P&L Lt, fee Ft, grant Gt 계산 → `VaultAccountingLib`를 통해 Vault 상태 업데이트
       - `OracleModule`에 정산 가격을 질의하고, 결과를 받아 state transition 수행

   - `TradeModule`
     - 포지션 트레이딩 / 뷰 로직 담당
     - 주요 책임:
      - `openPosition`, `increasePosition`, `decreasePosition`, `closePosition`, `claimPayout`
      - `calculateOpenCost`, `calculateIncreaseCost`, `calculateDecreaseProceeds`, `calculateCloseProceeds`, `calculatePositionValue`
      - CLMSR 분포 cost/proceeds 계산 시 `CLMSRMathLib` / `DistributionMathLib` 사용
      - 수수료 계산은 `IFeePolicy` 인터페이스를 구현한 FeePolicy 컨트랙트를 통해 수행하며, per-market `market.feePolicy` 또는 전역 `defaultFeePolicy`를 사용한다.
      - 포지션 NFT 발행/소각, fee 처리, 이벤트 발생

   - `LPVaultModule`
     - LP Vault/Backstop 회계와 batch 처리 담당
     - 주요 책임:
       - Vault 상태(N_t, S_t, P_t, peak P, drawdown 등)를 `SignalsCoreStorage`에서 관리
       - `requestDeposit`, `requestWithdraw`, `processDailyBatch` 등 일 단위 batch 처리
       - 일 단위 CLMSR maker P&L Lt, fee Ft, grant Gt를 Vault에 반영 (`VaultAccountingLib` 사용)
       - withdrawal lag(Dlag), drawdown cap, per-LP limit 적용

   - `RiskModule`
     - 리스크/limit/파라미터 조정 정책 담당 (SignalsCoreStorage를 공유하는 delegate 모듈, read/write 모두 수행)
     - 주요 책임:
       - per-market / per-account exposure limit, α upper/lower bound, daily VaR/Drawdown limit 체크 및 상태 기록
       - drawdown cap(pdd), Backstop Grant G_t 결정, α_base,t / α_limit,t 계산
       - `TradeModule`/`LPVaultModule`에 대한 gating hook 제공 (예: `beforeOpenPosition`, `beforeIncreasePosition`, `beforeDailyBatch`)
       - Config 컨트랙트에서 파라미터를 읽어 invariant 위반 시 revert

   - `OracleModule`
     - 정산 가격 feed 검증 전담
     - 주요 책임:
       - marketId별 Oracle feed 설정 및 변경
       - Oracle packet signature 검증, staleness/Δmax 체크
       - Settlement 시점에 `getSettlementPrice(marketId, timestamp)` 제공
     - 메커니즘 레이어에서는 "어떤 패킷이 유효한 정산 가격인가"의 규칙이 여기 고정되며, provider/adapter는 Config/Hooks로 교체 가능하게 설계

   각 모듈의 공통 규칙:

   - `SignalsCoreStorage`를 상속하여 **Core와 동일한 스토리지 레이아웃을 공유**
   - `onlyDelegated`와 같은 modifier로 직접 호출 방지 (v0 `CLMSRMarketManager` 패턴 확장)
   - UUPS proxy에 달지 않고 **delegate 전용**으로 설계 (필요 시 신규 배포 + Core의 모듈 주소 교체)
   - 모든 모듈은 `SignalsCoreStorage`만 상속하고, `Ownable`/`Pausable`/`ReentrancyGuard` 등의 업그레이더블 베이스를 모듈에서 직접 중복 상속하지 않는다(스토리지 선형화 일관성 확보).
   - 프로덕션에서는 모듈 주소를 외부에 노출하지 않고, FE/SDK는 항상 `SignalsCore`만 호출한다. 테스트에서도 Core 경유(delegatecall) 헬퍼를 사용하며, 모듈 컨트랙트를 직접 인스턴스해 호출하지 않는다.

3. **토큰 및 부가 컨트랙트 (업그레이더블 가능하지만 스토리지는 깨끗하게)**

   - `SignalsPosition` (v0의 `CLMSRPosition` 역할)

     - ERC721 포지션 토큰
     - v0에서 이미 `DEPRECATED`된 필드는 제거
     - v1 기준으로 스토리지 레이아웃을 정리하고 gap 확보

   - (추후) LP share token, Backstop share token 등

     - Vault/Backstop의 지분 토큰

4. **라이브러리**

   - `FixedPointMathU`, `LazyMulSegmentTree` 등은 기존처럼 라이브러리로 유지
   - 어떤 모듈이 어떤 라이브러리를 사용하는지 명확히 정의하여
     불필요한 중복 링크 최소화

### 1-2. 스토리지 레이아웃

#### 1-2-1. Core Storage (`SignalsCoreStorage`)

- 새 파일: `contracts/core/storage/SignalsCoreStorage.sol` (이름은 유연하나 컨셉은 고정)
- v0 `CLMSRMarketCoreStorage`에서 실제 사용하는 필드만 가져와 정리:

  - `Market` struct
  - `markets`, `marketTrees`
  - `settlementOracleState`
  - `_nextMarketId`
  - 각종 mapping (포지션/마켓 인덱스, 설정값 등)
- `Market` struct에는 정산 스냅샷 메타데이터도 포함한다.
  - `openPositionCount`: settle 직전까지 quantity>0인 포지션 수
  - `snapshotChunkCursor`: `SettlementChunkRequested`를 몇 번째 `chunkIndex`까지 emit했는지
  - `snapshotChunksDone`: 모든 청크 emit 완료 여부

- 실험적/임시/사용하지 않는 필드는 제거
- 향후 확장을 위한 `__gap` 재설계
- Signals v1 이후 **canonical layout**로 간주하고 mainnet V1 배포에도 그대로 사용

#### 1-2-2. Position Storage (`SignalsPosition`)

- 새 컨트랙트: `SignalsPosition` (UUPS 업그레이더블 가능)
- v0 `CLMSRPosition`에서 실제 사용하는 필드만 유지:

  - `core` (SignalsCore 주소)
  - `_nextId`
  - `_positions`
  - `_marketTokenList`
  - `_positionMarketIndex`

- `DEPRECATED` 필드:

  - `_totalSupply`, `_ownedTokensSlot`, `_positionMarket` 등은 **완전히 제거**

- v1 기준으로 `gap`을 정의해 이후에는 추가만 가능하도록 layout 고정

---

### 1-3. 메커니즘 라이브러리 분리 제안

Signals v1에서 Mechanism Layer(0-4에서 정의한 immutable semantics)는 가능한 한 다음 라이브러리들 안에만 위치하도록 강제한다. 이 라이브러리들은 외부 라이브러리로 배포되고, 각 모듈 바이트코드는 컴파일 시점에 해당 라이브러리 주소를 링크하므로 사실상 immutable로 취급한다.

필수 Mechanism 라이브러리 집합은 최소한 다음을 포함한다.

- `CLMSRMathLib` (또는 `SignalsClmsrMath`)
  - CLMSR cost/proceeds 수학:
    - C(q) = α * ln(Σ_after / Σ_before)
    - P(q) = α * ln(Σ_before / Σ_after)
  - `_safeExp`, chunk-splitting (`MAX_EXP_INPUT_WAD`, `MAX_CHUNKS_PER_TX`)
  - 수학적 도메인/invariant 체크 (입력 범위, overflow 자유 구간)

- `DistributionMathLib` (트리 + 수식 결합)
  - LazyMulSegmentTree를 사용해 range sum을 읽고, cost/proceeds/qty를 계산
  - 인터페이스는 v0 `_calculateTradeCostInternal`, `_calculateSellProceeds`, `_calculateQuantityFromCostInternal`의 역할을 대체하는 형태
  - TradeModule은 tick→bin 변환과 파라미터 수집까지만 하고 나머지는 여기 위임

- `VaultAccountingLib`
  - Market-Cycle batch 회계 invariants 담당:
    - Vault 상태 (N, S, P=N/S)를 일관되게 업데이트
    - 일간 maker P&L Lt, fee Ft, grant Gt 반영
    - deposit/withdraw 수식:
      - deposit: (N, S) → (N+D, S+D/P)
      - withdraw: (N, S) → (N−xP, S−x)
    - peak P, drawdown 계산

- `SettlementLib`
  - Settlement state machine 전담:
    - 상태: Trading → SettlementOpen → PendingOps → FinalizedPrimary/Secondary
    - Tset, Δsettle, Δops, Δclaim 에 따른 time gate 체크
    - toTick(x), clamp 규칙 구현
  - MarketLifecycleModule은 이 라이브러리를 통해서만 상태 전이를 수행한다.

이 기준에 따라 **모듈은 “스토리지 + 플로우 오케스트레이션”**, **라이브러리는 “CLMSR/Vault/Settlement 메커니즘 엔진”**으로 역할을 분리한다. 모듈은 tick/bin 변환, 파라미터 수집, 토큰 이동, 이벤트, 검증에 집중하고 계산은 라이브러리에 위임한다.

### 1-4. 정산 스냅샷 / 인덱싱 전략 (서브그래프 구동)

Signals V1에서는 whitepaper 6.5의 “포지션별 정산 스냅샷” 요구를 만족하되, v0처럼 포지션 수만큼 on-chain 이벤트를 emit하지 않는다.

핵심 원칙:

- **On-chain**
  - 정산 로직은 settlementTick만 기록하며 포지션별 승/패/정산금은 상태로 기록하지 않는다.
  - 정산 이후, 시장별로 O(1) 크기의 `SettlementChunkRequested(marketId, chunkIndex)` 이벤트만 emit한다.
  - `Market.openPositionCount`, `Market.snapshotChunkCursor`, `Market.snapshotChunksDone`는 스냅샷 배치 진행상태 메타데이터다.

- **Off-chain (subgraph/indexer)**
  - 포지션 생성 시 `UserPosition`에 `seqInMarket`를 부여(온체인 저장 없음).
  - `CHUNK_SIZE`(예: 256~512) 단위로 `chunkIndex`를 나누고, `SettlementChunkRequested`를 수신한 서브그래프가 `seqInMarket` 범위별 승/패/정산금을 계산해 `UserPosition.outcome/payout/settledByBatch`에 기록한다.
  - On-chain view(`_calculateClaimAmount`)는 claim 처리에만 사용, 서브그래프는 동일 수학을 off-chain에서 복제한다.

이렇게 하면 정산 로그 가스는 O(#chunks)로 제한되고, per-position 정산 상태는 인덱서 레이어에서만 관리한다.

---

## 2. 24KB 코드 사이즈 & 업그레이드 전략

### 2-1. 24KB 코드 사이즈 기준 대응

#### Core (`SignalsCore`)

- Core의 외부 함수는 대부분 다음 패턴을 따른다.

```solidity
function openPosition(
    uint256 marketId,
    int256 lowerTick,
    int256 upperTick,
    uint128 quantity,
    uint256 maxCost
) external override whenNotPaused nonReentrant returns (uint256 positionId) {
    _delegate(tradeModule);
}
```

- Core 자체에 포함되는 것은:

  - 스토리지 정의 (`SignalsCoreStorage`)
  - Ownable/Pausable/UUPS/ReentrancyGuard 등 관리 로직
  - 모듈 주소 관리 및 `setModules`
  - `_delegate(address module)` helper

- 비즈니스 로직이 거의 없으므로, Core 바이트코드는 24KB 기준에서 **충분히 여유**를 가지도록 설계 가능
- 다음 로직은 Core에 두지 않는다: `openPositionInternal`/`closePositionInternal` 같은 트레이드 헬퍼, CLMSR 비용/가격 계산, fee 계산, oracle 검증, Vault 회계, 라이프사이클 상태 전이 구현. 이런 로직은 모두 `TradeModule`, `MarketLifecycleModule`, `LPVaultModule`, `RiskModule`, `OracleModule`로 이동하며 Core는 스토리지, 접근제어, 모듈 주소 관리와 `_delegate` 라우팅만 담당한다.

#### 모듈들 (`TradeModule`, `MarketLifecycleModule` 등)

- CLMSR 수학, 세그먼트 트리, settlement state machine 등의 heavy 로직은 모두 모듈로 이동
- 각 모듈에 대해 빌드 시:

  - `hardhat size-contracts` 또는 `forge build --sizes`로 **개별 코드 사이즈 측정**

- 만약 `TradeModule`가 24KB에 근접하면:

  - `TradeExecModule` (open/increase/decrease/close/claim)
  - `TradeViewModule` (`calculate*` 뷰 함수들)
  - 두 개의 모듈로 분리하고 Core에서 각각 delegatecall

핵심 원칙:

- **`SignalsCore` = 얇은 라우터 + 스토리지 + 권한 컨트랙트**
- heavy 비즈니스 로직은 모두 모듈로 분리

### 2-2. 업그레이드 전략 (Tenet / 메인넷)

#### Tenet / Signals v1 개발 단계

- `SignalsCore`, `SignalsPosition`은 UUPS proxy를 사용한다.
- Trade / Lifecycle / LPVault / Risk / Oracle 모듈은 **proxy 없는 구현 컨트랙트**로 배포하고, `SignalsCore`가 들고 있는 모듈 주소(slot)를 교체하는 방식으로 업그레이드한다.
- 따라서 "업그레이드 가능"이라는 뜻은
  - Core/Position은 UUPS 업그레이드 경로가 있고,
  - 모듈들은 새 구현을 배포한 뒤 Core의 모듈 주소를 바꾸는 식의 교체가 가능하다는 의미다.

- 다만 “메커니즘 레이어”, 즉:

  - CLMSR cost 함수, pricing formula
  - settlement 샘플링/상태 머신

- 은 가능한 한 **하나의 모듈/라이브러리**로 고정하고, 자주 변경하지 않도록 설계

#### 메인넷 Signals V1

- 가격/정산 메커니즘 레이어(가격 수식, 정산 규칙, settlement state machine)는 **사실상 immutable**로 본다.

  - 방법 1: proxy 없이 non-upgradeable로 배포
  - 방법 2: proxy를 사용하더라도 governance 상 “이 모듈은 더 이상 업그레이드하지 않는다”를 선언하고, 변경 필요 시에는 **새 버전 시스템(Signals V2)을 배포**

- 반면 다음 요소는 업그레이드 혹은 교체 가능한 컨트랙트로 유지:

  - Config/시장 파라미터
  - Fee policy
  - Risk limit/Exposure limit
  - Vault 파라미터
  - Oracle provider/adapter 등

---

## 3. v0 → v1 엔드포인트 및 컴포넌트 매핑

### 3-1. 외부에서 보이는 Core 인터페이스 (`ISignalsCore`)

기존 v0의 `ICLMSRMarketCore`가 제공하던 주요 인터페이스는 v1에서도 그대로 유지한다.
(Core 컨트랙트 이름만 `SignalsCore`로 변경)

`ISignalsCore`에는 다음 함수들이 포함된다 (예시):

- 트레이드/정산:

  - `openPosition(...)`
  - `increasePosition(... )`
  - `decreasePosition(...)`
  - `closePosition(...)`
  - `claimPayout(...)`

- 가격/가치 계산:

  - `calculateOpenCost(...)`
  - `calculateIncreaseCost(...)`
  - `calculateDecreaseProceeds(...)`
  - `calculateCloseProceeds(...)`
  - `calculatePositionValue(...)`

**FE 및 오프체인 엔진 관점:**

- 여전히 `signalsCore.openPosition(...)` 형식으로 콜한다.
- 내부에서는 `SignalsCore` → `TradeModule` delegatecall로 흐른다.

### 3-2. Core에서 모듈로의 실제 routing

`SignalsCore`는 외부 시그니처만 가지고, 실제 구현은 모듈로 delegate한다.

```solidity
contract SignalsCore is
    ISignalsCore,
    SignalsCoreStorage,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    address public tradeModule;
    address public lifecycleModule;
    address public riskModule;
    address public vaultModule;
    address public oracleModule;

    function setModules(
        address _tradeModule,
        address _lifecycleModule,
        address _riskModule,
        address _vaultModule,
        address _oracleModule
    ) external onlyOwner {
        tradeModule = _tradeModule;
        lifecycleModule = _lifecycleModule;
        riskModule = _riskModule;
        vaultModule = _vaultModule;
        oracleModule = _oracleModule;
    }

    function openPosition(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity,
        uint256 maxCost
    ) external override whenNotPaused nonReentrant returns (uint256 positionId) {
        _delegate(tradeModule);
    }

    // ... increase/decrease/close/claim, calculate* 등도 동일 패턴
}
```

### 3-3. 모듈 내 구현 (v0 로직 포팅)

#### `TradeModule`

- v0 `CLMSRMarketCore`에서 다음 구현들을 **그대로 옮긴다**:

  - 트레이드 실행:

    - `openPosition`, `increasePosition`, `decreasePosition`, `closePosition`, `claimPayout`

  - internal helper:

    - `_calcCostInWad` (Lib 결과 + 반올림 래퍼)
    - `_applyFactorChunked` (factor 적용 및 트리 업데이트)
    - `_quoteFee`, `_resolveFeeRecipient`, `_resolveFeePolicy`
    - `_validateActiveMarket`, `_validateTick`, `_marketExists`

  - 다음 함수들은 `SignalsClmsrMath` / `SignalsDistributionMath`에만 존재하고 TradeModule에서는 호출만 한다:

    - `_safeExp`
    - `_computeSafeChunk`
    - `_calculateTradeCostInternal`, `_calculateSingleTradeCost`
    - `_calculateSellProceeds`, `_calculateSingleSellProceeds`
    - `_calculateQuantityFromCostInternal`

- 이 함수들은 `TradeModule` 내에서 `internal`/`private`로 유지
- `SignalsCore.*`는 해당 함수 시그니처를 그대로 노출하고 `_delegate(tradeModule)`만 수행

#### `MarketLifecycleModule`

- v0 `CLMSRMarketManager`의 로직을 거의 그대로 포팅하되, v0의 `emitPositionSettledBatch/PositionSettled` 패턴은 포팅하지 않는다(포지션 수만큼 로그를 찍지 않는다).

  - `createMarket`
  - `settleMarket`
  - `reopenMarket`
  - `setMarketActive`
  - `updateMarketTiming`
  - 정산/오라클 상태 머신, 실패/수동 정산 등
  - 정산 후 스냅샷 배치 트리거:

    ```solidity
    event SettlementChunkRequested(uint256 indexed marketId, uint32 indexed chunkIndex);
    uint32 internal constant CHUNK_SIZE = 512; // 스테이징 인덱서 성능 보고 튜닝

    function requestSettlementChunks(uint256 marketId, uint32 maxChunksPerTx) external onlyOwner onlyDelegated {
        require(_marketExists(marketId), CE.MarketNotFound(marketId));
        Market storage m = markets[marketId];
        require(m.settled, CE.MarketNotSettled(marketId));
        require(!m.snapshotChunksDone, "SNAPSHOT_ALREADY_DONE");
        require(maxChunksPerTx > 0, CE.ZeroLimit());

        uint32 totalChunks = (m.openPositionCount + CHUNK_SIZE - 1) / CHUNK_SIZE;
        uint32 cursor = m.snapshotChunkCursor;
        uint32 emitted = 0;

        while (cursor < totalChunks && emitted < maxChunksPerTx) {
            emit SettlementChunkRequested(marketId, cursor);
            cursor++;
            emitted++;
        }

        m.snapshotChunkCursor = cursor;
        if (cursor >= totalChunks) {
            m.snapshotChunksDone = true;
        }
    }
    ```

- `SignalsCore`에 라이프사이클 엔드포인트를 정의하고 `_delegate(lifecycleModule)`로 연결

  - v0의 `_delegateToManager()` 패턴을 일반화한 형태

### 3-4. Position 토큰: `CLMSRPosition` → `SignalsPosition`

- v0 `CLMSRPosition`의 기능을 유지하되, 스토리지를 정리한 형태로 재구현:

  - ERC721 기능
  - 포지션 메타데이터
  - 마켓별 포지션 인덱스 등

- v1에서는 `SignalsPosition`이 canonical Position 구현이 되며, Tenet에서는 **새 proxy를 배포**하므로 기존 storage 호환성 문제는 없다.
- mainnet V1 배포 시에는 이 v1 스토리지를 그대로 사용한다.

---

## 4. v0 → Signals v1 작업 단계 (Phase 0~6)

이 섹션은 실제 레포 작업 관점에서 Step-by-step 플랜을 정의한다.
새 레포 이름은 예시로 `signals-v1`을 가정한다.

> **Phase 0~1 전제: v0 컨트랙트/테스트를 통째로 복사하지 않는다.**  
> 이유: (1) canonical storage를 깔끔하게 재설계해야 하고, (2) 레거시가 섞이면 리팩터링 속도가 늦어지며, (3) diff/리뷰 단위가 비대해진다.  
> v0는 “참고용 코드/스펙”으로만 두고, 실제 포팅은 Phase 3에서 기능·심볼 단위로 가져온다.

---

### Phase 0. 레포 부트스트랩

1. 새 레포 생성: `signals-v1`
2. **빌드/테스트 인프라만** 세팅:

   - Hardhat/Foundry 설정, `tsconfig`, lint, CI 설정 등 **infra 파일만** v0에서 복사
   - `contracts/`는 비워두되, `core/`, `modules/`, `position/` 같은 서브폴더 스캐폴딩 정도만 만든다. (CLMSR 도메인 컨트랙트(`CLMSRMarketCore`, `CLMSRMarketManager`, `CLMSRPosition`)는 이 단계에서 가져오지 않는다.)
   - `test/`는 `unit/`, `integration/`, `e2e/` 등 기본 구조만 잡고, 구체 테스트 케이스는 Phase 3에서 v1 API에 맞춰 다시 작성한다.
   - 공용/비도메인 유틸(`FixedPointMathU`, `SafeERC20` 등)만 필요한 경우 선택적으로 가져온다.
   - **패키지 매니저는 Yarn을 기본으로 사용** (scripts/pnpm/npm 대비 우선)

3. 라이선스/패키지 이름, 네트워크 설정 등 프로젝트 메타데이터 정리

> 이 단계 목표: **도메인 로직/컨트랙트/테스트는 아무것도 복사하지 않고**, v1 개발을 위한 빌드·테스트 인프라 템플릿만 준비한다. v0 컨트랙트는 reference로만 본다.

**Phase 0 진입 기준**

- 레포 초기화 및 프로젝트 킥오프 완료.

**Phase 0 종료 기준**

- 빌드/테스트 인프라 스캐폴딩을 마치고 로컬에서 동작 확인.
- contracts/test 폴더가 스캐폴딩 외에는 비어 있음.
- Yarn 기반 워크스페이스 및 CI/lint/format 설정이 완료됨.

---

### Phase 1. Storage / Interface 정리 (v1 기준 스토리지 확정)

> v1 레포에는 “이유 없이 들어온 v0 코드”가 없도록 한다. 가져오는 심볼은 “v1 설계를 만족시키기 위해 지금 필요하다”는 근거가 있어야 하고, 나머지는 Phase 3에서 기능 단위 포팅 시점에 검토한다.

#### Step 1-1. Core Storage 설계

- 새 파일 생성: `contracts/core/storage/SignalsCoreStorage.sol`
- v0 `CLMSRMarketCoreStorage`에서 실제 사용 필드만 선별:

  - `Market` struct, `markets`, `marketTrees`
  - `settlementOracleState`
  - `_nextMarketId`
  - 기타 필요한 mappings
- 스냅샷/인덱싱을 위한 `Market` 필드(`openPositionCount`, `snapshotChunkCursor`, `snapshotChunksDone`)까지 포함해 v1 canonical 레이아웃으로 확정한다.

- 사용하지 않는 필드, 실험/임시 필드는 제거
- v1 기준으로 `__gap` 크기 재설정

#### Step 1-2. Position Storage 설계

- 새 컨트랙트: `SignalsPosition` (`contracts/position/SignalsPosition.sol` 등)

  - 실제 사용하는 필드만 유지
  - `DEPRECATED` 필드 완전 제거
  - v1 기준으로 layout 확정 + gap 설정

#### Step 1-3. 인터페이스 정리

- `ISignalsCore` (v0의 `ICLMSRMarketCore` 역할)

  - FE/엔진에서 사용하는 함수는 가능하면 모두 유지
  - 이번 기회에 제거하고 싶은 함수/이름을 확정하여 인터페이스에서 제거

- `ISignalsPosition` 인터페이스 정리
- “Signals V1 Core 인터페이스 스펙”을 별도 문서/노션에 명시

**Phase 1 진입 기준**

- Phase 0 종료 기준을 만족.
- CI에서 빌드/테스트 인프라가 녹색.

**Phase 1 종료 기준**

- `SignalsCoreStorage` 레이아웃이 canonical로 정의·문서화됨.
- `SignalsPosition` 스토리지 레이아웃이 canonical로 정의·문서화됨.
- `ISignalsCore`, `ISignalsPosition` 인터페이스가 작성·리뷰됨.

---

### Phase 2. Core + 모듈 스캐폴딩 (로직 없이 뼈대만)

#### Step 2-1. `SignalsCore` 뼈대 작성

- 상속:

  - `SignalsCoreStorage`
  - `UUPSUpgradeable`, `OwnableUpgradeable`, `PausableUpgradeable`, `ReentrancyGuardUpgradeable`

- 모듈 주소 필드:

```solidity
address public tradeModule;
address public lifecycleModule;
address public riskModule;    // 나중에 사용
address public vaultModule;   // 나중에 사용
address public oracleModule;  // 나중에 사용
```

- `setModules(...)` 등 onlyOwner setter 구현
- `_delegate(address module)` helper 구현

  - v0 `CLMSRMarketCore`의 `_delegateToManager` 일반화 버전

#### Step 2-2. `MarketLifecycleModule`, `TradeModule`, `OracleModule` 뼈대 작성

- 공통 상속(모듈):

  - `SignalsCoreStorage`
  - `CLMSRErrors` 등 도메인 에러 전용 베이스 (필요 시)
  - (주의) `Ownable` / `Pausable` / `ReentrancyGuard` / `UUPSUpgradeable` 등 업그레이더블 베이스는 **모듈에서 상속하지 않는다.** 이들은 모두 `SignalsCore`에만 존재한다.

- 직접 호출 방지:

  - `address private immutable self;`
  - `modifier onlyDelegated`를 두고, `address(this) == self`인 경우 revert

- 함수 시그니처만 먼저 정의 (구현은 비워둠):

  - `MarketLifecycleModule`:

    - `createMarket(...)`
    - `settleMarket(...)`
    - `reopenMarket(...)`
    - `setMarketActive(...)`
    - `updateMarketTiming(...)`
    - `requestSettlementChunks(uint256 marketId, uint32 maxChunksPerTx)`
    - `event SettlementChunkRequested(uint256 indexed marketId, uint32 indexed chunkIndex);`

  - `TradeModule`:

    - `openPosition(...)`
    - `increasePosition(...)`
    - `decreasePosition(...)`
    - `closePosition(...)`
    - `claimPayout(...)`
    - `calculateOpenCost(...)` 등 각종 `calculate*` 뷰 함수

  - `OracleModule`:

    - `setOracleConfig(marketId, feedId, ... )`
    - `getSettlementPrice(marketId, timestamp)` 인터페이스만 먼저 정의 (구현은 Phase 3-4에서 포팅)

(참고) `LPVaultModule`과 `RiskModule`의 스켈레톤은 Phase 4~5에서 Risk/Vault 레이어를 온보딩할 때 함께 정의/도입한다. Phase 0~3의 스코프는 v0 parity + Core/Trade/Lifecycle/Oracle 구조 정리에 한정한다.

> 이 단계 목표: **구현 없이도 전체가 compile 되는 상태** 확보.

**Phase 2 진입 기준**

- Phase 1 종료 기준을 만족.
- 스토리지/레이아웃 문서가 승인됨.

**Phase 2 종료 기준**

- 모듈 라우팅을 포함한 `SignalsCore` 스켈레톤이 컴파일됨.
- `TradeModule`/`MarketLifecycleModule` 스켈레톤이 delegation guard와 함께 존재.
- 빈 스켈레톤 기준 CI 빌드가 통과.
- 스토리지 선형화 규칙이 문서화됨: 모든 모듈은 `SignalsCoreStorage`만 상속하고, `Ownable`/`Pausable`/`ReentrancyGuard` 등의 업그레이더블 베이스를 모듈에서 직접 중복 상속하지 않는다.
- 재진입/일시중지 규칙이 명시됨: `nonReentrant`/`whenNotPaused`는 Core 외부 함수에만 적용하고 모듈 내부에서는 중첩 적용하지 않는다.

---

### Phase 3. v0 동작을 고정하고 v1 모듈로 포팅

**목표:** Tenet v0와 동일한 동작을 유지하면서 Signals v1 모듈 구조로 이관한다.

**Phase 3 절대 금지 체크리스트**

- [ ] public interface 변경
- [ ] storage layout 변경
- [ ] CLMSR 수식/반올림 규칙 변경
- [ ] 새 제품 기능 추가

**중요:** 우발적인 동작 변경을 허용하지 않는다. 순서는 반드시 다음과 같다.

1. 인바리언트·SDK ↔ 온체인 매핑 이해 및 문서화
2. 동작을 고정하는 테스트·회귀 하네스 추가
3. 구조 변경 없는 소규모 리팩토링
4. CLMSR 수학을 라이브러리로 분리
5. 트레이드/라이프사이클 플로우를 모듈로 포팅

이 Phase에서는 공개 인터페이스, 스토리지 레이아웃, 신규 기능을 변경하지 않는다.

#### Phase 3-0. 인바리언트 & SDK 패리티 하네스

**목표:** 구조를 건드리기 전에 기존 동작을 이해하고 테스트로 고정한다.

1. **인바리언트 및 매핑 문서화**
   - `_calculateTradeCostInternal`, `_calculateQuantityFromCostInternal`, `_calculateSellProceeds`, `_safeExp`, `_computeSafeChunk`에 대해 도메인 가정, 반올림 규칙, SDK ↔ 온체인 매핑을 기록.

2. **수준별 동치성 테스트 (온체인 vs SDK)**
   - 임의의 `(alpha, distribution, lowerTick, upperTick, quantity)`에 대해 `calculateOpenCost`, `calculateQuantityFromCost`, `calculateDecreaseProceeds`, `calculateCloseProceeds`가 SDK 기대값과 허용 오차 내에서 일치하는지 검증.

3. **왕복 특성 테스트**
   - cost/quantity, proceeds/quantity 왕복이 정의된 반올림 허용치 내에서 일치하는지 확인.

4. **엔드투엔드 트레이드 플로우 테스트**
   - `open → increase → decrease → close` 시나리오를 수수료 유무로 검증하며, 유저 debit/credit과 재진입 방어를 확인.

**Phase 3-0 종료 기준**

- 인바리언트와 SDK 매핑을 요약한 마크다운 노트가 존재.
- 수학 패리티 테스트가 구현되어 모두 통과.
- 왕복 특성 테스트 1개 이상, E2E 시나리오 테스트 1개 이상이 통과.
- CLMSR 수학과 트레이드 플로우의 동작 변화를 확실히 감지할 수 있음.

#### Phase 3-1. 소규모 내부 리팩토링 (구조 변경 없음)

**목표:** 동작이나 파일 경계 변경 없이 중복을 줄이고 의도를 명확히 한다.

범위:

1. **마켓 검증 공통화**

   - 다음과 같은 헬퍼를 추출:

     ```solidity
     function _loadAndValidateMarket(uint256 marketId)
         internal
         view
         returns (Market storage market)
     {
         market = markets[marketId];
         require(_marketExists(marketId), CE.MarketNotFound(marketId));
         require(market.isActive, CE.MarketNotActive());
         require(block.timestamp >= market.startTimestamp, CE.MarketNotStarted());
         require(block.timestamp <= market.endTimestamp, CE.MarketExpired());
     }
     ```

   - `openPosition`, `increasePosition`, `decreasePosition`, `closePosition` 등에 적용.

2. **틱 검증 공통화**

   - 다음 규칙을 하나의 헬퍼로 묶어 중복 제거:
     - `lower < upper`
     - `(upper - lower) % tickSpacing == 0`
     - “no point bet” 규칙

3. **네이밍 및 소규모 정리**

   - `_safeExp`, `_computeSafeChunk`, `_applyFactorChunked` 주변 변수명 개선 등, 로직 변경 없는 정리.

**가드레일**

- 공개 함수 시그니처 변경 없음.
- 스토리지 레이아웃 변경 없음.
- 파일/모듈 간 함수 이동 없음.
- Phase 3-0 테스트가 모두 통과해야 함.

**Phase 3-1 종료 기준**

- 마켓 검증 로직이 단일 헬퍼로 모임.
- 틱 범위 검증 로직이 단일 헬퍼로 모임.
- Phase 3-0 테스트가 모두 녹색 유지.

#### Phase 3-2. CLMSR 수학을 라이브러리로 분리 (SignalsClmsrMath / SignalsDistributionMath)

**선행 조건:** Phase 3-0, 3-1 테스트가 모두 녹색.

- 대상 함수 (기존 Core 내부):

  - `_safeExp`
  - `_computeSafeChunk`
  - `_calculateTradeCostInternal`, `_calculateSingleTradeCost`
  - `_calculateSellProceeds`, `_calculateSingleSellProceeds`
  - `_calculateQuantityFromCostInternal`

- 작업 흐름:

  1) 위 함수들을 `SignalsClmsrMath`(순수 수학) / `SignalsDistributionMath`(트리+수식)로 이동  
  2) TradeModule가 라이브러리 호출 기반으로 리팩토링되도록 시그니처 정비  
  3) 기존 유닛/통합/E2E 테스트(특히 CLMSR Math internal, replay/시장 시나리오)로 parity 검증

- 효과:

  - 모듈은 “스토리지+플로우”에 집중, 메커니즘은 Lib로 고정
  - 24KB 분할에 유리, 메커니즘 불변성 경계 정의 용이

**가드레일**

- 순수 코드 이동만 수행하며 입력/출력은 동일해야 함.
- 수학 관련 테스트(SDK 패리티, 왕복, E2E)가 모두 녹색 유지.

**Phase 3-2 종료 기준**

- CLMSR 수학이 `SignalsClmsrMath` / `SignalsDistributionMath`로 분리됨.
- TradeModule이 라이브러리를 사용하며 3-0/3-1 패리티 테스트가 유지.

#### Phase 3-3. 트레이드 로직 포팅 (`CLMSRMarketCore` → `TradeModule`)

- v0 `CLMSRMarketCore`에서 다음을 `TradeModule`로 옮김:

  - `openPosition`, `increasePosition`, `decreasePosition`, `closePosition`, `claimPayout`
- 내부 helper (TradeModule에 남기는 것):

  - `_calcCostInWad` (라이브러리 결과 + 반올림 래퍼)
  - `_applyFactorChunked` (factor 적용 및 트리 업데이트)
  - `_quoteFee`, `_resolveFeeRecipient`, `_resolveFeePolicy` (`IFeePolicy` external call 기반으로 정리, v0 FeePolicy 컨트랙트들은 Config Layer에서 관리)
  - `_validateActiveMarket`, `_validateTick`, `_marketExists`
  - `openPositionCount` 유지: 신규 포지션 생성 시 +1, 수량 0으로 완전 종료 시(정산 전) -1, 정산 후에는 더 이상 변경하지 않는다.

- 반대로, 다음 함수들은 `SignalsClmsrMath` / `SignalsDistributionMath` 라이브러리로만 존재하고 TradeModule에서는 호출만 한다:

  - `_safeExp`
  - `_computeSafeChunk`
  - `_calculateTradeCostInternal`, `_calculateSingleTradeCost`
  - `_calculateSellProceeds`, `_calculateSingleSellProceeds`
  - `_calculateQuantityFromCostInternal`

- `SignalsCore.openPosition` 등은 `_delegate(tradeModule)`만 수행하도록 정리
- 테스트:

  - v0 unit/integration 테스트(`market`, `core` 관련)를 v1 `SignalsCore`/`TradeModule`에 붙여 실행
  - 목표: **v0와 동일한 동작** 확인

**진입 기준**

- Phase 3-0~3-2 종료 기준이 모두 충족되고 테스트가 녹색.

**종료 기준**

- 모든 트레이드 플로우(open/increase/decrease/close/claim)가 `TradeModule`에 존재.
- `SignalsCore.*` 트레이드 엔트리포인트는 얇은 `_delegate(tradeModule)` stub만 남음.
- 가격/뷰, 상태 전환, 이벤트 관련 패리티 테스트 통과.

#### Phase 3-4. 라이프사이클 로직 포팅 (`CLMSRMarketManager` → `MarketLifecycleModule`)

- v0 `CLMSRMarketManager`를 `MarketLifecycleModule`로 이동:

  - `CLMSRMarketCoreStorage` → `SignalsCoreStorage`로 교체
  - 이벤트/에러 명칭은 가능하면 유지(필요 시 v1에서 리네임)

- `SignalsCore`에 라이프사이클 엔드포인트 정의:

  - `createMarket`, `settleMarket`, `reopenMarket`, `setMarketActive`, `updateMarketTiming` 등
  - 각 함수는 `_delegate(lifecycleModule)`로 연결

- v0 `CLMSRMarketManager` 안에 있던 오라클 패킷 검증, priceTimestamp/Δmax 체크 로직은 `OracleModule`로 분리 포팅하고, `MarketLifecycleModule.settleMarket`는 항상 `OracleModule.getSettlementPrice(marketId, timestamp)`를 통해 정산 가격을 읽도록 고정

- 테스트:
  - `settleMarket`는 `OracleModule.getSettlementPrice(marketId, timestamp)`를 통해 정산 가격을 획득하며, OracleModule이 feed/adapter/서명 검증의 단일 진입점임을 검증

  - 정산/오라클 관련 테스트(`claim-gating`, `settlement`, `manager` spec)를 v1 모듈에 맞춰 재실행
  - `requestSettlementChunks` 테스트:
    - `totalChunks = ceil(openPositionCount / CHUNK_SIZE)` 계산 검증
    - 첫 호출에서 `min(totalChunks, maxChunksPerTx)`개의 `SettlementChunkRequested` 이벤트 발생 검증
    - 충분히 큰 `maxChunksPerTx`로 한 번에 `snapshotChunksDone == true` 되는지 확인
    - `openPositionCount == 0`이면 이벤트 없이 `snapshotChunksDone == true` 되는지 확인

**진입 기준**

- Phase 3-3 종료 기준 충족.

**종료 기준**

- 라이프사이클 엔드포인트가 모두 `MarketLifecycleModule`로 이동.
- Core는 라이프사이클 엔트리포인트에서 `_delegate(lifecycleModule)`만 수행.
- v0 대비 정산/오라클 플로우 패리티 테스트가 녹색.

#### Phase 3-5. Position 컨트랙트 교체 (`SignalsPosition`)

- 새 `SignalsPosition` 구현:

  - v0 Position 테스트로 동작 동일성 확인
  - Core(`SignalsCore`)에서 포지션 컨트랙트 참조를 `ICLMSRPosition` → `ISignalsPosition`으로 교체

- Tenet에서는 새 proxy를 배포하므로 storage 호환성 문제 없음.
- mainnet v1에서도 이 레이아웃을 기준점으로 사용.

**진입 기준**

- Phase 3-4 종료 기준 충족.

**종료 기준**

- `SignalsPosition`이 배포 준비 상태이며 v0 테스트를 통과.
- Core에서 Position 참조가 v1 인터페이스로 교체.
- 스토리지 레이아웃 문서와 코드가 일치.

#### Phase 3-6. 배포/업그레이드 스크립트 정리

- v0 배포 스크립트(예: `deploy-core.ts`, `upgrade-core.ts`, `sync-manifest.ts`)를 참고하되:

  - 기존 proxy에 forceImport/upgrade 하는 로직은 제거
  - **“깨끗한 v1 배포”**만을 위한 스크립트로 재구성

- v1 배포 플로우 (예시):

  1. 라이브러리 배포 (`FixedPointMathU`, `LazyMulSegmentTree`)
  2. `MarketLifecycleModule` 배포
  3. `TradeModule` 배포
  4. `SignalsPosition` (proxy) 배포
  5. `SignalsCore` (proxy) 배포
  6. `SignalsCore.setModules(...)` 호출로 모듈 주소 세팅
  7. `SignalsCore`에 Position 컨트랙트 주소 등 초기 설정

- 서브그래프/인덱서 연동

  - v1 subgraph 스키마/매핑에서:
    - `UserPosition`에 `seqInMarket`, `outcome`, `payout`, `settledByBatch`, `closedBeforeSettlement` 필드 추가.
    - 포지션 생성 핸들러에서 마켓별 `seqInMarket` 카운터 증가, 정산 전 완전 종료된 포지션은 `closedBeforeSettlement=true`.
    - `SettlementChunkRequested(marketId, chunkIndex)` 핸들러에서 CHUNK_SIZE 범위별 승/패/정산금 계산 후 `settledByBatch=true` 반영.
  - Goldsky 스테이징 인덱서에서 CHUNK_SIZE(예: 256/512/1024) 후보 부하 테스트 후 최종값 채택.

- 환경 변수(`envManager`)도 v1 기준으로 리셋
- 운영 환경에서는 모듈 주소를 외부에 노출하지 않고 FE/SDK는 항상 `SignalsCore`만 호출하도록 하며, 테스트에서도 Core 경유(delegatecall) 헬퍼로 모듈 로직을 실행하고 모듈 컨트랙트를 직접 인스턴스해 호출하지 않는다는 규칙을 명문화

**진입 기준**

- Phase 3-5 종료 기준 충족.

**종료 기준**

- 배포/업그레이드 스크립트가 v1 전용으로 정리되고 CI 테스트 통과.
- forceImport/기존 proxy 업그레이드 경로 제거.
- 새 배포 플로우 문서화 완료.

> Phase 3 완료 시점:
> **Signals v1 = Tenet v0와 거의 동일한 기능 + 구조/스토리지만 모듈화/클린업된 상태**

---

### Phase 4. Risk / Invariants 도입

whitepaper의 Risk/Safety Layer를 코드로 통합하는 단계.

#### Step 4-1. Risk 인터페이스 및 Hook 설계

- `RiskModule`는 다음 인바리언트를 지키는 것을 1차 목표로 한다:
  - (1) per-market exposure limit: Σ|position notional| ≤ L_market
  - (2) per-account exposure limit: Σ|position notional| ≤ L_account
  - (3) daily drawdown limit: P_t ≥ (1 − d_max) · P_peak
  - (4) Vault solvency: Vault NAV ≥ worst-case liability (whitepaper 손실 상한 기반)

- RiskModule은 Core에서 delegatecall로 실행되는 모듈이며, gating + 상태 기록을 모두 수행한다. Core 엔트리포인트에서 먼저 `riskModule`을 delegate하고, 통과 시 `tradeModule`/`LPVaultModule`을 delegate하는 패턴을 따른다.
  - RiskModule은 “현재 상태 + 요청 delta”를 입력으로 limit/Safety invariant를 검증하고 필요한 리스크 상태(DD_t, α_base,t, α_limit,t, exposure)만 기록한다.
  - 실제 CLMSR 체결·트리 업데이트·Vault 회계는 TradeModule/LPVaultModule에서만 수행한다.

* Config 컨트랙트에는 L_market, L_account, d_max 등의 파라미터만 보관하고, RiskModule은 이를 읽어 사용한다.

#### Step 4-2. 테스트

- 단위 테스트:

  - 노출 제한(L_market, L_account) 초과 포지션 오픈/증가 시 revert되는지 검증.
  - drawdown cap(d_max) 이하로 P_t가 떨어지는 일일 P&L을 주입하고 `_beforeDailyBatch`에서 revert가 발생하는지 확인.

- 통합 테스트:

  - 여러 계정/마켓에서 포지션을 열고 일부 마켓이 크게 움직이는 시나리오에서
    - RiskModule이 어떤 순서에서 어떤 트랜잭션을 막는지,
    - Vault solvency 인바리언트가 유지되는지 검증.
    - LOLR 지표(DD_t, α_limit 대비 α_t 등)를 이벤트/뷰로 노출하고, Treasury는 이를 참고해 수동 개입한다는 기본 스코프 명시

**Phase 4 진입 기준**

- Phase 3 종료 기준을 만족.
- 동작 패리티 테스트 스위트가 녹색 유지.

**Phase 4 종료 기준**

- Risk hook surface(`_before*` 스타일)이 구현되어 동작 확인.
- 기본 한도 체크용 RiskModule이 존재하거나, 회귀 없이 stub가 연결되어 있음.
- 단위/통합 테스트가 revert 경로와 인바리언트를 검증.

---

### Phase 5. LP Vault / Backstop 통합

whitepaper의 Vault & Backstop 설계를 온체인 구현과 연결하는 단계.

#### Step 5-1. Vault/Backstop 스토리지 및 인터페이스

- Vault 상태(N, S, P), peak P, drawdown, 입출금 큐 등은 모두 `SignalsCoreStorage`에 포함시킨다.
- `LPVaultModule`은 이 스토리지를 사용하는 delegate 모듈로서:

  - `requestDeposit`, `requestWithdraw`, `cancelDeposit/Withdraw` 등 큐 관리
  - 하루 단위 batch(`processDailyBatch`):
    - 해당 market-cycle의 CLMSR maker P&L L_t, fee F_t를 Vault에 반영
    - RiskModule이 결정한 Backstop Grant `G_t`(±)를 반영 (`B_t = B_{t-1} − G_t`)
    - `VaultAccountingLib`로 N/S/P 업데이트
    - pending withdraw/deposit를 같은 기준가 `P_e,t`로 실행
  - withdrawal lag(Dlag), drawdown cap, per-LP limit 적용

- LP share token은 별도 ERC-4626 컨트랙트(`SignalsLPShare`)로 두되, Dlag 때문에 즉시 체결되지 않는다. 4626 `deposit`/`redeem`는 내부적으로 `SignalsCore.requestDeposit/Withdraw`를 호출하는 요청 래퍼이며, `preview*` 값은 마지막 기준가 기준의 참고치임을 명시한다.

#### Step 5-2. Trade / Lifecycle와 Vault 연결

- `MarketLifecycleModule.settleMarket` 흐름:

  1. `OracleModule`을 통해 정산 가격을 받아 settlement tick 확정
  2. CLMSR maker P&L L_t, fee F_t 계산
  3. `RiskModule`이 drawdown cap 규칙에 따라 G_t(±) 결정 (G_t > 0: Backstop → LP, G_t < 0: 과거 Grant 회수), Backstop NAV 업데이트
  4. `LPVaultModule`이 L_t, F_t, G_t를 읽어 `VaultAccountingLib`로 회계 처리:
     - `N_raw,t = N_{t-1} + L_t + F_t`
     - `N_pre,t = N_raw,t + G_t`
     - `P_e,t = N_pre,t / S_{t-1}`
  5. `LPVaultModule.processDailyBatch`에서:
     - withdraw queue 처리: (N, S) → (N − x·P_e,t, S − x)
     - deposit queue 처리: (N, S) → (N + D, S + D / P_e,t)
     - 최종 `(N_t, S_t, P_t)` 기록 (`P_t`는 이론상 `P_e,t`와 동일), peak P_t·drawdown 업데이트 및 RiskModule hook 호출

#### Step 5-3. 테스트

- 단위 테스트:
  - 단일 market-cycle에서 L_t/F_t/G_t(±)가 들어왔을 때 N/S/P 업데이트가 수식과 일치하는지 검증
  - deposit/withdraw 조합 시 인바리언트:
    - 모든 LP의 share 합 × P_t = Vault NAV
    - drawdown cap 위반 시 적절히 revert 또는 제한되는지

- 통합 테스트:
  - 여러 시장의 settlement가 Vault로 들어오고, LP들이 동시에 출입금할 때
    - fee/Backstop 적립, P_t trajectory, drawdown 인바리언트가 유지되는 시나리오 검증

**Phase 5 진입 기준**

- Phase 4 종료 기준을 만족.
- Risk hook과 테스트가 안정적으로 녹색.

**Phase 5 종료 기준**

- Vault/Backstop 스토리지와 인터페이스 초안이 정의·리뷰됨.
- Lifecycle/Trade 플로우가 필요한 지점에서 `LPVaultModule`을 호출.
- 정산 → Vault P&L 연결, deposit/withdraw batch를 다루는 통합 테스트가 통과.

---

### Phase 6. 메인넷 Signals V1 준비 (Immutable 경계 확정)

메인넷 배포 전에, 어떤 부분을 실질적으로 immutable로 취급할지 결정한다.

1. **메커니즘 레이어 고정**

   - CLMSR cost 함수
   - 가격/정산 수학
   - settlement state machine
   - 해당 로직은:

     - 아예 non-upgradeable 컨트랙트로 배포하거나,
     - proxy를 유지하더라도 governance 상 “더 이상 변경하지 않는다”고 선언

2. **Config Surface만 mutable 유지**

   - Oracle feed/adapter
   - Fee 정책
   - Risk limit/exposure limit
   - Vault 파라미터
   - 시장 파라미터

3. 변경이 필요한 새로운 메커니즘은:

   - Signals V2 등 **새 시스템**으로 배포하는 방향으로 설계
   - 기존 Signals V1은 그대로 historical/legacy system으로 유지

**Phase 6 진입 기준**

- Phase 5 종료 기준을 만족.
- Vault/Backstop 통합이 테스트에서 안정적.

**Phase 6 종료 기준**

- 불변/메커니즘 경계가 문서화·승인됨.
- 업그레이드 가능 범위에 대한 거버넌스 정책이 작성됨.
- 메인넷 배포 체크리스트에 불변 경계 결정이 반영됨.
- CLMSR 메커니즘 변경이 필요할 경우 기존 Lib/모듈 업그레이드 대신 새 Lib+모듈 또는 Signals V2(새 주소) 롤아웃을 기본 전략으로 삼는다는 정책이 명시됨.

---

## 5. 정리

- Core:

  - **`SignalsCore`** 하나만 업그레이더블 UUPS proxy에 연결
  - 역할: 스토리지 + 권한 + 모듈 라우터

- 모듈:

  - `TradeModule`, `MarketLifecycleModule`, `LPVaultModule`, `RiskModule`, `OracleModule`은 모두 delegate 전용
  - 각 모듈은 `SignalsCoreStorage` 공유, Core 외부 함수를 통해서만 접근

- 토큰:

  - `SignalsPosition`은 v1 기준으로 깔끔한 storage layout을 갖는 ERC721 포지션 토큰
  - v0의 `CLMSRPosition`에서 `DEPRECATED` 필드는 제거

- 24KB:

  - Core는 얇게, heavy 로직은 모듈에 분리
  - 필요 시 Trade 모듈을 Exec/View로 추가 분할

- v0 → v1 마이그레이션:

  - Phase 0~3에서 v0 parity + 구조/스토리지 클린업
  - Phase 4~5에서 Risk/Vault layer 추가
  - Phase 6에서 메인넷용 immutable 경계 및 upgrade policy 확정

- 네이밍:

  - 외부에서 호출되는 Core 컨트랙트 이름은 **`SignalsCore`**를 사용한다.
  - `SignalsCoreV1`같은 suffix는 붙이지 않고, 버전 업은 **새 시스템/새 주소**로 관리한다.

이 문서를 그대로 `docs/signals-v1-architecture.md`와 유사한 형태로 저장해 두고,
추가 논의/구현이 진행되면서 각 Phase별로 구체적인 TODO(파일/심볼 단위)를 체크리스트로 확장해 나가면 된다.

- 이 문서에서 말하는 **Signals V1**은
  - Phase 0~3의 v0 동작 패리티 + 모듈화된 CLMSR 코어,
  - Phase 4~5에서 whitepaper 상 Risk / Vault / Backstop 레이어를 통합한 상태까지를 포함한다.
  - Phase 6은 이 V1 메커니즘을 기준으로 메인넷 immutable 경계와 거버넌스/업그레이드 정책을 확정하는 단계다.
