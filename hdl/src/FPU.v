/*
| Port       | Dir | Width | Description       
| ---------- | --- | ----- | ----------------- 
| i_start    | in  | 1     | control이 보낸 start 
| i_weight   | in  | 9     |                   
| i_input    | in  | 9     |                   
| o_result   | out | 9     |                         
*/

`timescale 1ns / 1ps

module FPU (
    // input            i_start,
    input  [8:0]     i_weight,
    input  [8:0]     i_input,
    output reg [8:0] o_result
);

wire sign_weight = i_weight [8];
wire sign_input  = i_input  [8];
wire sign_out    = sign_weight ^ sign_input;

// 1. 각 weight와 input의 exp/mant field 분리
// E5M3: S.EEEEE.MMM
//     [8] [7:3] [2:0]
wire [4:0] exp_weight   = i_weight [7:3]; 
wire [4:0] exp_input    = i_input  [7:3]; 
wire [2:0] mant_weight  = i_weight [2:0];
wire [2:0] mant_input   = i_input  [2:0];

// 2. 특수값 사전 감지

//zero
wire weight_is_zero = (exp_weight==5'b00000) & (mant_weight==3'b000);
wire input_is_zero  = (exp_input ==5'b00000) & (mant_input ==3'b000);
//nan or inf
wire weight_is_nan_or_inf  = (exp_weight==5'b11111);
wire input_is_nan_or_inf   = (exp_input ==5'b11111);



// 3. Exponent 덧셈
// 5bit+5bit = 6bit --> signed로 표현 위해 7bit
wire signed [6:0] exp_added = $signed({2'd0, exp_weight}) + $signed({2'd0, exp_input}) - 7'sd15;

// 4. Mantissa 곱셈
// leading 1 붙여서 연산, 4bit x 4bit = 8bit
wire [7:0] mant_product = {1'b1, mant_weight} * {1'b1, mant_input};

// 5. 정규화
// 1X.XXXXXX --> exp+1, mant 유지
// 01.XXXXXX --> exp 유지, mant left shift
wire signed [6:0] exp_normalized = mant_product[7] ? (exp_added+7'sd1) : exp_added;
wire [7:0] mant_normalized = mant_product[7] ? mant_product : (mant_product<<1);

// 6. Rounding
// normalized: 1.(XXX)(X)   (X)   (XX)
//                    guard round sticky
//rounding 결과: 1.XXXX --> rounding overflow 가능성 있어서 MSB에 1bit 추가
wire [2:0] mant_round_candidate = mant_normalized [6:4];
wire guard  = mant_normalized [3];
wire round  = mant_normalized [2];
wire sticky = |mant_normalized [1:0];

wire round_up = guard & (round | sticky | mant_round_candidate[0]);
// mant_rounded는 leading 1 포함 X, only mantissa
wire [3:0] mant_rounded = {1'b0, mant_round_candidate} + {3'b0, round_up};

// 7. Rounding overflow 처리 (정규화)
// 만약 rounding에서 overflow: 1.1000 꼴. 이건 10.000과 동일, 1.000으로 정규화 
// (mant 0으로, exp+1)
// --> rounding할 때 1이 넘어갔다는거니까.
wire round_overflow = mant_rounded [3];
wire [2:0] mant_final = round_overflow ? 3'b000 : mant_rounded [2:0];
wire signed [6:0] exp_final  = round_overflow ? (exp_normalized + 7'sd1) : exp_normalized;

// 8. overflow/underflow 처리 (exp)
// E5M3에서 max normal: S.11110.111 --> exp는 최대 30.
wire overflow  = (exp_final >  7'sd30);
wire underflow = (exp_final <= 7'sd0 );

// 7. 출력 값 정의
wire [8:0] max_val    = {sign_out, 5'b11110, 3'b111};
// 9. 출력 값 정의 
wire [8:0] inf_val    = {sign_out, 5'b11111, 3'b000};
wire [8:0] zero_val   = {sign_out, 5'b00000, 3'b000};
wire [8:0] nan_val    = {sign_out, 5'b11111, 3'b001};
wire [8:0] normal_val = {sign_out, exp_final [4:0], mant_final [2:0]};

// 8. 출력
// 10. 출력
/*
always @(*) begin
    if (i_start) begin
        if (is_nan_or_inf || overflow)
            o_result = nan_val;
        else if (is_zero || underflow)
            o_result = zero_val;
        else
            o_result = normal_val;
    end else begin
        o_result = 9'd0;
    end
end */

always @(*) begin
        if (weight_is_nan_or_inf || input_is_nan_or_inf) begin
            o_result = nan_val;
        end else if (weight_is_zero || input_is_zero) begin
            o_result = zero_val;
        end else if (overflow) begin
            o_result = max_val;
        end else if (underflow) begin
            o_result = zero_val;
        end else begin
          o_result = normal_val;
        end
    end
 
endmodule