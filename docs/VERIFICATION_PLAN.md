# 검증 계획서 (Verification Plan)

이 파일은 `docs/gen_verification_plan.py`가 생성한다(데이터 원본은 그 스크립트). 같은 내용이 `docs/VERIFICATION_PLAN.xlsx`에 있다. 직접 고치지 말고 스크립트를 고친 뒤 다시 실행한다.

"통과"는 **시뮬레이션 또는 합성 보고서에서 통과**했다는 뜻이다. **보드에서는 아무것도 실행하지 않았다.**

## 1. 요약

전체 49개: 통과 25, 부분 3, 미실행 18, 미정 2, 제외 1

| 단계 | 통과 | 부분 | 미실행 | 미정 | 제외 |
|---|---|---|---|---|---|
| L0 도구 점검 | 3 | 0 | 0 | 0 | 0 |
| L1 단위 | 5 | 1 | 0 | 0 | 0 |
| L2 통합 | 11 | 0 | 1 | 1 | 0 |
| L3 타이밍 | 3 | 0 | 0 | 0 | 1 |
| L4 합성 후 | 0 | 0 | 1 | 0 | 0 |
| L5 보드 | 0 | 0 | 6 | 0 | 0 |
| 격차 | 3 | 2 | 10 | 1 | 0 |

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
| V-T1 | 도구 | xsim 신뢰도 점검(FPU) | 3,896 벡터(정상 범위 + SUB/F2I/비교 + 경계값, numpy IEEE와 RISC-V 규칙 기준)를 FPU RTL과 합성 네트리스트에 입력 | 3,896/3,896 일치 | fpga/xsim/run_fpu_test.sh, run_fpu_verilator.sh | 통과 | 우회 패치 후 xsim RTL 3896/3896, 네트리스트 3896/3896, Verilator RTL 3896/3896 (11-22의 1,402개 벡터는 패치 전 671/1402) | xsim 결과를 믿기 전에 매번 먼저 실행(LESSONS_LEARNED C단계) |
| V-T2 | 도구 | 시뮬레이션 환경 빌드 | CPU, CPU 프로파일러, SoC 시뮬레이터 빌드 | 빌드 성공 | reproduce.sh 첫 단계 | 통과 | reproduce.sh quick 42/42 | Ubuntu 24.04, verilator 5.038, riscv64 gcc + picolibc |
| V-T3 | 도구 | 시험이 틀림을 잡는지(변이 시험) | 기대값 또는 RTL을 일부러 훼손한 뒤 단위 시험 실행 | 불일치가 검출됨 | w8/test_w8_gemv.c, w8/run_test_w8.py | 통과 | 불일치 1,019건 검출 | 새 단위 시험을 추가할 때마다 반복 |

### L1 단위

