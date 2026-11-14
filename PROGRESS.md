# CV32E40P Stories260K — 진행 기록 (index)

목표: llama2.c Stories260K를 CV32E40P(RV32IMFC+FPU) RISC 단독으로 실행 → 대표 연산을 HW로 교체 →
**RISC-SW와 bit-exact**를 유지하며 가속 → ZCU104 통합.

기록 원칙: 구현·테스트 결과는 이 저장소(GitHub)가 최종 근거, 승인된 결정·이력은 Notion
(`업무 / LLM HW Architecture`). 수치는 모두 이 저장소의 실행 결과에서 옮긴 것.

## 단계별 기록
| 단계 | 날짜 | 결과 | 상세 기록 | 결과 데이터 |
|---|---|---|---|---|
| HOLD | ~11-13 | forward 1 step RTL 실행(ctx 1/128/512), host와 비교 | `CHECKPOINT_KO.md` | `results.json`, `base_*.bin` |
| G0 재현 환경 | 11-13 | 로컬 툴체인으로 HOLD byte 동일 재현 | `g0/G0_REPRO.md` | `g0/results_local_tc.json` |
| ① 연속 생성 | 11-13 | 512 step 생성 PASS, host greedy와 토큰열 일치 | `gen/P1_GEN.md` | `gen/out_*_Os`, `gen/out_*_O2u` |
| ② 기준선 | 11-13 | 비침습 프로파일러, SW 기준선 `-O2 -funroll-loops`(bit 동일, −43~53%) | `prof/P2_PROFILE.md` | `prof/O2u`, `prof/gen_O2u` |
| ③ FFN GEMV 가속 | 11-13 | CPU와 같은 FPU 모듈 재사용 → bit-exact, ctx1 1.80× | `acc/P3_ACC.md` | `prof/acc_ffn_L0_G1` |
| ④-a QK/AV | 11-13 | 같은 엔진 stride 재사용, ctx512 1.55× | `acc/P3_ACC.md` | `prof/acc_ffn_attn_L0_G1` |
| ④-b VFU | 11-14 | softmax·SiLU·expf HW(picolibc sf_exp 연산 순서), 1M 원소 불일치 0 | `acc/P4B_VFU.md` | `prof/acc_all_L0_G1`, `vfu/` |
| 범위 확대 + lanes | 11-14 | 모든 GEMV, MAC 4 lanes, VFU 4 lanes, ÷√8 융합 → **11.93×/10.67×/10.07×**, E2E 512 step **10.29×** | `acc/P4C_LANES.md` | `prof/acc_full_l4v4`, `gen/out_512_O2u_accfull_l4v4_L0_G1` |
| 메모리 모델 현실화 | 11-14 | DDR/SRAM sim 모델, burst run fetch, RMS·embedding 최적화 → DDR에서도 **10.27×/9.97×/9.82×**, E2E 64 step **10.09×**, 스윕 162 조건 bit-exact | `acc/P5_MEMORY_PLAN.md` | `prof/ddr_full_opt`, `acc/sweep/ddr_ddr_full_opt`, `gen/out_64_O2u_accfull_l4v4r16_ddr_opt_L0_G1` |

## 현재 성능 (사실, SW 기준선 대비, 가속기 포트 16 B/cycle, latency 0)
| | SW 기준선 cycles | 최종 가속 cycles | 배율 | bit-exact |
|---|---:|---:|---:|---|
| single step ctx1 | 1,454,871 | 121,958 | 11.93× | HOLD와 동일 |
| single step ctx128 | 3,039,674 | 284,910 | 10.67× | HOLD와 동일 |
| single step ctx512 | 7,854,556 | 780,213 | 10.07× | HOLD와 동일 |
| E2E 512 step | 2,383,853,770 | 231,588,051 | 10.29× | `-Os`와 동일 |

DDR 모델(Weight는 DDR: latency 40, burst 16, 12.8 B/cycle, outstanding 8 / KV·activation은 SRAM) 적용 시:

