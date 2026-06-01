// ============================================================================
// ethercat_slave.v — EtherCAT slave core (resource-optimised for GW2AR-18)
//
// Resource optimisation vs v1:
//   fbuf is a 64×8 register array accessed with AT MOST ONE read address and
//   ONE write address per clock cycle.  This allows the synthesiser to infer
//   a single-port distributed RAM (~40 LUTs) rather than the 10+ simultaneous
//   variable-index reads that produced ~3000 LUTs of multiplexer logic.
//
//   Changes:
//     - EtherType bytes captured into dedicated regs during RX_COLLECT
//       (no fixed-address fbuf reads in RX_PROCESS)
//     - DG_HEADER parsed sequentially over 10 cycles (hdr_byte 0-9),
//       one fbuf read per cycle
//     - Auto-increment address write-back interleaved into hdr_byte 3 and 4
//     - DG_WKC split into 3 sequential sub-states (DG_WKC_LO, DG_WKC_HI,
//       DG_WKC_WRITE) so WKC read and write never share a cycle
//
// Timing impact: ~15 extra clock cycles per datagram (header + WKC) at
// 27 MHz = ~555 ns per datagram.  Negligible for EtherCAT mailbox traffic.
// ============================================================================
module ethercat_slave (
    input  wire        clk,
    input  wire        rst_n,

    // ── MAC Port 0 stream interface ───────────────────────────────────────
    input  wire [7:0]  p0_rx_data,
    input  wire        p0_rx_valid,
    input  wire        p0_rx_last,
    input  wire        p0_rx_fcs_ok,
    output wire        p0_rx_ready,

    output reg  [7:0]  p0_tx_data,
    output reg         p0_tx_valid,
    output reg         p0_tx_last,
    output wire        p0_tx_sof,
    input  wire        p0_tx_ready,

    // ── ESC register / process data interface ────────────────────────────
    output reg  [15:0] esc_addr,
    output reg  [7:0]  esc_wdata,
    input  wire [7:0]  esc_rdata,
    output reg         esc_wr,
    output reg         esc_rd,

    input  wire [15:0] station_addr,

    output reg  [3:0]  al_state,
    output reg  [15:0] al_status_code,
    input  wire [3:0]  al_control,

    output reg         sm0_written,
    output reg         sm1_read,
    output reg  [7:0]  dl_status
);

    // ── EtherCAT command codes ────────────────────────────────────────────
    localparam CMD_NOP  = 8'h00;
    localparam CMD_APRD = 8'h01;
    localparam CMD_APWR = 8'h02;
    localparam CMD_APRW = 8'h03;
    localparam CMD_FPRD = 8'h04;
    localparam CMD_FPWR = 8'h05;
    localparam CMD_FPRW = 8'h06;
    localparam CMD_BRD  = 8'h07;
    localparam CMD_BWR  = 8'h08;
    localparam CMD_APRW2= 8'h09;
    localparam CMD_LRD  = 8'h0A;
    localparam CMD_LWR  = 8'h0B;
    localparam CMD_LRW  = 8'h0C;
    localparam CMD_ARMW = 8'h0D;
    localparam CMD_FRMW = 8'h0E;

    localparam AL_INIT   = 4'h1;
    localparam AL_PREOP  = 4'h2;
    localparam AL_SAFEOP = 4'h4;
    localparam AL_OP     = 4'h8;

    // ── Frame buffer: 64 bytes — SINGLE read port, SINGLE write port ─────
    // Synthesises as distributed RAM (~40 LUTs) with one read + one write.
    localparam FBUF_SZ = 6;   // 2^6 = 64 bytes
    reg [7:0] fbuf [0:(1<<FBUF_SZ)-1];
    reg [6:0] fbuf_len;

    // ── Main state machine ────────────────────────────────────────────────
    localparam RX_COLLECT  = 2'd0;
    localparam RX_PROCESS  = 2'd1;
    localparam RX_TRANSMIT = 2'd2;

    reg [1:0]  main_state;
    reg [10:0] rx_idx;
    reg        rx_fcs_ok_r;

    assign p0_rx_ready = (main_state == RX_COLLECT);

    // Capture EtherType during collection (avoids fbuf read in RX_PROCESS)
    reg [7:0] eth_type_lo, eth_type_hi;

    // ── Datagram sub-state ────────────────────────────────────────────────
    localparam DG_HEADER    = 3'd0;  // sequential byte-by-byte, hdr_byte 0-9
    localparam DG_DATA      = 3'd1;
    localparam DG_WKC_LO    = 3'd2;  // read WKC_LO byte
    localparam DG_WKC_HI    = 3'd3;  // read WKC_HI, write WKC_LO
    localparam DG_WKC_WRITE = 3'd4;  // write WKC_HI
    localparam DG_NEXT      = 3'd5;

    reg [2:0]  dg_state;
    reg [3:0]  hdr_byte;             // 0-9 for DG_HEADER sub-cycles

    // Datagram fields (all parsed sequentially in DG_HEADER)
    reg [10:0] dg_ptr;               // current fbuf index
    reg [10:0] dg_header_start;
    reg [7:0]  dg_cmd;
    reg [7:0]  dg_addr_lo, dg_addr_hi;
    reg [7:0]  dg_offset_lo, dg_offset_hi;
    reg [10:0] dg_len;
    reg [1:0]  dg_flags;
    reg [15:0] dg_offset;
    reg        dg_match;
    reg [10:0] dg_data_ptr;
    reg [7:0]  wkc_lo_r, wkc_hi_r;

    reg [10:0] tx_idx;
    reg        tx_sof_r;
    assign p0_tx_sof = tx_sof_r;

    // Auto-increment: is current command an auto-inc type?
    wire is_auto_inc = (dg_cmd == CMD_APRD || dg_cmd == CMD_APWR ||
                        dg_cmd == CMD_APRW || dg_cmd == CMD_APRW2 ||
                        dg_cmd == CMD_ARMW);

    // ── AL state machine ──────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            al_state       <= AL_INIT;
            al_status_code <= 16'h0000;
        end else begin
            case (al_control)
            4'h1: al_state <= AL_INIT;
            4'h2: al_state <= AL_PREOP;
            4'h4: al_state <= AL_SAFEOP;
            4'h8: al_state <= AL_OP;
            default:;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n)
        if (!rst_n) dl_status <= 8'h00;
        else        dl_status <= 8'h11; // Port 0 link up + loop open

    // ── Main FSM ──────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            main_state   <= RX_COLLECT;
            rx_idx       <= 0;
            fbuf_len     <= 0;
            rx_fcs_ok_r  <= 0;
            eth_type_lo  <= 0;
            eth_type_hi  <= 0;
            dg_state     <= DG_HEADER;
            dg_ptr       <= 0;
            hdr_byte     <= 0;
            dg_cmd       <= 0;
            dg_addr_lo   <= 0;
            dg_addr_hi   <= 0;
            dg_offset_lo <= 0;
            dg_offset_hi <= 0;
            dg_len       <= 0;
            dg_flags     <= 0;
            dg_offset    <= 0;
            dg_match     <= 0;
            dg_data_ptr  <= 0;
            dg_header_start <= 0;
            wkc_lo_r     <= 0;
            wkc_hi_r     <= 0;
            tx_idx       <= 0;
            tx_sof_r     <= 0;
            sm0_written  <= 0;
            sm1_read     <= 0;
            p0_tx_valid  <= 0;
            p0_tx_last   <= 0;
            p0_tx_data   <= 0;
            esc_wr       <= 0;
            esc_rd       <= 0;
            esc_addr     <= 0;
            esc_wdata    <= 0;
        end else begin
            esc_wr      <= 0;
            esc_rd      <= 0;
            sm0_written <= 0;
            sm1_read    <= 0;
            tx_sof_r    <= 0;

            case (main_state)

            // ── COLLECT: store incoming frame into fbuf ───────────────────
            RX_COLLECT: begin
                p0_tx_valid <= 0;
                if (p0_rx_valid) begin
                    fbuf[rx_idx] <= p0_rx_data;
                    // Capture EtherType into dedicated regs (bytes 12-13)
                    if (rx_idx == 12) eth_type_lo <= p0_rx_data;
                    if (rx_idx == 13) eth_type_hi <= p0_rx_data;
                    rx_idx <= rx_idx + 1;
                    if (p0_rx_last) begin
                        fbuf_len    <= rx_idx[6:0] + 7'd1;
                        rx_fcs_ok_r <= p0_rx_fcs_ok;
                        rx_idx      <= 0;
                        main_state  <= RX_PROCESS;
                        dg_state    <= DG_HEADER;
                        hdr_byte    <= 0;
                        // First datagram starts at byte 16 (14 Eth + 2 EtherCAT)
                        dg_ptr          <= 16;
                        dg_header_start <= 16;
                    end
                end
            end

            // ── PROCESS: parse and patch datagrams in place ───────────────
            RX_PROCESS: begin
                // Drop bad FCS or non-EtherCAT frames (no fbuf access needed)
                if (!rx_fcs_ok_r ||
                    eth_type_lo != 8'h88 || eth_type_hi != 8'hA4) begin
                    main_state <= RX_COLLECT;
                    rx_idx     <= 0;
                end else begin
                    case (dg_state)

                    // ── DG_HEADER: parse 10 bytes, one per cycle ─────────
                    // fbuf[dg_ptr] is the ONLY read per cycle.
                    // Write-back for auto-increment address is interleaved.
                    DG_HEADER: begin
                        case (hdr_byte)
                        4'd0: dg_cmd      <= fbuf[dg_ptr];
                        4'd1: ;  // index byte — not used internally
                        4'd2: dg_addr_lo  <= fbuf[dg_ptr];
                        4'd3: begin
                                dg_addr_hi <= fbuf[dg_ptr];
                                // Write-back addr_lo+1 for auto-increment cmds
                                // READ addr (dg_ptr) ≠ WRITE addr (dg_ptr-1) ✓
                                if (is_auto_inc)
                                    fbuf[dg_ptr-1] <= dg_addr_lo + 8'd1;
                              end
                        4'd4: begin
                                dg_offset_lo <= fbuf[dg_ptr];
                                // Write-back addr_hi + carry
                                if (is_auto_inc && dg_addr_lo == 8'hFF)
                                    fbuf[dg_ptr-2] <= dg_addr_hi + 8'd1;
                              end
                        4'd5: dg_offset_hi  <= fbuf[dg_ptr];
                        4'd6: dg_len[7:0]   <= fbuf[dg_ptr];
                        4'd7: begin
                                dg_len[10:8] <= fbuf[dg_ptr][2:0];
                                dg_flags     <= fbuf[dg_ptr][7:6];
                              end
                        // Bytes 8-9: IRQ field, ignored
                        4'd9: begin
                                // All header fields now captured.
                                // Compute match condition.
                                dg_data_ptr <= 0;
                                case (dg_cmd)
                                CMD_APRD, CMD_APWR, CMD_APRW,
                                CMD_APRW2, CMD_ARMW: begin
                                    dg_match  <= ({dg_addr_hi, dg_addr_lo}
                                                  == 16'h0000);
                                    dg_offset <= {dg_offset_hi, dg_offset_lo};
                                end
                                CMD_FPRD, CMD_FPWR, CMD_FPRW, CMD_FRMW: begin
                                    dg_match  <= ({dg_addr_hi, dg_addr_lo}
                                                  == station_addr);
                                    dg_offset <= {dg_offset_hi, dg_offset_lo};
                                end
                                CMD_BRD, CMD_BWR: begin
                                    dg_match  <= 1'b1;
                                    dg_offset <= {dg_offset_hi, dg_offset_lo};
                                end
                                default: begin
                                    dg_match  <= 1'b0;
                                    dg_offset <= 16'h0;
                                end
                                endcase
                                dg_state <= DG_DATA;
                              end
                        default:;
                        endcase

                        if (hdr_byte == 4'd9) begin
                            hdr_byte <= 4'd0;
                            dg_ptr   <= dg_ptr + 11'd1; // now = header_start+10
                        end else begin
                            hdr_byte <= hdr_byte + 4'd1;
                            dg_ptr   <= dg_ptr + 11'd1;
                        end
                    end

                    // ── DG_DATA: read/write data bytes one at a time ─────
                    // At most ONE fbuf[dg_ptr] access per cycle.
                    DG_DATA: begin
                        if (dg_data_ptr < dg_len) begin
                            if (dg_match) begin
                                case (dg_cmd)
                                CMD_FPRD, CMD_APRD, CMD_BRD,
                                CMD_FRMW, CMD_ARMW: begin
                                    esc_addr <= dg_offset + {{5{1'b0}}, dg_data_ptr};
                                    esc_rd   <= 1;
                                    fbuf[dg_ptr[FBUF_SZ-1:0]] <= esc_rdata;
                                end
                                CMD_FPWR, CMD_APWR, CMD_BWR: begin
                                    esc_addr  <= dg_offset + {{5{1'b0}}, dg_data_ptr};
                                    esc_wdata <= fbuf[dg_ptr[FBUF_SZ-1:0]];
                                    esc_wr    <= 1;
                                end
                                CMD_FPRW, CMD_APRW, CMD_LRW: begin
                                    esc_addr  <= dg_offset + {{5{1'b0}}, dg_data_ptr};
                                    esc_rd    <= 1;
                                    esc_wdata <= fbuf[dg_ptr[FBUF_SZ-1:0]];
                                    esc_wr    <= 1;
                                    fbuf[dg_ptr[FBUF_SZ-1:0]] <= esc_rdata;
                                end
                                default:;
                                endcase
                            end
                            dg_ptr      <= dg_ptr + 1;
                            dg_data_ptr <= dg_data_ptr + 1;
                        end else begin
                            dg_state <= DG_WKC_LO;
                        end
                    end

                    // ── DG_WKC_LO: read WKC low byte ─────────────────────
                    DG_WKC_LO: begin
                        wkc_lo_r <= fbuf[dg_ptr[FBUF_SZ-1:0]];
                        dg_ptr   <= dg_ptr + 1;
                        dg_state <= DG_WKC_HI;
                    end

                    // ── DG_WKC_HI: read WKC high byte; write WKC_LO ──────
                    // READ at dg_ptr ≠ WRITE at dg_ptr-1 → single-port OK
                    DG_WKC_HI: begin
                        wkc_hi_r <= fbuf[dg_ptr[FBUF_SZ-1:0]];
                        if (dg_match)
                            fbuf[dg_ptr[FBUF_SZ-1:0]-1] <=
                                wkc_lo_r + 8'd1;
                        dg_ptr   <= dg_ptr + 1;
                        dg_state <= DG_WKC_WRITE;
                    end

                    // ── DG_WKC_WRITE: write WKC_HI + carry ───────────────
                    DG_WKC_WRITE: begin
                        if (dg_match)
                            fbuf[dg_ptr[FBUF_SZ-1:0]-1] <=
                                wkc_hi_r + (wkc_lo_r == 8'hFF ? 8'd1 : 8'd0);

                        // SM mailbox handshake
                        if (dg_match &&
                            (dg_cmd==CMD_FPWR || dg_cmd==CMD_BWR ||
                             dg_cmd==CMD_APWR) &&
                            dg_offset[15:8] == 8'h10)
                            sm0_written <= 1;

                        if (dg_match &&
                            (dg_cmd==CMD_FPRD || dg_cmd==CMD_BRD ||
                             dg_cmd==CMD_APRD) &&
                            dg_offset[15:8] == 8'h11)
                            sm1_read <= 1;

                        dg_state <= DG_NEXT;
                    end

                    // ── DG_NEXT: more datagrams? ──────────────────────────
                    DG_NEXT: begin
                        dg_header_start <= dg_ptr;
                        hdr_byte <= 0;
                        if (dg_flags[1] && dg_ptr < {4'd0, fbuf_len} - 4) begin
                            dg_state <= DG_HEADER;
                        end else begin
                            main_state <= RX_TRANSMIT;
                            tx_idx     <= 0;
                        end
                    end

                    default: main_state <= RX_COLLECT;
                    endcase
                end
            end

            // ── TRANSMIT: replay modified frame via Port 0 ────────────────
            // One fbuf read per cycle (sequential tx_idx).
            RX_TRANSMIT: begin
                if (p0_tx_ready || !p0_tx_valid) begin
                    if (tx_idx < {4'd0, fbuf_len} - 4) begin
                        p0_tx_data  <= fbuf[tx_idx[FBUF_SZ-1:0]];
                        p0_tx_valid <= 1;
                        p0_tx_last  <= (tx_idx == {4'd0, fbuf_len} - 5);
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

            default: main_state <= RX_COLLECT;
            endcase
        end
    end

endmodule
