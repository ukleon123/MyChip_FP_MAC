`timescale 1ns / 1ps

module TOP (
    input        i_clk,
    input        i_rstn,
    // SPI physical pins
    input        i_ssn,
    input        i_mosi,
    input        i_sclk,
    output       o_miso,
    // DEBUG: 명령 1개 완료 시 high, 새 명령 들어오면 0
    output       o_cmd_done
);

// ===== Internal wires =====

// SPI_slave
wire [15:0] spi_o_dat;
wire        spi_rx_done;

// IR
wire [2:0]  ir_cmd;
wire        ir_cmd_valid_one_pulse;
wire        ir_mode;
wire [8:0]  ir_data;
wire [3:0]  ir_addr;

// CONTROL
wire        ctrl_tx_load;
// wire        ctrl_clear_valid;
wire        ctrl_w_wen;
wire        ctrl_i_wen;
//wire        ctrl_fpu_start;
//wire        ctrl_fpu_rf_wen;
wire        ctrl_fpu_rf_send_start;
wire        ctrl_acc_start;
wire        ctrl_acc_r_wen;
wire        ctrl_mode;
wire        ctrl_cmd_done;

// W_I_RF
// wire        w_all_valid;
// wire        i_all_valid;
wire [8:0]  w_data   [8:0];
wire [8:0]  i_data_rf [8:0];

// FPU (3개 병렬, ACC가 acc_cnt로 1개 결과만 선택해 순차 누산)
wire [3:0]  fpu_sel;
wire [8:0]  fpu_prod0, fpu_prod1, fpu_prod2;
wire [8:0]  fpu_product;

// FPU_RF
// 변경
wire [8:0]  router_out;
//wire        fpu_rf_all_valid;

// ACC
wire [12:0]  acc_result;
wire        acc_done;

// ACC_R
wire [7:0]  acc_r_data;

// ===== SPI TX data: ACC_R 8bit -> 16bit padding =====
wire [15:0] spi_tx_data = {8'h00, acc_r_data};

// ===== rx_done 1-cycle delay =====
// SPI o_dat가 NBA로 갱신되므로, 1사이클 지연해야 IR이 올바른 o_dat를 봄
reg rx_done_d;
always @(posedge i_clk or negedge i_rstn) begin
    if (!i_rstn) rx_done_d <= 1'b0;
    else         rx_done_d <= spi_rx_done;
end

// ===== SPI_slave =====
SPI_slave u_spi (
    .i_rstn    (i_rstn),
    .i_clk     (i_clk),
    .i_ssn     (i_ssn),
    .i_mosi    (i_mosi),
    .i_sclk    (i_sclk),
    .i_tx_load (ctrl_tx_load),
    .o_miso    (o_miso),
    .i_dat     (spi_tx_data),
    .o_dat     (spi_o_dat),
    .o_rx_done (spi_rx_done)
);

// ===== IR =====
IR u_ir (
    .i_rx_data            (spi_o_dat),
    .i_rx_done            (rx_done_d),
    .o_cmd                (ir_cmd),
    .o_cmd_valid_one_pulse(ir_cmd_valid_one_pulse),
    .o_mode               (ir_mode),
    .o_data               (ir_data),
    .o_addr               (ir_addr)
);

// ===== CONTROL =====
CONTROL u_ctrl (
    .i_clk                (i_clk),
    .i_rstn               (i_rstn),
    .o_tx_load            (ctrl_tx_load),
    .i_cmd                (ir_cmd),
    .i_cmd_valid_one_pulse(ir_cmd_valid_one_pulse),
    .i_mode               (ir_mode),
    //.o_clear_valid        (ctrl_clear_valid),
    .o_w_wen              (ctrl_w_wen),
    .o_i_wen              (ctrl_i_wen),
    //.i_w_all_valid        (w_all_valid),
    //.i_i_all_valid        (i_all_valid),
    //.o_fpu_start          (ctrl_fpu_start),
    //.o_fpu_rf_wen         (ctrl_fpu_rf_wen),
    .o_fpu_rf_send_start  (ctrl_fpu_rf_send_start),
    //.i_fpu_rf_all_valid   (fpu_rf_all_valid),
    .o_acc_start          (ctrl_acc_start),
    .i_acc_done           (acc_done),
    .o_acc_r_wen          (ctrl_acc_r_wen),
    .o_mode               (ctrl_mode),
    .o_cmd_done           (ctrl_cmd_done)
);

// ===== DEBUG 핀 외부 출력 =====
assign o_cmd_done = ctrl_cmd_done;

// ===== W_I_RF =====
W_I_RF u_w_i_rf (
    .i_clk        (i_clk),
    .i_rstn       (i_rstn),
    //.i_clear_valid(ctrl_clear_valid),
    .i_w_wen      (ctrl_w_wen),
    .i_i_wen      (ctrl_i_wen),
    .i_addr       (ir_addr),
    .i_data       (ir_data),
    //.o_w_all_valid(w_all_valid),
    //.o_i_all_valid(i_all_valid),
    .o_w_data     (w_data),
    .o_i_data     (i_data_rf)
);

// ===== FPU x3 (병렬) =====
// 9개 원소를 3개 그룹으로 나눠 FPU 3개가 담당 (병렬 인스턴스, 항상 동작):
//   FPU0={0,1,2}, FPU1={3,4,5}, FPU2={6,7,8}
// 매 사이클 FPU 3개가 모두 곱하지만, ACC는 grp_sel에 해당하는 1개 결과만 선택해
// 1개 adder로 9사이클 순차 누산 → 결과는 9-FPU와 bit-identical.
//
// ----- 고정 스케줄 상수 (cnt가 즉석 선택하지 않고, 순서를 미리 박아둠) -----
// step(=fpu_sel) 0~8 동안의 처리 순서를 상수 테이블로 고정. cnt는 인덱스 역할만.
//   step :  0  1  2  3  4  5  6  7  8
//   누산 원소: 0  1  2  3  4  5  6  7  8   (고정 순서)
//   grp  :  0  0  0  1  1  1  2  2  2   ← 어느 FPU 출력을 쓸지
//   sub  :  0  1  2  0  1  2  0  1  2   ← 그룹 내 위치
// 2bit씩 9 step을 한 벡터에 pack (LSB = step0).
localparam [17:0] GRP_SCHED = {2'd2,2'd2,2'd2, 2'd1,2'd1,2'd1, 2'd0,2'd0,2'd0};
localparam [17:0] SUB_SCHED = {2'd2,2'd1,2'd0, 2'd2,2'd1,2'd0, 2'd2,2'd1,2'd0};

wire [1:0] grp_sel = GRP_SCHED[fpu_sel*2 +: 2];  // step별 사용할 FPU 번호
wire [1:0] sub_idx = SUB_SCHED[fpu_sel*2 +: 2];  // step별 그룹 내 인덱스

// 각 FPU는 자기 그룹 내에서 sub_idx로 (w,i) 한 쌍 선택 (3:1 input mux)
wire [3:0] idx0 = {2'b00, sub_idx};          // 0,1,2
wire [3:0] idx1 = {2'b00, sub_idx} + 4'd3;   // 3,4,5
wire [3:0] idx2 = {2'b00, sub_idx} + 4'd6;   // 6,7,8

FPU u_fpu0 (
    .i_weight (w_data   [idx0]),
    .i_input  (i_data_rf[idx0]),
    .o_result (fpu_prod0)
);
FPU u_fpu1 (
    .i_weight (w_data   [idx1]),
    .i_input  (i_data_rf[idx1]),
    .o_result (fpu_prod1)
);
FPU u_fpu2 (
    .i_weight (w_data   [idx2]),
    .i_input  (i_data_rf[idx2]),
    .o_result (fpu_prod2)
);

// group으로 1개 FPU 결과 선택 (3:1 output mux) → ACC로
assign fpu_product = (grp_sel == 2'd0) ? fpu_prod0 :
                     (grp_sel == 2'd1) ? fpu_prod1 : fpu_prod2;

// ===== FPU_RF =====
/*FPU_RF u_fpu_rf (
    .i_clk       (i_clk),
    .i_rstn      (i_rstn),
    .i_wen       (ctrl_fpu_rf_wen),
    .i_send_start(ctrl_fpu_rf_send_start),
    .i_data      (fpu_result),
    .o_data      (fpu_rf_out),
    .o_all_valid (fpu_rf_all_valid)
);*/

// 변경
// ===== ACC =====
ACC u_acc (
    .i_clk    (i_clk),
    .i_rstn   (i_rstn),
    .i_start  (ctrl_acc_start),
    .i_data   (fpu_product),
    .o_sel    (fpu_sel),
    .o_result (acc_result),
    .o_done   (acc_done)
);

// ===== ACC_R =====
ACC_R u_acc_r (
    .i_clk   (i_clk),
    .i_rstn  (i_rstn),
    .i_wen   (ctrl_acc_r_wen),
    .i_mode  (ctrl_mode),
    .i_data  (acc_result),
    .o_data  (acc_r_data)
);

endmodule
