# ② FPGA 합성 1차 — 현재 RTL은 ZCU104에 들어가지 않고 200 MHz도 못 맞춤 (2026-11-15)

## 결론
- **현재 설계(시뮬레이션 기준으로 작성)는 FPGA용으로 재구성이 필요.** 합성 결과 LUT 101.7%(초과), BRAM 0, WNS −9.876 ns @ 5 ns.
- 원인은 세 가지(사실, 합성 리포트): ① FPU 지연 0(조합) 설정 — CPU 자체 FPU가 최악 경로,
  ② 버퍼·FIFO가 BRAM이 아니라 FF+대형 mux로 합성, ③ VFU lane마다 전체 fpnew(나눗셈·변환 포함).
- 세 가지 모두 **수치(bit-exact)를 바꾸지 않고** 고칠 수 있는 구조 문제(추정). cycle 수는 바뀌므로 성능은 재측정 필요.

## 조건 (사실)
- Vivado 2026.1 (Windows, `H:\2026.1`), part `xczu7ev-ffvc1156-2-e` (ZCU104), out-of-context 합성,
  clock 5.0 ns(200 MHz) on `clk_i`. top `soc_top` (CV32E40P FPU=1 + gemv_acc 4 lanes RUN16 FIFO256 + vfu 4 lanes).
- 소스: `cv32e40p_fpu_manifest.flist`에서 시뮬레이션 전용(tracer, tb_wrapper, sim clock gate) 제외 +
  `fpga/cv32e40p_clock_gate_fpga.sv`(BUFGCE) + `acc/*.sv`. 스크립트 `fpga/prepare.py`, `fpga/synth.tcl`.
- 리포트: `fpga/reports_v1_soc_top/` (util_synth, util_synth_hier, timing_synth).

## 결과 (사실)
| 자원 | 사용 | XCZU7EV | 비율 |
|---|---:|---:|---:|
| CLB LUT | 234,266 | 230,400 | **101.68%** |
| CLB FF | 112,285 | 460,800 | 24.37% |
| BRAM tile | 0 | 312 | 0% |
| URAM | 0 | 96 | 0% |
| DSP | 39 | 1,728 | 2.26% |

| 계층 | LUT | FF | 비고 |
|---|---:|---:|---|
| gemv_acc | 96,060 | 71,478 | 자체(버퍼·FIFO·제어) 57,406 LUT / 71,478 FF, FPU 8개 ≈ 38.7K LUT |
| vfu | 126,943 | 37,168 | 자체 30,758 / 33,740, lane 4개 9.6K·20.6K·9.2K·55.9K LUT, 합산 FPU 0.85K |
| cv32e40p | 11,263 | 3,637 | core 9,678, FPU 1,600 |

timing: WNS −9.876 ns, TNS −167,924 ns(24,550 endpoint). 최악 경로 14.72 ns, logic level 69:
`cpu_i/core_i/id_stage_i/apu_operands_ex_o_reg → cs_registers_i/fflags_q_reg` — **CPU FPU(FPU_ADDMUL_LAT=0)의 조합 경로**.
→ 현재 구성의 CPU 자체 한계 ≈ 68 MHz(추정, 1/14.7 ns). HOLD 측정 설정을 그대로 쓴 결과.

## 원인과 수정 방향 (추정 포함)
1. **FPU 파이프라인**: `FPU_ADDMUL_LAT ≥ 1`(CPU와 가속기 모두). 연산·반올림은 동일하고 지연만 늘어 bit-exact 유지.
   - GEMV: 누적 덧셈의 지연을 행 interleave로 숨김(lane당 L_a개 행을 번갈아 누적) → lane당 1 MAC/cycle 유지.
   - VFU: 이미 handshake 방식이라 그대로 동작(원소당 cycle 증가 → lane 수로 보상).
   - CPU: SW 기준선 cycle이 바뀜 → 모든 기준선·가속비 재측정 필요.
2. **버퍼를 BRAM으로**: 배열마다 쓰기 포트 1개, 읽기 등록(1 cycle) 구조로 변경.
   - gemv `xbuf`(1R1W), `ybuf`는 lane별 bank, lane FIFO는 4-word bank 또는 128-bit 폭 FIFO.
   - vfu `abuf/bbuf`는 index mod lane으로 bank(lane p가 원소 p, p+4, … 담당 → 충돌 없음).
3. **VFU lane 면적**: fpnew 전체 대신 lane에 필요한 연산(ADDMUL, DIV, F2I/I2F)만. lane 3의 55.9K LUT는
   다른 lane(9~20K)의 3~6배 — 버퍼 쓰기 경로가 특정 lane 쪽에 합쳐진 것으로 추정, BRAM화 후 재확인.

## 다음
1. CPU 단독 FPU_ADDMUL_LAT 0/1/2 합성 → Fmax 확인(가장 빠른 확인).
2. 가속기 BRAM화 + FPU 파이프라인 RTL 수정 → sim으로 bit-exact 재확인(단위 테스트·E2E) → 재합성 → place & route.
3. 성능 재측정(새 FPU 지연 기준 SW 기준선 포함).
