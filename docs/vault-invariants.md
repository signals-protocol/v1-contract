# Vault Invariants & TDD Checklist (Phase 4-0)

This document captures the invariants and test strategy for the Vault accounting system.
Use it to guide implementation in `VaultAccountingLib.sol` and related modules.

## Scope

- Libraries: `VaultAccountingLib`
- State structs: `VaultState`, `VaultQueue`, `CapitalStackState`
- Modules: `LPVaultModule`
- Entry points: `processDailyBatch`, `requestDeposit`, `requestWithdraw`, `processDeposit`, `processWithdraw`

---

## 1. Daily P&L Spine (Sec 3, Appendix A.2)

### 1.1 수식 정의

| 변수             | 정의                                   | 단위     |
| ---------------- | -------------------------------------- | -------- |
| `N_{t-1}`        | 전일 NAV                               | WAD      |
| `L_t`            | 당일 P&L (signed, 음수 가능)           | WAD      |
| `F_t`            | 당일 LP Vault 귀속 수수료              | WAD      |
| `G_t`            | Backstop Grant (손실 보전 지원금)      | WAD      |
| `Π_t`            | 당일 총 income = `L_t + F_t + G_t`     | WAD      |
| `N_pre,t`        | 배치 전 NAV = `N_{t-1} + Π_t`          | WAD      |
| `S_{t-1}`        | 전일 총 shares                         | WAD      |
| `P_e,t`          | 배치 가격 = `N_pre,t / S_{t-1}`        | WAD      |
| `D_t`, `W_t`     | 당일 deposit/withdraw 금액 (pending)   | WAD      |
| `d_t`, `w_t`     | 당일 발행/소각 shares                  | WAD      |
| `N_t`            | 배치 후 NAV = `N_pre,t + D_t - W_t`    | WAD      |
| `S_t`            | 배치 후 shares = `S_{t-1} + d_t - w_t` | WAD      |
| `P_t`            | 배치 후 가격 = `N_t / S_t`             | WAD      |

### 1.2 인바리언트

#### INV-V1: Pre-batch NAV 계산
```
N_pre,t = N_{t-1} + L_t + F_t + G_t
```
- **보장 함수**: `VaultAccountingLib.computePreBatch()`
- **테스트 검증**: 
  - Given: `(navPrev=1000e18, L=-50e18, F=30e18, G=10e18)`
  - Expected: `N_pre = 990e18`
  - Tolerance: 0 (exact arithmetic)

#### INV-V2: Batch 가격 불변
```
P_e,t = N_pre,t / S_{t-1}  (S_{t-1} > 0)
```
- **보장 함수**: `VaultAccountingLib.computePreBatch()`
- **테스트 검증**:
  - Given: `(N_pre=990e18, sharesPrev=900e18)`
  - Expected: `P_e = 1.1e18`
  - Tolerance: 1 wei (rounding)

#### INV-V3: Shares=0 초기화 (Seeding)
```
IF S_{t-1} == 0 AND isSeeded == false:
  require first deposit >= MIN_SEED_AMOUNT
  set isSeeded = true
  P_e = 1e18 (initial price = 1.0)
```
- **보장 함수**: `LPVaultModule._seedVault()`, `VaultAccountingLib.computePreBatch()`
- **테스트 검증**:
  - First deposit with `D >= MIN_SEED_AMOUNT` succeeds, sets `isSeeded=true`
  - Subsequent batch with `S > 0` computes `P_e` normally
  - Attempt deposit before seed → revert `VaultNotSeeded()`

---

## 2. Deposit & Withdraw (Sec 3.2)

### 2.1 수식 정의

| 연산    | NAV 변화                | Shares 변화           | 가격 보존 조건             |
| ------- | ----------------------- | --------------------- | -------------------------- |
| Deposit | `N' = N + D`            | `S' = S + D/P`        | `N'/S' = P` (within 1 wei) |
| Withdraw| `N'' = N - x·P`         | `S'' = S - x`         | `N''/S'' = P` (within 1 wei)|

### 2.2 인바리언트

#### INV-V4: Deposit 가격 보존
```
After deposit D at price P:
  N' = N + D
  S' = S + D/P
  |N'/S' - P| <= 1 wei
```
- **보장 함수**: `VaultAccountingLib.applyDeposit()`
- **테스트 검증**:
  - Given: `(N=1000e18, S=1000e18, P=1e18, D=100e18)`
  - Expected: `(N'=1100e18, S'=1100e18)`
  - Verify: `|N'/S' - P| <= 1`

