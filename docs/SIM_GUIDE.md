# RTL 시뮬레이션 매뉴얼 (Verilator + GTKWave)

이 저장소의 RTL(CV32E40P + GEMV/VFU 가속기 + 온칩 메모리)을 시뮬레이션하고 결과와 파형을 보는 방법.
모든 명령은 저장소 최상위 폴더에서 실행한다(`cd ~/work/3_Company_PJT/CSO/Server/LLM/CV32E40P_Stories260K`).
작성 2026-11-18, 아래 명령은 이 날짜 main 기준으로 실행 확인한 것이다.

---

## 0. 준비 (처음 한 번)

| 필요한 것 | 확인 / 설치 |
|---|---|
| Ubuntu 24.04 (WSL2) | — |
| RISC-V 툴체인 | `sudo apt install gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf` |
| Verilator 5.038 | `verilator --version` |
| Python 3 + numpy | `sudo apt install python3-numpy` |
| GTKWave (파형) | `sudo apt install gtkwave` (WSL에서 창이 뜨려면 Windows 11 WSLg) |
| 최신 코드 | `git pull --ff-only` |

---

## 1. 전체 흐름

```
RTL (acc/*.sv, cv32e40p-master/rtl)
   │  ./build_sim.sh            ← Verilator가 RTL을 C++ 시뮬레이터 실행 파일로 변환 (약 5분)
   ▼
시뮬레이터 실행 파일 (obj_*/V*)
   │  펌웨어 이미지(.bin)를 넣고 실행
   ▼
결과: 터미널 "DONE cycles=…" + 메모리 dump(.bin)  ──→  스크립트가 host 기준과 비교 → PASS/FAIL, 표
      (선택) VCD 파형 ──→ GTKWave
```

보통은 2장의 스크립트만 쓰면 된다(빌드·이미지·실행·비교를 한 번에 함). 3장은 시뮬레이터를 직접 돌리는 방법,
4장은 파형 보는 방법이다.

---

## 2. 스크립트로 돌리기 (권장)

### 2.1 시뮬레이터 빌드
```bash
./build_sim.sh                     # CPU 단독            -> obj/Vcv32e40p_top
TOP=soc_top ./build_sim.sh         # CPU + GEMV + VFU     -> obj_soc/Vsoc_top   (문장 생성·프로파일 기본)
TOP=soc_chip ./build_sim.sh        # + imem + SRAM 2 MiB  -> obj_chip/Vsoc_chip (보드에 올라가는 칩)
TOP=chip_axi_top ./build_sim.sh    # 보드 top(PS가 AXI-Lite로 적재하는 흐름) -> obj_axi/Vchip_axi_top
```
기본은 D2 구성(FPU latency 4, 150 MHz 실현 구성). 옵션은 `build_sim.sh` 맨 위 주석 참고.

### 2.2 문장 생성 (가장 먼저 해 볼 것)
```bash
OPTA=1 GEN_ACC=full python3 gen/run_gen.py 16                        # 기본 prompt "Once upon a time", 16 step
OPTA=1 GEN_ACC=full python3 gen/run_gen.py 64 "One day, a little cat" # prompt 지정
```
| 옵션 | 의미 |
|---|---|
| 첫 인자 | 생성할 step 수(prompt 토큰 포함, prompt보다 커야 함). 최대 512 |
| 둘째 인자 | prompt (쉬운 영어 동화 문장. 모델이 TinyStories 260K라 어휘 512개) |
| `GEN_ACC=` | 없음: CPU만 · `1`: FFN · `attn`: +attention · `all`: +softmax/SiLU · `full`: 전부 가속 |
| `OPTA=1` | Option A 수치(exp2q softmax/SiLU). 없으면 원래 llama2.c 수치 |
| `GEN_CFLAGS=""` | `-Os` 빌드(비교 기준용). 기본은 `-O2 -funroll-loops` |
| `SIM_DDR=1 GEN_HW=_d2_ddr` | 가중치를 DDR로 읽는 메모리 모델 |

**출력 (터미널, 끝날 때)**
```
{ "pass": true, "cycles_total": …, "logits_rel_L2_max": 0.0, … }
RISC text : Once upon a time, there was a little girl named Lily. …   ← RTL(RISC-V)이 만든 문장
host free : Once upon a time, there was a little girl named Lily. …   ← PC의 원본 llama2.c
```
**결과 폴더** `gen/out_<step>_<태그>/` (예: `gen/out_16_O2u_opta_accfull_d2_L0_G1/`)

