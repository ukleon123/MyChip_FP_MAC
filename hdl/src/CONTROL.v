`timescale 1ns / 1ps

module CONTROL (
    input i_clk,
    input i_rstn,
    // SPI_slave
    output reg o_tx_load, // 연산이 끝난 master에 보낼 data 저장 신호
    // IR
    input [2:0] i_cmd,
    input i_cmd_valid_one_pulse,
    input i_mode,
    // W_I_RF
    // output reg o_clear_valid,
    output reg o_w_wen,
    output reg o_i_wen,
    // input i_w_all_valid,
    // input i_i_all_valid,
    // FPU (FPU 9개)
    // FPU_RF
    output reg o_fpu_rf_send_start,
    // ACC
    output reg o_acc_start,
    input i_acc_done,
    //ACC_R
    output reg o_acc_r_wen,
    output reg o_mode,
    // DEBUG: 명령 1개 완료 시 high, 새 명령 들어오면 0
    output reg o_cmd_done
);

localparam S_IDLE          = 3'b000;
localparam S_LOAD_W        = 3'b001;
localparam S_LOAD_I        = 3'b010;
localparam S_COMPUTE = 3'b011;
//localparam S_COMPUTE_DONE  = 3'b100;
localparam S_ACC_START     = 3'b100;
localparam S_READ_RESULT   = 3'b101;
localparam S_TX_RESULT     = 3'b110;

localparam CMD_LOAD_W      = 3'b000;
localparam CMD_LOAD_I      = 3'b001;
localparam CMD_COMPUTE     = 3'b010;
localparam CMD_ACC         = 3'b011;
localparam CMD_READ_RESULT = 3'b100;

reg [2:0] state, next_state;

//--------------------
reg acc_done_flag;

always @(posedge i_clk or negedge i_rstn) begin
    if (!i_rstn)
        acc_done_flag <= 1'b0;
    else if (i_acc_done)
        acc_done_flag <= 1'b1;
    else if (state == S_TX_RESULT)
        acc_done_flag <= 1'b0;
end


//--------------------
/*
reg fpu_rf_done_flag;

always @(posedge i_clk or negedge i_rstn) begin
    if (!i_rstn)
        fpu_rf_done_flag <= 1'b0;
    else if (i_fpu_rf_all_valid)
        fpu_rf_done_flag <= 1'b1;
    else if (state == S_ACC_START)
        fpu_rf_done_flag <= 1'b0;
end
*/
//--------------------

// --- state 넘기기 ---
always @(posedge i_clk or negedge i_rstn) begin
    if (!i_rstn)
        state <= S_IDLE;
    else
        state <= next_state;
end

// --- 다음-state logic (combinational) ---
always @(*) begin
    next_state = state;
    case (state)
        S_IDLE:begin
            if ((i_cmd==CMD_LOAD_W) && i_cmd_valid_one_pulse)
                next_state = S_LOAD_W;
            if ((i_cmd==CMD_LOAD_I) && i_cmd_valid_one_pulse)
                next_state = S_LOAD_I;
            // if ((i_cmd==CMD_COMPUTE) && i_cmd_valid_one_pulse && i_w_all_valid && i_i_all_valid)
            if ((i_cmd==CMD_COMPUTE) && i_cmd_valid_one_pulse)
                next_state = S_COMPUTE;
            if ((i_cmd==CMD_ACC) && i_cmd_valid_one_pulse)
                next_state = S_ACC_START;
            if ((i_cmd==CMD_READ_RESULT) && i_cmd_valid_one_pulse && acc_done_flag)
                next_state = S_READ_RESULT;
        end 
        S_LOAD_W:        next_state = S_IDLE;
        S_LOAD_I:        next_state = S_IDLE;
        S_COMPUTE: next_state = S_IDLE;
        //S_COMPUTE_DONE:  next_state = S_IDLE;
        S_ACC_START:     next_state = S_IDLE;
        S_READ_RESULT: next_state = S_TX_RESULT;
        S_TX_RESULT: next_state = S_IDLE;
        default: next_state = S_IDLE;
    endcase
end

//--------------------
// DEBUG 핀: 명령 1개가 끝나면 high, 새 명령 펄스가 오면 0으로 클리어
//   ACC는 FSM이 바로 IDLE로 돌아오므로 실제 누산 완료(i_acc_done)를 완료로 사용,
//   나머지 명령은 해당 처리 state를 완료 시점으로 사용.
wire cmd_done_event = (state == S_LOAD_W)    ||
                      (state == S_LOAD_I)    ||
                      (state == S_COMPUTE)   ||
                      (state == S_TX_RESULT) ||
                      i_acc_done;

always @(posedge i_clk or negedge i_rstn) begin
    if (!i_rstn)
        o_cmd_done <= 1'b0;
    else if (i_cmd_valid_one_pulse)   // 새 명령 들어오면 0
        o_cmd_done <= 1'b0;
    else if (cmd_done_event)          // 명령이 끝나면 high
        o_cmd_done <= 1'b1;
end

//--------------------

// --- output logic ---
always @(posedge i_clk or negedge i_rstn) begin
    if (!i_rstn) begin
        o_tx_load           <= 1'b0;
        // o_clear_valid       <= 1'b0;
        o_w_wen             <= 1'b0;
        o_i_wen             <= 1'b0;
        //o_fpu_start         <= 1'b0;
        //o_fpu_rf_wen        <= 1'b0;
        o_fpu_rf_send_start <= 1'b0;
        o_acc_start         <= 1'b0;
        o_acc_r_wen         <= 1'b0;
        o_mode              <= 1'b0;
    end else begin
        o_tx_load           <= 1'b0;
        // o_clear_valid       <= 1'b0;
        o_w_wen             <= 1'b0;
        o_i_wen             <= 1'b0;
        //o_fpu_start         <= 1'b0;
        //o_fpu_rf_wen        <= 1'b0;
        o_fpu_rf_send_start <= 1'b0;
        o_acc_start         <= 1'b0;
        o_acc_r_wen         <= 1'b0; 
        case (next_state)
            S_IDLE: ;
            S_LOAD_W: o_w_wen <= 1'b1;
            S_LOAD_I: o_i_wen <= 1'b1;
            S_COMPUTE: ;
            S_ACC_START: begin
                o_fpu_rf_send_start <= 1'b1;
                o_acc_start <= 1'b1;
            end
            S_READ_RESULT: begin
                o_acc_r_wen <= 1'b1;
                o_mode <= i_mode;
            end
            S_TX_RESULT: begin
                o_tx_load <= 1'b1;
                // o_clear_valid <= 1'b1;
            end
            default: ;
        endcase
    end
end

endmodule