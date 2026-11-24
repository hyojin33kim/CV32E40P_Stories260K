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
