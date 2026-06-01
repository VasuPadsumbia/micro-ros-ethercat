// ============================================================================
// mdio_ctrl.v — MDIO controller for DP83848 PHY configuration
//
// On reset, sequences through a PHY init table (both PHY0 and PHY1):
//   - Force 100BASE-TX full-duplex
//   - Enable auto-negotiation (optional; kept off for deterministic timing)
//
// MDC period = 2 * MDC_DIV * sys_clk period  (target: ≤ 2.5 MHz per IEEE 802.3)
// With 27 MHz sys_clk and MDC_DIV=6: MDC ≈ 2.25 MHz
//
// Interface:
//   init_done — goes high after all init writes complete
//   mdc[1:0]  — MDC clocks (one per PHY)
//   mdio_oe   — drive MDIO line (SDA) when set
//   mdio_out  — MDIO output bit
//   mdio_in   — MDIO input bit (for reads)
// ============================================================================
module mdio_ctrl #(
    parameter MDC_DIV = 6   // sys_clk / (2*MDC_DIV) = MDC freq
) (
    input  wire       clk,
    input  wire       rst_n,

    output reg        init_done,

    // PHY 0
    output wire       mdc0,
    output reg        mdio0_oe,
    output reg        mdio0_out,
    input  wire       mdio0_in,

    // PHY 1
    output wire       mdc1,
    output reg        mdio1_oe,
    output reg        mdio1_out,
    input  wire       mdio1_in
);

    // ── MDC generation ────────────────────────────────────────────────────
    reg [$clog2(MDC_DIV)-1:0] div_cnt;
    reg                        mdc_r;
    reg                        mdc_rise;   // one-cycle pulse at MDC rising edge
    reg                        mdc_fall;   // one-cycle pulse at MDC falling edge

    assign mdc0 = mdc_r;
    assign mdc1 = mdc_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt  <= 0;
            mdc_r    <= 0;
            mdc_rise <= 0;
            mdc_fall <= 0;
        end else begin
            mdc_rise <= 0;
            mdc_fall <= 0;
            if (div_cnt == MDC_DIV[$clog2(MDC_DIV)-1:0] - 1) begin
                div_cnt <= 0;
                mdc_r   <= ~mdc_r;
                if (!mdc_r) mdc_rise <= 1;
                else        mdc_fall <= 1;
            end else begin
                div_cnt <= div_cnt + 1;
            end
        end
    end

    // ── Init table: {phy_sel[0], regaddr[4:0], data[15:0]} ───────────────
    // phy_sel: 0 = PHY0, 1 = PHY1, 2 = both
    // Uses write (no read needed for init)
    //
    // DP83848 register map (relevant):
    //   Reg 0x00: BMCR — Basic Mode Control
    //     bit15 = reset, bit13 = speed (1=100), bit8 = duplex (1=FD), bit12 = ANE
    //   Reg 0x10: PHYCR — PHY Control
    //
    localparam INIT_LEN = 4;
    reg [22:0] init_table [0:INIT_LEN-1];
    // {phy_sel[1:0], regaddr[4:0], data[15:0]}
    initial begin
        // PHY0: BMCR = 0x2100 (100Mbps, Full-duplex, no AN)
        init_table[0] = {2'd0, 5'h00, 16'h2100};
        // PHY1: BMCR = 0x2100
        init_table[1] = {2'd1, 5'h00, 16'h2100};
        // PHY0: PHYCR set LED mode (optional)
        init_table[2] = {2'd0, 5'h19, 16'h0001};
        // PHY1: same
        init_table[3] = {2'd1, 5'h19, 16'h0001};
    end

    // ── MDIO frame: 32 preamble + ST + OP + PA5 + RA5 + TA + DATA16
    // Write frame: 1_1_01_PADDR_RADDR_10_DATA (total 32 bits payload)
    // ────────────────────────────────────────────────────────────────────
    localparam PREAMBLE_LEN = 32;
    localparam FRAME_LEN    = 32;   // ST(2)+OP(2)+PA(5)+RA(5)+TA(2)+DATA(16)

    // PHY addresses: PHY0 = 0, PHY1 = 1 (set by HW strapping on DP83848)
    localparam PHY0_ADDR = 5'd0;
    localparam PHY1_ADDR = 5'd1;

    reg [5:0]  bit_cnt;
    reg [31:0] shift_out;
    reg [4:0]  init_idx;

    localparam ST_PREAMBLE = 2'd0;
    localparam ST_FRAME    = 2'd1;
    localparam ST_DONE     = 2'd2;

    reg [1:0] state;
    reg       current_phy;   // 0 = PHY0, 1 = PHY1

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_PREAMBLE;
            init_done  <= 0;
            init_idx   <= 0;
            bit_cnt    <= PREAMBLE_LEN - 1;
            mdio0_oe   <= 1;
            mdio0_out  <= 1;
            mdio1_oe   <= 1;
            mdio1_out  <= 1;
            current_phy <= 0;
            shift_out  <= 0;
        end else if (!init_done && mdc_fall) begin
            case (state)

            ST_PREAMBLE: begin
                // Drive MDIO = 1 for 32 cycles (preamble)
                mdio0_oe  <= 1; mdio0_out <= 1;
                mdio1_oe  <= 1; mdio1_out <= 1;
                if (bit_cnt == 0) begin
                    // Load frame for current init entry
                    begin : load_frame
                        reg [1:0]  phy_sel;
                        reg [4:0]  reg_addr;
                        reg [15:0] wr_data;
                        reg [4:0]  phy_addr;
                        {phy_sel, reg_addr, wr_data} = init_table[init_idx];
                        phy_addr = (phy_sel == 2'd0) ? PHY0_ADDR : PHY1_ADDR;
                        current_phy = phy_sel[0];
                        // Build 32-bit MDIO write frame
                        shift_out = {2'b01,     // ST
                                     2'b01,     // OP = write
                                     phy_addr,  // PADDR
                                     reg_addr,  // RADDR
                                     2'b10,     // TA (turnaround)
                                     wr_data};  // DATA
                    end
                    bit_cnt <= FRAME_LEN - 1;
                    state   <= ST_FRAME;
                end else begin
                    bit_cnt <= bit_cnt - 1;
                end
            end

            ST_FRAME: begin
                // Shift out MSB first
                if (!current_phy) begin
                    mdio0_oe  <= 1; mdio0_out <= shift_out[31];
                    mdio1_oe  <= 0; mdio1_out <= 0;
                end else begin
                    mdio1_oe  <= 1; mdio1_out <= shift_out[31];
                    mdio0_oe  <= 0; mdio0_out <= 0;
                end
                shift_out <= {shift_out[30:0], 1'b0};

                if (bit_cnt == 0) begin
                    if (init_idx == INIT_LEN - 1) begin
                        state     <= ST_DONE;
                        init_done <= 1;
                    end else begin
                        init_idx <= init_idx + 1;
                        bit_cnt  <= PREAMBLE_LEN - 1;
                        state    <= ST_PREAMBLE;
                    end
                end else begin
                    bit_cnt <= bit_cnt - 1;
                end
            end

            ST_DONE: begin
                mdio0_oe <= 0; mdio1_oe <= 0;
                init_done <= 1;
            end

            endcase
        end
    end

endmodule