| ID | 분류 | 점검 항목 | 방법 / 자극 | 합격 기준 | 실행 위치 | 상태 | 근거 | 비고 |
|---|---|---|---|---|---|---|---|---|
| V-U1 | RTL | VFU(expf, softmax, SiLU, 나눗셈, 나눗셈+softmax) | RISC-V 소프트웨어 결과와 비교. 7개 명령 전부, softmax 계열 벡터 길이 1, 2, 8, 512와 무작위 1~512 포함. 규모는 quick/standard/full로 선택 | 비트 단위 일치 | vfu/run_test.py (reproduce.sh) | 통과 | PR #3 기록: 1.31M 벡터 불일치 0 | quick은 작은 규모만 재실행. 이번 세션에서 1.31M을 다시 돌리지는 않음 |
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
| V-P3 | 성능 | pre-tiling의 DDR top 실측 | AXI_MAXB 64/256으로 빌드해 버스트 길이 효과 측정 | 버스트 6~8 line에서 늘어남 확인 | build_sim.sh (AXI_MAXB) | 미실행 | 버스트 통계만 계산됨(6~8 line에서 최대 256) | AXI_MAXB를 늘릴 때 CRED ≥ MAXB와 외부 FIFO(64 line) 한도를 함께 키워야 함(V-A2에서 확인) |

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
| V-F1 | FPU | FPU 경계값 벡터(subnormal, Inf, NaN, ±0) | 17개 특수 피연산자의 모든 쌍을 ADD, SUB, MUL, DIV, 비교에, 특수값을 SQRT, I2F, F2I에 입력(1,494개). NaN 결과는 정규 NaN 0x7fc00000, F2I는 포화 규칙 | RISC-V F 규칙의 기대값과 비트 일치 | fpga/xsim/fpu_vectors.py (edge-*) | 통과 | xsim RTL, 네트리스트, Verilator RTL(AFTER, DISTRIBUTED) 모두 3896/3896. 변이 시험(SUB→ADD 등 4건)이 모두 검출됨 | 예외 플래그는 비교하지 않음(V-F2) |
| V-F2 | FPU | FPU 예외 플래그(rflags) 비교 | 연산별 NV, DZ, OF, UF, NX 기대값을 만들어 rflags와 비교 | 플래그 일치 | fpga/xsim/fpu_vectors.py, tb_fpu.sv | 미실행 | 현재 기대값 파일에 결과만 있음 |  |
| V-F3 | FPU | 펌웨어가 쓰지만 벡터에 없던 연산: SUB(fsub.s), F2I(fcvt.w.s, RTZ), 비교(flt.s, RTZ) | 정상 범위 SUB 300, F2I 300, FLT 400(무작위, 동일 값, 이웃 값)을 numpy와 비교. 펌웨어는 FMA, fmin, fmax를 쓰지 않음(fw.dis 0건) | 일치 | fpga/xsim/fpu_vectors.py | 통과 | xsim RTL, 네트리스트, Verilator RTL 모두 일치 | fw.dis 사용 횟수: fsub 36, flt 27, fcvt.w.s 1 |
| V-F4 | FPU | FPU 연속 요청(back-to-back, 파이프라인 중첩) | 같은 연산 그룹(ADDMUL, DIVSQRT, NONCOMP, CONV)의 요청을 gnt가 허용하는 매 cycle 입력하고 결과를 순서대로 수집 | 순서 보존, 값 일치, 요청 없는 결과 0 | fpga/xsim/fpu_verilator.cpp (stream 모드) | 부분 | Verilator RTL(AFTER, DISTRIBUTED) 3896/3896. ADDMUL, NONCOMP, CONV 1.00 cycle/op, 동시 진행 최대 3개, DIVSQRT 13.4 cycle/op | xsim RTL과 합성 네트리스트의 연속 요청 시험은 미구현. 서로 다른 그룹 사이 중첩은 시험하지 않음 |
| V-R1 | RISC-V | 코어 ISA 적합성(펌웨어가 쓰는 RV32IMFC 부분집합) | riscv-arch-test에서 펌웨어가 쓰는 명령군만 골라 CPU sim에서 실행 | 서명(signature) 일치 | (환경 구성 필요) | 미실행 | 코어는 현재 펌웨어 실행으로만 간접 확인 |  |
| V-A1 | RTL | GEMV, VFU 버퍼 한계 경계 | GEMV 모드 D: 한계(n 또는 d = XBUF/YBUF)와 초과(+1, +8, 2배, 양쪽 동시)를 하나씩 실행해 소프트웨어 기준과 비교. VFU softmax, divsoftmax, softmax2: 청크 길이 512, 513, 520, 1024 | 한계 안은 일치, 초과는 정의된 동작(오류 신호 또는 안전한 거부) | w8/overlimit.sh, vfu/overlimit.sh (run_test_w8.py의 TEST_CASES, run_test.py의 TEST_LN) | 부분 | 한계 안 통과(GEMV 512×8, 8×512, 1024 빌드의 1024×8, 8×1024, VFU 길이 512). 초과는 전부 조용히 틀림: GEMV 512 빌드 7/7, 1024 빌드 6/6 사례 실패, VFU 513에서 불일치 3,115, 520에서 5,887, 1024에서 12,279. 멈춤, 센티널 위반 없음 | 합격 기준 "초과는 정의된 동작"을 만족하지 못함(RTL에 보호 없음). 시뮬레이션 전용 어서션 추가 여부는 결정 D7. 1025×1025는 크기 필터(n×d > 1 MiB)로 제외되어 판정 없음. 실험 E08 |
| V-A2 | RTL | AXI 외부 읽기 경계: 4 KB 경계, 슬레이브 지연·정지·beat 간격, 오류 응답 | 무작위 AXI 슬레이브(ready 확률 1/0.5/0.1과 긴 정지, 지연 0~200 cycle, R beat 간격)에 가속기 line 요청(4 KB 경계 걸침, 긴 연속, 점프, 반복, 내림차순)과 CPU word 읽기를 섞어 입력. 오류 주입 시험은 한 beat에 SLVERR/DECERR | 매 cycle 프로토콜 검사 통과(16 B 정렬, 4 KB 비횡단, arlen≤MAXB, AR 안정, TD, CRED+1), 응답 데이터가 주소 해시와 일치, 오류 시 err_o 설정 후 리셋으로 해제 | acc/tb_axi_ext_rd/run.sh, checks.sh | 통과 | 5개 구성(MAXB/CRED/TD = 16/48/8, 8/16/2, 4/8/2, 32/48/8, 48/63/4) × 일반 21 seed(약 10.8만 line, 6,562 CPU 읽기, burst 약 2.4만) + 오류 주입 11 seed 모두 PASS. 변이 5건(4 KB 검사, 오류 플래그, 크레딧, CPU word 선택, TD 한도 제거)을 모두 검출 | 구성 제약(시험으로 확인): CRED ≥ MAXB(아니면 deadlock), TD는 2 이상의 2의 거듭제곱(TD=1, 3, 6은 응답이 밀림). 마스터 쪽 백프레셔는 rready=1이라 없음. 오류 정책은 현재 동작(sticky 플래그, 실행 계속)을 확인한 것이고 더 엄격한 정책 여부는 결정 대기(D7). 전체 칩에서의 오류 주입은 미시험 |
| V-A3 | RTL | CPU, GEMV, VFU 동시 메모리 접근 충돌 | 세 master가 같은 구간을 동시에 접근하는 시나리오를 직접 만들어 실행 | 결과가 순차 실행과 동일 | acc/soc_top.sv | 미실행 | E2E 실행에서만 간접 확인 |  |
| V-A4 | RTL | 가속기 레지스터 인터페이스 경계: busy 중 쓰기, 잘못된 CTRL 값 | busy 상태에서 새 명령/설정 쓰기, 정의되지 않은 모드 값 | 정의된 동작(무시 또는 오류 표시) | acc/gemv_acc.sv, acc/vfu.sv | 미실행 | 펌웨어는 busy 폴링 후에만 씀 |  |

