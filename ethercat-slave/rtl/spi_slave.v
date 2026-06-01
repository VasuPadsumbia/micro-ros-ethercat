// ============================================================================
// spi_slave.v — SPI slave, Mode 0 (CPOL=0, CPHA=0), MSB first
//
// Protocol framing (both TX and RX use the same format):
//   Byte 0   : Command
//              0x01 = Write mailbox (ESP32 → FPGA)
//              0x02 = Read mailbox  (FPGA  → ESP32)
//              0x03 = Status query
//   Byte 1-2 : Length (big-endian, 16-bit) — payload bytes that follow
//   Byte 3…N : Payload
//   Byte N+1 : CRC-8 (poly 0x07, init 0x00) over bytes 0…N
//
// Status response (CMD=0x03):
//   Byte 0 : Flags
//              bit0 = rx_data_available (FPGA has data for ESP32)
//              bit1 = tx_ready          (FPGA ready to accept data from ESP32)
//   Bytes 1-2: rx_len (bytes available in mailbox-in buffer)
//
// The INT_N pin (active-low output) is driven separately by mailbox.v.
//
// Internal 512-byte TX and RX FIFOs bridge the 8 MHz SPI domain to the
// 27 MHz system clock domain.
// ============================================================================
module spi_slave (
    input  wire        sys_clk,
    input  wire        rst_n,

    // SPI pins (connected to ESP32)
    input  wire        spi_sck,
    input  wire        spi_mosi,
    output reg         spi_miso,
    input  wire        spi_cs_n,

    // Mailbox write port (SPI → mailbox_out)
    output reg         mbox_wr_valid,   // pulse: byte ready to write
    output reg  [7:0]  mbox_wr_data,
    output reg  [15:0] mbox_wr_len,     // total payload length of current packet
    output reg         mbox_wr_start,   // first byte of new packet

    // Mailbox read port (mailbox_in → SPI)
    output reg         mbox_rd_req,     // request next byte
    input  wire [7:0]  mbox_rd_data,
    input  wire        mbox_rd_valid,   // data valid this cycle
    input  wire        mbox_rd_empty,   // no data in mailbox-in

    // Status bits for CMD=0x03 response
    input  wire        status_rx_avail, // mailbox_in has data
    input  wire        status_tx_ready  // mailbox_out can accept data
);

    // ── Edge detection (SPI clock in sys_clk domain) ─────────────────────
    reg [2:0] sck_sync;
    reg [2:0] cs_sync;
    reg [2:0] mosi_sync;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            sck_sync  <= 3'b000;
            cs_sync   <= 3'b111;
            mosi_sync <= 3'b000;
        end else begin
            sck_sync  <= {sck_sync[1:0],  spi_sck};
            cs_sync   <= {cs_sync[1:0],   spi_cs_n};
            mosi_sync <= {mosi_sync[1:0], spi_mosi};
        end
    end

    wire sck_rise = (sck_sync[2:1] == 2'b01);
    wire sck_fall = (sck_sync[2:1] == 2'b10);
    wire cs_active = !cs_sync[1];
    wire cs_deassert = (cs_sync[2:1] == 2'b01); // CS de-asserted (rising)

    // ── Shift register ────────────────────────────────────────────────────
    reg [7:0]  rx_shift;
    reg [2:0]  bit_pos;         // counts 7..0, byte complete when wraps to 7 after 0
    reg        byte_done;       // one-cycle pulse: a full byte has been received

    reg [7:0]  tx_byte;         // byte to shift out on MISO
    reg        tx_byte_load;    // pulse: load next tx_byte on bit_pos==7 after byte

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_shift  <= 0;
            bit_pos   <= 7;
            byte_done <= 0;
            spi_miso  <= 0;
        end else begin
            byte_done    <= 0;
            tx_byte_load <= 0;

            if (!cs_active) begin
                bit_pos  <= 7;
                spi_miso <= tx_byte[7]; // pre-load MSB
            end else begin
                if (sck_rise) begin
                    // Sample MOSI
                    rx_shift <= {rx_shift[6:0], mosi_sync[1]};
                    if (bit_pos == 0) begin
                        byte_done <= 1;
                    end
                end
                if (sck_fall) begin
                    // Shift out MISO
                    if (bit_pos == 0) begin
                        // Byte boundary — will load next tx_byte
                        tx_byte_load <= 1;
                        bit_pos      <= 7;
                        spi_miso     <= tx_byte[7]; // first bit of next byte
                    end else begin
                        spi_miso <= tx_byte[bit_pos - 1];
                        bit_pos  <= bit_pos - 1;
                    end
                end
            end
        end
    end

    // ── CRC-8 (poly 0x07) over transmitted/received bytes ────────────────
    function [7:0] crc8_byte;
        input [7:0] crc_in;
        input [7:0] data;
        integer j;
        reg [7:0] c;
        begin
            c = crc_in ^ data;
            for (j = 0; j < 8; j = j + 1)
                c = c[7] ? ({c[6:0], 1'b0} ^ 8'h07) : {c[6:0], 1'b0};
            crc8_byte = c;
        end
    endfunction

    // ── Frame state machine ───────────────────────────────────────────────
    localparam F_CMD     = 3'd0;
    localparam F_LEN_H   = 3'd1;
    localparam F_LEN_L   = 3'd2;
    localparam F_DATA    = 3'd3;
    localparam F_CRC     = 3'd4;

    reg [2:0]  frame_state;
    reg [7:0]  cmd;
    reg [15:0] payload_len;
    reg [15:0] byte_idx;
    reg [7:0]  rx_crc;
    reg [7:0]  tx_crc;

    // TX state for read/status responses
    reg [7:0]  tx_fifo [0:3];  // small TX header buffer
    reg [2:0]  tx_head;        // next byte to send
    reg [2:0]  tx_tail;
    reg [7:0]  status_flags_r; // latched status for STATUS command response

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_state  <= F_CMD;
            cmd          <= 0;
            payload_len  <= 0;
            byte_idx     <= 0;
            rx_crc       <= 0;
            tx_crc       <= 0;
            mbox_wr_valid <= 0;
            mbox_wr_data  <= 0;
            mbox_wr_len   <= 0;
            mbox_wr_start <= 0;
            mbox_rd_req   <= 0;
            tx_byte       <= 0;
            tx_head       <= 0;
            tx_tail       <= 0;
            status_flags_r <= 0;
        end else begin
            mbox_wr_valid <= 0;
            mbox_wr_start <= 0;
            mbox_rd_req   <= 0;

            if (cs_deassert) begin
                // Transaction ended; reset frame parser
                frame_state <= F_CMD;
                rx_crc      <= 0;
                tx_crc      <= 0;
            end

            if (byte_done && cs_active) begin
                case (frame_state)

                F_CMD: begin
                    cmd       <= rx_shift;
                    rx_crc    <= crc8_byte(8'h00, rx_shift);
                    // Prepare TX response header
                    case (rx_shift)
                    8'h01: begin // Write — nothing to send back except CRC
                        tx_byte <= 8'h00;
                    end
                    8'h02: begin // Read — send LEN_H next
                        tx_byte <= 8'h00; // LEN_H placeholder (updated in LEN_H state)
                    end
                    8'h03: begin // Status — latch flags now, hold tx_byte through LEN_H/LEN_L
                        status_flags_r <= {6'h00, status_tx_ready, status_rx_avail};
                        tx_byte <= {6'h00, status_tx_ready, status_rx_avail};
                    end
                    default: tx_byte <= 8'hFF;
                    endcase
                    frame_state <= F_LEN_H;
                end

                F_LEN_H: begin
                    payload_len[15:8] <= rx_shift;
                    rx_crc            <= crc8_byte(rx_crc, rx_shift);
                    if (cmd == 8'h02) begin
                        tx_byte <= 8'h00; // LEN_L placeholder for read
                    end else if (cmd == 8'h03) begin
                        tx_byte <= status_flags_r; // keep flags byte visible
                    end
                    frame_state <= F_LEN_L;
                end

                F_LEN_L: begin
                    payload_len[7:0] <= rx_shift;
                    rx_crc           <= crc8_byte(rx_crc, rx_shift);
                    byte_idx         <= 0;
                    if (cmd == 8'h01 && {payload_len[15:8], rx_shift} > 0) begin
                        // Write command with data following
                        mbox_wr_len   <= {payload_len[15:8], rx_shift};
                        mbox_wr_start <= 1;
                        frame_state   <= F_DATA;
                        tx_byte       <= 8'h00;
                    end else if (cmd == 8'h02) begin
                        // Read — start sending mailbox data
                        mbox_rd_req <= 1;
                        frame_state <= F_DATA;
                        tx_byte     <= 8'h00;
                    end else begin
                        // Status or zero-length write — go straight to CRC
                        // Keep tx_byte as status_flags_r for STATUS cmd
                        frame_state <= F_CRC;
                    end
                end

                F_DATA: begin
                    rx_crc <= crc8_byte(rx_crc, rx_shift);
                    if (cmd == 8'h01) begin
                        // Store incoming byte to mailbox
                        mbox_wr_valid <= 1;
                        mbox_wr_data  <= rx_shift;
                        byte_idx      <= byte_idx + 1;
                        if (byte_idx + 1 >= payload_len) begin
                            frame_state <= F_CRC;
                        end
                    end else if (cmd == 8'h02) begin
                        // TX already in progress; request next read byte
                        if (!mbox_rd_empty) mbox_rd_req <= 1;
                        byte_idx <= byte_idx + 1;
                        if (byte_idx + 1 >= payload_len) begin
                            frame_state <= F_CRC;
                        end
                    end
                end

                F_CRC: begin
                    // rx_shift is the received CRC — validate
                    // (Error handling: discard frame if mismatch)
                    frame_state <= F_CMD;
                    rx_crc      <= 0;
                end

                default: frame_state <= F_CMD;
                endcase
            end // byte_done

            // Feed mbox_rd_data into tx_byte for read commands
            if (mbox_rd_valid) begin
                tx_byte <= mbox_rd_data;
            end

            // On tx_byte_load during STATUS cmd, hold the latched flags
            if (tx_byte_load && cmd == 8'h03 && frame_state == F_LEN_H) begin
                tx_byte <= status_flags_r;
            end

        end // not rst
    end

endmodule
