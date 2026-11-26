"""Data of docs/EXPERIMENT_LOG.md and the sheets "실험 기록" / "판단 이력" of docs/VERIFICATION_PLAN.xlsx (written by docs/gen_verification_plan.py).
One record per experiment: what was done, the numbers as measured, what was observed, the interpretation that was given to the user with its
confidence, corrections and limits, what it changed, and the raw files (docs/experiments/raw/). Add a record after every experiment (rule R12).
Numbers are copied from the raw outputs; "추정" marks anything that is an estimate. Experiments before 11-22 are only pointed to (EARLIER)."""

FIELDS = ['ID', '날짜', '주제', '목적', '구성 / 명령', '결과 (측정값)', '관찰', '의견 / 해석 (확신도)', '정정 · 한계', '영향 · 후속', '원본 데이터 (raw/)']

EXPERIMENTS = [
 dict(id='E01', date='2026-11-22', topic='FPU: xsim RTL vs 합성 네트리스트',
  purpose='전체 칩 xsim과 Verilator의 cycle 차이(4,347,318 vs 4,501,912)가 FPU에서 오는지 분리한다.',
  setup='fpga/xsim/run_fpu_test.sh. 벡터 1,402개(MUL 301, ADD 300, DIV 300, SQRT 300, I2F 201; numpy float32 기준, 정상 범위, RNE), FPU_LAT 4, flags 0x400 고정.',
  result='xsim RTL 671/1402 (틀린 것: MUL 301/301, I2F 201/201, ADD 229/300; DIV, SQRT는 모두 정확. 첫 오류 #0: 0x3d1d9db1 × 0x3d1d9db1 = 0x7f800000, 기대 0x3ac21598). 합성 네트리스트(xsim) 1402/1402. Verilator RTL은 1402/1402로 확인했음(원본 출력 파일 없음).',
  observation='MUL과 I2F는 전부 틀리고 ADD는 일부만 틀리며 DIV, SQRT는 맞다. 지수를 계산하는 경로가 의심된다.',
  opinion='합성 결과는 맞고 xsim RTL만 틀리므로 하드웨어 결함이 아니라 시뮬레이터 평가 문제로 본다. 확신: 높음(E02, E03에서 입증).',
  caveat='Verilator 1402/1402의 원본 출력은 보존되지 않았다.',
  impact='원인 추적을 E02로 이어감. 전체 칩 불일치의 원인이 FPU 하나라는 뜻은 아니었음(E04에서 확인).',
  raw='fpu_after.out, fpu_net.out'),
 dict(id='E02', date='2026-11-22', topic='xsim 최소 재현: 포맷 표의 변수 인덱스 읽기',
  purpose='FPU 오류의 원인을 가장 작은 코드로 특정한다.',
  setup='fpga/xsim/tb_fpfmt.sv: fpnew_pkg의 FP_ENCODINGS와 같은 구조(packed array of packed struct)를 변수 인덱스, 상수 인덱스, 연결 상수, case 함수로 읽어 비교.',
  result='변수 인덱스: 5개 포맷 모두 exp=7, man=7, bias=63 (기대 exp 8/11/5/5/8, man 23/52/10/2/7). 상수 인덱스: exp 8, 11, 5, 5, 8로 정확. case 함수: 정확. 연결 상수 표도 변수 인덱스에서 exp=7.',
  observation='bias 63 = 2^6−1이라 지수 합이 64 어긋나며, 이것은 MUL, ADD, I2F의 오류 양상과 맞는다.',
  opinion='xsim이 packed array of packed struct의 변수 인덱스 읽기를 잘못 평가한다. 확신: 높음(상수 인덱스와 case는 정확).',
  caveat='xsim이 왜 7을 돌려주는지(내부 평가 방식)는 모른다. 벤더에 보고할지는 사용자 판단.',
  impact='우회 패치 fpga/xsim/xsim_workaround.py. docs/XSIM_VS_VERILATOR.md의 원인 1.',
  raw='fpfmt_repro.txt'),
 dict(id='E03', date='2026-11-22', topic='FPU: 우회 패치 효과',
  purpose='E02의 원인이 맞는지 패치 전후 결과로 확인한다.',
  setup='xsim_workaround.py가 fp_width, exp_bits, man_bits, bias를 상수 인덱스 case로 바꾼 작업 복사본으로 run_fpu_test.sh 재실행.',
  result='xsim RTL 1402/1402, 합성 네트리스트 1402/1402.',
  observation='패치 전 671/1402가 패치 후 1402/1402로 바뀜.',
  opinion='원인 확정. 확신: 높음.',
  caveat='패치는 xsim 작업 복사본에만 적용한다. 저장소의 RTL은 바꾸지 않았다.',
  impact='run_xsim.sh가 기본으로 패치를 적용(FIXFMT=0으로 끔).',
  raw='fpu_workaround.out'),
 dict(id='E04', date='2026-11-23', topic='전체 칩 xsim: 멈춤 추적과 해결',
  purpose='FPU 패치 후에도 전체 칩 xsim이 DONE에 도달하지 못하는 원인을 찾는다.',
  setup='이미지 prof/chip_full_opta_d2/image_1.bin(Verilator는 157,437 cycle에 DONE). fpga/xsim/run_xsim.sh, TRACE_N, PC_FROM/PC_TO, tb_chip.sv의 IF, VFU, XSPROBE 추적, compare_trace.py.',
  result='(a) FPU 패치만: 약 15시간 뒤에도 DONE 없음, 로그 "TB running 232,500,000"에서 수동 종료(정상은 약 157,000 cycle).\n'
         '(b) CPU 데이터 포트 trace(20만 cycle, Verilator 20,133 이벤트): 처음에는 18 cycle에서 "Verilator 0 / xsim x" 차이로 보였으나 저장(store) 응답의 의미 없는 값이었다. 이를 제외하면 4,462 이벤트가 동일하고 cycle 9,910 이후 xsim은 요청이 없다(Verilator는 10,085에 다음 요청).\n'
         '(c) 명령 fetch 9,900~10,300: 0x0100013c~0x01000148 루프 반복(acc_vfu_sum의 busy 폴링, 레지스터 0x30000044). FPU(APU) 요청 없음.\n'
         '(d) VFU: 10,032~10,035 st=1(LOAD) cmd=6(softmax2) n=1, 10,036에 st=6(XS) 진입 후 계속 6 (rsp=1, iss=1, rd_v=1, max=0x3ffe90a4).\n'
         '(e) XSPROBE: 10,036에는 rd_ok=0(rd_st_q가 아직 1), 10,037부터 st==XS, src<n, rd_ok(식 직접 계산도 1), 크레딧(0<32) 모두 참인데 x_req=0. 테스트벤치에서 직접 부른 rd_ok는 1.\n'
         '(f) vfu.sv의 rd_ok를 작업 복사본에서 인라인(5곳): DONE run_cycles=157,433(3분 30초), 덤프 2 MiB가 Verilator와 동일(sim.cpp는 157,437).',
  observation='원소 1개(n=1)의 softmax2에서 멈춘다. 상태가 XS로 들어간 다음 cycle에 rd_st_q가 바뀌는데, 그 사이 assign의 인자(상태 상수, src_q)는 바뀌지 않는다.',
  opinion='assign이 함수 인자만 감시하고 함수가 읽는 모듈 변수(rd_v_q, rd_st_q, rd_elem_q)의 변화에는 재평가하지 않는다고 해석한다. 인라인 패치로 해결된 것이 이 해석을 지지한다. 확신: 중간~높음.',
  caveat='이것이 xsim 버그인지 표준(LRM)이 허용하는 동작인지는 확인하지 않았다. 중간에 "SRAM 0 워드 미적재가 원인"이라고 추정했으나 근거가 의미 없는 차이였고 철회했다. xsim 15시간 대기는 로그 단위(cycle)와 예상 종료를 확인하지 않은 제 오판이다. 이전 불일치(4,347,318 vs 4,501,912)에서 패치별 기여는 분리하지 않았다. 합성 후 전체 칩과 보드는 미확인.',
  impact='docs/XSIM_VS_VERILATOR.md 원인 2, 규칙 R2, R10. 저장소 RTL의 rd_ok 수정 여부는 결정 D3(미정).',
  raw='trace_compare.txt, trace_compare2.txt, xsim_hang_window_trace.txt, xsim_fix.out, xsim_probe.out, xsim_vfu.out, xsim_pc.out, xsim_trace.out, xsim_full.out'),
 dict(id='E05', date='2026-11-23', topic='FPU 벡터 확장(경계값, SUB/F2I/비교), 연속 요청, 변이 시험',
  purpose='V-F1, V-F3, V-F4: 펌웨어가 쓰는 연산과 경계 피연산자, 파이프라인 중첩을 확인하고 시험이 틀림을 잡는지 본다.',
  setup='fpga/xsim/fpu_vectors.py(5열: op a b c flags), fpu_compare.py, fpu_verilator.cpp(stream 모드: 같은 연산 그룹을 매 cycle 요청). 벡터 3,896 = 기존 1,402 + 정상 범위 1,000 + 경계값 1,494. Verilator는 파이프라인 구성 AFTER, DISTRIBUTED 각각. 기대값: numpy float32와 RISC-V F 규칙(NaN은 0x7fc00000, fcvt.w.s 포화, NaN 비교는 0).',
  result='xsim RTL 3896/3896, 합성 네트리스트 3896/3896, Verilator RTL 3896/3896(일반 2구성 + 연속 2구성 = 4회).\n'
         '연속 요청: ADDMUL 1,768 ops / 1,771 cycles(1.00 cycle/op), NONCOMP 689 / 692(1.00), CONV 533 / 536(1.01), 동시 진행 최대 3개. DIVSQRT 906 ops / 12,172 cycles(13.43 cycle/op), 동시 1개. 요청 없는 결과 0건.\n'
         '변이 시험(입력만 바꾸고 기대값은 그대로): SUB를 ADD로 보내면 3505/3896(SUB 273/300 오류), F2I의 RTZ를 RNE로 바꾸면 3773/3896(F2I 119/300), 비교를 LT에서 LE로 바꾸면 3780/3896(FLT 100/400), I2F를 부호 없음으로 바꾸면 3891/3896(edge-I2F 5/13).\n'
         '기대값에 들어 있는 특수 결과: 정규 NaN 399개, Inf 219개, subnormal 76개.',
  observation='경계값까지 모두 일치했고, 연속 요청은 ADDMUL, NONCOMP, CONV에서 실제로 겹쳤다(동시 진행 3개).',
  opinion='이전에 우려한 subnormal, Inf, NaN, ±0과 펌웨어가 쓰는 SUB, F2I, 비교 연산이 RISC-V F 규칙과 일치한다. 확신: 중간~높음(기대값은 제가 규칙으로 만든 것).',
  caveat='예외 플래그는 비교하지 않았다(V-F2). 기대값은 독립 기준기(Spike 등)와 대조하지 않았다. xsim과 합성 네트리스트의 연속 요청은 구현하지 않았다. 서로 다른 연산 그룹 사이의 중첩은 시험하지 않았다. 처음에 FPU 빈칸을 "FMA, min, max"로 짚었으나 펌웨어는 쓰지 않았고(fw.dis 0건) 실제 빈칸은 SUB, F2I, 비교였다.',
  impact='V-F1, V-F3 통과, V-F4 부분. 검증 계획서와 규칙 R11.',
  raw='fpuv_run.out, fpu_xsim_new2.out'),
 dict(id='E06', date='2026-11-23', topic='사고: 낡은 결과 파일과 비교',
  purpose='(의도하지 않은 결과) E05의 첫 xsim 실행 결과를 어떻게 해석할지 기록한다.',
  setup='run_fpu_test.sh를 3,896 벡터로 실행. run_fpu_test.tcl은 fpu_out_rtl.hex가 있으면 RTL 시뮬레이션을 건너뛴다.',
  result='"rtl: 1402/3896 correct (result lines 1402, expected 3896)"와 카테고리별 전부 오류, 네트리스트는 3896/3896.',
  observation='결과 줄 수(1,402)가 기대값 줄 수(3,896)와 달랐다. 이전 1,402 벡터 실행의 결과 파일을 읽은 것이다.',
  opinion='RTL 결과는 무의미하다. 네트리스트 시뮬레이션은 매번 새로 돌므로 3896/3896은 유효. 제 확인 부족이다.',
  caveat='RTL 쪽 새 결과는 스크립트를 고친 뒤 다시 돌려 얻었다(E05).',
  impact='run_fpu_test.sh가 실행 시작 때 결과 파일을 지움. 규칙 R11.',
  raw='fpu_xsim_new.out'),
 dict(id='E07', date='2026-11-23', topic='AXI 외부 읽기 master(axi_ext_rd) 단독 시험',
  purpose='V-A2: 4 KB 경계, 슬레이브 지연과 정지, 오류 응답, 파라미터 범위를 확인한다.',
  setup='acc/tb_axi_ext_rd/(tb.cpp, run.sh, checks.sh). 무작위 AXI 슬레이브(ready 확률 1/0.5/0.1, 긴 정지, 지연 0~200 cycle, R beat 간격)와 가속기 line 요청(4 KB 경계 걸침, 긴 연속, 점프, 반복, 내림차순) + CPU word 읽기. 매 cycle 프로토콜 검사와 주소 해시 데이터 비교. 일반 21 seed, 오류 주입 11 seed.',
  result='5개 구성 모두 PASS (구성 MAXB/CRED/TD: acc line 합계 107,914, CPU 읽기 6,562, beat 114,476):\n'
         '16/48/8: burst 24,788, 최대 동시 burst 8, 최대 미해결 line 49. 오류 주입 burst 29,248.\n'
         '8/16/2: burst 32,616 (오류 주입 32,678), 최대 미해결 line 16.\n'
         '4/8/2: burst 44,979 (36,299), 8.   32/48/8: burst 22,205 (28,901), 49(오류 주입은 48).   48/63/4: burst 19,520 (24,991), 64(오류 주입은 62).\n'
         '평균 burst 길이(= 107,914 / burst 수): 4.35, 3.31, 2.40, 4.86, 5.53 line.\n'
         '오류 주입: 오류 beat 뒤 err_o가 켜지고(3 cycle 이내) 데이터 경로가 멈추지 않으며 리셋으로 지워짐.\n'
         '구성 제약 탐침: TD=1, 3, 6은 실패(응답 데이터가 한 칸씩 밀림), MAXB 64/CRED 48은 요청 190/3,399 발행 후 정지(deadlock), MAXB 16/CRED 8은 66/3,399 후 정지.\n'
         '변이 5건 모두 검출: 4 KB 검사 제거("burst 401aafc0 len 7 crosses 4 KB"), 오류 플래그 제거(오류 주입에서 "err_o not set"), 크레딧 제거("50 lines outstanding > CRED+1 49"), CPU word 선택 오류, TD 한도 제거("9 bursts outstanding > TD 8").',
  observation='미해결 line이 CRED+1까지 쓰인다(CPU 읽기는 크레딧 제한 밖). 무작위 계획의 평균 burst 길이는 2.4~5.5 line으로 짧다.',
  opinion='파라미터 제약 2개(CRED ≥ MAXB, TD는 2 이상의 2의 거듭제곱)는 RTL 결함이라기보다 허용 범위 문제이고 기본값에서는 안전하다. TD=1, 3에서 응답이 밀리는 이유는 태그 포인터 폭 가설이며 확인하지 않았다. 확신: 제약의 존재는 높음, 원인은 낮음.',
  caveat='평균 burst 길이는 무작위 계획 기준이라 실제 가중치 스트림의 값이 아니다. 전체 칩에서의 오류 주입은 하지 않았다. 마스터 쪽 백프레셔는 rready=1이라 없다. 첫 실행은 빌드 폴더가 없어 시험이 한 번도 돌지 못했는데 알림은 "completed"였다(출력을 확인해 발견).',
  impact='V-A2 통과. V-P3는 MAXB를 늘릴 때 CRED와 외부 FIFO(64 line)도 키워야 함. 결정 D7(오류 정책과 파라미터 어서션).',
  raw='axi_ext_rd_1.out, axi_checks.out'),
 dict(id='E08', date='2026-11-23', topic='GEMV, VFU 버퍼 한계 초과 동작',
  purpose='V-A1: 한계 안과 한계 초과에서 하드웨어가 어떻게 동작하는지, 보호가 있는지 확인한다.',
  setup='코드 확인: acc/gemv_acc.sv와 acc/vfu.sv에 $error, assert, 클램프가 없음(문서상 한계는 N ≤ XBUF, D ≤ YBUF, VFU n ≤ BUF). w8/overlimit.sh(run_test_w8.py에 TEST_CASES, TEST_MAXCYC 추가)와 vfu/overlimit.sh(run_test.py에 TEST_LN 추가). 시뮬레이터 obj_soc(버퍼 512)와 obj_soc_big(버퍼 1024, TEST_BIG=1). 사례: 한계, +1, +8, 2배, 양쪽 동시. VFU는 softmax, divsoftmax, softmax2에 청크 길이 512, 513, 520, 1024(테스트당 4,096 원소).',
  result='GEMV 버퍼 512 빌드: 512×8 통과, 8×512 통과. 초과: 513×8 실패(출력 8개 전부 틀림), 520×8(7개), 1024×4(4개), 8×513(4개), 8×520(8개), 4×1024(512개), 513×513(452개). 모두 종료 표식 0x600d600d, 센티널 위반 0, 소요 3분.\n'
         'GEMV 버퍼 1024 빌드: 1024×8, 8×1024 통과. 초과: 1025×8(7개), 1032×8(6개), 2048×4(4개), 8×1025(4개), 8×1032(8개), 4×2048(953개) 실패. 1025×1025는 크기 필터(n×d > 1 MiB)로 사례 0개, 판정 없음.\n'
         'VFU 버퍼 512: 길이 512는 불일치 0. 길이 513: softmax 14, divsoftmax 3,080, softmax2 21(그중 합계 불일치 7), 합 3,115. 길이 520: 2,128 / 3,640 / 119(합계 7), 합 5,887. 길이 1024: 4,096 / 4,096 / 4,087(합계 4), 합 12,279. 하드웨어 cycle은 한계 안과 거의 같음(약 348,000 / 374,000 / 160,000)이라 멈추지 않음.',
  observation='모든 초과 사례에서 시뮬레이션이 정상 종료하고 cycle 수가 거의 달라지지 않으며 오류 신호가 없다. 한 칸만 넘어도(513) 틀린 값이 나온다. GEMV 513×8에서는 출력이 전부 틀렸다.',
  opinion='버퍼 인덱스 폭($clog2(512) = 9비트)에서 인덱스가 되감겨 앞쪽 원소를 덮는다는 가설이 관찰과 맞는다(513×8 전부 틀림, VFU에서 한 칸 초과에도 다수 불일치). 확신: 중간(내부 신호는 보지 않았다). 펌웨어 규칙을 어기면 조용히 틀리는 설계이므로 시뮬레이션 전용 어서션을 권고한다.',
  caveat='되감김은 직접 확인하지 않은 가설이다. VFU는 softmax 계열(2, 5, 6)만 시험했다(silu, 나눗셈 계열은 미시험). 512 빌드의 시험 메모리 배치는 d, n = 1024까지 영역을 침범하지 않지만(4 KB 영역), 이보다 큰 사례는 1024 빌드의 BIG 배치로만 시험했다. 한계 초과 시험은 펌웨어가 지켜야 하는 규칙을 일부러 어긴 것이며, 현재 펌웨어가 어기는 경우가 있다는 뜻이 아니다.',
  impact='V-A1은 "부분"(한계 안 통과, 초과는 정의되지 않음). 결정 D7을 버퍼 한계 어서션까지 확장. 15M 펌웨어 포팅(V-G4)에서 한계 규칙(분류기 청크 1024)을 확인해야 함.',
  raw='a1_overlimit_512.out, a1_overlimit_1024.out, a1_vfu_overlimit.out'),
 dict(id='E09', date='2026-11-24', topic='FPU 연속 요청: xsim RTL과 합성 네트리스트',
  purpose='V-F4의 남은 부분: 연속 요청 모드를 xsim RTL과 합성 네트리스트에서도 확인한다.',
  setup='fpga/xsim/tb_fpu.sv에 STREAM 정의 모드 추가(요청 발행 process와 결과 수집 process를 fork로 분리, 같은 연산 그룹을 매 cycle 요청, 결과는 원래 벡터 순서로 저장). fpga/xsim/run_fpu_test.tcl이 rtl, rtl_stream, net, net_stream 4개 시뮬레이션을 실행. 벡터 3,896개(E05와 동일).',
  result='rtl 3896/3896, net 3896/3896, rtl-stream 3896/3896, net-stream 3896/3896, 요청 없는 결과 0건(소요 1분 42초).\n'
         'RTL 연속 통계: ADDMUL 1,768 ops / 1,771 cycles (동시 진행 최대 3), DIVSQRT 906 / 12,172 (1), NONCOMP 689 / 692 (3), CONV 533 / 536 (3). Verilator(E05)와 cycle 수까지 같다.\n'
         '합성 네트리스트 연속 통계: ADDMUL 1,772 cycles (최대 4), DIVSQRT 12,173 (1), NONCOMP 693 (4), CONV 537 (4).',
  observation='네트리스트는 모든 그룹에서 RTL보다 1 cycle 길고, 파이프라인 그룹은 동시 진행이 하나 더 많다(3→4). 결과 값과 순서는 모두 맞다.',
  opinion='값과 순서가 맞으므로 V-F4는 통과로 본다. 1 cycle 차이는 UNISIM 플립플롭의 출력 지연(약 100 ps로 추정)과 시험대의 결과 샘플 시점(#0.1 ns)이 겹쳐 결과가 한 cycle 늦게 보이는 시험대 효과일 가능성이 있다. 확신: 낮음(확인하지 않음). 합성된 파이프라인의 실제 지연이 1 cycle 다를 가능성은 배제하지 못했다.',
  caveat='서로 다른 연산 그룹 사이의 중첩은 시험하지 않았다. 1 cycle 차이의 원인은 미확인이다. 샘플 시점을 클럭 하강 에지로 바꾸어 다시 재면 구분할 수 있다.',
  impact='V-F4 통과. D4(합성 후 전체 칩 시뮬레이션)의 시험대는 결과 샘플을 posedge+0.1 ns가 아니라 negedge에서 하도록 설계한다.',
  raw='fpu_xsim_stream.out'),
 dict(id='E10', date='2026-11-24', topic='CPU, GEMV, VFU 동시 접근 (V-A3)',
  purpose='CPU와 가속기, 그리고 가속기끼리 동시에 활동할 때 결과가 순차 실행과 같은지 확인한다.',
  setup='펌웨어 시험 acc/tb_conc/test_conc.c와 run_test.py, SoC 시뮬레이터 obj_soc/Vsoc_top. 데이터: GEMV 256×128 int8(모드 D), VFU softmax 512, CPU 계산은 256워드 6회 반복(별도 메모리). 먼저 세 작업을 블로킹으로 실행해 시간을 잰다(보정: GEMV 8,780 cycle, VFU 24,991, CPU 17,723). 시나리오마다 시뮬레이터를 새로 실행. 가속기를 실행하지 않은 쪽은 비교에서 제외.',
  result='시나리오 1(GEMV 중 CPU 계산): 불일치 0, CPU 6회 중 2회가 GEMV 실행 중에 끝남, 17,781 cycle. 통과.\n'
         '시나리오 2(VFU 중 CPU 계산): 불일치 0, 6회 모두 VFU 실행 중에 끝남, 25,000 cycle. 통과.\n'
         '시나리오 3(GEMV 실행 ⅓ 지점에서 VFU 시작, 그때 GEMV busy=1): GEMV 시간 초과(busy가 풀리지 않음), GEMV 출력 128/128 틀림, VFU 출력 508/512 틀림, CPU 불일치 0, 1,770,760 cycle.\n'
         '시나리오 4(VFU 실행 ⅓ 지점에서 GEMV 시작, 그때 VFU busy=1): 불일치 0, 시간 초과 없음, 51,461 cycle(순차 합 8,780 + 24,991 + 17,723 = 51,494와 거의 같음).\n'
         '같은 시험을 두 번 실행해 결과가 같았다(결정적).',
  observation='가속기끼리의 겹침은 비대칭이다. VFU 실행 중 GEMV를 시작하면 GEMV의 요청이 막혔다가 풀려 직렬화되어 정상이고, GEMV 실행 중 VFU를 시작하면 GEMV가 멈추고 두 결과 모두 틀린다.',
  opinion='코드 읽기(acc/soc_top.sv)로 세운 가설과 맞는다: GEMV와 VFU가 메모리 포트를 하나 공유하고 소유권을 vfu_busy 하나로 정하므로, GEMV가 읽기 응답을 기다리는 중에 VFU가 시작되면 그 응답이 GEMV에서 막히고 VFU로 전달된다. 확신: 중간(내부 신호는 보지 않았다). 펌웨어는 매번 busy를 폴링하고 다음 명령을 시작하므로 정상 동작에서는 이 경우가 생기지 않는다. 하드웨어가 이를 막지는 않는다.',
  caveat='한 가지 크기와 한 가지 시작 시점(⅓)만 시험했다. CPU가 가속기와 같은 메모리 영역을 동시에 접근하는 경우는 정의되지 않은 동작이라 시험하지 않았다. CPU와 두 가속기를 모두 동시에 돌리는 경우도 시험하지 않았다. 첫 실행은 시험 오류로 판정할 수 없었다(실행하지 않은 가속기를 비교, 겹침 여부를 기록하지 않음). 보정을 넣고 고쳐서 이 결과를 얻었다.',
  impact='V-A3 "부분". 결정 D7에 "GEMV 실행 중 VFU 시작을 하드웨어가 막거나 대기시킬지"를 추가. 펌웨어 규칙(항상 busy 폴링 후 다음 명령)은 지켜야 하는 요구사항이 됨.',
  raw='a3_conc.out'),
 dict(id='E11', date='2026-11-24', topic='합성 후 전체 칩 시뮬레이션(D4)의 준비와 막힘',
  purpose='V-S1: 합성된 하드웨어(소자 수준 네트리스트)가 Verilator RTL과 같은 결과를 내는지 전체 칩과 같은 이미지(157,437 cycle)로 확인한다.',
  setup='fpga/synth.tcl에 NETLIST 토큰 추가, soc_chip을 125 MHz 목표로 합성(구현 없음, FPU 레지스터 DISTRIBUTED, 작업 폴더 /mnt/e/fpga_work/chip_net). xsim: fpga/xsim/run_xsim_net.sh, run_xsim_net.tcl, tb_chip.sv(NETLIST 조건: 내부 신호 추적 제외, GSR 200 ns 대기, +LOADMAX, +MAXCYC). Verilator: fpga/xsim/net_verilator/(prep.py, prim_models.v, net_top.sv)로 lint.',
  result='합성: 5분 45초, 네트리스트 45,394,243 바이트(약 789,000줄), LUT 60,189, 레지스터 20,675, URAM 64, DSP 93, BRAM 7, 합성 단계 WNS −0.499 ns(구현 전 값). 소자 25종 89,803개(LUT6 28,051, FDCE 18,083, LUT5 13,397, LUT3 8,063, LUT4 7,089, LUT2 6,313, LUT1 2,693, FDRE 2,468, CARRY8 1,554, MUXF7 904, MUXF8 397, RAM64M8 176, RAM32M16 139, FDSE 95, DSP48E2 93, SRL16E 93, RAM32M 65, URAM288 64, 그 외 소수), 시뮬레이터 인스턴스 107,091개.\n'
         'xsim: 3분 31초 후 오류 "Vivado Simulator license tier BASIC ... Number of instances in this design, 107091, exceed maximum allowed 50000". 시뮬레이션이 시작되지 않음.\n'
         'Verilator 1차 lint(4초): 오류 10건 = FDRE, FDSE, FDCE, FDPE, SRL16E 모델의 Verilog-1995 deassign 미지원 5건, URAM288, RAMB18E2, RAMB36E2, SRL16E의 specify 블록(PATHPULSE$ 식별자) 문법 오류 4건, 제 주석이 Verilator 지시어로 오인된 1건.\n'
         '조치: FF 5종은 직접 동작 모델(prim_models.v), 나머지 모델은 specify 블록 제거. 2차 lint(27초): 오류 51건으로 줄었고 모두 CARRY8(3,708건)과 DSP48E2(1,292건) 입력의 "tristate in top-level IO"(모델의 X !== 1\'bz 연결 판별). 조치: 판별을 상수로 치환.\n'
         '3차 lint: 변환 단계가 10분을 넘겨 메모리 6.5 GB(호스트 7.9 GB, 여유 88 MB)에 도달해 메모리 부족 위험으로 중단. 결과 없음.',
  observation='xsim은 라이선스 한도에, Verilator는 메모리에 막힌다. 작은 FPU 네트리스트는 xsim에서 정상(3,896/3,896).',
  opinion='Verilator 메모리 급증의 원인은 소자마다 INIT 파라미터가 달라서 인스턴스마다 모듈 사본이 만들어지기 때문으로 추정한다(미검증). 선택지: (a) xsim 라이선스 상향(사용자 작업, 이미 만든 run_xsim_net.sh로 바로 실행 가능), (b) WSL 메모리 상향(사용자 작업), (c) LUT, 플립플롭, 캐리 소자를 assign/always 문장으로 바꾸는 변환기를 직접 작성해 모듈 사본을 없앰(수 시간 작업, 변환 오류 위험은 같은 방식으로 변환한 FPU 네트리스트를 xsim 결과 3,896/3,896과 대조해 관리). 권고: (a) 또는 (b)를 먼저 확인. 확신: 선택지의 작업량은 낮음(추정), 메모리 원인은 낮음.',
  caveat='3차 lint를 중단했기 때문에 메모리를 더 주면 Verilator가 끝까지 변환하는지는 모른다. 직접 만든 FF 모델과 상수로 치환한 모델이 벤더 모델과 같은 동작이라는 것은 FPU 네트리스트 교차 검증으로 아직 확인하지 않았다. 합성 단계 WNS −0.499 ns는 구현 전 값이며 타이밍 판단에 쓰지 않는다(PS 연결 구현 결과는 WNS +0.100).',
  impact='V-S1은 "미실행(막힘)". 결정 D4를 막힌 경로의 선택으로 바꿈. fpga/synth.tcl의 NETLIST 토큰, run_xsim_net.sh 등은 라이선스가 풀리면 그대로 사용 가능.',
  raw='xsim_net_license_error.txt, net_speed_a.out, net_lint.out, net_lint2.out, net_lint3.out'),
 dict(id='E12', date='2026-11-25', topic='exp2 RTL 전 입력 전수 확인 (V-U2)',
  purpose='Option A의 exp2 파이프라인(acc/vfu_exp2.sv)이 C 모델(opta/exp2q.h)과 모든 입력에서 비트 단위로 같은지 확인한다.',
  setup='acc/tb_exp2/tb.cpp(Verilator, 모듈 vfu_exp2 단독). 32비트 입력 패턴 2^32개 전부(inf, NaN 포함, 모델도 이들을 정의함)를 한 cycle에 하나씩 넣고, 5 cycle 뒤 valid_o와 함께 나오는 결과를 exp2q_bits(입력)과 비교. 4개 구간을 4개 프로세스로 병렬 실행.',
  result='0x00000000~0x3fffffff: 1,073,741,824개, 불일치 0, 1분 13초. 0x40000000~0x7fffffff: 1,073,741,824개, 불일치 0, 1분 19초. 0x80000000~0xbfffffff: 1,073,741,824개, 불일치 0, 1분 18초. 0xc0000000~0xffffffff: 1,073,741,824개, 불일치 0, 1분 18초. 합계 4,294,967,296개 불일치 0.',
  observation='첫 구간(0x00000000~0x3fffffff)은 저장소의 이전 기록(acc/tb_exp2/q2.txt, q3.txt, q4.txt)에 없던 구간이다. 나머지 세 구간은 이전 기록과 같은 결과.',
  opinion='"모든 입력"은 이 모듈의 32비트 입력 공간 전체라는 뜻이고, 비교 대상은 C 모델이다. RTL이 모델과 같다는 것을 완전하게 보인 것이며, 모델 자체가 수학적 2^y와 얼마나 가까운지는 보여 주지 않는다(그 정확도는 opta/test_exp2q.c가 별도로 측정). 확신: 높음(전 입력 비교).',
  caveat='입력을 매 cycle 연속으로 넣는 경우만 시험했다(valid가 끊기거나 리셋이 중간에 걸리는 경우는 아님). vfu_exp2 단독 시험이라 VFU 안에서 앞단 연산(fsub, fmul)과 연결된 상태는 V-U1이 확인한다. 합성된 네트리스트에서는 시험하지 않았다(2^32개를 네트리스트로 돌리는 것은 현재 xsim 라이선스 한도로 불가, D4).',
  impact='V-U2 "통과". 이 시험은 이후 exp2 RTL을 바꿀 때마다 약 5분(4구간 병렬)이면 다시 돌릴 수 있다.',
  raw='exp2_q1.out, exp2_q2.out, exp2_q3.out, exp2_q4.out'),
 dict(id='E13', date='2026-11-25', topic='xsim 패치별 기여 분리 (V-G7)',
  purpose='전체 칩 xsim에서 두 평가 문제(FP_ENCODINGS 변수 인덱스, rd_ok 연속 할당)가 각각 무엇을 일으키는지 분리한다. 가설: rd_ok는 멈춤, FPU 표는 틀린 값.',
  setup='같은 이미지(prof/chip_full_opta_d2/image_1.bin)로 fpga/xsim/run_xsim.sh를 세 번: (A) FIXFMT=0, 패치 없음. (B) XW=rd, rd_ok 인라인만. (C) XW=fmt, FPU 표 패치만. 각각 MAXCYC=600000(정상은 약 157,000 cycle)과 40분 시간 상한. 단계마다 새 작업 폴더(/mnt/e/fpga_work/xsim_vg7_a, b, c). 실행: .scratch/vg7.sh.',
  result='(A) 600,000 cycle까지 DONE 없음(상한 도달), 덤프 없음. (B) DONE run_cycles=149,074(정상 157,433), 덤프가 Verilator와 5,718 바이트 다름. (C) 600,000 cycle까지 DONE 없음(상한 도달), 덤프 없음. 실행 시간: A 3분 31초, B 3분 21초, C 3분 27초(합계 약 10분).',
  observation='rd_ok 인라인이 없으면(A, C) 멈추고, FPU 표 패치가 없으면(B) 끝까지 가지만 값이 틀리다. 두 패치를 모두 적용한 경우(E04)만 Verilator와 비트 단위로 같다.',
  opinion='두 문제는 서로 독립이고 각각 필요하다. B의 cycle이 8,359(5%) 적은 것은 FPU 표가 틀려 분기, 반복 횟수가 달라졌기 때문으로 추정(미검증). 확신: 멈춤과 틀린 값의 분리는 높음(세 변형이 가설과 맞음), B의 cycle 차이 원인은 낮음.',
  caveat='A와 C가 "멈춤"이라는 것은 600,000 cycle(정상의 약 3.8배)까지 DONE이 없었다는 뜻이며, 무한히 멈춘다는 증명은 아니다. 한 이미지(image_1)에서만 했다. B의 틀린 5,718바이트가 어떤 텐서인지는 분석하지 않았다.',
  impact='V-G7 "통과". D3(rd_ok RTL 변경)의 근거 강화: rd_ok 문제는 xsim에서 실제로 멈춤을 만든다(Verilator에는 영향 없음). 도구 문제 발견: 아래 정정 참조.',
  raw='vg7.out, vg7_a_unbounded.out'),
 dict(id='E14', date='2026-11-26', topic='RISC-V Debug Module + JTAG: 시뮬레이션과 125 MHz 합성 (V-D1, V-D2)',
  purpose='코어의 디버그 기능(halt, 레지스터 접근, resume)을 JTAG으로 쓸 수 있게 riscv-dbg를 붙이고, 기본 동작을 바꾸지 않으면서 125 MHz 타이밍을 유지하는지 확인한다.',
  setup='dbg/(riscv-dbg 643607e, common_cells v1.24.0 일부, tc_clk), acc/soc_chip.sv(DM_EN, dm_* 버스), dbg/soc_chip_dm.sv, acc/chip_axi_top.sv(DM_BUILD). 시험: dbg/tb_dm(JTAG 핀을 비트 단위로 구동, image_1, 6번 halt와 resume). 합성: DM=1 PERIOD=8.0 fpga/run_chip.sh <dir> DM_BUILD (합성과 배치배선, Vivado 2026.1).',
  result='시뮬레이션: IDCODE 0x00000DB3, DTMCS version 1 abits 7, dmstatus.version 2; 6번 halt(run cycle 약 25k~135k, 매번 다른 dpc), dcsr.cause 3, abstract 레지스터 읽기/쓰기, resume, DONE까지 실행, 덤프는 cycle 워드 2개(0x1aff00, 0x1ad000)만 다름; 변이 시험(데이터 응답 경로 고장)은 실패로 검출; 이어서 추가한 시험: 단일 스텝 4회(매번 dcsr.cause 4, dpc 이동), 하드웨어 breakpoint(트리거, dpc 주소에 설정, 재개 직후 cause 2로 같은 주소에서 정지), 실행하다가 도달하는 주소의 breakpoint(루프의 다른 주소 0x01000102, 정지 확인), ebreak(이미지의 c.lui를 c.ebreak로 바꾸고 reset 직후 halt, dcsr.ebreakm 설정, cause 1과 dpc 0x01000088 확인, 대체된 명령어를 디버거로 대신 수행 후 정상 종료, 덤프 차이는 cycle 워드 2개). 기본 빌드(DM_EN=0): image_1/128/512가 157,437/214,257/382,970 cycle, 덤프 동일. 합성 반복(모두 DM=1, 125 MHz): v1(영역 판별이 grant와 DM 앞 경로에 직결): 합성 단계 WNS -1.651 ns, 중단. v2a(DM 요청을 한 단계 레지스터에 담음, imem 읽기 enable에도 영역 판별): 합성 단계 -0.992 ns, 중단. v2b(imem 읽기 enable의 판별 제거): 합성 단계 -0.468 ns, 배치배선 WNS -2.579 ns(TNS -2105, 실패 끝점 3,785, 최악 경로 8.19 ns: 코어 트리거 일치 레지스터에서 dm_busy_i_q의 D까지). v3(명령어 grant가 레지스터 값만으로 결정, 명령어와 데이터 stage 분리): 합성 단계 -0.468 ~ -0.589 ns, 배치배선 WNS +0.110 ns, TNS 0, 실패 끝점 0, WHS +0.012 ns, LUT 60,456, 레지스터 21,932, BRAM 7, URAM 64, DSP 93.',
  observation='v1은 코어의 트리거 일치 레지스터에서 명령어 주소, DM 영역 판별을 거쳐 DM 내부로 가는 28단 조합 경로가 임계가 되었다. DM 앞에 레지스터를 넣어도(v2b) 영역 판별이 명령어 grant에 남아 있으면 배치배선이 -2.579 ns로 실패했고, grant를 레지스터 값만으로 정하자(v3) 통과했다. imem 읽기 enable에서 영역 판별을 빼는 것만으로도 합성 단계 WNS가 -1.651에서 -0.992 ns로 개선되었다(v2 중간 단계).',
  opinion='125 MHz 유지가 가능하다. 기준(DM 없음, V-M1)의 WNS는 +0.249 ns였으므로 DM이 여유를 약 0.14 ns 줄였다. 단 두 실행은 같은 흐름이지만 별개의 배치배선이며, 배치배선 결과의 변동이 0.1 ns 정도일 수 있어(측정한 것은 아니고 추정) 이 차이를 DM의 비용이라고 단정하지는 않는다. 확신: 타이밍 통과는 높음(보고서), DM의 비용 크기는 낮음.',
  caveat='BSCANE2 변형(실제 FPGA JTAG 사슬)은 합성만 했고 시뮬레이션하지 못했다(Verilator에 BSCANE2 없음). 보드에서 OpenOCD로 붙여 본 적 없음(보드 JTAG 사슬의 위치, IR 코드 미확인). ebreak는 이미지를 바꿔(c.lui를 c.ebreak로) 시험했고, 일반 펌웨어의 ebreak(ebreakm 없이 breakpoint 예외)는 시험하지 않았다. 트리거는 1개(코어가 가진 수)와 한 가지 유형만 시험했다. SBA는 연결하지 않아 실행 중 메모리 읽기 불가. 이 변경 후 reproduce.sh quick은 42/42 OK(약 28분, raw/repro_dm.out). Vivado가 같은 RTL(v3)에서 배치배선 포함 실행을 두 번 합성 도중 비정상 종료(EXCEPTION_ACCESS_VIOLATION, Start Timing Optimization 단계)했고 세 번째 실행과 합성만 한 실행은 정상이었다. 원인 미확인(간헐적 도구 오류로 추정).',
  impact='V-D1(디버그 모듈 시뮬레이션) 통과, V-D2(125 MHz 합성) 통과. 기본 흐름에는 영향 없음(DM_EN=0, DM_BUILD 없음). 정식 비트스트림에 넣을지는 별도 결정(면적 +약 1,200 LUT는 합성 단계 값, 하드웨어 breakpoint는 임계 경로와 관련).',
  raw='dm_chip_route_summary.txt'),
]

