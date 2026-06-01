// ============================================================================
// mailbox.v — EtherCAT mailbox controller (SyncManagers 0 and 1)
//
// SM0: Mailbox Out  (master→slave)
//   Physical address: MBX_OUT_BASE (default 0x1000), size MBX_OUT_SIZE (256 B)
//   Master writes a mailbox frame; SPI slave reads it out to ESP32.
//
// SM1: Mailbox In   (slave→master)
//   Physical address: MBX_IN_BASE  (default 0x1100), size MBX_IN_SIZE  (256 B)
//   ESP32 writes a mailbox frame via SPI slave; master reads it.
//
// Mailbox frame header (8 bytes, ETG.1000.6):
//   [1:0]  Length   — payload length (not including 8-byte header)
//   [3:2]  Address  — slave address (0 for this slave)
//   [4]    Channel/Count
//   [5]    Priority[1:0] | Type[3:0]  — Type 0x0F = VoE (vendor over EtherCAT)
//   [7:6]  Reserved
//
// Handshake (per ETG.1000.4, SM Activate/Status):
//   SM0 wr_en=1 when master has written full frame (EtherCAT sets SM busy)
//   SM1 rd_en=1 when master has fully read frame
//
// INT_N output goes low when SM1 buffer has unread data for master.
// ============================================================================
module mailbox #(
    parameter MBX_OUT_BASE = 16'h1000,
    parameter MBX_OUT_SIZE = 16'd64,
    parameter MBX_IN_BASE  = 16'h1040,
    parameter MBX_IN_SIZE  = 16'd64
) (
    input  wire        clk,
    input  wire        rst_n,

    // ── EtherCAT datagram access (from ethercat_slave.v) ─────────────
    input  wire [15:0] ec_addr,
    input  wire [7:0]  ec_wdata,
    output reg  [7:0]  ec_rdata,
    input  wire        ec_wr,
    input  wire        ec_rd,

    // SM0 full / SM1 empty triggers (from ESC register writes)
    // ethercat_slave sets these when a mailbox SM is fully written/read
    input  wire        sm0_written,   // master finished writing SM0
    input  wire        sm1_read,      // master finished reading SM1

    // ── SPI slave (PDI) access ────────────────────────────────────────
    // SPI slave reads SM0 data out (mailbox out → ESP32)
    output reg  [7:0]  spi_rx_data,  // byte from SM0 for ESP32
    output reg         spi_rx_valid, // SM0 has data
    input  wire        spi_rx_ack,   // ESP32 consumed the byte

    // SPI slave writes SM1 data (ESP32 → mailbox in → master)
    input  wire [7:0]  spi_tx_data,  // byte from ESP32 for SM1
    input  wire        spi_tx_valid, // new byte from ESP32
    input  wire        spi_tx_start, // start of new mailbox frame
    input  wire [15:0] spi_tx_len,   // total frame length

    // ── Status ────────────────────────────────────────────────────────
    output reg         mbox_out_ready,  // SM0 has a complete frame for ESP32
    output reg         mbox_in_ready,   // SM1 has a complete frame for master
    output wire        int_n            // active-low interrupt to ESP32
);

    assign int_n = ~mbox_out_ready;

    // ── SM0 buffer: Mailbox Out (EtherCAT writes, SPI reads) ─────────────
    reg [7:0]  sm0_buf [0:63];
    reg [5:0]  sm0_rd_ptr;
    reg [7:0]  sm0_len;     // payload len from header (fits in 64 bytes)
    reg        sm0_full;    // master has written complete frame

    // ── SM1 buffer: Mailbox In (SPI writes, EtherCAT reads) ──────────────
    reg [7:0]  sm1_buf [0:63];
    reg [5:0]  sm1_wr_ptr;
    reg [7:0]  sm1_len;
    reg        sm1_full;    // SPI has written complete frame

    // ── EtherCAT access ───────────────────────────────────────────────────
    always @(*) begin
        ec_rdata = 8'hFF;
        if (ec_rd) begin
            // SM1 (Mailbox In): master reads
            if (ec_addr >= MBX_IN_BASE &&
                ec_addr < MBX_IN_BASE + MBX_IN_SIZE) begin
                ec_rdata = sm1_buf[ec_addr - MBX_IN_BASE];
            end
            // SM0 (Mailbox Out): master may read status (not data)
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sm0_full      <= 0;
            sm1_full      <= 0;
            mbox_out_ready<= 0;
            mbox_in_ready <= 0;
            sm0_rd_ptr    <= 0;
            sm1_wr_ptr    <= 0;
            sm0_len       <= 0;
            sm1_len       <= 0;
        end else begin

            // EtherCAT writes to SM0 (master → slave)
            if (ec_wr &&
                ec_addr >= MBX_OUT_BASE &&
                ec_addr <  MBX_OUT_BASE + MBX_OUT_SIZE) begin
                sm0_buf[ec_addr - MBX_OUT_BASE] <= ec_wdata;
            end

            // sm0_written: master finished writing, frame is ready for ESP32
            if (sm0_written) begin
                // Extract length from header bytes 0-1
                sm0_len       <= sm0_buf[0] + 8'd8; // low byte of length + 8-byte header
                sm0_rd_ptr    <= 0;
                sm0_full      <= 1;
                mbox_out_ready<= 1;
            end

            // SPI reads from SM0 byte-by-byte
            if (spi_rx_ack && sm0_full) begin
                sm0_rd_ptr <= sm0_rd_ptr + 1;
                if (sm0_rd_ptr + 1 >= sm0_len) begin
                    sm0_full       <= 0;
                    mbox_out_ready <= 0;
                end
            end

            // SPI writes to SM1 (ESP32 → master)
            if (spi_tx_start) begin
                sm1_wr_ptr <= 0;
                sm1_len    <= spi_tx_len;
            end
            if (spi_tx_valid) begin
                sm1_buf[sm1_wr_ptr] <= spi_tx_data;
                sm1_wr_ptr          <= sm1_wr_ptr + 1;
                if (sm1_wr_ptr + 1 >= spi_tx_len[7:0]) begin
                    sm1_full      <= 1;
                    mbox_in_ready <= 1;
                end
            end

            // sm1_read: master finished reading SM1
            if (sm1_read) begin
                sm1_full      <= 0;
                mbox_in_ready <= 0;
                sm1_wr_ptr    <= 0;
            end

        end
    end

    // ── Feed SM0 data to SPI slave ────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_rx_data  <= 0;
            spi_rx_valid <= 0;
        end else begin
            spi_rx_valid <= sm0_full;
            spi_rx_data  <= sm0_buf[sm0_rd_ptr];
        end
    end

endmodule