#### INV-V5: Withdraw 가격 보존
```
After withdraw x shares at price P:
  N'' = N - x·P
  S'' = S - x
  |N''/S'' - P| <= 1 wei
```
- **보장 함수**: `VaultAccountingLib.applyWithdraw()`
- **테스트 검증**:
  - Given: `(N=1000e18, S=1000e18, P=1e18, x=50e18)`
  - Expected: `(N''=950e18, S''=950e18)`
  - Verify: `|N''/S'' - P| <= 1`

#### INV-V6: 출금 상한
```
x <= S (cannot withdraw more shares than exist)
x·P <= N (cannot withdraw more NAV than exists)
```
- **보장 함수**: `VaultAccountingLib.applyWithdraw()`
- **테스트 검증**: 
  - Attempt `x > S` → revert `InsufficientShares()`
  - Attempt `x·P > N` → revert `InsufficientNAV()`

---

## 3. Peak & Drawdown (Sec 3.4)

### 3.1 수식 정의

| 변수         | 정의                            | 단위  |
| ------------ | ------------------------------- | ----- |
| `P_peak,t`   | `max_{τ≤t} P_τ` (역대 최고가)   | WAD   |
| `DD_t`       | `1 - P_t / P_peak,t` (Drawdown) | WAD   |

### 3.2 인바리언트

#### INV-V7: Peak 단조 증가
```
P_peak,t >= P_peak,{t-1}  (peak never decreases)
P_peak,t = max(P_peak,{t-1}, P_t)
```
- **보장 함수**: `VaultAccountingLib.updatePeak()`
- **테스트 검증**:
  - Sequence: `P = [1.0, 1.2, 1.1, 1.3]`
  - Expected peaks: `[1.0, 1.2, 1.2, 1.3]`

#### INV-V8: Drawdown 범위
```
0 <= DD_t <= 1e18  (0% to 100%)
DD_t = 0 when P_t == P_peak,t
DD_t = 1e18 - (P_t * 1e18 / P_peak,t)
```
- **보장 함수**: `VaultAccountingLib.computeDrawdown()`
- **테스트 검증**:
  - `P_t = P_peak = 1e18` → `DD = 0`
  - `P_t = 0.8e18, P_peak = 1e18` → `DD = 0.2e18` (20%)
  - `P_t = 0, P_peak > 0` → `DD = 1e18` (100%)

---

## 4. Queue Processing (Sec 3.3)

### 4.1 큐 상태 구조

```solidity
struct VaultQueue {
    uint256 pendingDeposits;    // 대기 중 입금 총액
    uint256 pendingWithdraws;   // 대기 중 출금 shares 총량
    uint64  lastBatchTimestamp; // 마지막 배치 처리 시각
}
```

### 4.2 인바리언트

#### INV-V9: 배치 순서 보장
```
Withdraws processed before deposits within same batch
```
- **보장 함수**: `LPVaultModule.processDailyBatch()`
- **테스트 검증**:
  - Given pending `(W=100e18, D=200e18)` at price `P=1e18`
  - Process order: withdraw first, then deposit
  - Final state consistent with sequential application

#### INV-V10: D_lag 강제
```
Request at time T cannot be processed before T + D_lag
D_lag defined in governance parameters
```
- **보장 함수**: `LPVaultModule.requestDeposit()`, `LPVaultModule.requestWithdraw()`
- **테스트 검증**:
  - Request at `T=100`, `D_lag=86400`
  - Process attempt at `T=100 + 86399` → revert `WithdrawLagNotMet()`
  - Process at `T=100 + 86400` → success

#### INV-V11: 큐 잔액 일관성
```
After batch:
  pendingDeposits -= processedDeposits
  pendingWithdraws -= processedWithdraws
  
Sum of individual user pending == total pending
```
- **보장 함수**: `VaultQueue` state updates
- **테스트 검증**:
  - Multiple users request deposits/withdraws
  - After batch, sum of remaining user pending equals queue totals

---

## 5. Capital Stack Integration (Sec 4.3-4.6)

### 5.1 Fee Waterfall 상호작용

| 변수    | 정의                                        |
| ------- | ------------------------------------------- |
| `F_LP`  | LP Vault 귀속 수수료 (ϕ_LP 비율)            |
| `F_BS`  | Backstop 귀속 수수료 (ϕ_BS 비율)            |
| `F_TR`  | Treasury 귀속 수수료 (ϕ_TR 비율)            |
| `G_t`   | Backstop → LP Grant (손실 보전)             |

