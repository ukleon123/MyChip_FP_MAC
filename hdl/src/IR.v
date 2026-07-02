// Instruction Register
// 기존의 decoder, dec_dff_formatter, input_formatter 를 통합했다. 
// SPI로 받아온 값을 각 필드로 분해하고 data는 포맷을 맞춘다.

/*
| Port          | Dir | Width | Description            
| ------------- | --- | ----- | ---------------------- 
| i_rx_data     | in  | 16    | SPI 수신 데이터             
| i_rx_valid    | in  | 1     | SPI SSn rising edge 검출 (하나의 command에 대한 통신 끝)
| o_cmd_valid_one_pulse   | out | 1     | i_rx_valid를 그대로 내보냄
| o_cmd         | out | 3     | control이 받는 command    
| o_mode        | out | 1     | control이 받는 mode       
| o_data        | out | 9     | datapath가 받는 E5M3 data 
| o_addr        | out | 4     | datapath가 받는 addr      
*/

// i_rx_data format
// command(3bit) [15:13]
// data   (8bit) [12:5]
// address(4bit) [4:1]
// mode   (1bit) [0]

`timescale 1ns / 1ps

module IR (
    input     [15:0] i_rx_data, 
    input            i_rx_done,
    // to control
    output reg [2:0] o_cmd,
    output reg       o_cmd_valid_one_pulse,
    output reg       o_mode,
    // to datapath
    output reg [8:0] o_data, 
    output reg [3:0] o_addr
);

// mode 0: E4M3
// mode 1: E5M2
//E4M3를 E5M3로 확장하면 bias보정이 필요하다. 
  wire [3:0] exp_e4m3;
  wire [4:0] exp_conv;

  assign exp_e4m3 = i_rx_data[11:8];

  // E4M3 exponent bias conversion: bias 7 -> bias 15, add 8
  assign exp_conv = (exp_e4m3 == 4'b0000) ? 5'd0 : ({1'b0, exp_e4m3} + 5'd8);

/* always @(*) begin
    if (!i_rx_done) begin
        o_cmd       = 3'd0;
        o_cmd_valid_one_pulse = 1'd0;
        o_mode      = 1'd0;
        o_data      = 9'd0;
        o_addr      = 4'd0;
    end else begin
        o_cmd       = i_rx_data[15:13];
        o_cmd_valid_one_pulse = i_rx_done;
        o_mode      = i_rx_data[0];
        o_addr      = i_rx_data[4:1];
        if (o_mode == 0) begin
            o_data = {i_rx_data[12], exp_conv, i_rx_data[7:5]};
        end else if (o_mode == 1) begin
            o_data = {i_rx_data[12:5], 1'b0};
        end
    end
end
*/

always @(*) begin
    // 항상 디코딩 (i_rx_data는 SPI 레지스터라 값 유지됨)
    o_cmd                 = i_rx_data[15:13];
    o_cmd_valid_one_pulse = i_rx_done; // 이것만 펄스
    o_mode                = i_rx_data[0];
    o_addr                = i_rx_data[4:1];

    if (i_rx_data[0] == 0) begin                 // E4M3 (exp[11:8], mant[7:5])
        if (i_rx_data[11:8] == 4'b0000)          // exp=0 → zero/subnormal flush
            o_data = {i_rx_data[12], 8'b0};      // 부호 유지, exp/mant = 0
        else
            o_data = {i_rx_data[12], exp_conv, i_rx_data[7:5]};
    end else begin                               // E5M2 (exp[11:7], mant[6:5])
        if (i_rx_data[11:7] == 5'b00000)         // exp=0 → zero/subnormal flush
            o_data = {i_rx_data[12], 8'b0};
        else
            o_data = {i_rx_data[12:5], 1'b0};
    end
end

endmodule