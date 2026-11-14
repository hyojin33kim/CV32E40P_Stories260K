# 메모리 모델 현실화 — 계획 (2026-11-14 착수)

## 목적
현재 10배 가속비는 낙관적 메모리 모델(16 B/cycle line을 매 cycle, outstanding 무제한, 모든 데이터가 같은 포트)
기준이다. ZCU104에서 Weight를 PS DDR4에서 읽을 때 남는 가속비를 구하고, lane 수·KV 배치·prefetch 구조를
결정한다. **수치 결과(bit-exact)는 바뀌지 않고 timing만 바뀐다.**

## 가정 (보드 실측 전, 출처 표시)
| 항목 | 가정 | 출처/상태 |
|---|---|---|
| PL clock | 200 MHz | 11-08 Notion 초기 설계 목표 (Fmax 미검증) |
| Weight 경로 | PS DDR4 → PS HP 포트(128-bit), 이론 3.2 GB/s/포트 = 16 B/cycle, 효율 70~80% | 11-08 Notion(HP 포트 최대 128-bit, 효율 80% 가정) |
| DDR read latency | 20~40 cycles (100~200 ns) | 추정 — ⑤에서 실측 필요 |
| outstanding read | 4 / 8 / 16 (변수) | 미확인 → 스윕 |
| burst | 4 / 16 / 64 beats (변수) | AXI4 INCR 최대 256 beats, 실제 값은 설계 선택 |
| 배치 | Weight(1.04 MB)는 DDR, **KV(640 KB)·activation은 on-chip SRAM** | 권고(KV는 매 step 재사용, on-chip 수용). 11-08은 Weight만 외부로 결정 |
| 사용자 결정 | PL DDR 도터보드 미사용, 보드 기본 메모리 사용 | 11-14 (해석: PS DDR4) |

## 대역폭 사전 계산 (추정)
- ctx1 토큰당 122K cycles 동안 Weight 1.04 MB → 평균 **8.5 B/cycle (1.7 GB/s @200 MHz)** 필요.
- HP 포트 이론 16 B/cycle의 53% → 가능하지만 여유가 크지 않음. 기존 스윕 8 B/cycle에서 7.4× →
  현실 범위 **7~10×** 예상(측정 전).

## 작업
1. sim 메모리 포트 분리: DDR 포트(AXI형: burst·latency·outstanding 제한·효율) + 로컬 SRAM 포트(1 cycle, 넓음).
   주소 영역으로 선택(Weight 영역 → DDR, KV/activation → SRAM).
2. 가속기 fetch 현실화: AXI burst 요청(행이 연속: 256 B / 688 B), 다음 명령 Weight **prefetch**
   (명령 queue 또는 preload 레지스터).
3. 스윕: latency 20/40/100 × outstanding 4/8/16 × burst 4/16/64 × 효율 70/80/100%,
   ctx 1/128/512 single step + E2E 64 step. 모든 조건 bit-exact 확인.
4. 산출: 현실 가속비 범위, lane 4개 적정성, KV 배치·prefetch 구조 결정 → ② FPGA 설계 입력.

## 판단이 바뀌는 조건
- 실측 DDR 효율이 50% 미만이면(8 B/cycle 미만) lane 4개는 과잉 → lane 2개 또는 Weight 압축(INT8 등, bit-exact 기준 재정의 필요) 검토.
- KV를 on-chip에 둘 수 없으면(URAM 부족 등 — XCZU7EV 용량은 합성 시 확인) KV도 DDR → ctx512 성능 재평가.

## 진행 기록
- 11-14: 계획 수립. Vivado 사용 불가 확인(H: 드라이브 미연결) — 합성은 ② 단계에서.
