`timescale 1ns / 1ps

module SPI_slave(
    input i_rstn,
    input i_clk,
    input i_ssn,
    input i_mosi,
    input i_sclk,
    input i_tx_load,
    output o_miso,
    input [15:0] i_dat,
    output reg [15:0] o_dat,
    output o_rx_done // SSn 0→1 순간 1-cycle 펄스
    );

  reg [15:0] RBUF, TBUF;
  reg [15:0] r_dat;

  assign o_miso = TBUF[15];

  reg sclk_d1, sclk_d2;
  reg ssn_d1,  ssn_d2;
  reg mosi_d1, mosi_d2;

  always @(posedge i_clk or negedge i_rstn) begin
    if (i_rstn == 1'b0) begin
      sclk_d1 <= 1'b0; sclk_d2 <= 1'b0;  // SCLK idle low (mode 0)
      ssn_d1  <= 1'b1; ssn_d2  <= 1'b1;  // SSn idle high
      mosi_d1 <= 1'b0; mosi_d2 <= 1'b0;
    end else begin
      sclk_d1 <= i_sclk; sclk_d2 <= sclk_d1;
      ssn_d1  <= i_ssn;  ssn_d2  <= ssn_d1;
      mosi_d1 <= i_mosi; mosi_d2 <= mosi_d1;
    end
  end

  wire sclk_rising  =  sclk_d1 & ~sclk_d2;  // SCLK 상승엣지 펄스
  wire sclk_falling = ~sclk_d1 &  sclk_d2;  // SCLK 하강엣지 펄스
  wire ssn_falling  = ~ssn_d1  &  ssn_d2;   // 트랜잭션 시작
  wire ssn_rising   =  ssn_d1  & ~ssn_d2;   // 트랜잭션 끝

  always @(posedge i_clk or negedge i_rstn) begin
    if (i_rstn == 1'b0) begin
      RBUF <= 16'h00;
    end else if (sclk_rising) begin
      RBUF <= {RBUF[14:00], mosi_d2};
    end
  end

  always @(posedge i_clk or negedge i_rstn) begin
    if (i_rstn == 1'b0) begin
      TBUF <= 16'h00;
    end else if (ssn_falling) begin
      TBUF <= r_dat;
    end else if (sclk_falling) begin
      TBUF <= {TBUF[14:00], 1'b0};
    end
  end

  always @(posedge i_clk or negedge i_rstn) begin
    if (i_rstn == 1'b0) begin
      r_dat <= 16'h00;
      o_dat <= 16'h00;
    end else begin
      if (i_tx_load) begin
        r_dat <= i_dat;
      end
      if (ssn_rising) begin
        o_dat <= RBUF;       // 트랜잭션이 끝나는 순간 16비트 확정
      end
    end
  end

  assign o_rx_done = ssn_rising;  // SSn 0→1 순간 1-cycle 펄스

endmodule
