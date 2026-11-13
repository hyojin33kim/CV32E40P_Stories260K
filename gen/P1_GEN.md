# ① RISC 단독 연속 생성 — PASS (2026-11-13)

## 무엇을 검증했나
- CV32E40P(RV32IMFC+FPU) RTL sim에서 llama2.c `generate()`와 같은 루프를 실행: 프롬프트 "Once upon a time"(BOS 포함 5 토큰)
  → greedy 생성, **KV cache를 RISC가 직접 누적**. `forward()`는 HOLD baseline과 동일 소스.
  BOS에서 멈추지 않고 512 위치(최대 context)까지 진행해 KV 전체를 사용.
- host 기준(llama2.c `run.c` 무수정): RISC가 고른 토큰으로 teacher-forcing하여 **매 step logits**, 최종 **위치별 KV**,
  argmax를 비교. 별도로 host 단독 greedy 실행과 토큰열 비교.
- 컴파일 플래그 독립성: `-Os`(HOLD) 빌드와 `-O2 -funroll-loops`(② SW 기준선) 빌드의 RISC logits(512 step 전부)·KV·토큰이 **bit 동일**한지 비교.

## 결과 (사실)
| 실행 | 총 cycles | 첫/마지막 step | logits 상대L2 max | KV 상대L2 max | 최소 top1-top2 | bit 동일 vs -Os | 판정 |
|---|---:|---:|---:|---:|---:|---|---|
| 64 step, -Os | 242,027,879 | 3,119,978 / 4,441,938 | 1.03e-6 | 2.67e-7 | 0.0711 | (기준) | PASS |
| 64 step, -O2 -funroll-loops | 118,431,746 | 1,454,872 / 2,243,201 | 1.03e-6 | 2.67e-7 | 0.0711 | **True** | PASS |
| 512 step, -Os | 4,343,226,850 | 3,119,978 / 13,849,819 | 3.54e-6 | 5.99e-7 | 0.0026 | (기준) | PASS |
| 512 step, -O2 -funroll-loops | 2,383,853,770 | 1,454,872 / 7,860,540 | 3.54e-6 | 5.99e-7 | 0.0026 | **True** | PASS |

- 모든 실행에서 argmax 불일치 0, RISC 토큰 = RISC logits의 argmax, host 단독 greedy와 토큰열 완전 일치.
- host↔RISC logits·KV는 bit 동일이 아님(합의된 허용오차 기준 통과). 원인 추정: host glibc `expf`/`sqrtf` vs picolibc.
- 생성문(512 step): "Once upon a time, there was a little girl named Lily. ... You are a good friend."<BOS>Once upon a time, ... (두 번째 이야기)
- 토큰당 평균 cycles(512 step, SW 기준선): 4.66M. 64 step: 1.85M.
- sim 속도 약 0.58M cycles/s (512 step -O2u 4,117 s, -Os 7,486 s).

## 이후 기준
- ③ 가속 효과의 E2E 비교 기준: `gen/out_512_O2u`, `gen/out_64_O2u` (`cycles.npy`에 step별 cycles).
- RISC-SW 수치(bit-exact 기준)는 플래그와 무관함이 확인됨 → HW 경로는 이 수치와 bit 동일해야 함.

## 실행
```
python3 gen/run_gen.py 64                    # SW 기준선 플래그 (out_64_O2u)
GEN_CFLAGS="" python3 gen/run_gen.py 64      # -Os (out_64_Os)
bash gen/run_sw_baseline.sh                  # 64 + 512 step, -Os 결과와 bit 비교
```

## 미검증
- 프롬프트는 1종만 사용. temperature/top-p sampling은 미구현(greedy만).
- `reproduce.sh` 일괄 실행과 calibration bench 재실행은 하지 않음.
