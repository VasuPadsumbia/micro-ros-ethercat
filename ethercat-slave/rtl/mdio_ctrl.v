// ============================================================================
// mdio_ctrl.v — MDIO controller for DP83848 PHY0 configuration
//
// On reset, sequences through a PHY init table (PHY0 only):
//   - Force 100BASE-TX full-duplex, no auto-negotiation
//   - Configure PHY LED mode
//
// MDC frequency = sys_clk / (2 * MDC_DIV).
// IEEE 802.3 max MDC = 2.5 MHz.  With 27 MHz and MDC_DIV=6 → 2.25 MHz.
//
// MDIO is open-drain.  Drive open (tristate) when releasing; let the 2.2 kΩ
// external pull-up pull it high.  Never drive it high from the FPGA.
//
// PHY address: set PHY0_ADDR in slave_config.vh to match your module's
// PHYAD[4:0] strap resistors.
// ============================================================================
`include "slave_config.vh"

module mdio_ctrl #(
    parameter MDC_DIV = `MDC_DIV
) (
    input  wire  clk,
    input  wire  rst_n,
    output reg   init_done,

    // Single PHY (PHY0)
    output wire  mdc,
    output reg   mdio_oe,   // 1 = drive MDIO, 0 = tristate (release)
    output reg   mdio_out,  // bit to transmit when mdio_oe=1
    input  wire  mdio_in    // sampled MDIO pin (for reads, not used in init)
);

    // ── MDC generation ────────────────────────────────────────────────────
    reg [$clog2(MDC_DIV)-1:0] div_cnt;
    reg mdc_r, mdc_rise, mdc_fall;

    assign mdc = mdc_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt  <= 0;
            mdc_r    <= 1'b0;
            mdc_rise <= 1'b0;
            mdc_fall <= 1'b0;
        end else begin
            mdc_rise <= 1'b0;
            mdc_fall <= 1'b0;
            if (div_cnt == MDC_DIV[$clog2(MDC_DIV)-1:0] - 1) begin
                div_cnt <= 0;
                mdc_r   <= ~mdc_r;
                if (!mdc_r) mdc_rise <= 1'b1;
                else        mdc_fall <= 1'b1;
            end else begin
                div_cnt <= div_cnt + 1;
            end
        end
    end

    // ── Init table: {regaddr[4:0], data[15:0]} ───────────────────────────
    // BMCR (reg 0x00) = 0x2100: 100 Mbps, Full-Duplex, no autoneg
    //   bit13=1 (speed=100), bit8=1 (FD), bit12=0 (AN off)
    // PHYCR (reg 0x19) = 0x0001: LED mode bits
    localparam INIT_LEN = 2;
    reg [20:0] init_table [0:INIT_LEN-1]; // {regaddr[4:0], data[15:0]}

    initial begin
        init_table[0] = {5'h00, 16'h2100}; // BMCR: 100BASE-TX FD
        init_table[1] = {5'h19, 16'h0001}; // PHYCR: LED cfg
    end

    // ── MDIO write frame format (IEEE 802.3, clause 22) ──────────────────
    // 32×1 preamble | ST=01 | OP=01 | PADDR[4:0] | RADDR[4:0] | TA=10 | DATA[15:0]
    localparam PREAMBLE_LEN = 32;
    localparam FRAME_LEN    = 32;

    reg [5:0]  bit_cnt;
    reg [31:0] shift_out;
    reg [4:0]  init_idx;

    localparam ST_PREAMBLE = 2'd0;
    localparam ST_FRAME    = 2'd1;
    localparam ST_DONE     = 2'd2;

    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_PREAMBLE;
            init_done <= 1'b0;
            init_idx  <= 5'd0;
            bit_cnt   <= PREAMBLE_LEN - 1;
            mdio_oe   <= 1'b1;
            mdio_out  <= 1'b1;
            shift_out <= 32'd0;
        end else if (!init_done && mdc_fall) begin
            case (state)

            ST_PREAMBLE: begin
                mdio_oe  <= 1'b1;
                mdio_out <= 1'b1;   // preamble = all 1s
                if (bit_cnt == 6'd0) begin
                    begin : load_frame
                        reg [4:0]  reg_addr;
                        reg [15:0] wr_data;
                        {reg_addr, wr_data} = init_table[init_idx];
                        shift_out = {2'b01,         // ST
                                     2'b01,         // OP = write
                                     `PHY0_ADDR,    // PADDR
                                     reg_addr,      // RADDR
                                     2'b10,         // TA
                                     wr_data};      // DATA
                    end
                    bit_cnt <= FRAME_LEN - 1;
                    state   <= ST_FRAME;
                end else begin
                    bit_cnt <= bit_cnt - 1'b1;
                end
            end

            ST_FRAME: begin
                mdio_oe  <= 1'b1;
                mdio_out <= shift_out[31];
                shift_out <= {shift_out[30:0], 1'b0};
                if (bit_cnt == 6'd0) begin
                    if (init_idx == INIT_LEN - 1) begin
                        state     <= ST_DONE;
                        init_done <= 1'b1;
                        mdio_oe   <= 1'b0; // release MDIO
                    end else begin
                        init_idx <= init_idx + 5'd1;
                        bit_cnt  <= PREAMBLE_LEN - 1;
                        state    <= ST_PREAMBLE;
                    end
                end else begin
                    bit_cnt <= bit_cnt - 1'b1;
                end
            end

            ST_DONE: begin
                mdio_oe   <= 1'b0; // tristate — pull-up holds MDIO high
                init_done <= 1'b1;
            end

            endcase
        end
    end

endmodule