## 4. 신규 시험 등록부

블록별 점검에서 빈칸으로 나온 시험의 계획과 결과. 상태와 결과는 3절의 같은 ID와 같은 값이다. 작업량은 추정이며 측정값이 아니다.

| ID | 시험 | 분류 | 우선순위 | 추정 작업량 | 선행 결정 | 상태 | 결과 / 근거 | 구현 위치 | 갱신일 |
|---|---|---|---|---|---|---|---|---|---|
| V-F3 | 펌웨어가 쓰지만 벡터에 없던 연산: SUB(fsub.s), F2I(fcvt.w.s, RTZ), 비교(flt.s, RTZ) | FPU | 1 | 0.5일 | 없음 | 통과 | xsim RTL, 네트리스트, Verilator RTL 모두 일치 | fpga/xsim/fpu_vectors.py | 2026-11-23 |
| V-A2 | AXI 외부 읽기 경계: 4 KB 경계, 슬레이브 지연·정지·beat 간격, 오류 응답 | RTL | 2 | 1일 | 없음(오류 정책은 현재 동작을 확인, 변경 여부는 결정 D7) | 통과 | 5개 구성(MAXB/CRED/TD = 16/48/8, 8/16/2, 4/8/2, 32/48/8, 48/63/4) × 일반 21 seed(약 10.8만 line, 6,562 CPU 읽기, burst 약 2.4만) + 오류 주입 11 seed 모두 PASS. 변이 5건(4 KB 검사, 오류 플래그, 크레딧, CPU word 선택, TD 한도 제거)을 모두 검출 | acc/tb_axi_ext_rd/run.sh, checks.sh | 2026-11-23 |
| V-F1 | FPU 경계값 벡터(subnormal, Inf, NaN, ±0) | FPU | 2 | 0.5일 | 없음 | 통과 | xsim RTL, 네트리스트, Verilator RTL(AFTER, DISTRIBUTED) 모두 3896/3896. 변이 시험(SUB→ADD 등 4건)이 모두 검출됨 | fpga/xsim/fpu_vectors.py (edge-*) | 2026-11-23 |
| V-A1 | GEMV, VFU 버퍼 한계 경계 | RTL | 3 | 0.5일 | 확인 결과: 하드웨어는 막지 않음(조용한 오류). 어서션 추가는 결정 D7 | 부분 | 한계 안 통과(GEMV 512×8, 8×512, 1024 빌드의 1024×8, 8×1024, VFU 길이 512). 초과는 전부 조용히 틀림: GEMV 512 빌드 7/7, 1024 빌드 6/6 사례 실패, VFU 513에서 불일치 3,115, 520에서 5,887, 1024에서 12,279. 멈춤, 센티널 위반 없음 | w8/overlimit.sh, vfu/overlimit.sh (run_test_w8.py의 TEST_CASES, run_test.py의 TEST_LN) | 2026-11-23 |
| V-A3 | CPU, GEMV, VFU 동시 메모리 접근 충돌 | RTL | 3 | 1일 | 없음 | 미실행 | E2E 실행에서만 간접 확인 | acc/soc_top.sv | - |
| V-F4 | FPU 연속 요청(back-to-back, 파이프라인 중첩) | FPU | 3 | 0.5일(xsim 연속 요청까지는 +0.5일) | 없음 | 부분 | Verilator RTL(AFTER, DISTRIBUTED) 3896/3896. ADDMUL, NONCOMP, CONV 1.00 cycle/op, 동시 진행 최대 3개, DIVSQRT 13.4 cycle/op | fpga/xsim/fpu_verilator.cpp (stream 모드) | 2026-11-23 |
| V-A4 | 가속기 레지스터 인터페이스 경계: busy 중 쓰기, 잘못된 CTRL 값 | RTL | 4 | 0.5일 | busy 중 쓰기 등 정의되지 않은 동작의 정책 | 미실행 | 펌웨어는 busy 폴링 후에만 씀 | acc/gemv_acc.sv, acc/vfu.sv | - |
| V-F2 | FPU 예외 플래그(rflags) 비교 | FPU | 4 | 1일 | 플래그 기준 구현 선택(softfloat 등) | 미실행 | 현재 기대값 파일에 결과만 있음 | fpga/xsim/fpu_vectors.py, tb_fpu.sv | - |
| V-R1 | 코어 ISA 적합성(펌웨어가 쓰는 RV32IMFC 부분집합) | RISC-V | 5 | 1~2일 | 툴체인과 riscv-arch-test 환경 준비 | 미실행 | 코어는 현재 펌웨어 실행으로만 간접 확인 | (환경 구성 필요) | - |