# (date, what was said, what was found, where recorded)
CORRECTIONS = [
 ('11-23', 'xsim 전체 칩이 DONE에 도달하지 못한 원인은 SRAM 초기화 누락이라는 추정', '철회: 근거였던 trace 차이는 저장 응답의 의미 없는 값(Verilator 0 vs xsim x). 테스트벤치가 0 워드를 적재하지 않은 것은 보드 흐름과 다른 환경이라 고쳤지만 원인이라는 증거는 없음', 'E04'),
 ('11-23', 'xsim 로그 "TB running 2000000"을 보고 정상 진행이라고 보고', '오판: 단위가 cycle이고 정상 종료는 약 157,000 cycle이었다. 약 15시간 헛돎', 'E04, 규칙 R2'),
 ('11-23', 'VFU의 n=1 같은 경계 시험이 확인되지 않았다', '틀림: vfu/run_test.py가 7개 명령 모두에서 길이 1, 2, 8, 512와 무작위 1~512를 포함한다', 'E05 이전 점검, 블록별 점검 시트'),
 ('11-23', 'FPU 시험 빈칸은 F2I, 비교, min/max, FMA', '정정: 펌웨어는 FMA, fmin, fmax를 쓰지 않는다(fw.dis 0건). 실제 빈칸은 SUB, F2I, 비교(fsub 36, flt 27, fcvt.w.s 1)', 'E05'),
 ('11-23', 'xsim FPU 결과 "rtl: 1402/3896"', '무의미: 낡은 결과 파일(1,402줄)을 읽음. 재실행으로 3896/3896', 'E06, 규칙 R11'),
 ('11-23', 'axi_ext_rd 시험 실행 알림 "completed"', '시험이 돌지 못함: 빌드 폴더가 없어 빌드 실패였다. 출력을 확인하지 않았다면 통과로 오해할 뻔함', 'E07'),
 ('11-23', 'TD=1 실패는 TD 범위(2의 거듭제곱) 문제라는 가설', '지지됨: TD=1, 3, 6 모두 응답이 밀려 실패. 단, 내부 원인(포인터 폭)은 미확인', 'E07'),
 ('11-25', 'V-G7 첫 실행(약 3시간 헛돎)에서 XSIM_PLUS="MAXCYC=600000"이 적용되었다고 가정', '틀림: ~/bin/vivado가 cmd.exe로 Windows vivado를 실행하고 WSLENV가 비어 있어 환경변수가 전달되지 않는다. 상한이 없는 채 약 3시간(8,500만 cycle) 돌았다. 고침: run_xsim.sh가 plusargs.txt로 전달. 또한 장시간 실행에 시계 시간 상한과 실시간 출력이 없었고, 예상 시간(20분)에 진행 확인을 하지 않았다', 'E13, 규칙 R2'),
 ('11-26', 'DM 합성 대기 작업이 크래시를 감지하지 못함', 'Vivado가 합성 도중 비정상 종료했는데 대기 조건이 정상 종료와 프로세스 소멸만 보아 약 50분을 허비했다. 크래시 파일(hs_err), 로그 갱신 정지, 종료를 모두 감지하도록 고침(R13)', 'E14, 규칙 R13'),
]

