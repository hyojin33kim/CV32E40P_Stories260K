# ② 가속 전 기준선 — 비침습 프로파일 + 결과 동일 SW 최적화 (2026-11-13)

## 방법 (사실)
- `sim.cpp` 프로파일러(`SIM_PROF`): 매 cycle을 ID stage `pc_id`와 "현재 call site"(forward()/boot() 안의 마지막 PC)에 귀속.
  firmware에는 계측 코드 없음 → 계측 교란 0. callee(matmul, expf, softmax…) cycle은 호출한 forward() source line으로 집계.
- source line은 `-g` 빌드의 `addr2line -a -i` 최외곽 frame. `-g` 유무로 `.text` byte 동일함을 매 실행 assert.
- 메모리 접근: data request를 주소 class(Weight / KV / activation / RoPE / ctrl·stack)별로 count.
  pc 귀속은 EX의 load/store 다음 명령(ID) 기준이라 명령 1개 skew 있음. site(영역) 귀속에는 영향 없음.
- 정합성: 프로파일 합계 = firmware mcycle window − 11 cycles (cyc() 호출 자체), 3 case·4 변형 모두.
- 입력: HOLD와 동일한 ctx 1/128/512 single-step 케이스 (`kv_*.bin` 주입, 토큰 1).

## 결과 동일 SW 최적화 (bit-exact 확인)
| 변형 | ctx1 | ctx128 | ctx512 | .text B | logits+KV vs HOLD |
|---|---:|---:|---:|---:|---|
| `-Os` (HOLD baseline, 로컬 TC) | 3,119,977 | 5,783,258 | 13,847,235 | 2,708 | bit-exact |
| `-O2` | 2,561,436 | 4,425,529 | 10,092,980 | 3,360 | bit-exact |
| `-O3` | 2,623,292 | 4,484,701 | 10,136,914 | 3,768 | bit-exact |
| **`-O2 -funroll-loops` (채택)** | **1,454,872** | **3,039,675** | **7,854,557** | 10,360 | bit-exact |

FP 연산 순서를 바꾸는 최적화(fmadd contraction, 역수 곱셈, 재결합)는 적용하지 않음 → RISC-SW 수치 = HOLD 수치.
**이후 HW 가속 효과는 `-O2 -funroll-loops` 기준으로 비교한다.** (`-Os` 대비로는 약 2배 과대평가)

## 영역별 cycle — 채택 기준선 (`prof/O2u/table.md`)
| 영역 | ctx1 | ctx128 | ctx512 |
|---|---:|---:|---:|
| Weight GEMV 합 (W_qkv, W_o, W1/W3, W2, LM head) | 87.7% | 42.0% | 16.2% |
| └ FFN 블록 (W1/W3 + SwiGLU + W2) | 65.0% | 31.1% | 12.0% |
| Attention QK | 0.5% | 13.1% | 20.1% |
| softmax (expf 포함) | 0.4% | 28.8% | 44.9% |
| Attention AV | 0.8% | 10.6% | 16.0% |
| expf 합계 (softmax + SwiGLU) | 6.2% | 22.5% | 31.8% |

- GEMV 4.95 cycles/MAC (W1/W3: 544,494 / 110,080 MAC). QK 9.65, AV 7.68 cycles/MAC (ctx512).
- expf 1회 ≈ 117.5 cycles (softmax 내 20,480회 = 2,407,139 cycles, picolibc save/restore millicode 별도 15 cycles/회).
- 토큰당 Weight read = 260,032 words(≈1.04 MB, Weight당 1회). ctx512 KV read = 327,680 words(1.31 MB).
  activation read가 GEMV MAC당 1회 → 가속기는 x를 로컬 버퍼에 유지해야 함.

## Amdahl 상한 (해당 영역을 0 cycle로 만들 때, 채택 기준선 대비)
| 가속 범위 | ctx1 | ctx128 | ctx512 |
|---|---:|---:|---:|
| FFN 블록만 (11-08 결정) | 2.86× | 1.45× | 1.14× |
| Weight GEMV 전체 | 8.1× | 1.72× | 1.19× |
| GEMV + QK/AV | 9.0× | 2.9× | 2.1× |
| GEMV + QK/AV + softmax/exp | 9.4× | 17.8× | 36.3× |

(계산: 1 / (1 − 해당 비율). 실제 HW는 전송·제어 비용이 있어 이보다 낮음.)

## 판단에 주는 의미 (추정)
- 짧은 context(64토큰 이하 이야기)에서는 FFN/GEMV가 지배 → 11-08의 FFN 우선 결정과 정합.
- 긴 context에서는 attention과 **expf**가 지배. bit-exact 결정 하에서 HW exp는 picolibc `expf`와 bit 동일해야 하며,
  이는 SwiGLU 융합(FFN 가속기 내부)과 softmax 가속 모두의 전제 조건.

## 재현
```
MDIR=obj_prof ./build_sim.sh
python3 prof/run_prof.py baseline/firmware.c baseline
PROF_CFLAGS="-O2 -funroll-loops" python3 prof/run_prof.py baseline/firmware.c O2u
bash prof/run_opt_variants.sh        # baseline / O2 / O3
```
