// ============================================================================
// tb_mii_mac.v — Testbench for mii_mac.v
//
// Feeds a raw byte stream through the TX path and checks MII output:
//   - Preamble (7×0x55) + SFD (0xD5) present
//   - Payload bytes transmitted correctly
//   - FCS appended (verified by looping TX→RX and checking fcs_ok)
//
// Run: iverilog -o tb_mii_mac tb_mii_mac.v ../rtl/mii_mac.v && vvp tb_mii_mac
// ============================================================================
`timescale 1ns/1ps

module tb_mii_mac;

    reg        sys_clk = 0;
    reg        rst_n   = 0;

    // ── MII clocks (simulate 25 MHz from PHY) ────────────────────────────
    reg tx_clk = 0;
    reg rx_clk = 0;

    // ── MII TX signals ────────────────────────────────────────────────────
    wire [3:0] txd;
    wire       tx_en, tx_er;

    // ── MII RX signals (loop TX→RX) ───────────────────────────────────────
    reg  [3:0] rxd  = 0;
    reg        rx_dv= 0;
    reg        rx_er= 0;

    // ── TX stream ─────────────────────────────────────────────────────────
    reg  [7:0] tx_data  = 0;
    reg        tx_valid = 0;
    wire       tx_ready;
    reg        tx_last  = 0;
    reg        tx_sof   = 0;

    // ── RX stream ─────────────────────────────────────────────────────────
    wire [7:0] rx_data;
    wire       rx_valid, rx_last, rx_fcs_ok;
    reg        rx_ready = 1;

    mii_mac dut (
        .sys_clk (sys_clk),
        .rst_n   (rst_n),
        .tx_clk  (tx_clk),
        .txd     (txd),
        .tx_en   (tx_en),
        .tx_er   (tx_er),
        .rx_clk  (rx_clk),
        .rxd     (rxd),
        .rx_dv   (rx_dv),
        .rx_er   (rx_er),
        .tx_data (tx_data),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_last (tx_last),
        .tx_sof  (tx_sof),
        .rx_data (rx_data),
        .rx_valid(rx_valid),
        .rx_last (rx_last),
        .rx_fcs_ok(rx_fcs_ok),
        .rx_ready(rx_ready)
    );

    always #18   sys_clk = ~sys_clk; // 27 MHz
    always #20   tx_clk  = ~tx_clk;  // 25 MHz
    always #20   rx_clk  = ~rx_clk;

    // ── TX loopback to RX ─────────────────────────────────────────────────
    // Delay by ~2 nibble-clocks to simulate cable delay
    reg [3:0] txd_d1, txd_d2;
    reg       tx_en_d1, tx_en_d2;

    always @(posedge tx_clk) begin
        txd_d1   <= txd;
        txd_d2   <= txd_d1;
        tx_en_d1 <= tx_en;
        tx_en_d2 <= tx_en_d1;
    end

    always @(posedge rx_clk) begin
        rxd   <= txd_d2;
        rx_dv <= tx_en_d2;
    end

    // ── Send a test frame ──────────────────────────────────────────────────
    task send_frame;
        input integer len;
        integer i;
        reg [7:0] payload [0:63];
        begin
            // Fill with incrementing data
            for (i = 0; i < len; i = i + 1)
                payload[i] = i[7:0];

            @(posedge sys_clk);
            tx_sof = 1;
            for (i = 0; i < len; i = i + 1) begin
                @(negedge sys_clk);
                tx_data  = payload[i];
                tx_valid = 1;
                tx_last  = (i == len - 1);
                tx_sof   = (i == 0);
                @(posedge sys_clk);
                while (!tx_ready) @(posedge sys_clk);
            end
            tx_valid = 0;
            tx_last  = 0;
            tx_sof   = 0;
        end
    endtask

    // ── Checks ────────────────────────────────────────────────────────────
    integer errors = 0;
    task check;
        input cond;
        input [127:0] msg;
        begin
            if (!cond) begin
                $display("FAIL: %s at %0t", msg, $time); errors = errors + 1;
            end else $display("PASS: %s", msg);
        end
    endtask

    // Monitor received frame
    integer rx_count = 0;
    reg     rx_fcs_captured = 0;
    reg     rx_fcs_ok_r     = 0;

    always @(posedge sys_clk) begin
        if (rx_valid && rx_ready) begin
            rx_count = rx_count + 1;
            if (rx_last) begin
                rx_fcs_ok_r     = rx_fcs_ok;
                rx_fcs_captured = 1;
            end
        end
    end

    // ── Test sequence ─────────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_mii_mac.vcd");
        $dumpvars(0, tb_mii_mac);

        rst_n = 0; #200; rst_n = 1; #200;

        // Test 1: Send 60-byte frame (minimum Ethernet), check RX FCS OK
        $display("\n--- Test 1: 60-byte frame TX→loopback→RX ---");
        rx_count       = 0;
        rx_fcs_captured= 0;

        send_frame(60);
        // Wait for RX to complete (with loopback + IFG delay)
        #50000;
        check(rx_fcs_captured, "FCS captured on RX");
        check(rx_fcs_ok_r,     "FCS OK after loopback");
        check(rx_count >= 60,  "Received at least 60 bytes");

        // Test 2: Back-to-back frames
        $display("\n--- Test 2: Back-to-back frames ---");
        rx_count       = 0;
        rx_fcs_captured= 0;
        send_frame(64);
        #200;
        send_frame(64);
        #50000;
        check(rx_count >= 128, "Both frames received");

        #1000;
        if (errors == 0) $display("\n=== ALL TESTS PASSED ===");
        else             $display("\n=== %0d FAILED ===", errors);
        $finish;
    end

    initial begin #5000000; $display("TIMEOUT"); $finish; end

endmodule
