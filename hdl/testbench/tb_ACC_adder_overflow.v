`timescale 1ns / 1ps

// ================================================================
//  tb_ACC_adder_overflow : ACC_adder 의 overflow 처리(=saturation)
//  만 집중 검증하는 유닛 테스트벤치.
//   - 누산 결과가 표현범위를 넘으면 NaN 이 아니라 max_val 로 포화해야 함
//   - 검증 항목:
//      (1) 양/음 overflow -> ±max 로 포화 (부호 보존)
//      (2) 경계: exp=30 정상값은 포화되면 안 됨 (over-saturation 방지)
//      (3) 상쇄(opposite sign)로 작아지는 합은 overflow 가 아님
//      (4) NaN/Inf 입력은 overflow 보다 우선 -> NaN 출력
//      (5) 랜덤: same-sign exp=30 쌍은 항상 overflow -> ±max
//   ACC_adder 는 순수 조합회로라 클럭 없이 입력만 인가해서 본다.
// ================================================================

module tb_ACC_adder_overflow;

reg  [12:0] a, b;
wire [12:0] y;

integer pass, fail, i;
integer seed;
reg [12:0] exp_y;
reg        rs;
reg [6:0]  rma, rmb;

ACC_adder dut (
    .i_a     (a),
    .i_b     (b),
    .o_result(y)
);

// ---- E5M7 상수 ( {sign, exp[4:0](bias15), mant[6:0]} ) ----
localparam [12:0] MAXP  = 13'b0_11110_1111111;  // +max normal (exp30, mant 전부1)
localparam [12:0] MAXN  = 13'b1_11110_1111111;  // -max normal
localparam [12:0] NANV  = 13'b0_11111_0000001;  // 설계의 nan_val
localparam [12:0] INFP  = 13'b0_11111_0000000;  // +Inf (exp31, mant0)
localparam [12:0] INFN  = 13'b1_11111_0000000;  // -Inf
localparam [12:0] ZERO  = 13'd0;
localparam [12:0] ONE30P = 13'b0_11110_0000000; // +1.0 * 2^15  (exp30)
localparam [12:0] ONE30N = 13'b1_11110_0000000; // -1.0 * 2^15
localparam [12:0] ONE29P = 13'b0_11101_0000000; // +1.0 * 2^14  (exp29)

// 한 벡터 인가 + 결과 비교
task check;
    input [12:0]  ta, tb_;
    input [12:0]  ty;
    input [127:0] label;
    begin
        a = ta; b = tb_;
        #1;
        if (y === ty) begin
            pass = pass + 1;
        end else begin
            fail = fail + 1;
            $display("  [FAIL] %-16s a=%b b=%b  exp=%b got=%b",
                     label, a, b, ty, y);
        end
    end
endtask

initial begin
    $dumpfile("tb_ACC_adder_overflow.vcd");
    $dumpvars(0, tb_ACC_adder_overflow);

    pass = 0; fail = 0;
    seed = 32'hABCD_0001;

    $display("");
    $display("============================================================");
    $display("  ACC_adder OVERFLOW handling testbench");
    $display("============================================================");

    // ---- (1) 기본 overflow -> ±max (부호 보존) ----
    check(MAXP,   MAXP,   MAXP, "pos ovf->+max");   // 최대값 + 최대값
    check(MAXN,   MAXN,   MAXN, "neg ovf->-max");
    check(ONE30P, ONE30P, MAXP, "min pos ovf");     // 1.0+1.0=2.0*2^15 -> exp31 -> 포화
    check(ONE30N, ONE30N, MAXN, "min neg ovf");
    check(MAXP,   ONE30P, MAXP, "asym pos ovf");    // 비대칭 큰 값

    // ---- (2) 경계: exp=30 정상값은 포화 금지 (over-saturation 방지) ----
    //  1.0*2^15 + 1.0*2^14 = 1.5*2^15 -> exp30, mant=1000000  (정상값, max 아님)
    check(ONE30P, ONE29P, 13'b0_11110_1000000, "no ovf norm30");

    // ---- (3) 상쇄로 작아지는 합은 overflow 아님 ----
    check(MAXP, MAXN, ZERO, "cancel->zero");        // +max + -max = 0

    // ---- (4) NaN/Inf 입력은 overflow 보다 우선 -> NaN ----
    check(INFP, MAXP,   NANV, "inf op->nan");
    check(NANV, MAXN,   NANV, "nan op->nan");
    check(INFN, ONE30P, NANV, "infN op->nan");

    // ---- (5) 랜덤 스트레스 : same-sign exp=30 쌍은 항상 overflow -> ±max ----
    //  (두 값 모두 [1.0,2.0)*2^15 이므로 합은 [2.0,4.0)*2^15 -> 반드시 exp31)
    for (i = 0; i < 2000; i = i + 1) begin
        rs  = {$random(seed)} % 2;
        rma = {$random(seed)} % 128;
        rmb = {$random(seed)} % 128;
        exp_y = {rs, 5'b11110, 7'b1111111};         // ±max
        check({rs, 5'b11110, rma}, {rs, 5'b11110, rmb}, exp_y, "rand same ovf");
    end

    // ---- (6) 랜덤 : exp31(NaN/Inf) 한쪽 -> overflow 와 무관하게 항상 NaN ----
    for (i = 0; i < 500; i = i + 1) begin
        rs  = {$random(seed)} % 2;
        rma = {$random(seed)} % 128;
        rmb = {$random(seed)} % 128;
        check({rs, 5'b11111, rma}, {1'b0, 5'b11110, rmb}, NANV, "rand nan prio");
    end

    $display("------------------------------------------------------------");
    $display("  SUMMARY: %0d PASS / %0d FAIL", pass, fail);
    if (fail == 0)
        $display("  OVERFLOW HANDLING: ALL CHECKS PASSED");
    else
        $display("  OVERFLOW HANDLING: *** %0d FAIL ***", fail);
    $display("============================================================");

    #10;
    $finish;
end

endmodule
