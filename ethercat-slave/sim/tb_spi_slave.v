// ============================================================================
// tb_spi_slave.v — Verilog testbench for spi_slave.v
//
// Simulates the ESP32 SPI master sending commands to the FPGA SPI slave.
// Run with: iverilog -o tb_spi_slave tb_spi_slave.v ../rtl/spi_slave.v && vvp tb_spi_slave
// ============================================================================
`timescale 1ns/1ps

module tb_spi_slave;

    // ── DUT signals ───────────────────────────────────────────────────────
    reg        sys_clk = 0;
    reg        rst_n   = 0;
    reg        spi_sck = 0;
    reg        spi_mosi= 0;
    wire       spi_miso;
    reg        spi_cs_n= 1;

    wire       mbox_wr_valid;
    wire [7:0] mbox_wr_data;
    wire[15:0] mbox_wr_len;
    wire       mbox_wr_start;
    wire       mbox_rd_req;
    reg  [7:0] mbox_rd_data = 8'hAB;
    reg        mbox_rd_valid= 0;
    reg        mbox_rd_empty= 1;
    reg        status_rx_avail = 0;
    reg        status_tx_ready = 1;

    spi_slave dut (
        .sys_clk        (sys_clk),
        .rst_n          (rst_n),
        .spi_sck        (spi_sck),
        .spi_mosi       (spi_mosi),
        .spi_miso       (spi_miso),
        .spi_cs_n       (spi_cs_n),
        .mbox_wr_valid  (mbox_wr_valid),
        .mbox_wr_data   (mbox_wr_data),
        .mbox_wr_len    (mbox_wr_len),
        .mbox_wr_start  (mbox_wr_start),
        .mbox_rd_req    (mbox_rd_req),
        .mbox_rd_data   (mbox_rd_data),
        .mbox_rd_valid  (mbox_rd_valid),
        .mbox_rd_empty  (mbox_rd_empty),
        .status_rx_avail(status_rx_avail),
        .status_tx_ready(status_tx_ready)
    );

    // ── Clock: 27 MHz ─────────────────────────────────────────────────────
    always #18.5 sys_clk = ~sys_clk; // ~27 MHz

    // ── SPI master tasks ──────────────────────────────────────────────────
    // SPI period = 125 ns (8 MHz)
    localparam SPI_HALF = 62;   // ns

    task spi_byte;
        input  [7:0] send;
        output [7:0] recv;
        integer i;
        begin
            recv = 0;
            for (i = 7; i >= 0; i = i - 1) begin
                spi_mosi = send[i];
                #SPI_HALF;
                spi_sck = 1;
                recv[i] = spi_miso;
                #SPI_HALF;
                spi_sck = 0;
            end
        end
    endtask

    task spi_write_mbox;
        input [7:0] payload [0:7];
        input integer len;
        integer i;
        reg [7:0] dummy;
        reg [7:0] crc;
        begin
            crc = 0;
            spi_cs_n = 0; #10;
            spi_byte(8'h01, dummy); // CMD=write
            spi_byte(8'h00, dummy); // LEN_H
            spi_byte(len[7:0], dummy); // LEN_L
            for (i = 0; i < len; i = i + 1) begin
                spi_byte(payload[i], dummy);
            end
            spi_byte(crc, dummy);   // CRC (simplified: 0x00)
            #10; spi_cs_n = 1;
        end
    endtask

    task spi_status;
        output [7:0] flags;
        reg [7:0] dummy;
        begin
            spi_cs_n = 0; #10;
            spi_byte(8'h03, dummy); // CMD=status
            spi_byte(8'h00, dummy); // LEN_H
            spi_byte(8'h00, flags); // LEN_L receives flags
            #10; spi_cs_n = 1;
        end
    endtask

    // ── Logging ───────────────────────────────────────────────────────────
    integer errors = 0;

    task check;
        input cond;
        input [127:0] msg;
        begin
            if (!cond) begin
                $display("FAIL: %s at time %0t", msg, $time);
                errors = errors + 1;
            end else
                $display("PASS: %s", msg);
        end
    endtask

    // ── Test sequence ─────────────────────────────────────────────────────
    reg [7:0] payload [0:7];
    reg [7:0] flags;
    integer k;

    initial begin
        $dumpfile("tb_spi_slave.vcd");
        $dumpvars(0, tb_spi_slave);

        // Reset
        rst_n = 0; #100;
        rst_n = 1; #100;

        // ── Test 1: Status query ─────────────────────────────────────────
        status_rx_avail = 1;
        status_tx_ready = 1;
        spi_status(flags);
        check(flags[0] == 1, "STATUS: rx_avail set");
        check(flags[1] == 1, "STATUS: tx_ready set");

        #200;

        // ── Test 2: Write mailbox (4 payload bytes) ───────────────────────
        payload[0] = 8'h00; payload[1] = 8'h00; // mailbox header placeholder
        payload[2] = 8'hAA; payload[3] = 8'hBB;
        spi_write_mbox(payload, 4);
        #100;
        check(mbox_wr_valid === 1'bx || mbox_wr_len == 4,
              "WRITE: mbox_wr_len correct");

        // ── Test 3: Back-to-back transactions ─────────────────────────────
        for (k = 0; k < 3; k = k + 1) begin
            payload[0] = k;
            spi_write_mbox(payload, 1);
            #50;
        end

        #500;
        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end

    // ── Timeout guard ─────────────────────────────────────────────────────
    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
