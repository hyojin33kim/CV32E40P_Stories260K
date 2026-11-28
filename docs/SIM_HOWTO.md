# 시뮬레이션 실행 방법 (RTL, Vivado xsim, 디버그) — 2026-11-27

모든 명령은 저장소 루트에서 실행한다. 이 문서의 명령은 이 PC(WSL, Windows Vivado 2026.1, Verilator 5.038)에서 실행해 확인한 것이다. 이미지(`prof/chip_full_opta_d2/image_*.bin`)는 git에 없다(`docs/DEBUG_MODULE.md`, `docs/BOARD_BRINGUP.md` 참고). 기준 덤프는 `/mnt/e/fpga_work/board_kit/dump_sim_{1,128,512}.bin`(`pynq/pack_board_kit.sh`가 만듦)이다.
**규칙:** Vivado 작업(합성, xsim)은 한 번에 하나씩 직렬로 돌린다. 장시간 실행은 `timeout`과 크래시, 정체 감지를 건다(`docs/LESSONS_LEARNED.md` R13).

## 1. RTL 시뮬레이션 (Verilator, 기준 시뮬레이션)
```
TOP=soc_chip ./build_sim.sh                         # obj_chip/Vsoc_chip: CPU + 가속기 + imem + SRAM
obj_chip/Vsoc_chip prof/chip_full_opta_d2/image_1.bin /tmp/dump.bin
cmp /tmp/dump.bin /mnt/e/fpga_work/board_kit/dump_sim_1.bin      # 같아야 한다
```
- 정상: `DONE cycles=157437`(image_1), 214,257(image_128), 382,970(image_512).
- **보드와 같은 방식(AXI4-Lite로 적재):** `TOP=chip_axi_top ./build_sim.sh` 후 `obj_axi/Vchip_axi_top <image> <dump>`. `DONE cycles=157433`, `PERF`, `DBGREGS` 줄이 나온다.
- **전체 회귀(42개 항목):** `./reproduce.sh quick` (약 28분, 끝에 `42/42 OK`).
- **파형:** `TRACE=1 TOP=soc_chip ./build_sim.sh` 후 `SIM_VCD=<out.vcd> SIM_VCD_FROM=<시작 cycle> SIM_VCD_TO=<끝 cycle> <시뮬레이터> <image> <dump>`, 만들어진 `.vcd`는 GTKWave로 본다(`build_sim.sh` 머리말).
- **신호가 너무 많을 때(수천 개):** 큰 VCD에서 필요한 신호만 뽑아 작은 VCD와 GTKWave 저장 파일을 만든다.
  `python3 docs/wave/vcd_pick.py /tmp/w.vcd /mnt/e/fpga_work/wave/w_small.vcd /mnt/e/fpga_work/wave/w_small.gtkw` 후
  `gtkwave /mnt/e/fpga_work/wave/w_small.vcd /mnt/e/fpga_work/wave/w_small.gtkw &` (또는 `surfer <w_small.vcd>`). 기본 21개 신호:
  `clk_i`, 명령어 fetch(`i_req`, `i_addr`), CPU 데이터 포트(`d_*`), 가속기 포트(`a_*`), `g_busy`, `vfu_busy`, GEMV 상태(`acc_i.state_q`, `mode_q`),
  VFU 상태(`vfu_i.st_q`, `cmd_q`), 코어 제어 상태(`ctrl_fsm_cs`), `debug_halted_o`. 신호 경로를 인자로 주면 다른 신호도 뽑을 수 있다.
  저장 파일(`.gtkw`)은 GTKWave GUI에서 열어 확인하지 못했다(작은 VCD 자체는 그대로 열린다).
- **파형을 그림 파일로:** 뷰어 없이 이미지로 볼 때는 `python3 docs/wave/wave_svg.py <작은.vcd> docs/figures/waveform [reset loop gemv]`(진짜 파형 모양, SVG와 PNG)나
  `python3 docs/wave/wave_table.py <작은.vcd> prof/chip_full_opta_d2/fw.dis docs/figures/wave`(칸 표 모양, 8,000 cycle 개요 포함)를 쓴다. SVG를 PNG로 바꾸는 `rsvg-convert`가 필요하다
  (`sudo apt install librsvg2-bin`, 이 PC에는 2026-11-28에 설치함). 구간과 신호는 각 스크립트의 preset에 있다.
