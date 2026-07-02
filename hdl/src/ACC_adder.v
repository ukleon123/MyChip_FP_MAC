/*
ACC 에서 해당 FP_adder를 instanciation하여 사용한다.

| Port     | Dir | Width | Description |
| -------- | --- | ----- | ----------- |
| i_a      | in  | 9     | 연산 대상       |
| i_b      | in  | 9     | 연산 대상       |
| o_result | out | 9     | 연산 결과       |
*/

`timescale 1ns / 1ps

module ACC_adder (
    input      [12:0] i_a,
    input      [12:0] i_b,
    output reg [12:0] o_result
);

// 0) 필드 분리 / 특수값 감지 / mantissa leading 1 복원
wire sign_a = i_a [12];
wire sign_b = i_b [12];
wire [4:0] exp_a = i_a [11:7];
wire [4:0] exp_b = i_b [11:7];
wire [6:0] mant_a = i_a [6:0];
wire [6:0] mant_b = i_b [6:0];

wire a_is_nan_or_inf  = (exp_a == 5'b11111);
wire b_is_nan_or_inf  = (exp_b == 5'b11111);
wire a_is_zero = (exp_a == 5'b00000) & (mant_a == 7'd0);
wire b_is_zero = (exp_b == 5'b00000) & (mant_b == 7'd0);

wire [7:0] full_mant_a = {1'b1, mant_a};
wire [7:0] full_mant_b = {1'b1, mant_b};

// 1) a와 b의 exp 비교
wire a_is_larger = (exp_a > exp_b) || ((exp_a == exp_b) && (mant_a >= mant_b));
wire [4:0] exp_large = a_is_larger ? exp_a : exp_b;
wire [4:0] exp_diff  = a_is_larger ? (exp_a-exp_b) : (exp_b-exp_a);

// 1.1) exp의 크기에 따라 sign과 mant 구분
wire       sign_large = a_is_larger ? sign_a : sign_b;
wire       sign_small = a_is_larger ? sign_b : sign_a;
wire [7:0] mant_large = a_is_larger ? full_mant_a : full_mant_b;
wire [7:0] mant_small = a_is_larger ? full_mant_b : full_mant_a;

// 2) exp_diff 만큼 mant_small을 right shift
wire [7:0] mant_small_shifted = (exp_diff >= 5'd8) ? 8'd0 : (mant_small >> exp_diff);

// 3) 부호가 같으면 덧셈, 다르면 뺄셈 (A-B = A + ~B + 1)
wire same_sign = (sign_large == sign_small);
wire [8:0] operand_b = same_sign ? {1'b0, mant_small_shifted}
                                 : ~{1'b0, mant_small_shifted};
wire [8:0] mant_raw  = {1'b0, mant_large} + operand_b + {8'd0, ~same_sign};
wire       sign_raw  = sign_large;

// 4) Normalization
// mant_raw : XX.XXXXXXX (9bit)
reg signed [5:0] exp_norm;
reg [6:0] mant_norm;

always @(*) begin
    if (mant_raw[8]) begin         // 1X.XXXXXXX
        exp_norm  = $signed({1'b0, exp_large}) + 6'sd1;
        mant_norm = mant_raw[7:1];
    end else if (mant_raw[7]) begin // 01.XXXXXXX
        exp_norm  = exp_large;
        mant_norm = mant_raw[6:0];
    end else if (mant_raw[6]) begin // 00.1XXXXXX
        exp_norm  = $signed({1'b0, exp_large}) - 6'sd1;
        mant_norm = {mant_raw[5:0], 1'b0};
    end else if (mant_raw[5]) begin
        exp_norm  = $signed({1'b0, exp_large}) - 6'sd2;
        mant_norm = {mant_raw[4:0], 2'b0};
    end else if (mant_raw[4]) begin
        exp_norm  = $signed({1'b0, exp_large}) - 6'sd3;
        mant_norm = {mant_raw[3:0], 3'b0};
    end else if (mant_raw[3]) begin
        exp_norm  = $signed({1'b0, exp_large}) - 6'sd4;
        mant_norm = {mant_raw[2:0], 4'b0};
    end else if (mant_raw[2]) begin
        exp_norm  = $signed({1'b0, exp_large}) - 6'sd5;
        mant_norm = {mant_raw[1:0], 5'b0};
    end else if (mant_raw[1]) begin
        exp_norm  = $signed({1'b0, exp_large}) - 6'sd6;
        mant_norm = {mant_raw[0], 6'b0};
    end else if (mant_raw[0]) begin
        exp_norm  = $signed({1'b0, exp_large}) - 6'sd7;
        mant_norm = 7'b0;
    end else begin
        exp_norm  = 6'sd0;
        mant_norm = 7'd0;
    end
end

// 5) over/underflow 검사
wire overflow  = (exp_norm >= 6'sd31);
wire underflow = (exp_norm <= 6'sd0);

wire [12:0] max_val    = {sign_raw, 5'b11110, 7'b1111111};
wire [12:0] zero_val = {sign_raw, 5'b00000, 7'd0};
wire [12:0] nan_val  = 13'b0_11111_0000001;
wire [12:0] normal_val = {sign_raw, exp_norm[4:0], mant_norm};

// 6) 결과 출력
always @(*)begin
    if (a_is_nan_or_inf || b_is_nan_or_inf) begin
        o_result = nan_val;
    end else if (a_is_zero && b_is_zero) begin
        o_result = 13'd0;
    end else if (a_is_zero) begin
        o_result = i_b;
    end else if (b_is_zero) begin
        o_result = i_a;
    end else if (overflow) begin
        o_result = max_val;
    end else if (underflow) begin
        o_result = zero_val;
    end else begin
      o_result = normal_val;
    end
end

endmodule