# ③ FFN GEMV 가속기 + ④-a Attention QK/AV 재사용 (2026-11-13)

## 결론
- **bit-exact 유지**: FFN(W1/W3/W2) + Attention(QK, AV)을 가속기로 옮긴 후에도 logits·KV가 HOLD와 bit 동일
  (single-step ctx 1/128/512, 메모리 조건 24종 전부). E2E 연속 생성 결과는 아래 E2E 절 참조.
- **토큰당 가속 (SW 기준선 `-O2 -funroll-loops` 대비, 4 B/cycle, latency 0)**: ctx1 **1.82×**, ctx128 **1.64×**, ctx512 **1.55×**.
- 다음 병목: ctx512에서 softmax(expf) **68.9%**, QK 뒤 CPU 나눗셈 ≈ 0.42M cycles. → ④-b는 exp/나눗셈 HW.

## 설계 (사실)
| 항목 | 내용 |
|---|---|
| 연산 | `y[i] = Σ_j W[W_ADDR + i·W_STRIDE + j·J_STRIDE] · x[j]`, i<D, j<N (N≤512, D≤512) |
| 산술 | `cv32e40p_fp_wrapper` (CPU FPU와 동일 모듈, FP32, RNE, ADDMUL 지연 0) 2개: fmul → 레지스터 → fadd. 행마다 +0.0에서 j 순서로 누적 |
| bit-exact 근거 | C의 `val=0.0f; val+=w*x` / `score+=q*k` / `memset 0; xb+=a*v`와 연산 종류·순서·반올림이 동일. 곱셈 피연산자 순서 차이는 IEEE 곱셈 교환법칙(비 NaN)으로 동일 |
| 처리 순서 | x 로드(N reads) → W 스트림(D·N reads, 1 MAC/cycle) → y 쓰기(D writes) |
| 인터페이스 | MMIO 0x3000_0000 (CTRL/STATUS/X/W/Y/N/D/W_STRIDE/LAST_CYCLES/J_STRIDE), 메모리 master 1개(32-bit, 요청 1/cycle, in-order 응답) |
| SoC | `acc/soc_top.sv`: CV32E40P + gemv_acc, MMIO decode. 가속기 미사용 시 HOLD dump·cycles 동일 확인 |
| 펌웨어 | `gen/firmware_gen.c`: `-DUSE_ACC`(FFN), `-DUSE_ACC_ATTN`(QK/AV 추가). 미정의 시 코드 byte 동일 |
| 사용 방식 | FFN: W_STRIDE=4N, J_STRIDE=4 · QK: W=head의 K, W_STRIDE=4·kv_dim, J_STRIDE=4, 이후 CPU가 `/√8` · AV: W=head의 V, W_STRIDE=4, J_STRIDE=4·kv_dim |

## 결과 — single-step 영역별 (사실, `prof/acc_ffn_attn_L0_G1/table.md`)
| | SW 기준선 | FFN만 | FFN + QK/AV |
|---|---:|---:|---:|
| ctx1 cycles | 1,454,871 | 808,329 (1.80×) | **798,337 (1.82×)** |
| ctx128 | 3,039,674 | 2,388,880 (1.27×) | **1,852,500 (1.64×)** |
| ctx512 | 7,854,556 | 7,192,225 (1.09×) | **5,064,342 (1.55×)** |

영역별 (FFN + QK/AV, ctx512): FFN W1/W3 112,890 (이론 112,440+설정), W2 57,076 (이론 56,220+설정),
AV 186,320 (이론 184,640), QK 603,327 (HW ≈184K + CPU 나눗셈 ≈420K), softmax 3,490,124 (68.9%), SwiGLU 129,883 (CPU).

## 결과 — 메모리 조건 스윕 (사실, `acc/sweep/acc_ffn_attn_L0_G1/sweep.md`)
| ctx | L \ 대역폭 | 4 B/cycle | 2 B/cycle | 1 B/cycle |
|---|---|---:|---:|---:|
| 1 | L=0 | 1.82× | 1.50× | 1.11× |
| 1 | L=128 | 1.77× | 1.47× | 1.09× |
| 512 | L=0 | 1.55× | 1.40× | 1.18× |
| 512 | L=128 | 1.54× | 1.40× | 1.17× |