## 5. 블록별 점검 (FPU, RISC-V 코어, 가속기)

"확인" = 시험 코드나 기록에서 확인, "간접" = 펌웨어/E2E 실행으로만 확인, "없음" = 확인한 범위에서 시험 없음, "제외" = 대상 아님. "연결 ID"는 3절의 항목이다.

### FPU

| 점검 항목 | 확인 내용 | 현재 | 근거와 위치 | 연결 ID |
|---|---|---|---|---|
| ADD, MUL | numpy float32(정확한 반올림)와 비트 일치 | 확인 | fpga/xsim/fpu_vectors.py, 각 300 이상 + 경계값 | V-T1 |
| DIV, SQRT | 위와 동일 | 확인 | 같은 벡터 파일 | V-T1 |
| I2F(정수→실수) | 부호 있는 정수 200개 | 확인 | 같은 벡터 파일 | V-T1 |
| 반올림 모드 | RNE(연산), RTZ(F2I, 비교) | 간접 | 펌웨어가 쓰는 모드만. RDN, RUP, RMM은 시험하지 않음 |  |
| 피연산자 범위 | subnormal, Inf, NaN(조용한/신호), ±0, 최대·최소 정규수 | 확인 | 경계값 1,494개, xsim RTL, 네트리스트, Verilator 모두 일치 | V-F1 |
| 예외 플래그(rflags) | 플래그 비교 | 없음 | 기대값 파일에 결과만 있음 | V-F2 |
| SUB, F2I, 비교(펌웨어가 쓰는 연산) | numpy와 RISC-V 규칙 기준 일치 | 확인 | fw.dis: fsub 36, flt 27, fcvt.w.s 1 사용. 3곳 시뮬레이터 모두 일치 | V-F3 |
| FMA, fmin, fmax | 펌웨어가 쓰지 않음 | 제외 | fw.dis 0건 |  |
| 지연(latency) | FPU_LAT 0과 4에서 동작 | 간접 | D1(0), D2(4) 설정 회귀 | V-I1 |
| 연속 요청 핸드셰이크 | req→gnt→rvalid 중첩, 결과 순서 | 확인 | Verilator RTL만(연속 모드). xsim과 네트리스트는 미구현 | V-F4 |
| 합성 후 네트리스트 | 같은 벡터 | 확인 | 3,896/3,896 | V-T1 |

