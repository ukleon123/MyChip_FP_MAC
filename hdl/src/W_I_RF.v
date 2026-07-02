// 기존의 router와 weight/input dff를 통합했다. 

/*
| Port          | Dir | Width | Description                   
| ------------- | --- | ----- | ----------------------------- 
| i_clk, i_rstn | in  | 1     |                               
| i_clear_valid | in  | 1     |
| i_w_wen       | in  | 1     | weight write enable (w RF 지정) 
| i_i_wen       | in  | 1     | input write enable (i RF 지정)  
| i_addr        | in  | 4     | 몇번 register에 쓸지 지정            
| i_data        | in  | 9     | 쓸 data                        
| o_w_all_valid | out | 1     | 모든 weight register가 다 찼으면 1   
| o_i_all_valid | out | 1     | 모든 input register가 다 찼으면 1    
| o_w_data      | out | 9x9   | weight 저장                    
| o_i_data      | out | 9x9   | input 저장                      
*/

`timescale 1ns / 1ps

module W_I_RF (
    input            i_clk, 
    input            i_rstn,
    // input            i_clear_valid,
    input            i_w_wen,
    input            i_i_wen,
    input      [3:0] i_addr,
    input      [8:0] i_data,
    // output wire      o_w_all_valid,
    // output wire      o_i_all_valid,
    output reg [8:0] o_w_data [8:0],
    output reg [8:0] o_i_data [8:0]
);

// reg [8:0] w_all_set;
// reg [8:0] i_all_set;

always @(i_clk) begin
    /*if (!i_rstn) begin
        w_all_set     <= 9'd0;
        i_all_set     <= 9'd0;
    end else */
    if (i_w_wen) begin
        case (i_addr)
            4'b0000: begin 
                o_w_data  [0] <= i_data;
                // w_all_set [0] <= 1'd1;
            end
            4'b0001: begin
                o_w_data  [1] <= i_data;
                // w_all_set [1] <= 1'd1;
            end
            4'b0010: begin
                o_w_data  [2] <= i_data;
                // w_all_set [2] <= 1'd1;
            end
            4'b0011: begin
                o_w_data  [3] <= i_data;
                // w_all_set [3] <= 1'd1;
            end
            4'b0100: begin
                o_w_data  [4] <= i_data;
                // w_all_set [4] <= 1'd1;
            end
            4'b0101: begin
                o_w_data  [5] <= i_data;
                // w_all_set [5] <= 1'd1;
            end
            4'b0110: begin
                o_w_data  [6] <= i_data;
                // w_all_set [6] <= 1'd1;
            end
            4'b0111: begin
                o_w_data  [7] <= i_data;
                // w_all_set [7] <= 1'd1;
            end
            4'b1000: begin 
                o_w_data  [8] <= i_data;
                // w_all_set [8] <= 1'd1;
            end
        endcase
    end else if (i_i_wen) begin
        case (i_addr)
            4'b0000: begin 
                o_i_data  [0] <= i_data;
                // i_all_set [0] <= 1'd1;
            end
            4'b0001: begin
                o_i_data  [1] <= i_data;
                // i_all_set [1] <= 1'd1;
            end
            4'b0010: begin
                o_i_data  [2] <= i_data;
                // i_all_set [2] <= 1'd1;
            end
            4'b0011: begin
                o_i_data  [3] <= i_data;
                // i_all_set [3] <= 1'd1;
            end
            4'b0100: begin
                o_i_data  [4] <= i_data;
                // i_all_set [4] <= 1'd1;
            end
            4'b0101: begin
                o_i_data  [5] <= i_data;
                // i_all_set [5] <= 1'd1;
            end
            4'b0110: begin
                o_i_data  [6] <= i_data;
                // i_all_set [6] <= 1'd1;
            end
            4'b0111: begin
                o_i_data  [7] <= i_data;
                // i_all_set [7] <= 1'd1;
            end
            4'b1000: begin 
                o_i_data  [8] <= i_data;
                // i_all_set [8] <= 1'd1;
            end
        endcase
    end
end

// assign o_w_all_valid = &w_all_set;
// assign o_i_all_valid = &i_all_set;
    
endmodule