- 24개 조건 모두 bit-exact.
- 대역폭이 지배적, latency 영향은 작음. **단, sim 모델은 outstanding 무제한 pipelined 응답이라 latency 영향이 낙관적**(실제 AXI는 outstanding 제한).
- 단일 lane은 4 B/cycle만 필요. 11-08 분석의 ZCU104 PL DDR 실효 5~20 GB/s(200 MHz에서 25~100 B/cycle)를 가정하면
  현재 설계는 **연산 한계(1 MAC/cycle)** — 다음 레버는 MAC lane 수. 행 단위 병렬 lane은 각 행의 누적 순서를 유지하므로 bit-exact 유지 가능.

## E2E 연속 생성 (사실)
프롬프트 "Once upon a time", greedy, KV는 RISC가 누적. 판정 = 매 step logits·KV·토큰을 host와 비교(허용오차)
+ **`-Os` SW 실행과 512 step logits·KV·토큰 bit 비교** + host 단독 greedy와 토큰열 비교.

| 실행 | 총 cycles | 첫/마지막 step | vs SW 기준선 | bit 동일 vs -Os | host 토큰열 | 판정 |
|---|---:|---:|---:|---|---|---|
| 64 step SW 기준선 | 118,431,746 | 1,454,872 / 2,243,201 | — | True | 일치 | PASS |
| 64 step FFN 가속 | 76,976,406 | 808,329 / 1,594,563 | 1.54× | True | 일치 | PASS |
| 64 step FFN+QK/AV 가속 | 68,001,066 | 798,337 / 1,323,386 | **1.74×** | True | 일치 | PASS |
| 512 step SW 기준선 | 2,383,853,770 | 1,454,872 / 7,860,540 | — | True | 일치 | PASS |
| 512 step FFN 가속 (이력: J_STRIDE 이전 RTL, inline driver) | 2,048,327,882 | 809,763 / 7,194,991 | 1.16× | True | 일치 | PASS |
| 512 step FFN+QK/AV 가속 | 1,501,576,690 | 798,337 / 5,070,325 | **1.59×** | True | 일치 | PASS |

토큰당 평균(512 step): SW 4.66M → 가속 2.93M cycles.

최종 빌드 확인: 최종 RTL로 다시 빌드한 `obj_soc`에서 8 step 실행의 step별 cycles가 위 64 step 실행과 동일, bit-exact 유지.
가속기 미사용 시 SoC sim의 HOLD 회귀(ctx 1/128/512) dump byte 동일·cycles 동일.

## 가정 / 한계 (미검증 포함)
- FPU 지연 0(조합) 가정 — CV32E40P 설정(FPU_ADDMUL_LAT=0)과 동일. FPGA 200 MHz 타이밍은 **미검증**(합성·배치배선 안 함).
  파이프라인 FPU로 가면 행 interleave(지연 L만큼 행을 번갈아 처리)로 1 MAC/cycle 유지 + bit-exact 가능.
- 가속기 메모리 포트는 CPU 데이터 버스와 별도(경합 없음). x/y/KV도 같은 포트에서 읽음 — 실제 SRAM/DDR 분리 구조는 미반영.
- CPU는 가속 중 polling(대기). CPU-가속기 overlap 없음.
- `gen/out_512_O2u_acc_L0_G1`는 J_STRIDE 추가 이전 RTL·inline driver로 실행한 FFN-only 결과(이력용).

## 다음 (권고)
1. **④-b exp + 나눗셈 unit**: picolibc `sf_exp.c` 연산 순서를 같은 `cv32e40p_fp_wrapper`(DIV, F2I RTZ, I2F 포함)로 시퀀싱 →
   softmax(68.9%)와 SwiGLU, QK 나눗셈 대상. 검증: 대표 입력 + 범위 경계 RTL 비교, C 모델 2^32 전수.
2. **MAC lane 확장**: 행 병렬 P lane (P×4 B/cycle 필요). FFN/QK/AV 공통 이득.
3. **메모리 모델 현실화**: outstanding 제한·burst, x/KV 로컬 SRAM vs W DDR 분리 → ZCU104 PL DDR 수치로 재평가.
4. FPGA 합성으로 FPU 지연 0 경로 타이밍 확인 후 파이프라인 결정.

## 재현
```
TOP=soc_top ./build_sim.sh                     # obj_soc/Vsoc_top
MDIR=obj_prof ./build_sim.sh                   # 프로파일용 CPU 단독 sim
bash acc/run_attn_prof.sh                      # FFN / FFN+QK/AV single-step 영역 표
python3 acc/sweep_mem.py acc_ffn_attn_L0_G1    # 메모리 조건 스윕
bash acc/run_acc_e2e.sh                        # E2E 64/512 step (bit-exact vs -Os)
```
