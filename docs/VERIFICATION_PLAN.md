# 검증 계획서 (Verification Plan)

이 파일은 `docs/gen_verification_plan.py`가 생성한다(데이터 원본은 그 스크립트). 같은 내용이 `docs/VERIFICATION_PLAN.xlsx`에 있다. 직접 고치지 말고 스크립트를 고친 뒤 다시 실행한다.

"통과"는 **시뮬레이션 또는 합성 보고서에서 통과**했다는 뜻이다. **보드에서는 아무것도 실행하지 않았다.**

## 1. 요약

전체 40개: 통과 22, 부분 1, 미실행 14, 미정 2, 제외 1

| 단계 | 통과 | 부분 | 미실행 | 미정 | 제외 |
|---|---|---|---|---|---|
| L0 도구 점검 | 3 | 0 | 0 | 0 | 0 |
| L1 단위 | 5 | 1 | 0 | 0 | 0 |
| L2 통합 | 11 | 0 | 1 | 1 | 0 |
| L3 타이밍 | 3 | 0 | 0 | 0 | 1 |
| L4 합성 후 | 0 | 0 | 1 | 0 | 0 |
| L5 보드 | 0 | 0 | 6 | 0 | 0 |
| 격차 | 0 | 0 | 6 | 1 | 0 |

## 2. 게이트

| 게이트 | 조건 | 현재 |
|---|---|---|
| Gate A: 시뮬레이션 완료 | L0~L2 전 항목 통과, quick 42/42, xsim 일치 | 대부분 통과. V-U2, V-P3 부분/미실행, V-N1 기준 미정 |
| Gate B: 합성 후 확인 | V-M1~M3 통과 + V-S1 통과 | V-M 통과, V-S1 미실행 |
| Gate C: 보드 확인 | V-B0~B5 통과(DONE_V, CYCLES, 2 MiB 덤프 일치) | 미실행 |

## 3. 검증 항목 (단계별)

### L0 도구 점검

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-T1 | 도구 | xsim 신뢰도 점검(FPU) | 1,402 벡터(numpy IEEE 기준)를 FPU RTL과 합성 네트리스트에 입력 | 1,402/1,402 일치 | fpga/xsim/run_fpu_test.sh, run_fpu_verilator.sh | 통과 | 우회 패치 후 RTL 1402/1402, 네트리스트 1402/1402 (패치 전 671/1402) | xsim 결과를 믿기 전에 매번 먼저 실행(LESSONS_LEARNED C단계) |
| V-T2 | 도구 | 시뮬레이션 환경 빌드 | CPU, CPU 프로파일러, SoC 시뮬레이터 빌드 | 빌드 성공 | reproduce.sh 첫 단계 | 통과 | reproduce.sh quick 42/42 | Ubuntu 24.04, verilator 5.038, riscv64 gcc + picolibc |
| V-T3 | 도구 | 시험이 틀림을 잡는지(변이 시험) | 기대값 또는 RTL을 일부러 훼손한 뒤 단위 시험 실행 | 불일치가 검출됨 | w8/test_w8_gemv.c, w8/run_test_w8.py | 통과 | 불일치 1,019건 검출 | 새 단위 시험을 추가할 때마다 반복 |

### L1 단위

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-U1 | RTL | VFU(expf, softmax, SiLU, 나눗셈, 나눗셈+softmax) | RISC-V 소프트웨어 결과와 비교. 규모는 quick/standard/full로 선택 | 비트 단위 일치 | vfu/run_test.py (reproduce.sh) | 통과 | PR #3 기록: 1.31M 벡터 불일치 0 | quick은 작은 규모만 재실행. 이번 세션에서 1.31M을 다시 돌리지는 않음 |
| V-U2 | RTL | exp2 RTL vs C 모델 | 입력 벡터를 RTL과 C 모델에 넣어 비교 | 일치 | acc/tb_exp2/run.sh, opta/test_exp2q.c | 부분 | reproduce.sh Option A 단계에 포함 | 개별 수치는 이번 세션에서 재확인하지 않음 |
| V-U3 | RTL | GEMV 모드 D(int8 가중치, 행별 scale) 무작위 시험 | 무작위 행렬과 scale, 모드 D 실행 후 C 기준과 비교 | 불일치 0 | w8/test_w8_gemv.c, w8/run_test_w8.py | 통과 | 366건 불일치 0 (이어서 355건, 14건 추가 시험) | fmul+fadd, FMA 미사용 기준 |
| V-U4 | RTL | 15M 크기 GEMV(버퍼 1024) | 15M 모델 행렬 크기로 GEMV 실행 | 일치 | w8/test_w8_gemv.c (BIGLAYOUT) | 통과 | 기록된 세션 결과 | 15M 전체 모델이 아니라 GEMV 한 형태만 확인 |
| V-U5 | RTL | pre-tiled 가중치 모드(CTRL bit2) | w8/pretile.py로 재배열한 가중치로 모드 A, D 실행 | 일치 | w8/test_w8_gemv.c (tiled run), w8/pretile.py | 통과 | 기록된 세션 결과 | DDR top에서의 버스트 효과는 V-P3 |
| V-U6 | RTL | AXI 외부 읽기 master(axi_ext_rd) | DDR top 시뮬레이션으로 가중치를 DDR에서 읽음(지연 있는 메모리 모델) | 온칩 결과와 바이트 동일 | sim_axi_ddr.cpp, acc/S5B_DDR_AXI.md | 통과 | 8/64 토큰 동일 | 단독 단위 시험이 아니라 DDR top 통합 시험으로 확인 |

