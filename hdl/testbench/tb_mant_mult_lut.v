`timescale 1ns / 1ps
// ============================================================================
//  tb_mant_mult_lut : 가수 곱셈 LUT 전수검증 (3bit x 3bit = 64 조합 완전탐색)
//
//  의미:
//   - 각 가수 m 은 정규화 significand 1.mmm 의 소수부 → 정수표현 (8+m), 8..15
//   - 두 significand 곱 P = (8+a)*(8+b) ∈ [64,225],  실수값 = P/64 ∈ [1.0, 3.516)
//   - 곱은 [1,2) 또는 [2,4) → exp_delta = (P>=128) 로 정규화 후 가수 3bit 산출
//   - 반올림은 round-half-to-even(RNE)  (LUT 의 tie 처리와 일치)
//
//  기준모델: 정수연산 기반 RNE 를 독립 구현(LUT 로직 미사용)하여 bit-exact 비교.
//  추가검증: 교환법칙 LUT(a,b) == LUT(b,a).
// ============================================================================

module tb_mant_mult_lut;

reg  [2:0] a, b;
wire [2:0] mant_final;
wire       exp_delta;

mant_mult_lut dut (
    .mant_a     (a),
    .mant_b     (b),
    .mant_final (mant_final),
    .exp_delta  (exp_delta)
);

integer ia, ib;
integer e_ref, m_ref;
integer pass_count, fail_count, comm_fail;
reg [2:0] mf_ab, mf_ba;
reg       ed_ab, ed_ba;

// ---------------------------------------------------------------------------
//  RNE 기준모델 : (8+A)*(8+B) → (exp_delta, mant_final)
// ---------------------------------------------------------------------------
task ref_rne;
    input  integer A, B;
    output integer e_o, m_o;
    integer P, n, qi, rem, e, m;
    begin
        P = (8 + A) * (8 + B);
        if (P < 128) begin
            // significand in [1,2): value*8(eighths) = (P-64)/8, RNE
            e   = 0;
            n   = P - 64;
            qi  = n >> 3;
            rem = n & 7;
            if      (rem < 4) m = qi;
            else if (rem > 4) m = qi + 1;
            else              m = (qi & 1) ? qi + 1 : qi;   // tie -> even
        end else begin
            // significand in [2,4): /2 후 eighths = (P-128)/16, RNE
            e   = 1;
            n   = P - 128;
            qi  = n >> 4;
            rem = n & 15;
            if      (rem < 8) m = qi;
            else if (rem > 8) m = qi + 1;
            else              m = (qi & 1) ? qi + 1 : qi;   // tie -> even
        end
        // 가수 carry (예: 1.9375 -> 2.0): exp 한 단계 올리고 가수 0
        if (m == 8) begin
            m = 0;
            e = e + 1;
        end
        e_o = e;
        m_o = m;
    end
endtask

// ===========================================================================
//  Main
// ===========================================================================
initial begin
    $dumpfile("tb_mant_mult_lut.vcd");
    $dumpvars(0, tb_mant_mult_lut);

    pass_count = 0;
    fail_count = 0;
    comm_fail  = 0;

    $display("");
    $display("================================================================");
    $display("  mant_mult_lut EXHAUSTIVE testbench (64 combos)");
    $display("================================================================");
    $display("  a b | (8+a)*(8+b) | LUT ed,mant | REF ed,mant | result");
    $display("  ----+-------------+-------------+-------------+-------");

    for (ia = 0; ia < 8; ia = ia + 1) begin
        for (ib = 0; ib < 8; ib = ib + 1) begin
            // ---- LUT 평가 (a,b) ----
            a = ia[2:0]; b = ib[2:0]; #1;
            mf_ab = mant_final; ed_ab = exp_delta;

            // ---- LUT 평가 (b,a) : 교환법칙 ----
            a = ib[2:0]; b = ia[2:0]; #1;
            mf_ba = mant_final; ed_ba = exp_delta;

            // ---- 기준모델 ----
            ref_rne(ia, ib, e_ref, m_ref);

            // ---- bit-exact 비교 ----
            if ((ed_ab === e_ref[0]) && (mf_ab === m_ref[2:0])) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("  %0d %0d |     %3d     |   %b,%b     |   %b,%b     | FAIL",
                         ia, ib, (8+ia)*(8+ib), ed_ab, mf_ab, e_ref[0], m_ref[2:0]);
            end

            // ---- 교환법칙 비교 ----
            if ((ed_ab !== ed_ba) || (mf_ab !== mf_ba)) begin
                comm_fail = comm_fail + 1;
                $display("  %0d %0d | COMMUTATIVITY FAIL: (a,b)=%b,%b  (b,a)=%b,%b",
                         ia, ib, ed_ab, mf_ab, ed_ba, mf_ba);
            end
        end
    end

    $display("");
    $display("================================================================");
    $display("  SUMMARY: %0d PASS / %0d FAIL  (commutativity fails: %0d)",
             pass_count, fail_count, comm_fail);
    $display("================================================================");
    if (fail_count != 0 || comm_fail != 0) $display("  RESULT: ***** FAIL *****");
    else                                   $display("  RESULT: ALL PASS (64/64 exhaustive)");

    #10;
    $finish;
end

endmodule