| | 이상 SW cycles | DDR 가속 cycles | 배율 | bit-exact |
|---|---:|---:|---:|---|
| single step ctx1 | 1,454,871 | 141,694 | 10.27× | HOLD와 동일 |
| single step ctx512 | 7,854,556 | 799,949 | 9.82× | HOLD와 동일 |
| E2E 64 step | 118,431,746 | 11,736,888 | 10.09× | `-Os`와 동일 |

DDR 조건 스윕 범위: ctx1 2.82×(latency 100·outstanding 4·burst 4·8 B/c) ~ 11.77×. 최대 미지수는 실제 DDR latency(⑤ 실측).

## 사용자 결정 이력
| 날짜 | 결정 |
|---|---|
| 11-08 | FFN(W1/W3→SwiGLU→W2) 우선 가속, Weight는 외부 메모리에서 재로딩 (Notion) |
| 11-13 | 목표 FPGA ZCU104 / 동일성 = bit-exact / 성능 목표 없음 / FP32 우선 |
| 11-13 | 승인은 사용자만 아는 정보만 질문, 반복 yes/no 금지 |
| 11-14 | PL DDR 도터보드 미사용 → 보드 기본 메모리(해석: PS DDR4) / ⑤ ZCU104 통합 대기 |
| 11-14 | 순서: ④-b → MAC lane → 메모리 모델 현실화 |

## 재현
`./reproduce.sh [quick|standard|full]` — 결과는 `repro/`, 커밋된 값과 비교(`reproduce_check.py`).
마지막 확인: 11-14 `standard` 29/29 OK (main `f46934d` 기준).

## 환경 메모
- RISC-V: apt gcc-riscv64-unknown-elf 13.2 + picolibc 1.8.6, Verilator 5.038 (WSL2 Ubuntu 24.04).
- Vivado: `~/bin/vivado`는 Windows Vivado 2026.1(`H:\2026.1\Vivado\bin\vivado.bat`) wrapper, `/mnt/<drive>` 아래에서만 실행.
  11-14 확인 시 Windows에 **H: 드라이브 없음**(C:, E:, F:만 연결) → 현재 사용 불가.
  `C:\Xilinx`에는 Vivado_Lab(Lab Edition)과 설치기(xic)만 있음. H: 연결 후 `cd /mnt/c && vivado -version`으로 확인.

## 남은 일 (권장 순서, 11-14 기준)
1. **메모리 모델 후속**
   - 명령 간 Weight prefetch — 고 latency 대응(스윕: latency 100 cycles에서 ctx1 ≈7×).
   - `ACC_RUN=16`·`RMS_SRAM`·`EMB_WORDS` 기본 승격(권고). 이상 모델 cycles +1.4% → reproduce 기준값 재생성 필요.
   - DDR 조건 E2E 512 step 측정.
2. **FPGA 합성·타이밍·면적 (Vivado)** — FPU 지연 0(조합) 가정의 200 MHz 검증, 실패 시 FPU 파이프라인 + 행 interleave로
   bit-exact 유지. FPU 13개(나눗셈기 포함) XCZU7EV 면적 확인. **필요: Windows H: 드라이브 연결.**
3. **선택 최적화** — ctx512 softmax 66~69%(VFU lane 8개 또는 exp 파이프라인), CPU 잔여(rmsnorm·RoPE·residual, ctx1 ≈15%) overlap.
4. **검증 보강(선택)** — 다중 프롬프트, temperature·top-p sampling, expf 2³² 전수 비교.
5. **⑤ ZCU104 통합** — 대기. DDR latency·대역폭 실측으로 메모리 모델 보정.

## 미검증
- FPGA 타이밍·면적(합성 안 함), 실제 DDR 수치(현재 가정값), 다중 프롬프트·sampling.
- E2E 512 step은 이상 메모리 조건만 측정(DDR 조건 미측정).

## 기록 위치
- 이 파일(`PROGRESS.md`): 현재 상태의 단일 원본 — 단계가 끝날 때마다 갱신.
- 단계별 상세: 위 표의 기록 파일.
- Notion(`업무 / LLM HW Architecture`): 승인된 결정·이력·교훈. 상태 표는 이 파일을 링크.