### 5.2 인바리언트

#### INV-V12: Grant 한도
```
G_t <= B_{t-1}  (Grant cannot exceed Backstop NAV)
B_t = B_{t-1} + F_BS - G_t >= 0
```
- **보장 함수**: `FeeWaterfallLib.apply()`
- **테스트 검증**:
  - Attempt `G > B_prev` → revert `BackstopInsufficientForGrant()`
  - After grant: `B_t >= 0` always

#### INV-V13: Fee 분배 합산
```
F_LP + F_BS + F_TR = F_pool  (잔여 수수료 풀 완전 분배)
ϕ_LP + ϕ_BS + ϕ_TR = 1e18  (비율 합 = 100%)
```
- **보장 함수**: `FeeWaterfallLib.apply()`
- **테스트 검증**:
  - Given `F_pool = 1000e18`, ratios `(0.5, 0.3, 0.2)`
  - Expected: `F_LP=500e18, F_BS=300e18, F_TR=200e18`
  - Sum check: `F_LP + F_BS + F_TR = F_pool`

---

## 6. 테스트 전략

### 6.1 단위 테스트 (`test/unit/vault/`)

| 파일                         | 대상                    | 인바리언트              |
| ---------------------------- | ----------------------- | ----------------------- |
| `VaultAccountingLib.spec.ts` | 순수 수학 라이브러리    | INV-V1~V8               |
| `VaultQueue.spec.ts`         | 큐 상태 관리            | INV-V9~V11              |

### 6.2 통합 테스트 (`test/integration/vault/`)

| 파일                    | 대상                          | 인바리언트        |
| ----------------------- | ----------------------------- | ----------------- |
| `VaultBatchFlow.spec.ts`| Module + Lib 상호작용         | INV-V1~V13        |

### 6.3 E2E 테스트 (`test/e2e/vault/`)

| 파일                      | 대상                              | 시나리오                          |
| ------------------------- | --------------------------------- | --------------------------------- |
| `VaultWithMarkets.spec.ts`| Vault + Market P&L 연동           | 시장 손익 → Vault NAV 반영        |

### 6.4 Property-based / Fuzz 테스트

- `VaultAccountingLib` pure functions: 
  - 임의 입력에 대해 price preservation 검증
  - Overflow/underflow 경계 테스트
- `processDailyBatch`:
  - 임의 deposit/withdraw 시퀀스에 대해 invariant 유지 검증

---

## 7. 허용 오차 (Tolerance)

| 연산              | 허용 오차    | 근거                           |
| ----------------- | ------------ | ------------------------------ |
| NAV 계산          | 0 wei        | 정수 덧셈/뺄셈                 |
| Price 계산        | 1 wei        | WAD 나눗셈 반올림              |
| Price preservation| 1 wei        | 연쇄 연산 누적 오차            |
| Drawdown 계산     | 1 wei        | WAD 나눗셈 반올림              |

---

## 8. 구현 순서 (TDD 흐름)

1. **Phase 4-0**: 본 문서 + 테스트 스켈레톤 (현재)
2. **Phase 4-1**: `VaultAccountingLib` 구현 + 단위 테스트 통과
3. **Phase 4-2**: `VaultState` 스토리지 + `isSeeded` 로직
4. **Phase 4-3**: `VaultQueue` 구현 + 큐 테스트 통과
5. **Phase 4-4**: `LPVaultModule.processDailyBatch()` 구현 + 통합 테스트 통과
6. **Phase 4-5**: E2E 테스트 (Market 연동) 통과

---

## Appendix: Error Codes

| 에러 코드                      | 조건                                      |
| ------------------------------ | ----------------------------------------- |
| `VaultNotSeeded()`             | `shares == 0 && !isSeeded` 상태에서 연산  |
| `InsufficientShares()`         | `withdrawShares > totalShares`            |
| `InsufficientNAV()`            | `withdrawAmount > nav`                    |
| `WithdrawLagNotMet()`          | `block.timestamp < requestTime + D_lag`   |
| `BackstopInsufficientForGrant()`| `grantAmount > backstopNav`              |
| `InvalidFeeRatios()`           | `ϕ_LP + ϕ_BS + ϕ_TR != 1e18`              |
| `ZeroPriceNotAllowed()`        | `price == 0` in operations                |

