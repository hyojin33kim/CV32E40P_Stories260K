# G0 — HOLD 재현 환경 복구 (2026-11-13)

결과: **PASS.** 이 PC(WSL2 Ubuntu 24.04)에서 HOLD 결과 재현 확인.

## 환경
| 항목 | HOLD 기록 | 이 PC |
|---|---|---|
| RISC-V GCC | 14.2.0 + picolibc prefix | apt gcc-riscv64-unknown-elf 13.2.0 |
| picolibc | (버전 미기록) | apt picolibc-riscv64-unknown-elf 1.8.6 |
| Verilator | 5.032 | 5.038 |
| host cc (reference.c) | 미기록 | gcc 13.3.0 |

## 확인 결과
1. **RTL sim 재현 (저장된 baseline ELF 사용):** 3 case 모두 2 MiB DATA dump가 기존 `base_*.bin`과 byte 동일.
   firmware 측정 cycles 3,119,811 / 5,778,780 / 13,842,513 — results.json과 동일.
   sim `DONE cycles=`는 이보다 8,787 큰 상수 (boot/종료 경로 포함, firmware 측정 window 아님).
2. **host reference 재현:** `ref_*`, `kv_*`, `after_kv_*` 9개 파일 byte 동일.
3. **로컬 툴체인 재빌드 (`TC=/usr`):** `g0/run_tc.sh` → validate.py PASS.
   - logits·전체 KV: 기존 결과와 **bit 동일** (3 case).
   - `.text` baseline 2,676→2,708 B, profile 2,804→2,828 B.
   - cycles baseline 3,119,977 / 5,783,258 / 13,847,235 (+0.01~0.08%). exp window raw 동일.
   - 상세: `g0/results_local_tc.json`.

## 이후 기준
- 이후 작업(①~)의 SW 기준선은 **로컬 툴체인 수치**(`g0/results_local_tc.json`)를 사용. HOLD 수치와의 차이는 위 컴파일러 차이로 설명됨.
- 수정: 스크립트 실행 권한 복구(Windows 복사로 소실), `build.sh` 기본 `TC=/usr`.

## 미검증
- `reproduce.sh` 전체를 한 번에 실행하지 않음 (tracked 파일을 덮어쓰므로). 구성 단계별로 동일 내용을 실행해 확인함.
- calibration bench(`bench.c`) 재실행은 하지 않음 (기존 bench_out.bin 사용, HOLD와 동일 방침).
