// ============================================================================
// tb_mailbox.v — Testbench for mailbox.v
//
// Tests SM0 (EtherCAT→SPI) and SM1 (SPI→EtherCAT) paths and handshake.
// Run: iverilog -o tb_mailbox tb_mailbox.v ../rtl/mailbox.v && vvp tb_mailbox
// ============================================================================
`timescale 1ns/1ps

module tb_mailbox;

    reg        clk   = 0;
    reg        rst_n = 0;

    // EtherCAT port
    reg  [15:0] ec_addr  = 0;
    reg  [7:0]  ec_wdata = 0;
    wire [7:0]  ec_rdata;
    reg         ec_wr    = 0;
    reg         ec_rd    = 0;
    reg         sm0_written = 0;
    reg         sm1_read    = 0;

    // SPI port
    wire [7:0]  spi_rx_data;
    wire        spi_rx_valid;
    reg         spi_rx_ack  = 0;
    reg  [7:0]  spi_tx_data = 0;
    reg         spi_tx_valid= 0;
    reg         spi_tx_start= 0;
    reg [15:0]  spi_tx_len  = 0;

    wire        mbox_out_ready;
    wire        mbox_in_ready;
    wire        int_n;

    mailbox dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .ec_addr       (ec_addr),
        .ec_wdata      (ec_wdata),
        .ec_rdata      (ec_rdata),
        .ec_wr         (ec_wr),
        .ec_rd         (ec_rd),
        .sm0_written   (sm0_written),
        .sm1_read      (sm1_read),
        .spi_rx_data   (spi_rx_data),
        .spi_rx_valid  (spi_rx_valid),
        .spi_rx_ack    (spi_rx_ack),
        .spi_tx_data   (spi_tx_data),
        .spi_tx_valid  (spi_tx_valid),
        .spi_tx_start  (spi_tx_start),
        .spi_tx_len    (spi_tx_len),
        .mbox_out_ready(mbox_out_ready),
        .mbox_in_ready (mbox_in_ready),
        .int_n         (int_n)
    );

    always #18 clk = ~clk;

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

    // Write one byte to SM0 via EtherCAT
    task ec_write;
        input [15:0] addr;
        input [7:0]  data;
        begin
            @(posedge clk); #1;
            ec_addr  <= addr;
            ec_wdata <= data;
            ec_wr    <= 1;
            @(posedge clk); #1;
            ec_wr    <= 0;
        end
    endtask

    initial begin
        $dumpfile("tb_mailbox.vcd");
        $dumpvars(0, tb_mailbox);

        rst_n = 0; #100; rst_n = 1; #50;

        // ── Test 1: SM0 (EtherCAT→SPI) path ──────────────────────────────
        $display("\n--- Test 1: SM0 write by master, read by SPI ---");

        // Write a 4-byte mailbox frame to SM0 (EtherCAT side)
        // Header: len=0x0002, addr=0x0000, ch=0x00, type=VoE(0x0F)
        ec_write(16'h1000, 8'h02); // len lo
        ec_write(16'h1001, 8'h00); // len hi
        ec_write(16'h1002, 8'h00); // addr lo
        ec_write(16'h1003, 8'h00); // addr hi
        ec_write(16'h1004, 8'h00); // channel
        ec_write(16'h1005, 8'h0F); // type=VoE
        ec_write(16'h1006, 8'h00); // reserved
        ec_write(16'h1007, 8'h00); // reserved
        // Payload
        ec_write(16'h1008, 8'hDE);
        ec_write(16'h1009, 8'hAD);

        // Signal: master finished writing SM0
        @(posedge clk); sm0_written <= 1;
        @(posedge clk); sm0_written <= 0;
        @(posedge clk);

        check(mbox_out_ready == 1, "SM0 mbox_out_ready after write");
        check(int_n == 0,          "INT_N asserted (active-low)");
        check(spi_rx_valid == 1,   "SPI rx_valid: data available");

        // SPI reads bytes one by one
        repeat (10) begin
            @(posedge clk); spi_rx_ack <= 1;
            @(posedge clk); spi_rx_ack <= 0;
        end
        @(posedge clk);
        check(mbox_out_ready == 0, "SM0 cleared after SPI read");
        check(int_n == 1,          "INT_N deasserted");

        #100;

        // ── Test 2: SM1 (SPI→EtherCAT) path ─────────────────────────────
        $display("\n--- Test 2: SM1 write by SPI, read by master ---");

        // SPI writes a mailbox frame to SM1
        @(posedge clk);
        spi_tx_start <= 1; spi_tx_len <= 16'd10;
        spi_tx_data  <= 8'h02; spi_tx_valid <= 1;  // payload byte 0
        @(posedge clk); spi_tx_start <= 0;
        @(posedge clk); spi_tx_data  <= 8'h00; // byte 1
        @(posedge clk); spi_tx_data  <= 8'hBE; // byte 2
        @(posedge clk); spi_tx_data  <= 8'hEF; // byte 3
        @(posedge clk); spi_tx_data  <= 8'h00; // ...
        @(posedge clk); spi_tx_data  <= 8'h00;
        @(posedge clk); spi_tx_data  <= 8'h00;
        @(posedge clk); spi_tx_data  <= 8'h0F;
        @(posedge clk); spi_tx_data  <= 8'hCA;
        @(posedge clk); spi_tx_data  <= 8'hFE;
        @(posedge clk); spi_tx_valid <= 0;
        @(posedge clk);
        check(mbox_in_ready == 1, "SM1 mbox_in_ready after SPI write");

        // Master reads SM1
        @(posedge clk); sm1_read <= 1;
        @(posedge clk); sm1_read <= 0;
        @(posedge clk);
        check(mbox_in_ready == 0, "SM1 cleared after master read");

        #100;
        if (errors == 0) $display("\n=== ALL TESTS PASSED ===");
        else             $display("\n=== %0d FAILED ===", errors);
        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish; end

endmodule
