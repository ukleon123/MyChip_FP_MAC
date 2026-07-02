`timescale 1ns / 1ps
// ============================================================================
//  tb_ACC_adder : ACC_adder (E5M7 13bit float adder) 단위 검증
//
//  E5M7 포맷: S EEEEE MMMMMMM  (sign 1 / exp 5 (bias 15) / mant 7)
//    [12] sign  [11:7] exp  [6:0] mant
//
//  검증 전략 (2단):
//   1) Directed bit-exact : 손계산한 16진 기대값으로 정렬/정규화/상쇄/특수값 검증
//   2) Random + real 모델 : 큰 피연산자의 ULP 기반 허용오차로 광범위 스윕
//      (ACC_adder는 정렬 shift / 정규화에서 '절단(truncation)'하므로 1~수 ULP
//       오차는 정상. 허용오차를 ULP 스케일로 잡아 정상은 통과, 실제 버그는 검출)
// ============================================================================

module tb_ACC_adder;

reg  [12:0] a, b;
wire [12:0] y;

ACC_adder dut (
    .i_a      (a),
    .i_b      (b),
    .o_result (y)
);

integer pass_count, fail_count;
integer i;
integer seed;

// ---------------------------------------------------------------------------
//  E5M7 -> real (정상수 전용; 특수값은 호출하지 않음)
// ---------------------------------------------------------------------------
function real e5m7_to_real;
    input [12:0] v;
    real m;
    integer e;
    begin
        if (v[11:7] == 5'd0 && v[6:0] == 7'd0)
            e5m7_to_real = 0.0;
        else begin
            m = 1.0 + v[6:0] / 128.0;
            e = v[11:7];
            e = e - 15;
            e5m7_to_real = (v[12] ? -1.0 : 1.0) * m * (2.0 ** e);
        end
    end
endfunction

// ---------------------------------------------------------------------------
//  Directed bit-exact 체크
// ---------------------------------------------------------------------------
task check_exact;
    input [12:0]      ta;
    input [12:0]      tb_b;
    input [12:0]      texp;
    input [8*20-1:0]  name;
    begin
        a = ta; b = tb_b; #1;
        if (y === texp) begin
            $display("[PASS] %-18s | a=%h b=%h -> y=%h", name, a, b, y);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] %-18s | a=%h b=%h -> y=%h (expected %h)",
                     name, a, b, y, texp);
            fail_count = fail_count + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
//  Random 체크 (real 기준모델 + ULP 허용오차)
// ---------------------------------------------------------------------------
integer ea, eb, ma, mb, sa, sb, el;
real    ra, rb, rsum, ry, err, ulp, tol;

task check_rand;
    begin
        // exp [8,22] 범위의 정상수만 생성 → 합이 overflow/nan 영역에 안 들어감.
        // (underflow→0 케이스는 ULP 허용오차로 자연히 흡수됨)
        ea = 8 + ({$random(seed)} % 15);   // 8..22
        eb = 8 + ({$random(seed)} % 15);
        ma = {$random(seed)} % 128;
        mb = {$random(seed)} % 128;
        sa = {$random(seed)} % 2;
        sb = {$random(seed)} % 2;

        a = {sa[0], ea[4:0], ma[6:0]};
        b = {sb[0], eb[4:0], mb[6:0]};
        #1;

        ra   = e5m7_to_real(a);
        rb   = e5m7_to_real(b);
        rsum = ra + rb;
        ry   = e5m7_to_real(y);

        // 큰 쪽 피연산자의 1 ULP = 2^(exp_large - 15 - 7)
        el  = (a[11:7] > b[11:7]) ? a[11:7] : b[11:7];
        ulp = 2.0 ** (el - 22);
        tol = 3.0 * ulp;                   // 정렬/정규화 절단 여유 (3 ULP)

        err = ry - rsum;
        if (err < 0.0) err = -err;

        if (err <= tol) begin
            pass_count = pass_count + 1;
        end else begin
            fail_count = fail_count + 1;
            $display("[FAIL rand] a=%h(%f) b=%h(%f) -> y=%h(%f) | sum=%f err=%f tol=%f",
                     a, ra, b, rb, y, ry, rsum, err, tol);
        end
    end
endtask

// ===========================================================================
//  Main
// ===========================================================================
initial begin
    $dumpfile("tb_ACC_adder.vcd");
    $dumpvars(0, tb_ACC_adder);

    pass_count = 0;
    fail_count = 0;
    seed       = 32'h1234_5678;
    a = 0; b = 0;

    $display("");
    $display("================================================================");
    $display("  ACC_adder (E5M7) unit testbench");
    $display("================================================================");
    $display("-- Directed (bit-exact) --------------------------------------");

    // ---- 기본 덧셈 (같은/다른 exp, 정렬) ----
    check_exact(13'h0780, 13'h0780, 13'h0800, "1.0 + 1.0 = 2.0");   // 캐리 → exp+1
    check_exact(13'h0780, 13'h0800, 13'h0840, "1.0 + 2.0 = 3.0");   // exp_diff=1
    check_exact(13'h0800, 13'h0780, 13'h0840, "2.0 + 1.0 = 3.0");   // 교환법칙
    check_exact(13'h0780, 13'h0900, 13'h0910, "1.0 + 8.0 = 9.0");   // exp_diff=3

    // ---- 절단(truncation) 동작: 정렬 중 LSB 손실 → round-toward-zero ----
    //   1.0078125 + 2.0 = 3.0078125 이지만 가수 절단으로 3.0 출력
    check_exact(13'h0781, 13'h0800, 13'h0840, "trunc loss -> 3.0");

    // ---- exp_diff >= 8 : 작은 값 완전 소거 ----
    check_exact(13'h0780, 13'h0B80, 13'h0B80, "1.0 + 256 = 256");   // 1.0 dropped

    // ---- 뺄셈 / 상쇄 / 다단계 정규화 ----
    check_exact(13'h0780, 13'h1780, 13'h0000, "1.0 + (-1.0) = 0");  // 완전 상쇄 → underflow→0
    check_exact(13'h0840, 13'h1780, 13'h0800, "3.0 + (-1.0) = 2.0");
    check_exact(13'h0880, 13'h1840, 13'h0780, "4.0 + (-3.0) = 1.0");// leading-zero 다단계 정규화

    // ---- zero 피연산자 ----
    check_exact(13'h0000, 13'h0840, 13'h0840, "0 + 3.0 = 3.0");     // a=0 → b
    check_exact(13'h0840, 13'h0000, 13'h0840, "3.0 + 0 = 3.0");     // b=0 → a
    check_exact(13'h0000, 13'h0000, 13'h0000, "0 + 0 = 0");

    // ---- 특수값 (exp=11111) : nan/inf 입력 → nan 전파 (sign=0 고정) ----
    check_exact(13'h0F81, 13'h0780, 13'h0F81, "NaN + 1.0 = NaN");
    check_exact(13'h0F80, 13'h0780, 13'h0F81, "Inf + 1.0 = NaN");   // Inf도 nan_val로
    check_exact(13'h1F80, 13'h0780, 13'h0F81, "-Inf + 1.0 = NaN");  // sign 정규화(+)

    // ---- overflow : exp_norm >= 31 → saturate(max_val), NaN 아님 ----
    //  2^15 + 2^15 = 2^16 -> exp 30+1=31 overflow -> ±max 로 포화
    check_exact(13'h0F00, 13'h0F00, 13'h0F7F, "2^15+2^15 ->+max");  // +max = 0_11110_1111111
    check_exact(13'h1F00, 13'h1F00, 13'h1F7F, "-2^15-2^15 ->-max"); // 음수 overflow -> -max

    $display("-- Random (real reference, 5000 vectors) ---------------------");
    for (i = 0; i < 5000; i = i + 1)
        check_rand;

    $display("");
    $display("================================================================");
    $display("  SUMMARY: %0d PASS / %0d FAIL / %0d TOTAL",
             pass_count, fail_count, pass_count + fail_count);
    $display("================================================================");

    if (fail_count != 0)
        $display("  RESULT: ***** FAIL *****");
    else
        $display("  RESULT: ALL PASS");

    #10;
    $finish;
end

endmodule
