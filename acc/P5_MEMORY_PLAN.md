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
- 11-14: 1~3단계 구현·측정 (아래 결과).

## 결과 (사실)

### 구현
| 항목 | 내용 |
|---|---|
| sim DDR/SRAM 모델 | `sim.cpp`, `SIM_DDR=1`로 활성(꺼져 있으면 기존 이상 모델과 동일 — HOLD·E2E 회귀 byte/cycle 동일 확인). 주소 < 0x100000(Weight) = DDR, 나머지 = on-chip SRAM. DDR: 첫 데이터 지연 `SIM_DDR_LAT`, 새 burst 시작 추가 `SIM_DDR_OVH`, 연속 line을 최대 `SIM_DDR_BURST` beat로 묶음, 지속 대역폭 `SIM_DDR_BW` B/cycle, **burst transaction 단위** outstanding 한계 `SIM_DDR_OUT`. 응답은 in-order. CPU의 DDR load도 지연(`SIM_CPU_DDR_LAT`, cache 없음, 1개씩) |
| 가속기 run fetch | `gemv_acc` `RUN` 파라미터(`ACC_RUN`): mode A에서 lane마다 연속 RUN line을 받은 뒤 다음 lane. lane별 데이터 순서 불변 → bit 동일. RUN=1은 기존 동작(이상 모델 cycles 동일 확인) |
| 펌웨어 옵션 | `-DRMS_SRAM`: RMSNorm Weight 704 words를 boot 시 SRAM으로 복사 · `-DEMB_WORDS`: embedding 행을 word 단위 복사(memcpy byte load 256 → 64). 미정의 시 기존 코드 byte 동일 |

### 단계별 효과 (full offload, ctx1 single step, 기본 DDR 파라미터 L40·OVH4·burst16·12.8 B/cycle·outstanding 8)
| 구성 | cycles | DDR burst 수 | 이상 SW 대비 |
|---|---:|---:|---:|
| 이상 메모리 (기존) | 121,958 | — | 11.93× |
| DDR, RUN=1 (line마다 lane 순환) | 456,698 | 511,913 (≈line 수) | 3.19× |
| DDR, RUN=16 | 179,568 | 33,216 | 8.10× |
| + RMS_SRAM | 151,518 | 33,216 | 9.60× |
| **+ EMB_WORDS** | **141,694** | 33,216 | **10.27×** |
| (참고) SW 기준선을 같은 DDR에서 | 11,996,585 | — | 0.12× |

- 원인: RUN=1은 4 lane이 서로 다른 행의 line을 번갈아 요청 → 주소 불연속 → burst가 형성되지 않고 outstanding 한계 × latency에 묶임.
- SW 기준선은 DDR에서 8.2배 느려짐(cache 없는 CPU가 Weight를 word마다 DDR에서 읽음) → 가속기의 실제 이득은 이상 SW 대비 값보다 큼.

### single step, DDR 최적 구성 (`prof/ddr_full_opt`, ctx 1/128/512, HOLD와 bit 동일)
| | 이상 SW | DDR SW | **DDR 가속** | 이상 SW 대비 | 이상 가속 대비 손실 |
|---|---:|---:|---:|---:|---:|
| ctx1 | 1,454,871 | 11,996,585 | **141,694** | 10.27× | 1.16× |
| ctx128 | 3,039,674 | 13,581,388 | **304,926** | 9.97× | 1.07× |
| ctx512 | 7,854,556 | 18,396,270 | **799,949** | 9.82× | 1.03× |

### E2E 64 step, 기본 DDR 파라미터 (logits·KV·토큰 `-Os`와 bit 동일, host 토큰열 일치)
| 실행 | 총 cycles | 이상 SW(118,431,746) 대비 |
|---|---:|---:|
| 가속, 이상 메모리 (`gen/out_64_O2u_accfull_l4v4_L0_G1`) | 10,466,504 | 11.32× |
| **가속, DDR** (`gen/out_64_O2u_accfull_l4v4r16_ddr_opt_L0_G1`) | **11,736,888** | **10.09×** |
| SW 기준선, DDR (`gen/ddr_sw/out_64_O2u`) | 793,101,378 | 0.15× |

같은 DDR 조건의 SW 대비 가속은 67.6×.

### DDR 파라미터 스윕 (`acc/sweep/ddr_ddr_full_opt/sweep.md`, 162 runs 전부 bit-exact)
| ctx | 최악 (L100·out4·burst4·8 B/c) | 기본 | 최선 |
|---|---:|---:|---:|
| 1 | 2.82× | 10.27× | 11.77× |
| 512 | 6.69× | 9.82× | 10.05× |

민감도 (ctx1, 해당 값의 평균): latency 20/40/100 → 9.77/9.09/7.14× · 대역폭 8/12.8/16 → 7.25/9.04/9.72× ·
burst 4/16/64 → 7.55/9.19/9.28× · outstanding 4/8/16 → 7.93/8.83/9.26×. ctx512는 VFU(softmax) 비중이 커서 덜 민감.

## 판단 (추정 포함)
- **burst ≥16 beat, outstanding ≥8 transaction, 지속 12.8 B/cycle(200 MHz에서 2.56 GB/s, HP 포트 이론의 80%) 이상**이면
  이상 모델 대비 손실 ≤16% — HW 설계 목표로 채택 권고.
- 가장 큰 미지수는 **실제 DDR latency** (보드 실측 필요, ⑤). latency 100 cycles(500 ns)이면 ctx1 ~7×.
  대응: 다음 명령 Weight prefetch(명령 간 overlap), lane FIFO 확대.
- KV·activation on-chip 배치 가정 유지(ctx512에서 KV를 DDR로 보내는 경우는 미평가).
- lane 4개 유지: 기본 조건에서 대역폭 여유 있음(평균 필요 ≈ 1.04 MB / 141,694 cycles ≈ 7.3 B/cycle).

## 남은 일
- 명령 간 prefetch(다음 GEMV의 Weight를 현재 명령 중 미리 요청) — 고 latency 대응.
- `ACC_RUN=16`, `RMS_SRAM`, `EMB_WORDS`를 기본으로 승격할지: 이상 모델 cycles가 바뀌므로(RUN=16: +1.4%) reproduce 기준값 재생성 필요.
- ⑤에서 DDR latency·대역폭 실측 → 이 모델 보정.
