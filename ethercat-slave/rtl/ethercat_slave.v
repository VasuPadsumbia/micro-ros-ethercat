// ============================================================================
// ethercat_slave.v — EtherCAT slave core
//
// Implements a store-and-forward EtherCAT slave (ETG.1000.4 / ETG.1000.6).
//
// Frame flow (single-slave, Port 1 closed):
//   1. Receive complete Ethernet frame from MII MAC Port 0
//   2. Validate EtherType = 0x88A4
//   3. Parse EtherCAT datagrams; for each datagram:
//        a. Check command (APRD/APWR/FPRD/FPWR/BRD/BWR/LRD/LWR/ARMW)
//        b. Match address (auto-increment OR configured station address)
//        c. Read/write ESC register space
//        d. Increment Working Counter (WKC) if matched
//   4. Send modified frame back out Port 0 TX (loopback for single slave)
//
// AL (Application Layer) state machine:
//   INIT (0x01) → PRE-OP (0x02) → SAFE-OP (0x04) → OP (0x08)
//   Transitions driven by master writing AL Control (0x0120).
//
// Constants per ETG.1000.4:
//   EtherType   = 0x88A4
//   Datagram commands see below.
// ============================================================================
module ethercat_slave (
    input  wire        clk,
    input  wire        rst_n,

    // ── MAC Port 0 stream interface ───────────────────────────────────
    // RX: frame bytes arriving from Port 0
    input  wire [7:0]  p0_rx_data,
    input  wire        p0_rx_valid,
    input  wire        p0_rx_last,
    input  wire        p0_rx_fcs_ok,
    output wire        p0_rx_ready,

    // TX: frame bytes to send via Port 0
    output reg  [7:0]  p0_tx_data,
    output reg         p0_tx_valid,
    output reg         p0_tx_last,
    output wire        p0_tx_sof,
    input  wire        p0_tx_ready,

    // ── ESC register / process data RAM interface ─────────────────────
    output reg  [15:0] esc_addr,
    output reg  [7:0]  esc_wdata,
    input  wire [7:0]  esc_rdata,
    output reg         esc_wr,
    output reg         esc_rd,

    // Station address (from ESC registers)
    input  wire [15:0] station_addr,

    // AL Control / Status
    input  wire [3:0]  al_control,
    output reg  [3:0]  al_state,
    output reg  [15:0] al_status_code,

    // Mailbox handshake
    output reg         sm0_written,  // SM0 fully written by master
    output reg         sm1_read,     // SM1 fully read by master

    // DL status output
    output reg  [7:0]  dl_status
);

    // ── EtherCAT command codes ────────────────────────────────────────────
    localparam CMD_NOP  = 8'h00;
    localparam CMD_APRD = 8'h01; // Auto-increment physical read
    localparam CMD_APWR = 8'h02; // Auto-increment physical write
    localparam CMD_APRW = 8'h03; // Auto-increment physical read/write
    localparam CMD_FPRD = 8'h04; // Fixed address physical read
    localparam CMD_FPWR = 8'h05; // Fixed address physical write
    localparam CMD_FPRW = 8'h06;
    localparam CMD_BRD  = 8'h07; // Broadcast read
    localparam CMD_BWR  = 8'h08; // Broadcast write
    localparam CMD_APRW2= 8'h09;
    localparam CMD_LRD  = 8'h0A; // Logical read
    localparam CMD_LWR  = 8'h0B; // Logical write
    localparam CMD_LRW  = 8'h0C;
    localparam CMD_ARMW = 8'h0D; // Auto-increment read multiple write
    localparam CMD_FRMW = 8'h0E;

    // ── EtherCAT AL states ────────────────────────────────────────────────
    localparam AL_INIT   = 4'h1;
    localparam AL_PREOP  = 4'h2;
    localparam AL_SAFEOP = 4'h4;
    localparam AL_OP     = 4'h8;

    // ── Frame buffer ───────────────────────────────────────────────────────
    // 64 B covers the EtherCAT mailbox VoE frame (14 ETH + 2 EtherCAT + 10 DG + 8 mbx + 30 payload)
    localparam FRAME_BUF_SZ = 6; // 2^6 = 64 bytes
    reg [7:0]  fbuf [0:(1<<FRAME_BUF_SZ)-1];
    reg [6:0]  fbuf_len;     // received frame length (7-bit fits 64)

    // ── Receive state machine ─────────────────────────────────────────────
    localparam RX_COLLECT  = 2'd0;
    localparam RX_PROCESS  = 2'd1;
    localparam RX_TRANSMIT = 2'd2;

    reg [1:0]  main_state;
    reg [10:0] rx_idx;
    reg        rx_fcs_ok_r;
    assign p0_rx_ready = (main_state == RX_COLLECT);

    // ── Datagram processing state ─────────────────────────────────────────
    localparam DG_HEADER   = 3'd0; // parse datagram header (10 bytes)
    localparam DG_DATA     = 3'd1; // read/write data bytes
    localparam DG_WKC      = 3'd2; // update WKC (2 bytes)
    localparam DG_NEXT     = 3'd3; // check M bit for more datagrams

    reg [2:0]  dg_state;
    reg [10:0] dg_ptr;      // byte index into fbuf
    reg [7:0]  dg_cmd;
    reg [7:0]  dg_idx;      // datagram index (mirrors for chaining)
    reg [15:0] dg_addr;     // address (station or auto-increment position)
    reg [31:0] dg_full_addr;// 32-bit address field
    reg [10:0] dg_len;      // data length
    reg [1:0]  dg_flags;    // {M, C} bits from length field high byte
    reg [15:0] dg_wkc;      // working counter (read from frame)
    reg        dg_match;    // this slave responds to this datagram
    reg [10:0] dg_data_ptr; // current data byte offset within datagram data
    reg [15:0] dg_offset;   // offset into ESC address space
    reg [10:0] dg_header_start; // fbuf index of current datagram's first byte

    // Auto-increment address: each slave decrements; match when ==0
    reg [15:0] aprd_addr_dec; // decremented auto-inc address

    // ── Transmit state machine ────────────────────────────────────────────
    reg [10:0] tx_idx;
    reg        tx_sof_r;
    assign p0_tx_sof = tx_sof_r;

    // ── AL state machine ──────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            al_state      <= AL_INIT;
            al_status_code<= 16'h0000;
        end else begin
            // Simple AL: accept master's state request (no error checking)
            case (al_control)
            4'h1: al_state <= AL_INIT;
            4'h2: al_state <= AL_PREOP;
            4'h4: al_state <= AL_SAFEOP;
            4'h8: al_state <= AL_OP;
            default:;
            endcase
        end
    end

    // ── DL status ─────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dl_status <= 8'h00;
        else
            // Port 0 link up (bit4), Port 0 loop open (bit0)
            dl_status <= 8'h11;
    end

    // ── Main FSM ──────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            main_state  <= RX_COLLECT;
            rx_idx      <= 0;
            fbuf_len    <= 0;
            rx_fcs_ok_r <= 0;
            dg_state    <= DG_HEADER;
            dg_ptr      <= 0;
            dg_cmd      <= 0;
            dg_match    <= 0;
            dg_len      <= 0;
            dg_flags    <= 0;
            dg_wkc      <= 0;
            dg_data_ptr <= 0;
            dg_offset   <= 0;
            dg_full_addr<= 0;
            dg_header_start <= 0;
            tx_idx      <= 0;
            tx_sof_r    <= 0;
            sm0_written <= 0;
            sm1_read    <= 0;
            p0_tx_valid <= 0;
            p0_tx_last  <= 0;
            p0_tx_data  <= 0;
            esc_wr      <= 0;
            esc_rd      <= 0;
            esc_addr    <= 0;
            esc_wdata   <= 0;
        end else begin
            esc_wr      <= 0;
            esc_rd      <= 0;
            sm0_written <= 0;
            sm1_read    <= 0;
            tx_sof_r    <= 0;

            case (main_state)

            // ── COLLECT: receive entire frame into buffer ──────────────
            RX_COLLECT: begin
                p0_tx_valid <= 0;
                if (p0_rx_valid) begin
                    fbuf[rx_idx] <= p0_rx_data;
                    rx_idx       <= rx_idx + 1;
                    if (p0_rx_last) begin
                        fbuf_len    <= rx_idx + 1;
                        rx_fcs_ok_r <= p0_rx_fcs_ok;
                        rx_idx      <= 0;
                        // Check EtherType at bytes 12-13 = 0x88A4
                        main_state  <= RX_PROCESS;
                        dg_state    <= DG_HEADER;
                        // Datagram starts at byte 16 (14 Eth hdr + 2 EtherCAT hdr)
                        dg_ptr      <= 16;
                        dg_header_start <= 16;
                    end
                end
            end

            // ── PROCESS: parse and modify datagrams in-place ───────────
            RX_PROCESS: begin
                // Skip frames with bad FCS or wrong EtherType
                if (!rx_fcs_ok_r ||
                    fbuf[12] != 8'h88 || fbuf[13] != 8'hA4) begin
                    // Discard frame — restart receive
                    main_state <= RX_COLLECT;
                    rx_idx     <= 0;
                end else begin
                    case (dg_state)

                    // Parse 10-byte datagram header:
                    //  [0]cmd [1]idx [5:2]addr [7:6]len+flags [9:8]IRQ
                    DG_HEADER: begin
                        dg_cmd        <= fbuf[dg_ptr];
                        dg_idx        <= fbuf[dg_ptr+1];
                        dg_full_addr  <= {fbuf[dg_ptr+5], fbuf[dg_ptr+4],
                                          fbuf[dg_ptr+3], fbuf[dg_ptr+2]};
                        dg_len        <= {fbuf[dg_ptr+7][2:0], fbuf[dg_ptr+6]};
                        dg_flags      <= fbuf[dg_ptr+7][7:6]; // M,C bits
                        dg_wkc        <= {fbuf[dg_ptr+9+dg_len[7:0]+1],
                                          fbuf[dg_ptr+9+dg_len[7:0]]};
                        dg_data_ptr   <= 0;
                        dg_offset     <= 0;

                        // Address matching:
                        case (fbuf[dg_ptr]) // cmd
                        CMD_APRD, CMD_APWR, CMD_APRW, CMD_ARMW: begin
                            // Auto-increment: address field is signed 16-bit position
                            // Each slave increments (or decrements) the address
                            // Match when upper 16 bits == 0
                            aprd_addr_dec <= fbuf[dg_ptr+3][7] ?
                                // negative → slave 0 match is addr=0xFFFF (−1 style)
                                // Simplify: match when addr_lo==0x0000
                                {fbuf[dg_ptr+3], fbuf[dg_ptr+2]} :
                                {fbuf[dg_ptr+3], fbuf[dg_ptr+2]};
                            dg_match  <= ({fbuf[dg_ptr+3], fbuf[dg_ptr+2]} == 16'h0000);
                            dg_offset <= {fbuf[dg_ptr+5], fbuf[dg_ptr+4]};
                            // Increment address in frame for forwarding
                            fbuf[dg_ptr+2] <= fbuf[dg_ptr+2] + 1;
                            if (fbuf[dg_ptr+2] == 8'hFF) fbuf[dg_ptr+3] <= fbuf[dg_ptr+3] + 1;
                        end
                        CMD_FPRD, CMD_FPWR, CMD_FPRW, CMD_FRMW: begin
                            // Fixed address: upper 16 bits = station address
                            dg_match  <= ({fbuf[dg_ptr+3], fbuf[dg_ptr+2]} == station_addr);
                            dg_offset <= {fbuf[dg_ptr+5], fbuf[dg_ptr+4]};
                        end
                        CMD_BRD, CMD_BWR: begin
                            // Broadcast: always match
                            dg_match  <= 1'b1;
                            dg_offset <= {fbuf[dg_ptr+5], fbuf[dg_ptr+4]};
                        end
                        CMD_LRD, CMD_LWR, CMD_LRW: begin
                            // Logical: FMMU mapping (not implemented; skip)
                            dg_match  <= 1'b0;
                            dg_offset <= 16'h0000;
                        end
                        default: dg_match <= 1'b0;
                        endcase

                        dg_ptr  <= dg_ptr + 10; // skip header
                        dg_state<= DG_DATA;
                    end

                    // Process data bytes
                    DG_DATA: begin
                        if (dg_data_ptr < dg_len) begin
                            if (dg_match) begin
                                case (dg_cmd)
                                CMD_FPRD, CMD_APRD, CMD_BRD, CMD_FRMW, CMD_ARMW: begin
                                    // Read: ESC → frame
                                    esc_addr <= dg_offset + dg_data_ptr;
                                    esc_rd   <= 1;
                                    fbuf[dg_ptr] <= esc_rdata;
                                end
                                CMD_FPWR, CMD_APWR, CMD_BWR: begin
                                    // Write: frame → ESC
                                    esc_addr  <= dg_offset + dg_data_ptr;
                                    esc_wdata <= fbuf[dg_ptr];
                                    esc_wr    <= 1;
                                end
                                CMD_FPRW, CMD_APRW, CMD_LRW: begin
                                    // Read-Write: read ESC, write frame data to ESC
                                    esc_addr  <= dg_offset + dg_data_ptr;
                                    esc_rd    <= 1;
                                    esc_wdata <= fbuf[dg_ptr];
                                    esc_wr    <= 1;
                                    fbuf[dg_ptr] <= esc_rdata;
                                end
                                endcase
                            end
                            dg_ptr      <= dg_ptr + 1;
                            dg_data_ptr <= dg_data_ptr + 1;
                        end else begin
                            dg_state <= DG_WKC;
                        end
                    end

                    // Increment WKC if matched
                    DG_WKC: begin
                        if (dg_match) begin
                            // WKC is at dg_ptr and dg_ptr+1
                            dg_wkc <= dg_wkc + 1;
                            fbuf[dg_ptr]   <= dg_wkc[7:0] + 1;
                            fbuf[dg_ptr+1] <= (dg_wkc[7:0] == 8'hFF) ?
                                               dg_wkc[15:8] + 1 : dg_wkc[15:8];
                        end
                        dg_ptr   <= dg_ptr + 2;
                        dg_state <= DG_NEXT;

                        // Mailbox SM handshake detection
                        // SM0 written: master wrote to SM0 base address
                        if (dg_match &&
                            (dg_cmd == CMD_FPWR || dg_cmd == CMD_BWR || dg_cmd == CMD_APWR) &&
                            dg_offset[15:8] == 8'h10) begin
                            sm0_written <= 1;
                        end
                        // SM1 read: master read from SM1 base address
                        if (dg_match &&
                            (dg_cmd == CMD_FPRD || dg_cmd == CMD_BRD || dg_cmd == CMD_APRD) &&
                            dg_offset[15:8] == 8'h11) begin
                            sm1_read <= 1;
                        end
                    end

                    // Check M bit: more datagrams?
                    DG_NEXT: begin
                        dg_header_start <= dg_ptr;
                        if (dg_flags[1] && dg_ptr < fbuf_len - 4) begin
                            // More datagrams follow
                            dg_state <= DG_HEADER;
                        end else begin
                            // Done processing — transmit modified frame
                            main_state <= RX_TRANSMIT;
                            tx_idx     <= 0;
                        end
                    end

                    endcase
                end
            end

            // ── TRANSMIT: send modified frame back via Port 0 ──────────
            RX_TRANSMIT: begin
                if (p0_tx_ready || !p0_tx_valid) begin
                    if (tx_idx < fbuf_len - 4) begin
                        // Send all bytes except last 4 (original FCS; MAC adds new one)
                        p0_tx_data  <= fbuf[tx_idx];
                        p0_tx_valid <= 1;
                        p0_tx_last  <= (tx_idx == fbuf_len - 5);
                        tx_sof_r    <= (tx_idx == 0);
                        tx_idx      <= tx_idx + 1;
                    end else begin
                        p0_tx_valid <= 0;
                        p0_tx_last  <= 0;
                        main_state  <= RX_COLLECT;
                        rx_idx      <= 0;
                    end
                end
            end

            endcase
        end
    end

endmodule