### L2 통합

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-I1 | RISC-V | G0 HOLD 회귀 | 저장된 ELF를 ctx 1/128/512로 CPU sim, SoC sim, chip sim 3곳에서 실행 | 덤프가 기준과 바이트 동일(cycle 워드 제외) | reproduce.sh G0 단계 | 통과 | 9건 OK (quick 42/42에 포함) | RTL을 바꿀 때마다 실행 |
| V-I2 | RISC-V | 호스트 기준 C vs llama2.c | llama2.c와 512 step 정확도 비교 | 정확도 일치 | reproduce.sh Option A | 통과 | reproduce.sh quick 42/42에 포함 | 이번 세션에서 개별 수치 재확인은 안 함 |
| V-I3 | RISC-V | 단일 step 프로파일 | SW 기준과 오프로딩 단계별 cycle 및 결과 | 결과 일치 | reproduce.sh 프로파일 단계 | 통과 | quick 42/42에 포함 |  |
| V-I4 | RISC-V | E2E 생성 | 8 step(quick), 64 step(standard), 512 step(full) | 토큰과 덤프가 기준과 일치 | reproduce.sh quick/standard/full | 통과 | 8 step quick 포함, 512 step 기록 10.29x(PR #3) | 512 step은 수 시간이라 이번에 재실행 안 함 |
| V-I5 | 수치 | int8 경로 비트 일치(host = RISC-V = GEMV) | 8, 64 토큰 생성 후 세 구현 비교 | 비트 일치 | w8/, gen/run_gen.py (W8=1) | 통과 | 8/64 토큰 일치 |  |
| V-I6 | RTL | DDR top vs 온칩 top | 같은 이미지를 두 top에서 실행 | 덤프 바이트 동일 | sim_axi_ddr.cpp (chip_axi_ddr_top) | 통과 | 8/64 토큰 동일 | 지연 모델과 row/bank 모델 포함 |
| V-I7 | 보드 흐름 | PS 역할 시뮬레이션 | AXI4-Lite 레지스터 + AXI4 메모리 모델로 보드 흐름 재현 | 결과와 CYCLES 일치 | sim_axi.cpp, sim_axi_ddr.cpp | 통과 | 시뮬레이션 일치 | 실제 PS/PYNQ는 아님 |
| V-I8 | RTL | xsim 전체 칩 vs Verilator | XPM URAM과 UNISIM 모델로 전체 칩을 xsim에서 실행 | 2 MiB 덤프 일치, DONE 도달 | fpga/xsim/run_xsim.sh | 통과 | run_cycles 157,433 (sim.cpp 157,437), 덤프 일치 | 작업 복사본 우회 패치 2건 필요(docs/XSIM_VS_VERILATOR.md) |
| V-I9 | 전체 | 빠른 회귀 reproduce.sh quick | 42개 항목 일괄 | 42/42 OK | reproduce.sh quick | 통과 | RTL 변경마다 42/42 | 마지막 커밋은 문서와 xsim 파일만 변경 |
| V-N1 | 수치 | int8 정확도 | fp32 대비 nll과 argmax 일치율 측정 | 제안: nll_delta ≤0.01, argmax ≥0.97 | w8/eval_w8.py, quant/ | 미정 | 측정 nll_delta +0.0023, argmax 0.987 | 합격 기준은 사용자 결정 대기 |
| V-P1 | 성능 | 성능 카운터(gemv busy, vfu busy, acc stall, 읽은 line, tq_full, eq_max) | 카운터 레지스터 읽기 | 값이 시뮬레이션 모델과 일치 | acc/chip_axi_top.sv (0x200_0020..0x34) | 통과 | 구현과 시뮬레이션 확인 | 보드에서의 읽기는 미실행 |
| V-P2 | 성능 | DRAM 지연과 row/bank 영향 | SIM_ROWBANK=1 (page, map, core MHz 환경변수) | 영향을 정량화 | sim_axi_ddr.cpp | 통과 | 단일 타일 영향 2% 이하 | 두 master가 동시에 접근하는 경우는 미시험 |
| V-P3 | 성능 | pre-tiling의 DDR top 실측 | AXI_MAXB 64/256으로 빌드해 버스트 길이 효과 측정 | 버스트 6~8 line에서 늘어남 확인 | build_sim.sh (AXI_MAXB) | 미실행 | 버스트 통계만 계산됨(6~8 line에서 최대 256) |  |

### L3 타이밍

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-M1 | 타이밍 | 온칩 top 125 MHz (OOC) | fpga/run_chip.sh 단독 배치 합성 | WNS ≥ 0 | fpga/run_chip.sh | 통과 | WNS +0.249 ns |  |
| V-M2 | 타이밍 | DDR top 125 MHz (OOC) | int8 모드 + 외부 FIFO 포함 | WNS ≥ 0 | fpga/run_chip.sh (WITH_DDR=1) | 통과 | WNS +0.155 ns |  |
| V-M3 | 타이밍 | PS 연결 비트스트림 125 MHz | Vivado GUI에서 구현 후 보고서 확인 | WNS, WHS ≥ 0 | E:/fpga_work/board_release_125_int8/ | 통과 | WNS +0.100, WHS +0.008, WPWS 2.5, LUT 60,179, URAM 64, DSP 93 | 사용자가 GUI에서 구현. 스크립트 경로는 불안정 |
| V-M4 | 타이밍 | 150 MHz | OOC 반복 합성 | WNS ≥ 0 | fpga/run_chip.sh | 제외 | 최선 −0.001 ns, 미달 | 사용자가 150 MHz 불필요로 결정 |

### L4 합성 후

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-S1 | RTL | 합성 후 전체 칩 네트리스트 기능 시뮬레이션 | 합성 네트리스트를 같은 이미지로 실행하고 덤프 비교 | 덤프 일치, DONE 도달 | (스크립트 없음) | 미실행 | FPU 단위만 네트리스트로 확인(1402/1402) | 하드웨어가 Verilator와 같다는 근거를 보강하는 가장 큰 빈칸 |

### L5 보드

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-B0 | 보드 | 보드 준비 | bit와 hwh 이름 정리, 기준 덤프 생성, SHA256 기록 | 파일과 체크섬 목록 | docs/BOARD_BRINGUP.md 3절 step 0 | 미실행 |  | .hwh가 .bit와 같은 블록 디자인에서 나왔는지 확인 필요 |
| V-B1 | 보드 | PYNQ 부팅과 오버레이 | Overlay("board.bit"), ip_dict 확인, base 0xA000_0000, PL 125 MHz | 오류 없이 로드 | docs/BOARD_BRINGUP.md step 1 | 미실행 |  | 보드와 PYNQ 이미지 확보 필요 |
| V-B2 | 보드 | AXI 경로만(CTRL=0) | SRAM과 imem에 패턴을 쓰고 읽기 | 읽은 값이 쓴 값과 동일 | docs/BOARD_BRINGUP.md step 2 | 미실행 |  |  |
| V-B3 | 보드 | 16 토큰 이미지 실행 | python3 run_chip.py board.bit image.bin dump_sim.bin | DONE_V, CYCLES가 시뮬레이션과 동일, 2 MiB 덤프 바이트 동일 | pynq/run_chip.py | 미실행 |  | run_chip.py는 한 번도 실행된 적 없음 |
| V-B4 | 보드 | 512 토큰 이미지 실행 | 약 4.5M cycle(125 MHz에서 약 36 ms, 추정) | 위와 같은 세 가지 기준 | docs/BOARD_BRINGUP.md step 4 | 미실행 |  |  |
| V-B5 | 보드 | 결과 기록 | cycle, 시간, 일치 여부를 PROGRESS.md와 P1_REPORT.md에 반영 | 문서 갱신 | docs/BOARD_BRINGUP.md step 5 | 미실행 |  |  |

### 격차

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-G1 | RTL | `assign` 안에서 함수가 인자가 아닌 변수를 읽는 패턴 전수 탐색 | acc/ 와 vendor 외 RTL 소스를 검색해 `rd_ok`와 같은 패턴 확인 | 해당 패턴 없음 또는 인자화 | acc/*.sv | 미실행 | vfu.sv의 rd_ok만 확인됨 | 시뮬레이터 의존성 제거 목적 |
| V-G2 | RTL | 저장소 RTL의 `rd_ok` 수정 여부 | 인자로 넘기거나 인라인한 뒤 회귀와 재합성 확인 | reproduce quick 42/42 + 타이밍 영향 없음 | acc/vfu.sv | 미정 | 기능 변경 없음(논리 동일) | 수정 여부 결정 대기 |
| V-G3 | RTL | 커버리지, 어서션, 형식 검증 |  |  |  | 미실행 | 현재 사용하지 않음 | 도입 여부는 별도 결정 |
| V-G4 | RISC-V | 15M 모델용 펌웨어와 RTL 주소 일반화 | 15M 주소 맵대로 펌웨어와 RTL 파라미터 수정 | 15M 시뮬레이션 통과 | docs/15M_ADDRESS_MAP.md | 미실행 | 주소 맵 문서와 GEMV 형태 시험만 있음 | 모델 파일과 범위 결정 대기 |
| V-G5 | RTL | KV cache를 DDR에 두는 쓰기 경로 | AXI write 경로 설계와 시험 |  |  | 미실행 | 설계되지 않음(KV fp32 3.375 MiB는 URAM 3.0 MiB에 안 맞음) | int8 KV는 0.914 MiB |
| V-G6 | RTL | 정수 lane(I2: int8×int8 MAC + 활성화 양자화) | 고정소수점 C 기준부터 새로 시작 |  |  | 미실행 |  | 별도 세션에서 진행하기로 결정 |
| V-G7 | 도구 | 이전 xsim 불일치에서 패치별 기여 분리 | 패치를 하나씩만 적용해 재실행 | 각 패치의 효과 정량화 | fpga/xsim/run_xsim.sh | 미실행 |  | 우선순위 낮음 |

## 4. 사용자 결정 대기

| ID | 결정 | 현재 | 관련 항목 |
|---|---|---|---|
| D1 | int8 합격 기준 | nll_delta ≤0.01, argmax ≥0.97 (제안) | V-N1 |
| D2 | 15M 모델 파일과 범위(임베딩 int8 조회, KV 위치, 주소 맵 Option I/II) | 미정 | V-G4, V-G5 |
| D3 | 저장소 RTL의 rd_ok 수정 여부 | 미정 | V-G2 |
| D4 | 합성 후 전체 칩 시뮬레이션 수행 여부 | 미정 | V-S1 |
| D5 | 보드 확보와 PYNQ 이미지 | 미정(보드 없음) | V-B0..V-B5 |
| D6 | 커버리지, 어서션, 형식 검증 도입 여부 | 미정 | V-G3 |

## 5. 실행 규칙 (LESSONS_LEARNED 반영)

1. 실행 전에 `tasklist.exe`로 남은 `vivado.exe`, `xsimk.exe`를 확인하고, Vivado와 대형 시뮬레이션은 직렬로 돌린다.
2. xsim 결과는 V-T1(FPU 1,402 벡터)을 먼저 통과시킨 뒤에만 신뢰한다.
3. 장시간 실행은 로그의 단위와 예상 종료 시점을 계산해 두고, 상한을 넘으면 중단한다.
4. RTL을 바꾸면 V-I9(quick 42/42)를 다시 돌린다. 시험을 새로 만들면 V-T3(변이 시험)로 검출력을 확인한다.
5. "통과"는 시뮬레이션 또는 합성 보고서 기준이며 보드 결과가 아니다. 보고할 때 둘을 구분한다.

## 6. 한계

- 이 표는 `reproduce.sh`, `docs/`, 이번 세션 기록에서 확인한 것만 담았다. 저장소의 모든 시험을 찾아본 것은 아니다.
- "근거" 열의 수치는 저장소 문서와 세션 기록에서 옮겼고, 이번 세션에서 다시 측정한 것은 V-I8(xsim 전체 칩)과 V-T1뿐이다.
- `unit`급 시험이 따로 분리되지 않은 항목(V-U6)은 통합 시험으로 확인했다고 표시했다.
