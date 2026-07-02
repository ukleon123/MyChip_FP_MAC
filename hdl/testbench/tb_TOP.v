`timescale 1ns / 1ps

module tb_TOP;

reg clk, rstn;
reg ssn, mosi, sclk_reg;
wire miso;
wire dbg_cmd_done;          // DEBUG 핀

TOP u_top (
    .i_clk      (clk),
    .i_rstn     (rstn),
    .i_ssn      (ssn),
    .i_mosi     (mosi),
    .i_sclk     (sclk_reg),
    .o_miso     (miso),
    .o_cmd_done (dbg_cmd_done)
);

// DEBUG 핀이 0으로 떨어진 적이 있는지 감시 (새 명령 시 clear 확인용)
reg saw_low;
always @(negedge dbg_cmd_done) saw_low = 1'b1;

// System clock: 100MHz (10ns)
parameter CLK_PERIOD = 10;
always #(CLK_PERIOD/2) clk = ~clk;

// SPI clock half period: 50ns (10MHz)
parameter SCLK_HALF = 50;

// ================================================================
//  SPI master tasks
// ================================================================
task spi_transfer;
    input  [15:0] tx_data;
    output [15:0] rx_data;
    integer i;
    begin
        ssn = 1'b0;
        #(SCLK_HALF);
        for (i = 15; i >= 0; i = i - 1) begin
            mosi = tx_data[i];
            #(SCLK_HALF);
            sclk_reg = 1'b1;
            #1;
            rx_data[i] = miso;
            #(SCLK_HALF - 1);
            sclk_reg = 1'b0;
        end
        mosi = 1'b0;
        #(SCLK_HALF);
        ssn = 1'b1;
        #(CLK_PERIOD * 20);
    end
endtask

reg [15:0] rx_dummy;

task spi_cmd;
    input [2:0]  cmd;
    input [7:0]  data;
    input [3:0]  addr;
    input        mode;
    begin
        spi_transfer({cmd, data, addr, mode}, rx_dummy);
    end
endtask

// ================================================================
//  FP8 -> real conversion
// ================================================================
function real e4m3_to_real;
    input [7:0] val;
    real mantissa;
    integer exp_int;
    begin
        if (val[6:3] == 0 && val[2:0] == 0)
            e4m3_to_real = 0.0;
        else begin
            mantissa = 1.0 + val[2:0] / 8.0;
            exp_int  = val[6:3] - 7;
            e4m3_to_real = (val[7] ? -1.0 : 1.0) * mantissa * (2.0 ** exp_int);
        end
    end
endfunction

function real e5m2_to_real;
    input [7:0] val;
    real mantissa;
    integer exp_int;
    begin
        if (val[6:2] == 0 && val[1:0] == 0)
            e5m2_to_real = 0.0;
        else begin
            mantissa = 1.0 + val[1:0] / 4.0;
            exp_int  = val[6:2] - 15;
            e5m2_to_real = (val[7] ? -1.0 : 1.0) * mantissa * (2.0 ** exp_int);
        end
    end
endfunction

// ================================================================
//  Test infrastructure
// ================================================================
parameter NUM_TESTS = 29;

reg        read_mode [0:NUM_TESTS-1];
reg  [7:0] tw        [0:NUM_TESTS-1][0:8];  // weight values
reg        twm       [0:NUM_TESTS-1][0:8];  // weight modes
reg  [7:0] ti        [0:NUM_TESTS-1][0:8];  // input values
reg        tim       [0:NUM_TESTS-1][0:8];  // input modes
real       expected  [0:NUM_TESTS-1];
real       tol_rel   [0:NUM_TESTS-1];       // relative tolerance (0 => absolute 0.001)
reg        expect_special [0:NUM_TESTS-1];  // 1 => compare raw output byte (NaN/Inf 등 실수비교 불가)
reg  [7:0] expected_byte  [0:NUM_TESTS-1];  // 기대 8bit 출력 인코딩 (special 케이스 전용)

integer pass_count, fail_count;
integer t, j;
integer seed;
reg [15:0] result;
real actual, error_val, w_real, i_real, threshold;

// ================================================================
//  Test case definitions
// ================================================================
task define_tests;
    integer k, re, rm;
    begin
        // default: absolute tolerance (0.001) for all tests
        for (k=0; k<NUM_TESTS; k=k+1) tol_rel[k] = 0.0;

        // default: 일반(실수) 비교. special 케이스만 아래에서 1로 set
        for (k=0; k<NUM_TESTS; k=k+1) begin
            expect_special[k] = 1'b0;
            expected_byte[k]  = 8'h00;
        end

        // ---- Test01: All 1.0 x 1.0 (E4M3), expect=9.0 ----
        read_mode[0] = 0;
        expected[0]  = 9.0;
        for (k=0; k<9; k=k+1) begin twm[0][k]=0; tw[0][k]=8'h38; tim[0][k]=0; ti[0][k]=8'h38; end

        // ---- Test02: Single 2.0 x 3.0 (E4M3), rest=0, expect=6.0 ----
        read_mode[1] = 0;
        expected[1]  = 6.0;
        for (k=0; k<9; k=k+1) begin twm[1][k]=0; tw[1][k]=8'h00; tim[1][k]=0; ti[1][k]=8'h00; end
        tw[1][0] = 8'h40; ti[1][0] = 8'h44;

        // ---- Test03: All 2.0 x 2.0 (E4M3), expect=36.0 ----
        read_mode[2] = 0;
        expected[2]  = 36.0;
        for (k=0; k<9; k=k+1) begin twm[2][k]=0; tw[2][k]=8'h40; tim[2][k]=0; ti[2][k]=8'h40; end

        // ---- Test04: All 1.0 x (-1.0) (E4M3), sum=-9.0 -> ReLU -> 0.0 ----
        read_mode[3] = 0;
        expected[3]  = 0.0;
        for (k=0; k<9; k=k+1) begin twm[3][k]=0; tw[3][k]=8'h38; tim[3][k]=0; ti[3][k]=8'hB8; end

        // ---- Test05: All 1.0 x 1.0 (E5M2), sum=9.0 ----
        //   read=E5M2(가수 2bit): 9.0 표현불가 → round-to-even 으로 8.0 으로 양자화
        read_mode[4] = 1;
        expected[4]  = 8.0;
        for (k=0; k<9; k=k+1) begin twm[4][k]=1; tw[4][k]=8'h3C; tim[4][k]=1; ti[4][k]=8'h3C; end

        // ---- Test06: All 0.5 x 0.5 (E4M3), expect=2.25 ----
        read_mode[5] = 0;
        expected[5]  = 2.25;
        for (k=0; k<9; k=k+1) begin twm[5][k]=0; tw[5][k]=8'h30; tim[5][k]=0; ti[5][k]=8'h30; end

        // ---- Test07: All 4.0 x 4.0 (E4M3), expect=144.0 ----
        read_mode[6] = 0;
        expected[6]  = 144.0;
        for (k=0; k<9; k=k+1) begin twm[6][k]=0; tw[6][k]=8'h48; tim[6][k]=0; ti[6][k]=8'h48; end

        // ---- Test08: +1/-1 cancel (E4M3), expect=0.0 ----
        read_mode[7] = 0;
        expected[7]  = 0.0;
        for (k=0; k<9; k=k+1) begin twm[7][k]=0; tw[7][k]=8'h38; tim[7][k]=0; end
        ti[7][0]=8'h38; ti[7][1]=8'hB8; ti[7][2]=8'h38; ti[7][3]=8'hB8;
        ti[7][4]=8'h38; ti[7][5]=8'hB8; ti[7][6]=8'h38; ti[7][7]=8'hB8;
        ti[7][8]=8'h00;

        // ---- Test09: All zero (E4M3), expect=0.0 ----
        read_mode[8] = 0;
        expected[8]  = 0.0;
        for (k=0; k<9; k=k+1) begin twm[8][k]=0; tw[8][k]=8'h00; tim[8][k]=0; ti[8][k]=8'h00; end

        // ---- Test10: Mixed mode, read=E4M3, expect=20.0 ----
        read_mode[9] = 0;
        expected[9]  = 20.0;
        twm[9][0]=0; tw[9][0]=8'h38; tim[9][0]=1; ti[9][0]=8'h42;
        twm[9][1]=1; tw[9][1]=8'h40; tim[9][1]=0; ti[9][1]=8'h30;
        twm[9][2]=0; tw[9][2]=8'h30; tim[9][2]=1; ti[9][2]=8'h40;
        twm[9][3]=1; tw[9][3]=8'h3E; tim[9][3]=0; ti[9][3]=8'h40;
        twm[9][4]=0; tw[9][4]=8'h48; tim[9][4]=1; ti[9][4]=8'h3C;
        twm[9][5]=1; tw[9][5]=8'hBC; tim[9][5]=0; ti[9][5]=8'h38;
        twm[9][6]=0; tw[9][6]=8'h3C; tim[9][6]=1; ti[9][6]=8'hC0;
        twm[9][7]=1; tw[9][7]=8'h42; tim[9][7]=0; ti[9][7]=8'h44;
        twm[9][8]=0; tw[9][8]=8'h40; tim[9][8]=1; ti[9][8]=8'h3E;

        // ---- Test11: Mixed mode, read=E5M2, expect=20.0 ----
        read_mode[10] = 1;
        expected[10]  = 20.0;
        twm[10][0]=0; tw[10][0]=8'h38; tim[10][0]=1; ti[10][0]=8'h42;
        twm[10][1]=1; tw[10][1]=8'h40; tim[10][1]=0; ti[10][1]=8'h30;
        twm[10][2]=0; tw[10][2]=8'h30; tim[10][2]=1; ti[10][2]=8'h40;
        twm[10][3]=1; tw[10][3]=8'h3E; tim[10][3]=0; ti[10][3]=8'h40;
        twm[10][4]=0; tw[10][4]=8'h48; tim[10][4]=1; ti[10][4]=8'h3C;
        twm[10][5]=1; tw[10][5]=8'hBC; tim[10][5]=0; ti[10][5]=8'h38;
        twm[10][6]=0; tw[10][6]=8'h3C; tim[10][6]=1; ti[10][6]=8'hC0;
        twm[10][7]=1; tw[10][7]=8'h42; tim[10][7]=0; ti[10][7]=8'h44;
        twm[10][8]=0; tw[10][8]=8'h40; tim[10][8]=1; ti[10][8]=8'h3E;

        // ---- Test12: All 1.5 x 1.5 (E4M3), sum=20.25 ----
        //   read=E4M3(가수 3bit): 20.25 표현불가 → 최근접 20.0 으로 양자화
        read_mode[11] = 0;
        expected[11]  = 20.0;
        for (k=0; k<9; k=k+1) begin twm[11][k]=0; tw[11][k]=8'h3C; tim[11][k]=0; ti[11][k]=8'h3C; end

        // ---- Test13: All 4.0 x 3.0 (E4M3), sum=108.0 ----
        //   read=E4M3(가수 3bit): 108 표현불가 → 최근접 112.0 으로 양자화
        read_mode[12] = 0;
        expected[12]  = 112.0;
        for (k=0; k<9; k=k+1) begin twm[12][k]=0; tw[12][k]=8'h48; tim[12][k]=0; ti[12][k]=8'h44; end

        // ---- Test14: All 1.0 x 2.0 (E4M3), expect=18.0 ----
        read_mode[13] = 0;
        expected[13]  = 18.0;
        for (k=0; k<9; k=k+1) begin twm[13][k]=0; tw[13][k]=8'h38; tim[13][k]=0; ti[13][k]=8'h40; end

        // ---- Test15: All 1.0 x 2.0 (E5M2), read=E4M3, expect=18.0 ----
        read_mode[14] = 0;
        expected[14]  = 18.0;
        for (k=0; k<9; k=k+1) begin twm[14][k]=1; tw[14][k]=8'h3C; tim[14][k]=1; ti[14][k]=8'h40; end

        // ---- Test16: Single 3.0 x 3.0 (E4M3), read=E5M2, sum=9.0 ----
        //   read=E5M2(가수 2bit): 9.0 표현불가 → round-to-even 으로 8.0 으로 양자화
        read_mode[15] = 1;
        expected[15]  = 8.0;
        for (k=0; k<9; k=k+1) begin twm[15][k]=0; tw[15][k]=8'h00; tim[15][k]=0; ti[15][k]=8'h00; end
        tw[15][0] = 8'h44; ti[15][0] = 8'h44;

        // ---- Test17: Random SMALL values (E4M3), each entry different ----
        //   weight/input exp field 4..6 -> magnitude ~0.125..0.94 (all positive)
        //   output read as E4M3; expected = sum of 9 products (relative tol 15%)
        seed = 32'hDEAD_BEEF;
        read_mode[16] = 0;
        tol_rel[16]   = 0.15;
        expected[16]  = 0.0;
        for (k=0; k<9; k=k+1) begin
            re = 4 + ({$random(seed)} % 3);          // exp field 4,5,6
            rm = {$random(seed)} % 8;                // mantissa 0..7
            twm[16][k] = 0; tw[16][k] = {1'b0, re[3:0], rm[2:0]};
            re = 4 + ({$random(seed)} % 3);
            rm = {$random(seed)} % 8;
            tim[16][k] = 0; ti[16][k] = {1'b0, re[3:0], rm[2:0]};
            expected[16] = expected[16]
                         + e4m3_to_real(tw[16][k]) * e4m3_to_real(ti[16][k]);
        end

        // ---- Test18: Random LARGE values (E4M3 in), each entry different ----
        //   weight/input exp field 9..11 -> magnitude ~4..30 (all positive)
        //   sum overflows E4M3 range, so output read as E5M2 (relative tol 30%)
        read_mode[17] = 1;
        tol_rel[17]   = 0.30;
        expected[17]  = 0.0;
        for (k=0; k<9; k=k+1) begin
            re = 9 + ({$random(seed)} % 3);          // exp field 9,10,11
            rm = {$random(seed)} % 8;
            twm[17][k] = 0; tw[17][k] = {1'b0, re[3:0], rm[2:0]};
            re = 9 + ({$random(seed)} % 3);
            rm = {$random(seed)} % 8;
            tim[17][k] = 0; ti[17][k] = {1'b0, re[3:0], rm[2:0]};
            expected[17] = expected[17]
                         + e4m3_to_real(tw[17][k]) * e4m3_to_real(ti[17][k]);
        end

        // ================================================================
        //  특수값(NaN/Inf) 케이스 — 실수 비교 불가 → 출력 raw byte 비교
        //  특수값은 반드시 E5M2(mode=1) 입력으로 주입해야 E5M3 exp=11111 도달.
        //  (E4M3 입력은 bias +8 변환상 exp=11111에 도달 불가하여 nan 경로 미도달)
        //  E5M2 인코딩: +1.0=0x3C, +Inf=0x7C, -Inf=0xFC, NaN=0x7E, 0.0=0x00
        //  기대 출력: ACC_R nan 인코딩 → E5M2 읽기=0x7D, E4M3 읽기=0x7F
        // ================================================================

        // ---- Test19: 모든 input = +Inf, weight = +1.0, read E5M2 ----
        //   FPU는 inf 입력을 nan_val로 매핑 → 최종 NaN(0x7D)
        read_mode[18]      = 1;
        expect_special[18] = 1'b1;
        expected_byte[18]  = 8'h7D;
        expected[18]       = 0.0;
        for (k=0; k<9; k=k+1) begin
            twm[18][k]=1; tw[18][k]=8'h3C;   // +1.0 (E5M2)
            tim[18][k]=1; ti[18][k]=8'h7C;   // +Inf (E5M2)
        end

        // ---- Test20: 9개 중 1개 input만 NaN, 나머지 1.0x1.0, read E5M2 ----
        //   NaN 전파(propagation) 검증 → 최종 NaN(0x7D)
        read_mode[19]      = 1;
        expect_special[19] = 1'b1;
        expected_byte[19]  = 8'h7D;
        expected[19]       = 0.0;
        for (k=0; k<9; k=k+1) begin
            twm[19][k]=1; tw[19][k]=8'h3C;   // +1.0
            tim[19][k]=1; ti[19][k]=8'h3C;   // +1.0
        end
        ti[19][4] = 8'h7E;                   // lane4 input = NaN

        // ---- Test21: 9개 중 1개 weight만 NaN, 나머지 valid, read E4M3 ----
        //   weight-side 특수값 감지 + E4M3 nan 인코딩(0x7F) 검증
        read_mode[20]      = 0;
        expect_special[20] = 1'b1;
        expected_byte[20]  = 8'h7F;
        expected[20]       = 0.0;
        for (k=0; k<9; k=k+1) begin
            twm[20][k]=1; tw[20][k]=8'h3C;   // +1.0
            tim[20][k]=1; ti[20][k]=8'h3C;   // +1.0
        end
        tw[20][7] = 8'h7E;                   // lane7 weight = NaN

        // ---- Test22: 한 lane에서 Inf x 0, 나머지 valid, read E5M2 ----
        //   FPU 우선순위(nan_or_inf > zero) 검증: inf*0 → NaN(0x7D)
        read_mode[21]      = 1;
        expect_special[21] = 1'b1;
        expected_byte[21]  = 8'h7D;
        expected[21]       = 0.0;
        for (k=0; k<9; k=k+1) begin
            twm[21][k]=1; tw[21][k]=8'h3C;   // +1.0
            tim[21][k]=1; ti[21][k]=8'h3C;   // +1.0
        end
        tw[21][2]=8'h00; ti[21][2]=8'h7C;    // lane2: weight 0, input +Inf

        // ---- Test23: 모든 input = -Inf, weight = +1.0, read E5M2 ----
        //   ACC_adder의 nan_val은 sign=0 고정 → 음수 입력이어도 결과 부호는 + (0x7D)
        read_mode[22]      = 1;
        expect_special[22] = 1'b1;
        expected_byte[22]  = 8'h7D;
        expected[22]       = 0.0;
        for (k=0; k<9; k=k+1) begin
            twm[22][k]=1; tw[22][k]=8'h3C;   // +1.0
            tim[22][k]=1; ti[22][k]=8'hFC;   // -Inf (E5M2)
        end

        // ================================================================
        //  Subnormal(비정규) flush 검증 — IR.v 의 subnormal→0 수정 적용 후 통과
        //  비정규 입력 = exp 필드 0, mant!=0. 수정 후 IR이 0으로 flush →
        //  FPU 가 zero 로 인식 → 해당 lane 기여 0.
        //  · Test24~27 (discriminating): 비정규를 '큰 값'과 곱해 FPU underflow를
        //    피하므로, 수정 전이면 leading-1 정규수로 잘못 곱해져 nonzero → FAIL,
        //    수정 후엔 0 → PASS. read 는 E5M2(min normal 2^-14)로 해 작은 오염도 노출.
        //  · Test28~29 (boundary): exp=1(최소 정규값)이 '과도하게' flush되지 않는지
        //    확인. 수정 전/후 모두 PASS 여야 정상(잘못 flush하면 0 → FAIL).
        // ================================================================

        // ---- Test24: E4M3 weight 전부 비정규(0x07) × 256.0, read E5M2, expect 0 ----
        read_mode[23] = 1;
        expected[23]  = 0.0;
        for (k=0; k<9; k=k+1) begin
            twm[23][k]=0; tw[23][k]=8'h07;   // E4M3 subnormal (exp=0000, mant=111)
            tim[23][k]=0; ti[23][k]=8'h78;   // E4M3 256.0 (exp 큰 값 → FPU underflow 회피)
        end

        // ---- Test25: E5M2 input 전부 비정규(0x03) × 2^14, read E5M2, expect 0 ----
        read_mode[24] = 1;
        expected[24]  = 0.0;
        for (k=0; k<9; k=k+1) begin
            twm[24][k]=1; tw[24][k]=8'h74;   // E5M2 2^14 (exp=11101)
            tim[24][k]=1; ti[24][k]=8'h03;   // E5M2 subnormal (exp=00000, mant=11)
        end

        // ---- Test26: E4M3 input 전부 비정규(0x07), weight=256.0, read E5M2, expect 0 ----
        //   input-side 비정규 flush 검증
        read_mode[25] = 1;
        expected[25]  = 0.0;
        for (k=0; k<9; k=k+1) begin
            twm[25][k]=0; tw[25][k]=8'h78;   // E4M3 256.0
            tim[25][k]=0; ti[25][k]=8'h07;   // E4M3 subnormal
        end

        // ---- Test27: 혼합 - 정규 lane 3개(1.0x1.0)만 기여, 6개는 비정규, read E5M2, expect 3.0 ----
        //   수정 전: 비정규 6개가 lane당 ~0.875 오염 → ~8.25 → FAIL
        read_mode[26] = 1;
        expected[26]  = 3.0;
        for (k=0; k<3; k=k+1) begin
            twm[26][k]=1; tw[26][k]=8'h3C;   // +1.0 (E5M2)
            tim[26][k]=1; ti[26][k]=8'h3C;   // +1.0
        end
        for (k=3; k<9; k=k+1) begin
            twm[26][k]=1; tw[26][k]=8'h74;   // 2^14
            tim[26][k]=1; ti[26][k]=8'h03;   // E5M2 subnormal → 0
        end

        // ---- Test28: 경계 - E4M3 최소 정규값(exp=0001) NOT flush, read E4M3, expect 9.0 ----
        //   weight=2^-6(0x08) × input=64.0(0x68) → 곱=1.0, 합=9.0
        read_mode[27] = 0;
        expected[27]  = 9.0;
        for (k=0; k<9; k=k+1) begin
            twm[27][k]=0; tw[27][k]=8'h08;   // E4M3 smallest normal 2^-6 (exp=0001)
            tim[27][k]=0; ti[27][k]=8'h68;   // E4M3 64.0
        end

        // ---- Test29: 경계 - E5M2 최소 정규값(exp=00001) NOT flush, read E5M2, expect 8.0 ----
        //   weight=2^-14(0x04) × input=2^14(0x74) → 곱=1.0, 합=9.0 → E5M2 양자화 8.0
        read_mode[28] = 1;
        expected[28]  = 8.0;
        for (k=0; k<9; k=k+1) begin
            twm[28][k]=1; tw[28][k]=8'h04;   // E5M2 smallest normal 2^-14 (exp=00001)
            tim[28][k]=1; ti[28][k]=8'h74;   // E5M2 2^14
        end
    end
endtask

// ================================================================
//  Run one test: reset -> load W -> load I -> compute -> acc -> read
// ================================================================
task run_test;
    input integer idx;
    begin
        // Reset DUT
        rstn = 0;
        ssn = 1; mosi = 0; sclk_reg = 0;
        #(CLK_PERIOD * 10);
        rstn = 1;
        #(CLK_PERIOD * 10);

        // LOAD_W x9 (cmd=000)
        for (j = 0; j < 9; j = j + 1)
            spi_cmd(3'b000, tw[idx][j], j[3:0], twm[idx][j]);

        // LOAD_I x9 (cmd=001)
        for (j = 0; j < 9; j = j + 1)
            spi_cmd(3'b001, ti[idx][j], j[3:0], tim[idx][j]);

        // COMPUTE (cmd=010)
        spi_cmd(3'b010, 8'h00, 4'h0, 1'b0);
        #500;

        // ACC (cmd=011)
        spi_cmd(3'b011, 8'h00, 4'h0, 1'b0);
        #3000;

        // READ_RESULT (cmd=100)
        spi_cmd(3'b100, 8'h00, 4'h0, read_mode[idx]);
        #500;

        // Dummy SPI read to get result via MISO
        spi_transfer(16'h0000, result);

        // Evaluate
        if (expect_special[idx]) begin
            // 특수값(NaN/Inf): 실수 비교가 무의미 → 출력 8bit 인코딩을 직접 비교
            if (result[7:0] === expected_byte[idx]) begin
                $display("[PASS] Test%02d | (special) Expected=0x%02h  Actual=0x%02h",
                         idx+1, expected_byte[idx], result[7:0]);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Test%02d | (special) Expected=0x%02h  Actual=0x%02h",
                         idx+1, expected_byte[idx], result[7:0]);
                fail_count = fail_count + 1;
            end
        end else begin
            if (read_mode[idx])
                actual = e5m2_to_real(result[7:0]);
            else
                actual = e4m3_to_real(result[7:0]);

            error_val = actual - expected[idx];

            if (error_val < 0.0) error_val = -error_val;

            // relative tolerance for quantized (random) cases, else absolute 0.001
            if (tol_rel[idx] > 0.0) begin
                threshold = tol_rel[idx] * (expected[idx] < 0.0 ? -expected[idx] : expected[idx]);
                if (threshold < 0.001) threshold = 0.001;
            end else begin
                threshold = 0.001;
            end

            if (error_val < threshold) begin
                $display("[PASS] Test%02d | Expected=%f  Actual=%f  Error=%f",
                         idx+1, expected[idx], actual, actual - expected[idx]);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Test%02d | Expected=%f  Actual=%f  Error=%f",
                         idx+1, expected[idx], actual, actual - expected[idx]);
                fail_count = fail_count + 1;
            end
        end
    end
endtask

// ================================================================
//  DEBUG 핀(o_cmd_done) 검증
//   - 새 명령이 들어오면 0으로 clear (negedge 관측 = saw_low)
//   - 명령이 끝나면 high
// ================================================================
task dbg_step;
    input [2:0]    cmd;
    input [7:0]    data;
    input [3:0]    addr;
    input          mode;
    input integer  settle;       // 명령 완료까지 기다릴 시간(ns)
    input          check_clear;  // 1이면 새 명령 시 0으로 clear 됐는지도 확인
    input [8*16:1] name;
    begin
        saw_low = 1'b0;
        spi_cmd(cmd, data, addr, mode);
        #(settle);
        if (dbg_cmd_done === 1'b1 && (check_clear === 1'b0 || saw_low === 1'b1)) begin
            $display("[PASS] dbg %0s | clear_seen=%b done=%b", name, saw_low, dbg_cmd_done);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] dbg %0s | clear_seen=%b(exp %b) done=%b(exp 1)",
                     name, saw_low, check_clear, dbg_cmd_done);
            fail_count = fail_count + 1;
        end
    end
endtask

task dbg_pin_test;
    begin
        $display("");
        $display("================================================================");
        $display("  DEBUG PIN (o_cmd_done) 검증");
        $display("================================================================");

        // 리셋
        rstn = 0; ssn = 1; mosi = 0; sclk_reg = 0;
        #(CLK_PERIOD * 10);
        rstn = 1;
        #(CLK_PERIOD * 10);

        // 리셋 직후 0 확인
        if (dbg_cmd_done === 1'b0) begin
            $display("[PASS] dbg RESET | done=0 after reset");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] dbg RESET | done=%b (exp 0)", dbg_cmd_done);
            fail_count = fail_count + 1;
        end

        // 첫 명령: 리셋 후 핀이 이미 0이라 clear(negedge) 관측 불가 → done=1만 확인
        dbg_step(3'b000, 8'h38, 4'd0, 1'b0,  500, 1'b0, "LOAD_W(first)");
        // 이후: 새 명령 시 0으로 clear 되고 완료 후 다시 1 되는지 모두 확인
        dbg_step(3'b001, 8'h38, 4'd0, 1'b0,  500, 1'b1, "LOAD_I");
        dbg_step(3'b010, 8'h00, 4'd0, 1'b0,  500, 1'b1, "COMPUTE");
        dbg_step(3'b011, 8'h00, 4'd0, 1'b0, 3000, 1'b1, "ACC");
        // READ_RESULT 는 직전 ACC 로 acc_done_flag 가 set 되어야 동작
        dbg_step(3'b100, 8'h00, 4'd0, 1'b0,  500, 1'b1, "READ_RESULT");
    end
endtask

// ================================================================
//  Main
// ================================================================
initial begin
    $dumpfile("tb_TOP.vcd");
    $dumpvars(0, tb_TOP);

    clk = 0;
    pass_count = 0;
    fail_count = 0;

    define_tests;

    $display("");
    $display("================================================================");
    $display("  FP MAC Testbench — %0d tests", NUM_TESTS);
    $display("================================================================");

    for (t = 0; t < NUM_TESTS; t = t + 1)
        run_test(t);

    // DEBUG 핀 검증
    dbg_pin_test;

    $display("");
    $display("================================================================");
    $display("  SUMMARY: %0d PASS / %0d FAIL / %0d TOTAL",
             pass_count, fail_count, pass_count + fail_count);
    $display("================================================================");

    #200;
    $finish;
end

endmodule
