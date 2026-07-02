module ACC_R(
    input            i_clk,
    input            i_rstn,
    input            i_wen,
    input            i_mode,       // 0: E4M3 | 1: E5M2
    input      [12:0] i_data,      // E5M7 (13비트)
    output reg [7:0] o_data
);

// E5M7 필드 분리
wire       sign    = i_data[12];
wire [4:0] exp_raw = i_data[11:7];
wire [6:0] mant    = i_data[6:0];

// 특수값 감지
wire is_nan  = (exp_raw == 5'b11111) & (mant != 7'd0);
wire is_zero = (exp_raw == 5'b00000) & (mant == 7'd0);
wire relu_zero = sign & ~is_nan;

// =========================================================
//  공유 라운딩 회로 (mode에 따라 입력 비트 선택)
// =========================================================
//  E4M3(mode=0): keep [6:4], guard [3], round [2], sticky |[1:0], lsb [4]
//  E5M2(mode=1): keep [6:5], guard [4], round [3], sticky |[2:0], lsb [5]
wire [2:0] trunc   = i_mode ? {1'b0, mant[6:5]} : mant[6:4];
wire       guard   = i_mode ? mant[4]            : mant[3];
wire       round_b = i_mode ? mant[3]            : mant[2];
wire       sticky  = i_mode ? |mant[2:0]         : |mant[1:0];
wire       lsb     = i_mode ? mant[5]            : mant[4];

wire       round_up     = guard & (round_b | sticky | lsb);
wire [3:0] mant_rounded = {1'b0, trunc} + {3'b0, round_up};
//  E4M3: 가수 3비트가 [2:0] → 캐리는 [3]
//  E5M2: 가수 2비트가 [1:0] → 캐리는 [2]
wire       mant_carry   = i_mode ? mant_rounded[2] : mant_rounded[3];

// =========================================================
//  E4M3 출력 (bias 15→7)
// =========================================================
wire signed [6:0] e4m3_exp = $signed({2'b0, exp_raw})
                            - 7'sd8
                            + {6'd0, mant_carry};

reg [7:0] e4m3;
always @(*) begin
    if (is_nan)
        e4m3 = {sign, 4'b1111, 3'b111};
    else if (e4m3_exp > 7'sd15)
        e4m3 = {sign, 4'b1111, 3'b110};
    else if (is_zero || e4m3_exp <= 7'sd0)
        e4m3 = {sign, 4'b0000, 3'b000};
    else
        e4m3 = {sign, e4m3_exp[3:0], mant_rounded[2:0]};
end

// =========================================================
//  E5M2 출력 (bias 동일)
// =========================================================
wire [5:0] e5m2_exp = {1'b0, exp_raw} + {5'd0, mant_carry};

reg [7:0] e5m2;
always @(*) begin
    if (is_nan)
        e5m2 = {sign, 5'b11111, 2'b01};
    else if (e5m2_exp >= 6'd31)
        e5m2 = {sign, 5'b11110, 2'b11};
    else if (is_zero)
        e5m2 = {sign, 5'b00000, 2'b00};
    else
        e5m2 = {sign, e5m2_exp[4:0], mant_rounded[1:0]};
end

// 출력 레지스터
always @(posedge i_clk or negedge i_rstn) begin
    if (!i_rstn)
        o_data <= 8'd0;
    else if (i_wen && relu_zero)
        o_data <= 8'd0;
    else if (i_wen && (i_mode == 0))
        o_data <= e4m3;
    else if (i_wen && (i_mode == 1))
        o_data <= e5m2;
    else
        o_data <= 8'd0;
end

endmodule