# experiments before 11-22: details are in these documents / raw files, not re-summarized here
EARLIER = [
 ('P1: 보드 통합, 타이밍 마진, 성능 측정', 'docs/P1_REPORT.md'),
 ('S5b: 가중치를 DDR에서 AXI4로 읽기, 지연 민감도, CRED 스윕', 'acc/S5B_DDR_AXI.md, raw/sweep_ddr.txt'),
 ('I1: int8 가중치(행별 scale), 정확도와 비트 일치', 'w8/W8_I1.md, raw/w8_*.out'),
 ('PS 연결 125 MHz 비트스트림(WNS +0.100, WHS +0.008)', 'docs/BOARD_BRINGUP.md 0절, raw/board*.out'),
 ('합성 타이밍 반복(OOC, 150 MHz 시도 포함)', 'raw/chip_ddr*_synth.out, raw/chip_on125_synth.out, raw/cpu_*.txt, raw/soc_v2.txt'),
 ('15M 모델 크기, 주소 맵', 'docs/15M_ADDRESS_MAP.md, docs/size_model.py'),
 ('row/bank DRAM 모델(영향 2% 이하)', 'sim_axi_ddr.cpp (상세 수치는 이 기록에 없음)'),
 ('pre-tiled 가중치 GEMV', 'raw/tiled_verify.txt, w8/pretile.py'),
 ('reproduce.sh 회귀', 'raw/reproduce_quick*.out, raw/repro_*.txt'),
]
