/*
FPU에서 들어오는 9개의 곱셈 결과를 순차적으로 누적 덧셈한다.
ACC_adder를 instanciation하여 사용. (adder 1개, 9사이클 순차 누산)

| Port       | Dir | Width | Description                        |
| ---------- | --- | ----- | ---------------------------------- |
| i_clk      | in  | 1     |                                    |
| i_rstn     | in  | 1     |                                    |
| i_start    | in  | 1     | CONTROL에서 보내는 시작 신호              |
| i_data     | in  | 9     | 선택된 FPU 곱셈 결과 (acc_cnt 인덱스)      |
| o_sel      | out | 4     | 곱셈/선택할 인덱스 = acc_cnt (0~8)        |
| o_result   | out | 13    | 누적 덧셈 결과 (E5M7)                   |
| o_done     | out | 1     | 9개 누적 완료 신호 → CONTROL로            |
*/

`timescale 1ns / 1ps

module ACC (
    input            i_clk,
    input            i_rstn,
    input            i_start,
    input      [8:0] i_data,        // 선택된 FPU 곱셈 결과 (acc_cnt 인덱스)
    output     [3:0] o_sel,         // 곱셈/선택할 인덱스 = acc_cnt (0~8)
    output     [12:0] o_result,
    output reg       o_done
);

// 내부 신호
reg [3:0] acc_cnt;    // 누적 카운터 (0~8)
reg       active;     // 누적 진행 중
reg [12:0] acc_reg;    // 누적값 저장 (E5M7)

// ACC_adder 조합 로직 인스턴스 (1개, 매 사이클 1개씩 누산)
wire [12:0] adder_result;

ACC_adder u_adder (
    .i_a     (acc_reg),
    .i_b     ({i_data, 4'b0000}),
    .o_result(adder_result)
);

assign o_sel    = acc_cnt;
assign o_result = acc_reg;

always @(posedge i_clk or negedge i_rstn) begin
    if (!i_rstn) begin
        acc_cnt  <= 4'd0;
        active   <= 1'b0;
        acc_reg  <= 13'd0;
        o_done   <= 1'b0;
    end else if (i_start && !active) begin
        acc_cnt  <= 4'd0;
        active   <= 1'b1;
        acc_reg  <= 13'd0;
        o_done   <= 1'b0;
    end else if (active) begin
        // 누적 연산
        acc_reg <= adder_result;
        acc_cnt <= acc_cnt + 4'd1;

        if (acc_cnt == 4'd8) begin
            o_done   <= 1'b1;
            active   <= 1'b0;
        end
    end else begin
        o_done <= 1'b0;
    end
end

endmodule