| 파일 | 내용 |
|---|---|
| `result.json` | 판정과 수치 (아래 표) |
| `image.bin` | 시뮬레이터에 넣은 이미지 (3·4장에서 재사용) |
| `dump.bin` | 실행이 끝난 메모리 |
| `sim.log` | 시뮬레이터 출력 |
| `cycles.npy` | step별 cycle (`python3 -c "import numpy;print(numpy.load('cycles.npy'))"`) |

**`result.json`에서 볼 것**
| 항목 | 정상 값 | 의미 |
|---|---|---|
| `pass` | `true` | 종합 판정 |
| `cycles_total` | — | 전체 cycle. 150 MHz면 ÷ 150e6 = 초 |
| `logits_rel_L2_max` | < 1e-5 (Option A는 0.0) | host와의 차이 |
| `logits_kv_tokens_bitexact_vs_Os` | `true` (또는 `null`: 비교할 -Os 결과 없음) | CPU 소프트웨어와 bit 동일 |
| `host_free_run_first_divergence` | `null` | 문장이 host와 끝까지 같음 |

소요 시간(대략): Option A 가속 16 step 1분 이내, 64 step 수 분, 512 step 30분 내외. CPU만(`GEN_ACC` 없음)은 10배 이상 느림.

### 2.3 한 step 성능 프로파일 (어디에 시간이 드는가)
```bash
PROF_CFLAGS="-O2 -funroll-loops -DOPTA -DUSE_ACC_ATTN -DUSE_ACC_VFU -DUSE_ACC_MM -DUSE_ACC_VFU_DIV -DRMS_SRAM -DEMB_WORDS" \
  PROF_ACC=1 PROF_OUT=/tmp/prof python3 prof/run_prof.py gen/firmware_gen.c my_opta
```
결과 `/tmp/prof/my_opta/table.md`: ctx 1/128/512 각각의 영역별 cycle 표(GEMV, attention, softmax, …).
Markdown 미리보기(VS Code 등)로 보면 표로 보인다. 단계별 비교 표는 `prof/STAGE_PROFILE.md`.

### 2.4 회귀 테스트 (전부 맞는지 한 번에)
```bash
./reproduce.sh quick       # 약 10분, 42 항목 (standard 53 항목 약 40분, full 수 시간)
```
마지막에 `OK`/`FAIL` 표와 `42/42 OK`가 나온다. 모든 출력은 `repro/`에 남고, 실패 항목은 `repro/*.txt` 로그를 본다.
항목 구성: single step 프로파일 33(11 구성 × ctx 3), 8 step 생성 6, Option A 정확도 1, exp2 RTL 1, VFU 단위 테스트 1.

---

## 3. 시뮬레이터를 직접 실행하기

```bash
<시뮬레이터> <이미지.bin> <dump 출력.bin> [최대 cycle, 기본 30000000] [step 로그 파일]
```
예:
```bash
obj_chip/Vsoc_chip gen/out_16_O2u_opta_accfull_d2_L0_G1/image.bin /tmp/dump.bin
# -> DONE cycles=…  min_stack_write=0x1fff20
```
| 출력 | 의미 |
|---|---|
| `DONE cycles=N` | 정상 종료(펌웨어가 0x2000_0000에 씀), N = 전체 cycle(부팅 포함). 예: 8 step Option A 1,263,000 |
| `ACC reads=… writes=…` | 외부 가속기 포트 접근 수(칩 sim은 가중치가 칩 안이라 0) |
| `TIMEOUT` | 최대 cycle 도달 → 세 번째 인자로 늘린다 |
| `TRAP mepc=… cause=…` | CPU 예외(잘못된 명령/주소). mepc = 예외 PC |
| 5,000,000 cycle마다 `pc_fetch=…` | 진행 표시 |

이미지 구하는 곳: 2.2를 한 번 돌리면 `gen/out_*/image.bin`, `./reproduce.sh`를 돌리면 `repro/hold/image_{1,128,512}.bin`(한 step, ctx 1/128/512).
보드 흐름 sim(`obj_axi/Vchip_axi_top`)도 같은 인자를 받고, PS가 하듯 AXI-Lite로 적재 → 실행 → 회수한다.

---

## 4. 파형 보기 (GTKWave)

### 4.1 파형용 빌드 (한 번, 약 5분)
```bash
TRACE=1 TOP=soc_chip ./build_sim.sh      # -> obj_chip_trace/Vsoc_chip   (soc_top, CPU 단독도 가능)
```

