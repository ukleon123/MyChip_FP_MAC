`timescale 1ns / 1ps

// ================================================================
//  tb_TOP_random : 랜덤 입력 기반 자동 채점 테스트벤치
//  - 1000회 반복, 매회 9개 weight / 9개 input 을 랜덤 생성
//  - 700회: nan/inf 없는 정상값,  300회: 랜덤값 사이에 nan/inf 주입
//  - magnitude 프로파일: 90% no-overflow / 10% overflow
//  - 원소별 mode(E4M3/E5M2) 개별 랜덤
//  - 정상 케이스: 실수 골든모델 + 상대오차 채점
//  - nan/inf 주입 케이스: 출력 raw byte 가 NaN 인코딩인지 확인
//  - overflow 케이스: 누산 saturate -> 출력 포맷 max(0x7E/0x7B)인지 확인
// ================================================================

module tb_TOP_random;

reg clk, rstn;
reg ssn, mosi, sclk_reg;
wire miso;

TOP u_top (
    .i_clk  (clk),
    .i_rstn (rstn),
    .i_ssn  (ssn),
    .i_mosi (mosi),
    .i_sclk (sclk_reg),
    .o_miso (miso)
);

// System clock: 100MHz (10ns)
parameter CLK_PERIOD = 10;
always #(CLK_PERIOD/2) clk = ~clk;

// SPI clock half period: 50ns (10MHz)
parameter SCLK_HALF = 50;

// ================================================================
//  Test parameters
// ================================================================
parameter integer NUM_TESTS    = 1000;
parameter integer NUM_SPECIAL  = 300;   // nan/inf 주입 케이스 수
parameter integer OVERFLOW_PCT = 10;    // 누산 오버플로 케이스 비율(%)
parameter real    REL_TOL_E4M3 = 0.20;  // read E4M3 상대오차 허용
parameter real    REL_TOL_E5M2 = 0.30;  // read E5M2 상대오차 허용
parameter real    ABS_FLOOR    = 0.001; // 0 근처 절대오차

// ================================================================
//  SPI master tasks (tb_TOP.v 와 동일)
// ================================================================
task spi_transfer;
    input  [15:0] tx_data;
    output [15:0] rx_data;
    integer i;
    begin
        ssn = 1'b0;
        #(SCLK_HALF);
        for (i = 15; i >= 0; i = i - 1) begin
            mosi = tx_data[i];
            #(SCLK_HALF);
            sclk_reg = 1'b1;
            #1;
            rx_data[i] = miso;
            #(SCLK_HALF - 1);
            sclk_reg = 1'b0;
        end
        mosi = 1'b0;
        #(SCLK_HALF);
        ssn = 1'b1;
        #(CLK_PERIOD * 20);
    end
endtask

reg [15:0] rx_dummy;

task spi_cmd;
    input [2:0]  cmd;
    input [7:0]  data;
    input [3:0]  addr;
    input        mode;
    begin
        spi_transfer({cmd, data, addr, mode}, rx_dummy);
    end
endtask

// ================================================================
//  FP8 -> real conversion (tb_TOP.v 와 동일)
// ================================================================
function real e4m3_to_real;
    input [7:0] val;
    real mantissa;
    integer exp_int;
    begin
        if (val[6:3] == 0 && val[2:0] == 0)
            e4m3_to_real = 0.0;
        else begin
            mantissa = 1.0 + val[2:0] / 8.0;
            exp_int  = val[6:3] - 7;
            e4m3_to_real = (val[7] ? -1.0 : 1.0) * mantissa * (2.0 ** exp_int);
        end
    end
endfunction

function real e5m2_to_real;
    input [7:0] val;
    real mantissa;
    integer exp_int;
    begin
        if (val[6:2] == 0 && val[1:0] == 0)
            e5m2_to_real = 0.0;
        else begin
            mantissa = 1.0 + val[1:0] / 4.0;
            exp_int  = val[6:2] - 15;
            e5m2_to_real = (val[7] ? -1.0 : 1.0) * mantissa * (2.0 ** exp_int);
        end
    end
endfunction

// 원소 mode 에 맞춰 real 변환
function real fp_to_real;
    input       mode;     // 0:E4M3 1:E5M2
    input [7:0] val;
    begin
        fp_to_real = mode ? e5m2_to_real(val) : e4m3_to_real(val);
    end
endfunction

// ================================================================
//  랜덤 FP8 생성
//   mode 0(E4M3): {s, exp4, mant3}, stored exp = texp+7  (clamp 1..14)
//   mode 1(E5M2): {s, exp5, mant2}, stored exp = texp+15 (clamp 1..30)
// ================================================================
integer seed;

function [7:0] gen_fp;
    input        mode;
    input integer texp;
    integer e, m, s;
    begin
        s = {$random(seed)} % 2;
        if (mode == 0) begin                 // E4M3
            e = texp + 7;
            if (e < 1)  e = 1;
            if (e > 14) e = 14;
            m = {$random(seed)} % 8;
            gen_fp = {s[0], e[3:0], m[2:0]};
        end else begin                        // E5M2
            e = texp + 15;
            if (e < 1)  e = 1;
            if (e > 30) e = 30;
            m = {$random(seed)} % 4;
            gen_fp = {s[0], e[4:0], m[1:0]};
        end
    end
endfunction

// ================================================================
//  per-test 작업 배열 (매 테스트 재사용)
// ================================================================
reg [7:0] tw  [0:8];   // weight 8bit
reg       twm [0:8];   // weight mode
reg [7:0] ti  [0:8];   // input  8bit
reg       tim [0:8];   // input  mode

reg        read_mode;
reg        is_special;
reg        is_overflow;
// coverage 구멍을 닫기 위한 추가 자극 종류
reg        is_zero_c;    // 전부 0 입력 -> 결과 0
reg        is_unflow;    // 극소값 -> FPU/누산 underflow
reg        is_sat;       // 1레인 대형값 -> 출력 포맷 포화(saturate)
integer    subkind;

real expected, scale, prod, w_real, i_real, actual, error_val, threshold, tol;
reg [15:0] result;
reg [7:0]  exp_byte;

integer pass_count, fail_count;
integer t, k;
integer texp;

// special 케이스 배치 (정확히 NUM_SPECIAL 개)
reg special_flag [0:NUM_TESTS-1];
integer sh_j, sh_tmp;

// nan/inf 주입용
integer ninj, n, pos, wi, specsel;
reg [7:0] sval;

// ---- 오차 통계 (정상 케이스 전용) ----
real    abs_err, rel_err;
real    sum_abs_err, sum_rel_err, max_rel_err;
real    sum_rel_e4m3, sum_rel_e5m2;
integer norm_count, cnt_e4m3, cnt_e5m2;

// ================================================================
//  Functional coverage (priority-1: DUT 내부 분기 커버리지)
//   내부 신호 계층 참조로 각 모듈의 출력 분기를 샘플링한다.
//   - FPU      : 누산 active 동안 3개 인스턴스 모두 샘플 (9곱 모두 통과)
//   - ACC_adder: 누산 active 동안 1개 adder 샘플
//   - ACC_R    : write(i_wen) 시점에 mode별 샘플
// ================================================================
// FPU (u_fpu0/1/2 공유 bin)
integer cov_fpu_nan, cov_fpu_zin, cov_fpu_ovf, cov_fpu_uflow, cov_fpu_norm;
integer cov_fpu_rup, cov_fpu_rovf;
// ACC_adder
integer cov_add_nan, cov_add_bothzero, cov_add_azero, cov_add_bzero;
integer cov_add_ovf, cov_add_uflow, cov_add_norm;
integer cov_add_same, cov_add_diff, cov_add_shiftout;
integer cov_add_carry, cov_add_noshift, cov_add_cancel, cov_add_zero;
// ACC_R E4M3
integer cov_r4_nan, cov_r4_sat, cov_r4_zero, cov_r4_norm, cov_r4_carry;
// ACC_R E5M2
integer cov_r5_nan, cov_r5_sat, cov_r5_zero, cov_r5_norm, cov_r5_carry;
integer cov_holes;

// ================================================================
//  1회 실행 : reset -> LOAD_W -> LOAD_I -> COMPUTE -> ACC -> READ
// ================================================================
task run_dut;
    integer j;
    begin
        // Reset DUT
        rstn = 0;
        ssn = 1; mosi = 0; sclk_reg = 0;
        #(CLK_PERIOD * 10);
        rstn = 1;
        #(CLK_PERIOD * 10);

        // LOAD_W x9 (cmd=000)
        for (j = 0; j < 9; j = j + 1)
            spi_cmd(3'b000, tw[j], j[3:0], twm[j]);

        // LOAD_I x9 (cmd=001)
        for (j = 0; j < 9; j = j + 1)
            spi_cmd(3'b001, ti[j], j[3:0], tim[j]);

        // COMPUTE (cmd=010)
        spi_cmd(3'b010, 8'h00, 4'h0, 1'b0);
        #500;

        // ACC (cmd=011)
        spi_cmd(3'b011, 8'h00, 4'h0, 1'b0);
        #3000;

        // READ_RESULT (cmd=100), mode = read_mode
        spi_cmd(3'b100, 8'h00, 4'h0, read_mode);
        #500;

        // Dummy SPI read -> result via MISO
        spi_transfer(16'h0000, result);
    end
endtask

// FAIL 시 입력 덤프
task dump_inputs;
    integer j;
    begin
        for (j = 0; j < 9; j = j + 1)
            $display("        lane%0d | W(m%0d)=0x%02h  I(m%0d)=0x%02h",
                     j, twm[j], tw[j], tim[j], ti[j]);
    end
endtask

// ================================================================
//  Coverage 샘플링 task / always
// ================================================================
// FPU 출력 분기 (우선순위: nan, zero입력, overflow, underflow, normal)
task cov_fpu;
    input nan, zin, ovf, uflow, rup, rovf;
    begin
        if      (nan)   cov_fpu_nan   = cov_fpu_nan   + 1;
        else if (zin)   cov_fpu_zin   = cov_fpu_zin   + 1;
        else if (ovf)   cov_fpu_ovf   = cov_fpu_ovf   + 1;
        else if (uflow) cov_fpu_uflow = cov_fpu_uflow + 1;
        else            cov_fpu_norm  = cov_fpu_norm  + 1;
        if (rup)  cov_fpu_rup  = cov_fpu_rup  + 1;
        if (rovf) cov_fpu_rovf = cov_fpu_rovf + 1;
    end
endtask

// 매 클럭 내부 신호 샘플
always @(posedge clk) begin
    // ---- FPU 분기 (누산 진행 중, 3개 인스턴스 모두) ----
    if (u_top.u_acc.active) begin
        cov_fpu(u_top.u_fpu0.weight_is_nan_or_inf | u_top.u_fpu0.input_is_nan_or_inf,
                u_top.u_fpu0.weight_is_zero       | u_top.u_fpu0.input_is_zero,
                u_top.u_fpu0.overflow, u_top.u_fpu0.underflow,
                u_top.u_fpu0.round_up, u_top.u_fpu0.round_overflow);
        cov_fpu(u_top.u_fpu1.weight_is_nan_or_inf | u_top.u_fpu1.input_is_nan_or_inf,
                u_top.u_fpu1.weight_is_zero       | u_top.u_fpu1.input_is_zero,
                u_top.u_fpu1.overflow, u_top.u_fpu1.underflow,
                u_top.u_fpu1.round_up, u_top.u_fpu1.round_overflow);
        cov_fpu(u_top.u_fpu2.weight_is_nan_or_inf | u_top.u_fpu2.input_is_nan_or_inf,
                u_top.u_fpu2.weight_is_zero       | u_top.u_fpu2.input_is_zero,
                u_top.u_fpu2.overflow, u_top.u_fpu2.underflow,
                u_top.u_fpu2.round_up, u_top.u_fpu2.round_overflow);

        // ---- ACC_adder 출력 분기 ----
        // 우선순위: nan, both_zero, a_zero, b_zero, overflow, underflow, normal
        if      (u_top.u_acc.u_adder.a_is_nan_or_inf | u_top.u_acc.u_adder.b_is_nan_or_inf)
            cov_add_nan      = cov_add_nan + 1;
        else if (u_top.u_acc.u_adder.a_is_zero & u_top.u_acc.u_adder.b_is_zero)
            cov_add_bothzero = cov_add_bothzero + 1;
        else if (u_top.u_acc.u_adder.a_is_zero)
            cov_add_azero    = cov_add_azero + 1;
        else if (u_top.u_acc.u_adder.b_is_zero)
            cov_add_bzero    = cov_add_bzero + 1;
        else if (u_top.u_acc.u_adder.overflow)
            cov_add_ovf      = cov_add_ovf + 1;
        else if (u_top.u_acc.u_adder.underflow)
            cov_add_uflow    = cov_add_uflow + 1;
        else
            cov_add_norm     = cov_add_norm + 1;

        // 덧셈(동부호) vs 뺄셈(이부호 상쇄)
        if (u_top.u_acc.u_adder.same_sign) cov_add_same = cov_add_same + 1;
        else                               cov_add_diff = cov_add_diff + 1;
        // 작은 항이 완전히 shift-out
        if (u_top.u_acc.u_adder.exp_diff >= 5'd8) cov_add_shiftout = cov_add_shiftout + 1;

        // 정규화 shape (mant_raw 선행 1 위치)
        if      (u_top.u_acc.u_adder.mant_raw[8])      cov_add_carry   = cov_add_carry   + 1; // 1X.x (carry)
        else if (u_top.u_acc.u_adder.mant_raw[7])      cov_add_noshift = cov_add_noshift + 1; // 01.x (no shift)
        else if (|u_top.u_acc.u_adder.mant_raw[6:0])   cov_add_cancel  = cov_add_cancel  + 1; // 상쇄 left-shift
        else                                           cov_add_zero    = cov_add_zero    + 1; // 완전 상쇄=0
    end

    // ---- ACC_R 출력 분기 (write 시점, mode별) ----
    if (u_top.u_acc_r.i_wen) begin
        if (u_top.u_acc_r.i_mode == 1'b0) begin                         // E4M3
            if      (u_top.u_acc_r.is_nan)                       cov_r4_nan  = cov_r4_nan  + 1;
            else if ($signed(u_top.u_acc_r.e4m3_exp) >  7'sd15)  cov_r4_sat  = cov_r4_sat  + 1;
            else if (u_top.u_acc_r.is_zero ||
                     $signed(u_top.u_acc_r.e4m3_exp) <= 7'sd0)   cov_r4_zero = cov_r4_zero + 1;
            else                                                 cov_r4_norm = cov_r4_norm + 1;
            if (u_top.u_acc_r.mant_carry)                        cov_r4_carry = cov_r4_carry + 1;
        end else begin                                                  // E5M2
            if      (u_top.u_acc_r.is_nan)                       cov_r5_nan  = cov_r5_nan  + 1;
            else if (u_top.u_acc_r.e5m2_exp >= 6'd31)            cov_r5_sat  = cov_r5_sat  + 1;
            else if (u_top.u_acc_r.is_zero)                      cov_r5_zero = cov_r5_zero + 1;
            else                                                 cov_r5_norm = cov_r5_norm + 1;
            if (u_top.u_acc_r.mant_carry)                        cov_r5_carry = cov_r5_carry + 1;
        end
    end
end

// 커버리지 bin 1개 리포트 + hole 카운트
task cov_report1;
    input [127:0] nm;
    input integer cnt;
    begin
        $display("    %-18s : %0d%s", nm, cnt, (cnt==0) ? "   <== HOLE" : "");
        if (cnt == 0) cov_holes = cov_holes + 1;
    end
endtask

// ================================================================
//  Main
// ================================================================
initial begin
    clk = 0;
    ssn = 1; mosi = 0; sclk_reg = 0;
    pass_count = 0;
    fail_count = 0;
    seed = 32'h1234_5678;

    sum_abs_err  = 0.0;
    sum_rel_err  = 0.0;
    max_rel_err  = 0.0;
    sum_rel_e4m3 = 0.0;
    sum_rel_e5m2 = 0.0;
    norm_count   = 0;
    cnt_e4m3     = 0;
    cnt_e5m2     = 0;

    // ---- coverage bins 초기화 ----
    cov_fpu_nan=0; cov_fpu_zin=0; cov_fpu_ovf=0; cov_fpu_uflow=0; cov_fpu_norm=0;
    cov_fpu_rup=0; cov_fpu_rovf=0;
    cov_add_nan=0; cov_add_bothzero=0; cov_add_azero=0; cov_add_bzero=0;
    cov_add_ovf=0; cov_add_uflow=0; cov_add_norm=0;
    cov_add_same=0; cov_add_diff=0; cov_add_shiftout=0;
    cov_add_carry=0; cov_add_noshift=0; cov_add_cancel=0; cov_add_zero=0;
    cov_r4_nan=0; cov_r4_sat=0; cov_r4_zero=0; cov_r4_norm=0; cov_r4_carry=0;
    cov_r5_nan=0; cov_r5_sat=0; cov_r5_zero=0; cov_r5_norm=0; cov_r5_carry=0;
    cov_holes=0;

    // ---- special 케이스 분배: 앞 NUM_SPECIAL 개 1 후 Fisher-Yates 셔플 ----
    for (k = 0; k < NUM_TESTS; k = k + 1)
        special_flag[k] = (k < NUM_SPECIAL) ? 1'b1 : 1'b0;
    for (k = NUM_TESTS-1; k > 0; k = k - 1) begin
        sh_j = {$random(seed)} % (k + 1);
        sh_tmp              = special_flag[k];
        special_flag[k]     = special_flag[sh_j];
        special_flag[sh_j]  = sh_tmp[0];
    end

    $display("");
    $display("================================================================");
    $display("  FP MAC RANDOM Testbench  - %0d tests (%0d special)",
             NUM_TESTS, NUM_SPECIAL);
    $display("================================================================");

    for (t = 0; t < NUM_TESTS; t = t + 1) begin
        is_special  = special_flag[t];
        // special 은 항상 normal 프로파일 + nan/inf 주입 (출력은 어차피 NaN)
        is_overflow = is_special ? 1'b0 :
                      (({$random(seed)} % 100) < OVERFLOW_PCT);
        read_mode   = {$random(seed)} % 2;

        // ---- non-special/non-overflow 안에서 커버리지 보강 자극 선택 ----
        is_zero_c = 1'b0; is_unflow = 1'b0; is_sat = 1'b0;
        if (!is_special && !is_overflow) begin
            subkind = {$random(seed)} % 100;
            if      (subkind < 6)  is_zero_c = 1'b1;   //  6% : 전부 0
            else if (subkind < 12) is_unflow = 1'b1;   //  6% : underflow
            else if (subkind < 20) is_sat    = 1'b1;   //  8% : saturate
        end

        // ---- 9쌍 랜덤 생성 ----
        for (k = 0; k < 9; k = k + 1) begin
            twm[k] = {$random(seed)} % 2;     // 원소별 mode 개별 랜덤
            tim[k] = {$random(seed)} % 2;

            if (is_zero_c) begin
                // 모든 레인 0 -> 곱 0, 누산 0 -> FPU zero-in / ADD both_zero / ACC_R zero
                tw[k] = 8'h00; ti[k] = 8'h00;
            end else if (is_unflow) begin
                // E5M2 극소 지수 -> 곱이 FPU underflow, 누산도 underflow -> ACC_R zero/uflow
                twm[k] = 1'b1; tim[k] = 1'b1;
                tw[k] = gen_fp(1'b1, -14 + ({$random(seed)} % 2));
                ti[k] = gen_fp(1'b1, -14 + ({$random(seed)} % 2));
            end else if (is_sat) begin
                // lane0 만 FPU overflow 시키는 대형 양수(-> max_val=1.875*2^15),
                // 나머지는 0 -> 누산이 NaN 안 되고 유한 대형값 유지 -> ACC_R saturate.
                // (ADD b_zero 도 함께 커버)
                if (k == 0) begin
                    twm[0] = 1'b1; tim[0] = 1'b1;
                    tw[0] = gen_fp(1'b1, 12); ti[0] = gen_fp(1'b1, 12);
                    tw[0][7] = 1'b0; ti[0][7] = 1'b0;   // 양수 고정
                end else begin
                    tw[k] = 8'h00; ti[k] = 8'h00;
                end
            end else begin
                // 기존 normal/overflow 프로파일
                texp = is_overflow ? (8 + ({$random(seed)} % 5))   // 8..12 -> overflow
                                   : (-2 + ({$random(seed)} % 5)); // -2..2 -> 안전
                tw[k] = gen_fp(twm[k], texp);

                texp = is_overflow ? (8 + ({$random(seed)} % 5))
                                   : (-2 + ({$random(seed)} % 5));
                ti[k] = gen_fp(tim[k], texp);

                // overflow 케이스는 부호를 양수로 고정 -> 상쇄(cancellation) 제거 ->
                // 9개 큰 양수 누산이 반드시 표현범위를 초과해 결정적으로 saturate(max_val) 출력.
                // (부호 랜덤 시 큰 양/음수가 상쇄되어 유한값으로 떨어질 수 있음)
                if (is_overflow) begin
                    tw[k][7] = 1'b0;
                    ti[k][7] = 1'b0;
                end
            end
        end

        // ---- special: nan/inf 주입 (반드시 mode=1 E5M2) ----
        if (is_special) begin
            ninj = 1 + ({$random(seed)} % 3);   // 1..3 개 주입
            for (n = 0; n < ninj; n = n + 1) begin
                pos     = {$random(seed)} % 9;
                wi      = {$random(seed)} % 2;   // 0:weight 1:input
                specsel = {$random(seed)} % 4;
                case (specsel)
                    0: sval = 8'h7C;  // +Inf
                    1: sval = 8'hFC;  // -Inf
                    2: sval = 8'h7E;  // +NaN
                    3: sval = 8'hFE;  // -NaN
                endcase
                if (wi == 0) begin twm[pos] = 1'b1; tw[pos] = sval; end
                else         begin tim[pos] = 1'b1; ti[pos] = sval; end
            end
        end

        // ---- 실수 골든 (정상 케이스 채점에만 사용) ----
        expected = 0.0;
        scale    = 0.0;
        for (k = 0; k < 9; k = k + 1) begin
            w_real = fp_to_real(twm[k], tw[k]);
            i_real = fp_to_real(tim[k], ti[k]);
            prod   = w_real * i_real;
            expected = expected + prod;
            scale    = scale + (prod < 0.0 ? -prod : prod);
        end
        // ReLU 반영: 설계가 출력단에서 음수(비-NaN)를 0으로 클램프하므로
        // 정상 케이스 골든값도 음수면 0으로 만든다. (scale 은 임계값용이라 유지)
        if (expected < 0.0) expected = 0.0;

        // ---- DUT 실행 ----
        run_dut;

        // ---- 채점 ----
        if (is_special) begin
            // nan/inf 주입 -> NaN 출력 기대 : read E4M3 -> 0x7F, read E5M2 -> 0x7D
            exp_byte = read_mode ? 8'h7D : 8'h7F;
            if (result[7:0] === exp_byte) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] Test%04d | special | read=%s Expected=0x%02h Actual=0x%02h",
                         t+1, read_mode ? "E5M2" : "E4M3", exp_byte, result[7:0]);
                dump_inputs;
            end
        end else if (is_overflow || is_sat) begin
            // 누산 overflow -> ACC_adder가 NaN이 아니라 max_val로 saturate.
            // 포화 출력 기대 : E4M3 max=0x7E, E5M2 max=0x7B (양수 고정)
            exp_byte = read_mode ? 8'h7B : 8'h7E;
            if (result[7:0] === exp_byte) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] Test%04d | %s | read=%s Expected=0x%02h Actual=0x%02h",
                         t+1, is_overflow ? "ovf-sat " : "saturate",
                         read_mode ? "E5M2" : "E4M3", exp_byte, result[7:0]);
                dump_inputs;
            end
        end else begin
            actual    = fp_to_real(read_mode, result[7:0]);
            error_val = actual - expected;
            if (error_val < 0.0) error_val = -error_val;

            tol       = read_mode ? REL_TOL_E5M2 : REL_TOL_E4M3;
            threshold = tol * scale;
            if (threshold < ABS_FLOOR) threshold = ABS_FLOOR;

            // ---- 오차 통계 누적 (scale 기준 상대오차) ----
            abs_err = error_val;
            rel_err = abs_err / (scale > ABS_FLOOR ? scale : ABS_FLOOR);
            sum_abs_err = sum_abs_err + abs_err;
            sum_rel_err = sum_rel_err + rel_err;
            if (rel_err > max_rel_err) max_rel_err = rel_err;
            norm_count = norm_count + 1;
            if (read_mode) begin
                sum_rel_e5m2 = sum_rel_e5m2 + rel_err;
                cnt_e5m2     = cnt_e5m2 + 1;
            end else begin
                sum_rel_e4m3 = sum_rel_e4m3 + rel_err;
                cnt_e4m3     = cnt_e4m3 + 1;
            end

            if (error_val < threshold) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] Test%04d | normal read=%s Expected=%f Actual=%f Error=%f Thr=%f",
                         t+1, read_mode ? "E5M2" : "E4M3",
                         expected, actual, error_val, threshold);
                dump_inputs;
            end
        end

        // 진행 표시
        if (((t+1) % 100) == 0)
            $display("  ... %0d/%0d done  (PASS=%0d FAIL=%0d)",
                     t+1, NUM_TESTS, pass_count, fail_count);
    end

    $display("");
    $display("================================================================");
    $display("  SUMMARY: %0d PASS / %0d FAIL / %0d TOTAL",
             pass_count, fail_count, pass_count + fail_count);
    $display("================================================================");

    // ---- 오차 통계 (정상 케이스 전용, scale=Sum|product| 기준) ----
    $display("");
    $display("  ---- ERROR STATS (normal cases only: %0d) ----", norm_count);
    if (norm_count > 0) begin
        $display("  Mean relative error : %f %%   (max %f %%)",
                 100.0 * sum_rel_err / norm_count,
                 100.0 * max_rel_err);
        $display("  Mean absolute error : %f", sum_abs_err / norm_count);
        if (cnt_e4m3 > 0)
            $display("  read E4M3 mean rel error : %f %%  (%0d cases)",
                     100.0 * sum_rel_e4m3 / cnt_e4m3, cnt_e4m3);
        if (cnt_e5m2 > 0)
            $display("  read E5M2 mean rel error : %f %%  (%0d cases)",
                     100.0 * sum_rel_e5m2 / cnt_e5m2, cnt_e5m2);
    end
    $display("================================================================");

    // ---- FUNCTIONAL COVERAGE 리포트 (DUT 내부 분기) ----
    $display("");
    $display("  ---- FUNCTIONAL COVERAGE (DUT internal branches) ----");
    $display("  [FPU]  (active 동안 3개 인스턴스 샘플)");
    cov_report1("FPU nan/inf",   cov_fpu_nan);
    cov_report1("FPU zero-in",   cov_fpu_zin);
    cov_report1("FPU overflow",  cov_fpu_ovf);
    cov_report1("FPU underflow", cov_fpu_uflow);
    cov_report1("FPU normal",    cov_fpu_norm);
    cov_report1("FPU round_up",  cov_fpu_rup);
    cov_report1("FPU round_ovf", cov_fpu_rovf);
    $display("  [ACC_adder]");
    cov_report1("ADD nan/inf",   cov_add_nan);
    cov_report1("ADD both_zero", cov_add_bothzero);
    cov_report1("ADD a_zero",    cov_add_azero);
    cov_report1("ADD b_zero",    cov_add_bzero);
    cov_report1("ADD overflow",  cov_add_ovf);
    cov_report1("ADD underflow", cov_add_uflow);
    cov_report1("ADD normal",    cov_add_norm);
    cov_report1("ADD same_sign", cov_add_same);
    cov_report1("ADD diff_sign", cov_add_diff);
    cov_report1("ADD shift_out", cov_add_shiftout);
    cov_report1("ADD norm_carry",cov_add_carry);
    cov_report1("ADD norm_nosh", cov_add_noshift);
    cov_report1("ADD norm_cancel",cov_add_cancel);
    cov_report1("ADD result_zero",cov_add_zero);
    $display("  [ACC_R E4M3]");
    cov_report1("R4 nan",        cov_r4_nan);
    cov_report1("R4 saturate",   cov_r4_sat);
    cov_report1("R4 zero/uflow", cov_r4_zero);
    cov_report1("R4 normal",     cov_r4_norm);
    cov_report1("R4 mant_carry", cov_r4_carry);
    $display("  [ACC_R E5M2]");
    cov_report1("R5 nan",        cov_r5_nan);
    cov_report1("R5 saturate",   cov_r5_sat);
    cov_report1("R5 zero",       cov_r5_zero);
    cov_report1("R5 normal",     cov_r5_norm);
    cov_report1("R5 mant_carry", cov_r5_carry);
    $display("  ----------------------------------------------------");
    if (cov_holes == 0)
        $display("  COVERAGE: ALL bins hit  (no holes)");
    else
        $display("  COVERAGE: %0d bin(s) NEVER hit  <== COVERAGE FAIL", cov_holes);
    $display("================================================================");

    #200;
    $finish;
end

endmodule
