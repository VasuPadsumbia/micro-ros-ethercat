// ============================================================================
// crc32.v — Ethernet CRC-32 (IEEE 802.3)
//
// Computes the running CRC-32 for Ethernet frames.
// Input data is 4 bits wide (MII nibble order).
// Bit order: LSB-first within each nibble (standard Ethernet).
//
// Usage:
//   - Assert rst to reset to 0xFFFFFFFF
//   - Apply nibbles with valid=1 for each MII nibble
//   - Final CRC = ~crc (bit-reversed per nibble, appended to frame)
//   - To check: if last 4 bytes are correct FCS, crc == RESIDUE (0xC704DD7B)
// ============================================================================
module crc32 (
    input  wire        clk,
    input  wire        rst,       // synchronous reset to 0xFFFFFFFF
    input  wire [3:0]  din,       // MII nibble, LSB first
    input  wire        valid,     // process din this cycle
    output wire [31:0] crc        // running CRC (not yet inverted)
);

    reg [31:0] crc_r;
    assign crc = crc_r;

    // Standard CRC-32 polynomial (reflected): 0xEDB88320
    // Process one bit at a time from LSB
    function [31:0] crc_bit;
        input [31:0] prev;
        input        bit_in;
        reg          fb;
        begin
            fb      = prev[0] ^ bit_in;
            crc_bit = {1'b0, prev[31:1]} ^ (fb ? 32'hEDB88320 : 32'h0);
        end
    endfunction

    integer i;
    reg [31:0] tmp;

    always @(posedge clk) begin
        if (rst) begin
            crc_r <= 32'hFFFFFFFF;
        end else if (valid) begin
            // Process 4 bits (nibble), LSB first
            tmp = crc_r;
            for (i = 0; i < 4; i = i + 1)
                tmp = crc_bit(tmp, din[i]);
            crc_r <= tmp;
        end
    end

endmodule