- **단위 시험:**
  - `acc/tb_conc/run_test.py`: 가속기 겹침과 보호(시나리오 1~6). `obj_soc/Vsoc_top` 필요(`TOP=soc_top ./build_sim.sh`).
  - `acc/tb_dbgregs/run_test.py`: 출력과 trap 관찰 레지스터. `obj_axi` 필요.
  - `acc/tb_axi_ext_rd/run.sh`와 `checks.sh`: AXI 외부 읽기 마스터(무작위 시험, 제약 위반, 변이).
  - `acc/tb_exp2/run.sh [시작hex 끝hex]`: exp2 전수 검사.

## 2. Vivado에서 (xsim)
```
fpga/xsim/run_xsim.sh prof/chip_full_opta_d2/image_1.bin /mnt/e/fpga_work/xsim_run
```
- RTL 작업 복사본에 xsim용 우회(클럭, FPU 표)를 적용하고 Vivado 프로젝트를 만들어 실행한 뒤 `obj_chip/Vsoc_chip` 결과와 비교한다. `obj_chip`을 먼저 빌드해 둔다. 약 3~4분.
- 정상: `TB DONE run_cycles=157433`과 `XSIM (XPM) dump == Verilator chip dump`.
- **안전장치:** `XSIM_PLUS="MAXCYC=600000"`(플러스 인자는 작업 폴더의 `plusargs.txt`로 전달되어 WSL에서도 적용된다)과 `timeout`을 건다. 멈추면 `no dump.hex`.
- **GUI 파형:** 세 번째 인자 `gui` (`run_xsim.sh <image> <workdir> gui`).
- **FPU만:** `fpga/xsim/run_fpu_test.sh`(3,896 벡터, RTL과 합성 후 네트리스트, 약 몇 분).
- **합성 후 전체 칩:** `fpga/xsim/run_xsim_net.sh`는 xsim BASIC 라이선스 한도(50,000개 인스턴스, 네트리스트 107,091개)로 막혀 있다(결정 D4). Verilator 경로는 `fpga/xsim/net_verilator/README.md`.
- **Linux Vivado:** `VIVADO`와 `FPGA_WORK` 환경변수를 설정한다(`fpga/xsim/README_LINUX.md`).
- 패치별 효과를 보려면 `FIXFMT=0`(패치 없음), `XW=fmt`(FPU 표만), `XW=rd`(`rd_ok`만). 2026-11-27부터 `rd_ok`는 저장소 RTL에서 고쳐져서 `XW=fmt`만으로 끝까지 간다(E13 이후, `docs/XSIM_VS_VERILATOR.md`).

## 3. 디버그 시뮬레이션 (디버그 모듈 + JTAG)
```
dbg/tb_dm/run.sh prof/chip_full_opta_d2/image_1.bin /mnt/e/fpga_work/board_kit/dump_sim_1.bin .scratch/tb_dm \
    +HALTS=6 +FIRST=20000 +STEP=22000
```
- JTAG 핀을 직접 구동하는 시험환경이 실행 중 halt, 레지스터 읽기와 쓰기, resume, 단일 스텝, 하드웨어 breakpoint까지 확인하고 끝까지 실행한다. 정상: `PASSED: 0 check failure(s)`, 덤프는 cycle 워드 2개(`0x1aff00`, `0x1ad000`)만 기준과 다르다. 약 1분.
- 옵션: `+VERBOSE=1`(모든 확인 출력), `+EBREAK=1`(이미지의 명령어 하나를 `ebreak`로 바꿔 진입 시험), `+EXTRA=0`(단일 스텝과 breakpoint 시험 끄기).
- 실제 TAP(`dmi_jtag_tap`)을 쓴다. FPGA 빌드도 같은 TAP을 쓴다(11-28부터, BSCANE2 변형은 사용하지 않음).
- **보드 최상위에 DM을 넣은 빌드(대기 상태 확인):** `TOP=chip_axi_top VXARGS="-DDM_BUILD -f dbg/dbg_files.f" ./build_sim.sh`.
- **시뮬레이션 자체를 디버그할 때:** Verilator는 위 1번의 파형, xsim은 `gui`와 `TRACE_N=<cycle>`, 두 시뮬레이터 비교는 `fpga/xsim/compare_trace.py`.
- 자세한 설계와 한계: `docs/DEBUG_MODULE.md`, `docs/DEBUG_CHIP_LEVEL.md`.