### 4.2 원하는 구간만 VCD로 저장
```bash
SIM_VCD=/tmp/wave.vcd SIM_VCD_FROM=100000 SIM_VCD_TO=101000 \
  obj_chip_trace/Vsoc_chip gen/out_16_O2u_opta_accfull_d2_L0_G1/image.bin /tmp/dump.bin 200000
```
- `SIM_VCD_FROM`~`SIM_VCD_TO`: 저장할 cycle 구간. 크기는 신호 변화량에 비례한다(실측: 부팅 구간 200 cycle ≈ 5 MB,
  가속기 동작 구간 1,000 cycle ≈ 56 MB). 처음엔 1,000 cycle 이하로.
- 마지막 인자(최대 cycle)는 `SIM_VCD_TO`보다 크게. 구간이 끝나면 파일이 닫히고, 최대 cycle에서 `TIMEOUT`으로 끝나는 것은
  파형 저장 목적이면 정상이다(전체 실행이 필요하면 최대 cycle을 지정하지 않는다).

### 4.3 GTKWave로 열기
```bash
gtkwave /tmp/wave.vcd
```
왼쪽 위 트리에서 모듈을 고르고 → 아래 신호 목록에서 신호를 골라 **Append**(또는 드래그)하면 오른쪽에 파형이 나온다.
값 표시 형식은 신호 우클릭 → Data Format → Hex/Decimal.

### 4.4 볼 만한 신호 (트리 `TOP` → `soc_chip` 아래)
| 보고 싶은 것 | 위치 | 신호 |
|---|---|---|
| CPU 명령 fetch | `soc_chip` | `i_req`, `i_addr` |
| CPU 데이터 접근 | `soc_chip` | `d_req`, `d_addr`, `d_we`, `d_rvalid` |
| CPU 현재 PC | `soc_i` → `cpu_i` → `core_i` | `pc_id` |
| 가속기 메모리 요청/응답 | `soc_chip` | `a_req`, `a_addr`, `a_rvalid` |
| SRAM 가속기 포트(입력 레지스터 뒤) | `soc_chip` | `b_en_x`, `b_addr_x` |
| GEMV 상태 머신 | `soc_i` → `acc_i` | `st_q` |
| VFU 상태 머신 | `soc_i` → `vfu_i` | `st_q` (1 LOAD, 2 PAR, …, 6 XS = Option A softmax 스트림) |
| CPU FPU handshake | `soc_i` → `cpu_i` → `fpu_gen` → `fp_wrapper_i` | `apu_req_i`, `apu_gnt_o`, `apu_rvalid_o` |

### 4.5 구간 고르는 요령
- 0 ~ 수천 cycle: 부팅(BSS 클리어, 저장 루프만 보임).
- 가속기 동작은 수만 cycle 이후. 먼저 3장처럼 일반 sim으로 전체 cycle을 보고, 그 범위 안에서 잡는다.
- 특정 함수가 언제 실행되는지는 `gen/firmware_gen_*.dis`(disassembly)에서 함수 주소를 찾고, 파형의 `pc_id`가 그 주소일 때를 찾는다.

---

## 5. 자주 겪는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `TIMEOUT` | 최대 cycle 부족 → 세 번째 인자를 키운다(문장 생성은 스크립트가 자동으로 크게 줌) |
| `cmp`/비교에서 DIFF, `pass: false` | RTL이나 펌웨어 변경이 수치를 바꿈. `./reproduce.sh quick`으로 어느 항목인지 확인 |
| 빌드 실패 | `verilator_build*.log`(또는 `LOG=`로 지정한 파일) 끝부분 확인 |
| GTKWave 창이 안 뜸 | WSLg 미지원 → `.vcd`를 Windows 쪽 GTKWave로 연다 |
| VCD가 너무 큼 | 구간(`SIM_VCD_FROM/TO`)을 줄인다 |
| 첫 `fdiv.s`에서 CPU가 멈춤(직접 만든 top에서) | `scan_cg_en_i`를 리셋 동안 1로(`!rst_ni`). `docs/PLAYBOOK.md` §4 #10 |

---

## 6. 더 보기
- 단계별 설계·결정·결과: `docs/PLAYBOOK.md`, `PROGRESS.md`
- 시뮬레이터 내부(메모리 모델, 프로파일러, VCD 옵션): `sim.cpp` 맨 위 주석
- 빌드 옵션 전체: `build_sim.sh` 맨 위 주석