### RISC-V 코어

| 점검 항목 | 확인 내용 | 현재 | 근거와 위치 | 연결 ID |
|---|---|---|---|---|
| 명령 I, M, F, C | 펌웨어가 쓰는 범위 실행 | 간접 | HOLD 회귀, E2E 덤프 일치 | V-I1, V-I4 |
| 부팅 | _start, bss 초기화, imem 0x0100_0000 | 간접 | chip sim, xsim 실행 | V-I1, V-I8 |
| CSR | mstatus FS, mcountinhibit, mcycle | 간접 | 시작 코드에서 사용 |  |
| 트랩 | 예기치 않은 예외 | 간접 | sim.cpp가 TRAP mepc를 감지해 중단 |  |
| 데이터 포트 | 바이트 마스크, 크기, 정렬 | 간접 | xsim과 Verilator trace가 9,910 cycle까지 4,462 이벤트 동일 | V-I8 |
| 스택 | 최소 스택 주소 | 간접 | 실행 로그의 min_stack_write |  |
| 외부 인터럽트 | 사용하지 않음 | 제외 |  |  |
| ISA 적합성(riscv-arch-test 등) | 명령 하나하나 | 없음 |  | V-R1 |

### 가속기

| 점검 항목 | 확인 내용 | 현재 | 근거와 위치 | 연결 ID |
|---|---|---|---|---|
| GEMV 모드 A(fp32) | 온칩과 DDR에서 일치 | 확인 |  | V-I5, V-I6 |
| GEMV 모드 D(int8 + scale) | 무작위 366건, 불일치 0 | 확인 | w8/test_w8_gemv.c | V-U3 |
| GEMV 15M 형태, pre-tiled(bit2) | 일치 | 확인 |  | V-U4, V-U5 |
| GEMV 행 stride 16 B 배수, scale 16 B 라인 적재 | 오류 없이 동작 | 확인 | LOADS 상태 수정 후 비트 비교 |  |
| GEMV, VFU 버퍼 한계 | 한계 안 일치, 한계 초과 시 동작 | 확인 | 한계 안 통과(버퍼 512, 1024 빌드). 초과는 조용히 틀림(오류 신호, 어서션 없음). 실험 E08 | V-A1 |
| 레지스터 인터페이스 | CTRL, W_ADDR, SC_ADDR, busy 폴링 | 간접 | 펌웨어가 사용. 경계 입력은 미시험 | V-A4 |
| VFU 명령 1~7 | exp, softmax, SiLU, 나눗셈, 나눗셈+softmax, softmax2, SiLU2를 소프트웨어와 비트 일치 | 확인 | vfu/run_test.py | V-U1 |
| VFU 벡터 길이 경계 | softmax 계열 길이 1, 2, 8, 512, 무작위 1~512 | 확인 | vfu/run_test.py (53행 부근) | V-U1 |
| VFU 연속 명령, 상태 전이 | 명령 사이 상태 정리 | 간접 | E2E에서 확인 |  |
| AXI 외부 읽기 | 버스트 병합, 크레딧, 태그 FIFO, 지연 | 확인 | DDR top 시뮬레이션 | V-U6 |
| AXI 4 KB 경계, 슬레이브 정지·지연, 오류 응답 | 프로토콜 검사와 데이터 일치, 오류 시 err_o | 확인 | acc/tb_axi_ext_rd (5개 구성, 변이 5건 검출). 구성 제약 CRED≥MAXB, TD=2의 거듭제곱 | V-A2 |
| 성능 카운터 | 6종 값이 모델과 일치 | 확인 |  | V-P1 |
| CPU, GEMV, VFU 동시 접근 | 충돌 시 결과 일치 | 간접 | E2E에서만 확인 | V-A3 |

