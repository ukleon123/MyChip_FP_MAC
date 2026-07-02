`timescale 1ns / 1ps
// ============================================================================
//  tb_ACC_R : ACC_R (E5M7 -> E4M3 / E5M2 변환 & 반올림) 단위 검증
//
//  입력  E5M7 : S EEEEE MMMMMMM (sign1 / exp5 bias15 / mant7)
//  출력  mode=0 -> E4M3 (S.E4.M3, bias 7), mode=1 -> E5M2 (S.E5.M2, bias 15)
//  주: 본 설계는 E4M3 출력에서 exp field 1111 을 "예약(nan)"이 아니라
//      유효 유한수로 사용하며(overflow는 {1111,110}으로 clamp),
//      이는 tb_TOP 의 e4m3_to_real() 해석과 일치한다. 모델도 동일하게 해석.
//
//  검증 전략:
//   1) Directed bit-exact : 반올림(tie-to-even/carry), overflow, underflow,
//                           zero, nan, inf 인코딩을 손계산 16진값으로 검증
//   2) Random  : 타깃 포맷 256코드를 전수 탐색해 '최근접 표현가능값'을 독립
//                계산 → DUT 출력이 그 최근접 거리와 동일한지(올바른 반올림) 확인.
//                (tie 방향은 어느 쪽이든 허용; 정확한 tie-even은 directed가 담당)
// ============================================================================

module tb_ACC_R;

reg         clk, rstn;
reg         i_wen, i_mode;
reg  [12:0] i_data;
wire [7:0]  o_data;

ACC_R dut (
    .i_clk  (clk),
    .i_rstn (rstn),
    .i_wen  (i_wen),
    .i_mode (i_mode),
    .i_data (i_data),
    .o_data (o_data)
);

always #5 clk = ~clk;

integer pass_count, fail_count, rand_fail_print;
integer i;
integer seed;

// ---------------------------------------------------------------------------
//  타깃 포맷 코드 -> real (설계 의미와 동일하게 해석)
//   m=0 E4M3: expf=c[6:3], mant=c[2:0], bias7  (expf 1..15 유한)
//   m=1 E5M2: expf=c[6:2], mant=c[1:0], bias15 (expf 1..30 유한, 31=특수)
// ---------------------------------------------------------------------------
function real decode_target;
    input [7:0] c;
    input       m;
    integer expf, mant;
    real v;
    begin
        if (m == 1'b0) begin
            expf = c[6:3];
            mant = c[2:0];
            if (expf == 0) v = 0.0;
            else v = (c[7] ? -1.0 : 1.0) * (1.0 + mant/8.0) * (2.0 ** (expf-7));
        end else begin
            expf = c[6:2];
            mant = c[1:0];
            if (expf == 0)        v = 0.0;
            else if (expf == 31)  v = 1.0e30;   // 특수(inf/nan): 후보에서 제외용
            else v = (c[7] ? -1.0 : 1.0) * (1.0 + mant/4.0) * (2.0 ** (expf-15));
        end
        decode_target = v;
    end
endfunction

// 타깃 포맷에서 x 에 가장 가까운 유한 표현가능값까지의 거리(독립 최근접 탐색)
function real best_dist;
    input real x;
    input      m;
    integer c, expf;
    reg [7:0] cc;
    real v, d, best;
    begin
        best = 1.0e30;
        for (c = 0; c < 256; c = c + 1) begin
            cc = c[7:0];
            expf = (m == 1'b0) ? cc[6:3] : cc[6:2];
            // 유한 정상 코드만 후보(zero-exp / E5M2 exp=31 제외)
            if ( ((m==1'b0) && (expf != 0)) ||
                 ((m==1'b1) && (expf != 0) && (expf != 31)) ) begin
                v = decode_target(cc, m);
                d = x - v;
                if (d < 0.0) d = -d;
                if (d < best) best = d;
            end
        end
        best_dist = best;
    end
endfunction

// ---------------------------------------------------------------------------
//  변환 1회 수행 (registered 출력 → 변환 클럭 직후 샘플)
// ---------------------------------------------------------------------------
task do_conv;
    input  [12:0] d;
    input         m;
    output [7:0]  res;
    begin
        @(negedge clk);
        i_data = d; i_mode = m; i_wen = 1'b1;
        @(posedge clk);          // o_data <= 변환결과
        @(negedge clk);          // 안정화 후 샘플
        res   = o_data;
        i_wen = 1'b0;
    end
endtask

// ---------------------------------------------------------------------------
//  Directed bit-exact 체크
// ---------------------------------------------------------------------------
reg [7:0] r;
task check_exact;
    input [12:0]      d;
    input             m;
    input [7:0]       exp_b;
    input [8*24-1:0]  nm;
    begin
        do_conv(d, m, r);
        if (r === exp_b) begin
            $display("[PASS] %-22s | in=%h mode=%0d -> %h", nm, d, m, r);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] %-22s | in=%h mode=%0d -> %h (expected %h)",
                     nm, d, m, r, exp_b);
            fail_count = fail_count + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
//  Random : 올바른 반올림(최근접) 검증
// ---------------------------------------------------------------------------
integer e_raw, m_raw, s_raw, mode_r;
real    xin, xdut, best, ddut;
reg [7:0] rr;

task check_rand;
    begin
        // exp_raw [11,21] : 두 포맷 모두 overflow/underflow 없는 내부 영역
        e_raw  = 11 + ({$random(seed)} % 11);   // 11..21
        m_raw  = {$random(seed)} % 128;
        s_raw  = {$random(seed)} % 2;
        mode_r = {$random(seed)} % 2;

        do_conv({s_raw[0], e_raw[4:0], m_raw[6:0]}, mode_r[0], rr);

        // 입력 실수값 (E5M7 정상수)
        xin = (s_raw[0] ? -1.0 : 1.0) * (1.0 + m_raw/128.0) * (2.0 ** (e_raw-15));

        if (s_raw[0]) begin
            // ReLU: 음수(비-NaN) 입력 -> 0x00 기대
            if (rr === 8'h00) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                if (rand_fail_print < 20) begin
                    $display("[FAIL rand-relu] in(s1 e%0d m%0d)=%f mode=%0d -> %h (expected 00)",
                             e_raw, m_raw, xin, mode_r[0], rr);
                    rand_fail_print = rand_fail_print + 1;
                end
            end
        end else begin
            // 양수: 기존 최근접 표현가능값 검증
            best = best_dist(xin, mode_r[0]);
            xdut = decode_target(rr, mode_r[0]);
            ddut = xdut - xin; if (ddut < 0.0) ddut = -ddut;

            // DUT 출력이 '최근접 표현가능값'이면 통과 (tie는 어느쪽이든 허용)
            if (ddut <= best + best*1.0e-9 + 1.0e-30) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                if (rand_fail_print < 20) begin
                    $display("[FAIL rand] in(s%0d e%0d m%0d)=%f mode=%0d -> %h(%f) | best=%f ddut=%f",
                             s_raw[0], e_raw, m_raw, xin, mode_r[0], rr, xdut, best, ddut);
                    rand_fail_print = rand_fail_print + 1;
                end
            end
        end
    end
endtask

// ===========================================================================
//  Main
// ===========================================================================
initial begin
    $dumpfile("tb_ACC_R.vcd");
    $dumpvars(0, tb_ACC_R);

    clk = 0; rstn = 0;
    i_wen = 0; i_mode = 0; i_data = 0;
    pass_count = 0; fail_count = 0; rand_fail_print = 0;
    seed = 32'hC0FFEE11;

    #12 rstn = 1;
    @(negedge clk);

    $display("");
    $display("================================================================");
    $display("  ACC_R (E5M7 -> E4M3/E5M2) unit testbench");
    $display("================================================================");
    $display("-- Directed (bit-exact) --------------------------------------");

    // ---- 정확 표현 (반올림 없음) ----
    check_exact(13'h0840, 1'b0, 8'h44, "3.0 -> E4M3");      // (1+4/8)*2^1
    check_exact(13'h0840, 1'b1, 8'h42, "3.0 -> E5M2");      // (1+2/4)*2^1
    check_exact(13'h0800, 1'b0, 8'h40, "2.0 -> E4M3");
    check_exact(13'h0800, 1'b1, 8'h40, "2.0 -> E5M2");

    // ---- 반올림: tie-to-even (kept-LSB 가 odd → 올림) ----
    //  E4M3: in=3.875(0x0878) → 4.0(0x48), 가수 carry 로 exp+1
    check_exact(13'h0878, 1'b0, 8'h48, "3.875 tie-even E4M3"); // -> 4.0
    //  E5M2: in=1.375(0x07B0) → 1.5(0x3E)
    check_exact(13'h07B0, 1'b1, 8'h3E, "1.375 tie-even E5M2"); // -> 1.5
    //  E5M2: in=1.875(0x07F0) → 2.0(0x40), carry 로 exp+1
    check_exact(13'h07F0, 1'b1, 8'h40, "1.875 tie-even E5M2"); // -> 2.0

    // ---- overflow ----
    //  E4M3: in=2^9=512(0x0C00) → exp 초과 → {1111,110}=0x7E
    check_exact(13'h0C00, 1'b0, 8'h7E, "512 overflow E4M3");
    //  E5M2: in=2^16 (exp_raw=31 은 특수라 불가) → 큰 exp 로 inf clamp 는 random/inf로 확인

    // ---- underflow (E4M3 만 flush, E5M2 는 미flush) ----
    //  E4M3: in=2^-7(0x0400) → e4m3_exp<=0 → 0x00
    check_exact(13'h0400, 1'b0, 8'h00, "2^-7 underflow E4M3");
    //  같은 입력 E5M2 는 표현가능 → {01000,00}=0x20
    check_exact(13'h0400, 1'b1, 8'h20, "2^-7 normal E5M2");

    // ---- zero ----
    check_exact(13'h0000, 1'b0, 8'h00, "zero -> E4M3");
    check_exact(13'h0000, 1'b1, 8'h00, "zero -> E5M2");

    // ---- 특수값: NaN (exp=11111, mant!=0) ----
    check_exact(13'h0F81, 1'b0, 8'h7F, "NaN -> E4M3");      // {sign,1111,111}
    check_exact(13'h0F81, 1'b1, 8'h7D, "NaN -> E5M2");      // {sign,11111,01}

    // ---- 특수값: Inf (exp=11111, mant=0) : is_nan 아님 → overflow 경로로 saturate ----
    //   현재 설계는 두 포맷 모두 overflow 를 '최대 유한수'로 saturate (Inf 미출력):
    //     E4M3 -> {1111,110}=0x7E,  E5M2 -> {11110,11}=0x7B
    check_exact(13'h0F80, 1'b0, 8'h7E, "Inf -> E4M3 saturate");
    check_exact(13'h0F80, 1'b1, 8'h7B, "Inf -> E5M2 saturate");

    // ---- 음수: ReLU 적용 -> 0 (NaN 아닌 음수는 0으로 클램프) ----
    check_exact(13'h1840, 1'b0, 8'h00, "-3.0 ReLU E4M3");   // 음수 -> 0
    check_exact(13'h1840, 1'b1, 8'h00, "-3.0 ReLU E5M2");

    $display("-- Random (nearest-code reference, 5000 vectors) -------------");
    for (i = 0; i < 5000; i = i + 1)
        check_rand;

    $display("");
    $display("================================================================");
    $display("  SUMMARY: %0d PASS / %0d FAIL / %0d TOTAL",
             pass_count, fail_count, pass_count + fail_count);
    $display("================================================================");
    if (fail_count != 0) $display("  RESULT: ***** FAIL *****");
    else                 $display("  RESULT: ALL PASS");

    #20;
    $finish;
end

endmodule
