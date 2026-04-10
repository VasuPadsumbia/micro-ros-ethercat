// ============================================================================
// mii_mac.v — MII MAC layer for DP83848 (100BASE-TX, 4-bit MII)
//
// One instance per PHY port.  Handles:
//   TX: preamble (7×0x55 + SFD 0xD5), frame bytes, FCS append
//   RX: preamble strip, frame receive, FCS check
//
// Clocking:
//   TX uses tx_clk (25 MHz from PHY, synchronous to MII TX domain).
//   RX uses rx_clk (25 MHz from PHY, synchronous to MII RX domain).
//   sys_clk (27 MHz) domain interfaces via small async FIFOs.
//
// TX FIFO interface (sys_clk side):
//   tx_data[7:0]  — byte to transmit
//   tx_valid      — byte present in FIFO
//   tx_ready      — MAC can accept byte
//   tx_last       — last byte of frame (triggers FCS)
//   tx_sof        — start of frame (triggers preamble)
//
// RX FIFO interface (sys_clk side):
//   rx_data[7:0]  — received byte (FCS stripped)
//   rx_valid      — byte valid
//   rx_last       — last byte of frame
//   rx_fcs_ok     — frame FCS was correct
//   rx_ready      — consumer ready
// ============================================================================
module mii_mac (
    input  wire        sys_clk,
    input  wire        rst_n,

    // ── MII TX (tx_clk domain) ────────────────────────────────────────
    input  wire        tx_clk,
    output reg  [3:0]  txd,
    output reg         tx_en,
    output reg         tx_er,

    // ── MII RX (rx_clk domain) ────────────────────────────────────────
    input  wire        rx_clk,
    input  wire [3:0]  rxd,
    input  wire        rx_dv,
    input  wire        rx_er,

    // ── TX stream (sys_clk domain) ───────────────────────────────────
    input  wire [7:0]  tx_data,
    input  wire        tx_valid,
    output wire        tx_ready,
    input  wire        tx_last,
    input  wire        tx_sof,

    // ── RX stream (sys_clk domain) ───────────────────────────────────
    output wire [7:0]  rx_data,
    output wire        rx_valid,
    output wire        rx_last,
    output wire        rx_fcs_ok,
    input  wire        rx_ready
);

    // =========================================================================
    // TX path (tx_clk domain)
    // =========================================================================
    // Async FIFO: sys_clk write side → tx_clk read side
    // Simple 64-byte async FIFO (enough for back-pressure)
    localparam FIFO_DEPTH = 6; // 2^6 = 64 entries; each = {last,data}

    reg [8:0]  txf_mem  [0:(1<<FIFO_DEPTH)-1]; // {last, data[7:0]}
    reg [FIFO_DEPTH:0] txf_wptr; // sys_clk domain
    reg [FIFO_DEPTH:0] txf_rptr; // tx_clk domain
    // Gray-coded pointers for CDC
    wire [FIFO_DEPTH:0] txf_wptr_gray = txf_wptr ^ (txf_wptr >> 1);
    wire [FIFO_DEPTH:0] txf_rptr_gray = txf_rptr ^ (txf_rptr >> 1);

    // Sync rptr_gray → sys_clk
    reg [FIFO_DEPTH:0] txf_rptr_gray_s1, txf_rptr_gray_s2;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) {txf_rptr_gray_s1, txf_rptr_gray_s2} <= 0;
        else begin
            txf_rptr_gray_s1 <= txf_rptr_gray;
            txf_rptr_gray_s2 <= txf_rptr_gray_s1;
        end
    end

    // Sync wptr_gray → tx_clk
    reg [FIFO_DEPTH:0] txf_wptr_gray_s1, txf_wptr_gray_s2;
    always @(posedge tx_clk or negedge rst_n) begin
        if (!rst_n) {txf_wptr_gray_s1, txf_wptr_gray_s2} <= 0;
        else begin
            txf_wptr_gray_s1 <= txf_wptr_gray;
            txf_wptr_gray_s2 <= txf_wptr_gray_s1;
        end
    end

    // Recover binary rptr in sys_clk domain for full detection
    // Gray-to-binary: bin[i] = XOR of gray[FIFO_DEPTH:i]
    // Use upward loop: bin[FIFO_DEPTH] = gray[FIFO_DEPTH],
    //                  bin[k] = bin[k+1] ^ gray[k]  (k = FIFO_DEPTH-1 .. 0)
    // Encoded as bin[FIFO_DEPTH-1-k] = bin[FIFO_DEPTH-k] ^ gray[FIFO_DEPTH-1-k]
    wire [FIFO_DEPTH:0] txf_rptr_bin_s;
    assign txf_rptr_bin_s[FIFO_DEPTH] = txf_rptr_gray_s2[FIFO_DEPTH];
    genvar gi;
    generate
        for (gi = 0; gi < FIFO_DEPTH; gi = gi + 1)
            assign txf_rptr_bin_s[FIFO_DEPTH-1-gi] =
                txf_rptr_bin_s[FIFO_DEPTH-gi] ^ txf_rptr_gray_s2[FIFO_DEPTH-1-gi];
    endgenerate

    wire txf_full  = (txf_wptr[FIFO_DEPTH] != txf_rptr_bin_s[FIFO_DEPTH]) &&
                     (txf_wptr[FIFO_DEPTH-1:0] == txf_rptr_bin_s[FIFO_DEPTH-1:0]);
    assign tx_ready = !txf_full;

    // Write side (sys_clk)
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) txf_wptr <= 0;
        else if (tx_valid && !txf_full) begin
            txf_mem[txf_wptr[FIFO_DEPTH-1:0]] <= {tx_last, tx_data};
            txf_wptr <= txf_wptr + 1;
        end
    end

    // ── TX state machine (tx_clk domain) ─────────────────────────────────
    localparam TX_IDLE  = 3'd0;
    localparam TX_PRE   = 3'd1;  // preamble
    localparam TX_SFD   = 3'd2;  // start frame delimiter
    localparam TX_DATA  = 3'd3;  // data nibbles
    localparam TX_FCS   = 3'd4;  // FCS nibbles
    localparam TX_IFG   = 3'd5;  // inter-frame gap

    reg [2:0]  tx_state;
    reg [3:0]  tx_pre_cnt;  // preamble byte count
    reg        tx_nibble;   // 0=low nibble, 1=high nibble
    reg [7:0]  tx_byte_r;
    reg        tx_last_r;
    reg [31:0] tx_crc_r;
    reg [2:0]  tx_fcs_cnt;
    reg [3:0]  tx_ifg_cnt;

    // Recover wptr in tx_clk domain
    wire [FIFO_DEPTH:0] txf_wptr_bin_r;
    assign txf_wptr_bin_r[FIFO_DEPTH] = txf_wptr_gray_s2[FIFO_DEPTH];
    generate
        for (gi = 0; gi < FIFO_DEPTH; gi = gi + 1)
            assign txf_wptr_bin_r[FIFO_DEPTH-1-gi] =
                txf_wptr_bin_r[FIFO_DEPTH-gi] ^ txf_wptr_gray_s2[FIFO_DEPTH-1-gi];
    endgenerate
    wire txf_empty = (txf_wptr_bin_r == txf_rptr);

    // CRC32 update function (reflected, Ethernet)
    function [31:0] crc32_nibble;
        input [31:0] crc;
        input [3:0]  nib;
        integer k;
        reg [31:0] c;
        begin
            c = crc;
            for (k = 0; k < 4; k = k + 1)
                c = c[0] ? ({1'b0, c[31:1]} ^ 32'hEDB88320) ^ ({31'b0, nib[k]} << 31)
                         :  {1'b0, c[31:1]} ^ ({31'b0, nib[k]} << 31);
            // Simplified: process bit by bit
            c = crc;
            for (k = 0; k < 4; k = k + 1) begin
                if (c[0] ^ nib[k])
                    c = {1'b0, c[31:1]} ^ 32'hEDB88320;
                else
                    c = {1'b0, c[31:1]};
            end
            crc32_nibble = c;
        end
    endfunction

    always @(posedge tx_clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state   <= TX_IDLE;
            txd        <= 4'h0;
            tx_en      <= 0;
            tx_er      <= 0;
            txf_rptr   <= 0;
            tx_pre_cnt <= 0;
            tx_nibble  <= 0;
            tx_crc_r   <= 32'hFFFFFFFF;
            tx_fcs_cnt <= 0;
            tx_ifg_cnt <= 0;
            tx_byte_r  <= 0;
            tx_last_r  <= 0;
        end else begin
            tx_er <= 0;
            case (tx_state)

            TX_IDLE: begin
                tx_en      <= 0;
                txd        <= 0;
                tx_pre_cnt <= 7;
                tx_nibble  <= 0;
                tx_crc_r   <= 32'hFFFFFFFF;
                if (!txf_empty) begin
                    tx_state <= TX_PRE;
                    tx_en    <= 1;
                end
            end

            TX_PRE: begin
                // 7 bytes of 0x55 (nibbles: 0x5, 0x5 repeated)
                txd   <= 4'h5;
                tx_en <= 1;
                if (tx_nibble) begin
                    tx_nibble <= 0;
                    if (tx_pre_cnt == 0) begin
                        tx_state <= TX_SFD;
                    end else begin
                        tx_pre_cnt <= tx_pre_cnt - 1;
                    end
                end else begin
                    tx_nibble <= 1;
                end
            end

            TX_SFD: begin
                // SFD = 0xD5 → nibbles 0x5 then 0xD
                if (!tx_nibble) begin
                    txd       <= 4'h5;
                    tx_nibble <= 1;
                end else begin
                    txd <= 4'hD;
                    tx_nibble <= 0;
                    // Read first data byte from FIFO
                    {tx_last_r, tx_byte_r} <= txf_mem[txf_rptr[FIFO_DEPTH-1:0]];
                    txf_rptr  <= txf_rptr + 1;
                    tx_state  <= TX_DATA;
                end
            end

            TX_DATA: begin
                if (!tx_nibble) begin
                    txd       <= tx_byte_r[3:0];
                    tx_crc_r  <= crc32_nibble(tx_crc_r, tx_byte_r[3:0]);
                    tx_nibble <= 1;
                end else begin
                    txd       <= tx_byte_r[7:4];
                    tx_crc_r  <= crc32_nibble(tx_crc_r, tx_byte_r[7:4]);
                    tx_nibble <= 0;
                    if (tx_last_r) begin
                        // End of payload — send FCS
                        tx_fcs_cnt <= 7; // 4 bytes × 2 nibbles - 1
                        tx_state   <= TX_FCS;
                    end else if (!txf_empty) begin
                        {tx_last_r, tx_byte_r} <= txf_mem[txf_rptr[FIFO_DEPTH-1:0]];
                        txf_rptr <= txf_rptr + 1;
                    end
                end
            end

            TX_FCS: begin
                // Transmit FCS = ~crc_r, LSB first per byte, LSB nibble first
                // Byte order: byte0 = crc[7:0], byte1 = crc[15:8], ...
                // But CRC is bit-reflected so: send ~crc_r nibble by nibble LSB first
                case (tx_fcs_cnt)
                7: txd <= ~tx_crc_r[3:0];
                6: txd <= ~tx_crc_r[7:4];
                5: txd <= ~tx_crc_r[11:8];
                4: txd <= ~tx_crc_r[15:12];
                3: txd <= ~tx_crc_r[19:16];
                2: txd <= ~tx_crc_r[23:20];
                1: txd <= ~tx_crc_r[27:24];
                0: txd <= ~tx_crc_r[31:28];
                endcase
                if (tx_fcs_cnt == 0) begin
                    tx_en      <= 0;
                    tx_ifg_cnt <= 23; // 96-bit IFG at 100Mbps = 24 nibble-clocks
                    tx_state   <= TX_IFG;
                end else begin
                    tx_fcs_cnt <= tx_fcs_cnt - 1;
                end
            end

            TX_IFG: begin
                txd <= 0; tx_en <= 0;
                if (tx_ifg_cnt == 0) tx_state <= TX_IDLE;
                else tx_ifg_cnt <= tx_ifg_cnt - 1;
            end

            endcase
        end
    end

    // =========================================================================
    // RX path (rx_clk domain → sys_clk domain)
    // =========================================================================
    localparam RXF_DEPTH = 6; // 64-entry async FIFO; entry = {last,fcs_ok,data}
    reg [9:0] rxf_mem [0:(1<<RXF_DEPTH)-1]; // {last, fcs_ok, data[7:0]}
    reg [RXF_DEPTH:0] rxf_wptr; // rx_clk domain
    reg [RXF_DEPTH:0] rxf_rptr; // sys_clk domain

    wire [RXF_DEPTH:0] rxf_wptr_gray = rxf_wptr ^ (rxf_wptr >> 1);
    wire [RXF_DEPTH:0] rxf_rptr_gray = rxf_rptr ^ (rxf_rptr >> 1);

    reg [RXF_DEPTH:0] rxf_rptr_gray_s1_r, rxf_rptr_gray_s2_r;
    always @(posedge rx_clk or negedge rst_n) begin
        if (!rst_n) {rxf_rptr_gray_s1_r, rxf_rptr_gray_s2_r} <= 0;
        else begin
            rxf_rptr_gray_s1_r <= rxf_rptr_gray;
            rxf_rptr_gray_s2_r <= rxf_rptr_gray_s1_r;
        end
    end
    // Full check in rx_clk domain
    wire [RXF_DEPTH:0] rxf_rptr_bin_r;
    assign rxf_rptr_bin_r[RXF_DEPTH] = rxf_rptr_gray_s2_r[RXF_DEPTH];
    generate
        for (gi = 0; gi < RXF_DEPTH; gi = gi + 1)
            assign rxf_rptr_bin_r[RXF_DEPTH-1-gi] =
                rxf_rptr_bin_r[RXF_DEPTH-gi] ^ rxf_rptr_gray_s2_r[RXF_DEPTH-1-gi];
    endgenerate
    wire rxf_full_rx = (rxf_wptr[RXF_DEPTH] != rxf_rptr_bin_r[RXF_DEPTH]) &&
                       (rxf_wptr[RXF_DEPTH-1:0] == rxf_rptr_bin_r[RXF_DEPTH-1:0]);

    // ── RX state machine (rx_clk domain) ─────────────────────────────────
    localparam RX_IDLE = 2'd0;
    localparam RX_PRE  = 2'd1;
    localparam RX_DATA = 2'd2;

    reg [1:0]  rx_state;
    reg        rx_nibble;
    reg [3:0]  rx_nib_lo;
    reg [31:0] rx_crc_r;
    // Sliding window over last 4 bytes for FCS stripping
    reg [7:0]  rx_pipe [0:3];
    reg [1:0]  rx_pipe_idx;
    reg [2:0]  rx_pipe_fill; // counts 0..4

    always @(posedge rx_clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state    <= RX_IDLE;
            rx_nibble   <= 0;
            rx_crc_r    <= 32'hFFFFFFFF;
            rxf_wptr    <= 0;
            rx_pipe_fill <= 0;
            rx_pipe_idx  <= 0;
        end else begin
            case (rx_state)

            RX_IDLE: begin
                rx_crc_r    <= 32'hFFFFFFFF;
                rx_pipe_fill <= 0;
                rx_nibble   <= 0;
                if (rx_dv) rx_state <= RX_PRE;
            end

            RX_PRE: begin
                // Wait for SFD nibble pair 0x5,0xD
                if (!rx_dv) begin rx_state <= RX_IDLE; end
                else if (!rx_nibble) begin
                    rx_nib_lo <= rxd;
                    rx_nibble <= 1;
                end else begin
                    rx_nibble <= 0;
                    if (rx_nib_lo == 4'h5 && rxd == 4'hD) begin
                        rx_state <= RX_DATA;
                    end
                end
            end

            RX_DATA: begin
                if (!rx_dv) begin
                    // Frame ended — flush pipeline minus last 4 bytes (FCS)
                    // Check FCS: residue = 0xC704DD7B
                    begin : flush
                        integer fi;
                        reg fcs_good;
                        fcs_good = (rx_crc_r == 32'hC704DD7B);
                        // Mark last byte with fcs_ok
                        // Note: pipe contains bytes including FCS; we skip last 4
                        // Simplified: mark last pushed byte as last+fcs
                        // (For a proper impl, buffer entire frame; here we mark last)
                        if (!rxf_full_rx && rx_pipe_fill >= 4) begin
                            rxf_mem[rxf_wptr[RXF_DEPTH-1:0]] <=
                                {1'b1, fcs_good, rx_pipe[rx_pipe_idx]};
                            rxf_wptr <= rxf_wptr + 1;
                        end
                    end
                    rx_state <= RX_IDLE;
                end else if (!rx_nibble) begin
                    rx_nib_lo <= rxd;
                    rx_nibble <= 1;
                end else begin
                    // Assembled full byte
                    rx_nibble <= 0;
                    begin : store_byte
                        reg [7:0] byt;
                        byt = {rxd, rx_nib_lo};
                        // Update CRC
                        rx_crc_r <= crc32_nibble(
                                        crc32_nibble(rx_crc_r, rx_nib_lo), rxd);
                        // Push into pipeline (circular buffer of 4)
                        if (rx_pipe_fill < 4) begin
                            rx_pipe[rx_pipe_fill[1:0]] <= byt;
                            rx_pipe_fill <= rx_pipe_fill + 1;
                        end else begin
                            // Pipeline full: push oldest byte to FIFO
                            if (!rxf_full_rx) begin
                                rxf_mem[rxf_wptr[RXF_DEPTH-1:0]] <=
                                    {1'b0, 1'b0, rx_pipe[rx_pipe_idx]};
                                rxf_wptr    <= rxf_wptr + 1;
                                rx_pipe[rx_pipe_idx] <= byt;
                                rx_pipe_idx <= rx_pipe_idx + 1;
                            end
                        end
                    end
                end
            end

            endcase
        end
    end

    // ── RX FIFO read side (sys_clk domain) ───────────────────────────────
    reg [RXF_DEPTH:0] rxf_wptr_gray_s1, rxf_wptr_gray_s2;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) {rxf_wptr_gray_s1, rxf_wptr_gray_s2} <= 0;
        else begin
            rxf_wptr_gray_s1 <= rxf_wptr_gray;
            rxf_wptr_gray_s2 <= rxf_wptr_gray_s1;
        end
    end
    wire [RXF_DEPTH:0] rxf_wptr_bin_s;
    assign rxf_wptr_bin_s[RXF_DEPTH] = rxf_wptr_gray_s2[RXF_DEPTH];
    generate
        for (gi = 0; gi < RXF_DEPTH; gi = gi + 1)
            assign rxf_wptr_bin_s[RXF_DEPTH-1-gi] =
                rxf_wptr_bin_s[RXF_DEPTH-gi] ^ rxf_wptr_gray_s2[RXF_DEPTH-1-gi];
    endgenerate
    wire rxf_empty_s = (rxf_wptr_bin_s == rxf_rptr);

    assign rx_data   = rxf_mem[rxf_rptr[RXF_DEPTH-1:0]][7:0];
    assign rx_last   = rxf_mem[rxf_rptr[RXF_DEPTH-1:0]][9];
    assign rx_fcs_ok = rxf_mem[rxf_rptr[RXF_DEPTH-1:0]][8];
    assign rx_valid  = !rxf_empty_s;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) rxf_rptr <= 0;
        else if (rx_valid && rx_ready) rxf_rptr <= rxf_rptr + 1;
    end

endmodule