## 6. 사용자 결정 대기

| ID | 결정 | 현재 | 관련 항목 |
|---|---|---|---|
| D1 | int8 합격 기준 | nll_delta ≤0.01, argmax ≥0.97 (제안) | V-N1 |
| D2 | 15M 모델 파일과 범위(임베딩 int8 조회, KV 위치, 주소 맵 Option I/II) | 미정 | V-G4, V-G5 |
| D3 | 저장소 RTL의 rd_ok 수정 여부 | 미정 | V-G2 |
| D4 | 합성 후 전체 칩 시뮬레이션 수행 여부 | 미정 | V-S1 |
| D5 | 보드 확보와 PYNQ 이미지 | 미정(보드 없음) | V-B0..V-B5 |
| D6 | 커버리지, 어서션, 형식 검증 도입 여부 | 미정 | V-G3 |
| D7 | AXI 외부 읽기 오류 응답 정책 | 현재: err_o(sticky, STATUS bit1)만 켜고 실행 계속. 오류 시 중단이나 재시도가 필요한지, 파라미터 제약(CRED≥MAXB, TD=2의 거듭제곱)과 버퍼 한계(N>XBUF, D>YBUF, VFU n>BUF)를 시뮬레이션 전용 RTL 어서션으로 강제할지(V-A1: 지금은 조용히 틀린 결과) | V-A1, V-A2 |

## 7. 실행 규칙 (LESSONS_LEARNED 반영)

1. 실행 전에 `tasklist.exe`로 남은 `vivado.exe`, `xsimk.exe`를 확인하고, Vivado와 대형 시뮬레이션은 직렬로 돌린다.
2. xsim 결과는 V-T1(FPU 1,402 벡터)을 먼저 통과시킨 뒤에만 신뢰한다.
3. 장시간 실행은 로그의 단위와 예상 종료 시점을 계산해 두고, 상한을 넘으면 중단한다.
4. RTL을 바꾸면 V-I9(quick 42/42)를 다시 돌린다. 시험을 새로 만들면 V-T3(변이 시험)로 검출력을 확인한다.
5. "통과"는 시뮬레이션 또는 합성 보고서 기준이며 보드 결과가 아니다. 보고할 때 둘을 구분한다.
6. 결과 파일을 재사용하는 시험 스크립트는 입력이 바뀌면 낡은 결과를 비교하지 않는지 확인한다(`run_fpu_test.sh`는 실행 시작 때 결과 파일을 지운다).

## 8. 한계

- 이 표는 `reproduce.sh`, `docs/`, 이번 세션 기록에서 확인한 것만 담았다. 저장소의 모든 시험을 찾아본 것은 아니다.
- "근거" 열의 수치는 저장소 문서와 세션 기록에서 옮겼고, 이번 세션에서 다시 측정한 것은 V-I8(xsim 전체 칩)과 V-T1뿐이다.
- 단위 시험으로 따로 분리되지 않은 항목(V-U6)은 통합 시험으로 확인했다고 표시했다.
- 4절 "블록별 점검"의 "없음"은 코드를 검색해 찾지 못했다는 뜻이며, 다른 위치에 시험이 있을 가능성을 완전히 배제하지는 않는다.
- V-F1~V-A4(신규 시험)의 "추정 N일"은 작업량 추정이며 측정값이 아니다.
