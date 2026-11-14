# 가속 범위 확대 + MAC/VFU lane 병렬화, bit-exact (2026-11-14)

## 결론
- **모든 weight GEMV + Attention QK/AV + softmax(÷√8 융합) + SwiGLU를 가속, lane 병렬화 후에도 bit-exact.**
  single-step ctx 1/128/512 logits·KV가 HOLD와 bit 동일, 메모리 조건 24종 bit 동일, VFU 단위 테스트 불일치 0.
- **토큰당 (SW 기준선 `-O2 -funroll-loops` 대비, 16 B/cycle, latency 0)**:
  ctx1 **11.93×**, ctx128 **10.67×**, ctx512 **10.07×**.
- 기본 SoC 빌드 = gemv_acc 4 MAC lanes + vfu 4 lanes (tag `_l4v4`).

## 단계별 효과 (사실, single step cycles)
| 구성 | ctx1 | ctx128 | ctx512 | 기록 |
|---|---:|---:|---:|---|
| SW 기준선 | 1,454,871 | 3,039,674 | 7,854,556 | `prof/gen_O2u` |
| ④-b (FFN+QK/AV+VFU, 1 lane) | 728,297 | 1,272,041 | 2,925,226 | `prof/acc_all_L0_G1` |
| + Wq/Wk/Wv/Wo/LM head (`USE_ACC_MM`), 1 lane | 355,913 | 899,017 | 2,550,282 | `prof/acc_full_L0_G1` |
| + MAC 2 lanes | 226,343 | 728,847 | 2,257,192 | `prof/acc_full_lanes2` |
| + MAC 4 lanes | 161,278 | 643,622 | 2,110,367 | `prof/acc_full_lanes4` |
| + VFU 4 lanes | 122,452 | 358,088 | 1,072,271 | `prof/acc_nodiv_l4v4` |
| + ÷√8를 VFU softmax에 융합 (`USE_ACC_VFU_DIV`) | **121,958** | **284,910** | **780,213** | `prof/acc_full_l4v4` |

## 설계 (사실)
| 항목 | 내용 |
|---|---|
| MAC lanes | lane p = 행 i0+p. 행마다 j 순서·+0.0 시작 순차 누적 유지 → lane 수와 무관하게 bit 동일 |
| 메모리 포트 | 가속기 read 128-bit line(16B 정렬), write 32-bit. lane FIFO(128 words/lane) + credit |
| fetch 방식 | A: 행 연속(FFN/QK/LM head) — line = 한 행의 j 4개, lane 순환 · B: W_STRIDE=4(AV) — line = 같은 j의 4행 · C: 그 외 word 단위 |
| VFU lanes | 원소별 엔진 4개(`acc/vfu_lane.sv`, 각자 FPU 1개). softmax 합은 원소 순서대로 가산기 1개에서 순차 누적(bit-exact 조건) |
| ÷√8 융합 | CMD 5 divsoftmax: lane 병렬 나눗셈 → 순차 max scan → exp → 순차 합 → 나눗셈. CPU의 `/=` 루프 + softmax()와 동일 순서 |
| 파라미터 | `ACC_LANES`, `VFU_LANES` (build_sim.sh), `FDEPTH` |

## 메모리 조건 스윕 — 최종 구성 (사실, `acc/sweep/acc_full_l4v4`)
| ctx | L \ 대역폭 | 16 B/cycle | 8 B/cycle | 4 B/cycle |
|---|---|---:|---:|---:|
| 1 | L=0 | 11.93× | 7.40× | 4.21× |
| 1 | L=128 | 8.99× | 6.28× | 3.82× |
| 512 | L=0 | 10.07× | 7.71× | 5.26× |
| 512 | L=128 | 9.54× | 7.45× | 5.13× |

- lane FIFO 32 → 128 words로 latency 내성 개선(L=64, ctx1: 5.57× → 8.11×, MAC lanes 단독 구성).
- 남은 latency 영향은 작은 명령(QK/AV head별 등)마다 x 로드·첫 데이터 대기 — 메모리 모델 단계에서 다룸.

## E2E (사실, `gen/out_*_l4v4_L0_G1`)
- 8·64 step: acc / accattn / accall / accfull 모두 `-Os`와 logits·KV·토큰 bit 동일, host 토큰열 일치.

| 64 step | 총 cycles | vs SW 기준선 (118,431,746) |
|---|---:|---:|
| FFN (acc) | 69,050,646 | 1.72× |
| + QK/AV (accattn) | 59,100,146 | 2.00× |
| + VFU (accall) | 40,037,568 | 2.96× |
| 전부 (accfull) | **10,466,504** | **11.32×** |
- 512 step 최종 구성(accfull, l4v4): **231,588,051 cycles, SW 기준선 2,383,853,770 대비 10.29×**.
  512 step logits·KV·토큰 `-Os`와 bit 동일, host 단독 greedy와 토큰열 일치. 토큰당 평균 0.45M cycles.
- VFU 단위 테스트 (lane 빌드, `vfu/out/results.json`): exp·softmax·silu·divs·divsoftmax × 4 seed × 65,536
  = **1,310,720 원소, 불일치 0**.

## 한계 / 미검증
- FPGA 합성·타이밍 미검증: FPU 지연 0(조합) 가정, lane별 FPU 2개(GEMV)·1개(VFU) 면적 미평가.
- 메모리 모델: outstanding 무제한·line 단위 요청(burst 없음). PS DDR4(HP 포트) 수치 반영 전.
- `gen/out_*_acc*_L0_G1`, `prof/acc_*_L0_G1`은 lane 이전(32-bit 포트, 1 lane) 이력으로 reproduce.sh에서 재검사하지 않음.
