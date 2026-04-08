// ============================================================================
// i2c_master.v — Simple I2C master (100 kHz standard mode)
//
// Supports:
//   - 7-bit device address
//   - 16-bit word address (for AT24C256 EEPROM)
//   - Sequential byte read (for SII EEPROM reads)
//
// Clock: sys_clk must be >= 1 MHz.  Prescaler divides sys_clk to ~100 kHz SCL.
// Set CLK_DIV = sys_clk_hz / (4 * 100_000) - 1
//
// Interface:
//   start  — pulse to begin transaction
//   dev_addr[6:0] — 7-bit I2C device address
//   word_addr[15:0] — 16-bit memory address (sent MSB first, 2 bytes)
//   rd_len[7:0]  — number of bytes to read (1-255)
//   busy   — asserted during transaction
//   rdata_valid — one-cycle pulse per received byte
//   rdata[7:0]  — received byte
//   error  — NACK detected; cleared on next start
// ============================================================================
module i2c_master #(
    parameter CLK_DIV = 67   // 27 MHz / 4 / 100 kHz ≈ 67
) (
    input  wire        clk,
    input  wire        rst_n,

    // Control
    input  wire        start,
    input  wire [6:0]  dev_addr,
    input  wire [15:0] word_addr,
    input  wire [7:0]  rd_len,

    // Status
    output reg         busy,
    output reg         rdata_valid,
    output reg  [7:0]  rdata,
    output reg         error,

    // I2C pins (open-drain via tristate)
    output reg         scl_oe,   // 1 = drive SCL low; 0 = release (pull-up)
    input  wire        scl_in,
    output reg         sda_oe,   // 1 = drive SDA low; 0 = release (pull-up)
    input  wire        sda_in
);

    // ── Clock divider ─────────────────────────────────────────────────────
    reg [$clog2(CLK_DIV)-1:0] clk_cnt;
    reg clk_tick; // quarter-period tick

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt  <= 0;
            clk_tick <= 0;
        end else begin
            clk_tick <= 0;
            if (clk_cnt == CLK_DIV[($clog2(CLK_DIV)-1):0]) begin
                clk_cnt  <= 0;
                clk_tick <= 1;
            end else begin
                clk_cnt <= clk_cnt + 1;
            end
        end
    end

    // ── State machine ─────────────────────────────────────────────────────
    localparam IDLE      = 4'd0;
    localparam START     = 4'd1;   // generate START condition
    localparam SEND_DEV_W= 4'd2;   // send device address + W bit
    localparam ACK_DEV_W = 4'd3;
    localparam SEND_ADDRH= 4'd4;   // send word address high byte
    localparam ACK_ADDRH = 4'd5;
    localparam SEND_ADDRL= 4'd6;   // send word address low byte
    localparam ACK_ADDRL = 4'd7;
    localparam RSTART    = 4'd8;   // repeated START
    localparam SEND_DEV_R= 4'd9;   // send device address + R bit
    localparam ACK_DEV_R = 4'd10;
    localparam READ_BYTE = 4'd11;  // read data byte
    localparam SEND_ACK  = 4'd12;  // send ACK after each byte
    localparam STOP      = 4'd13;  // STOP condition

    reg [3:0]  state;
    reg [3:0]  bit_cnt;
    reg [7:0]  shift_reg;
    reg [7:0]  bytes_left;
    reg [1:0]  phase;       // 0=scl_lo, 1=sda_setup, 2=scl_hi, 3=scl_hi+sample

    // Latch inputs on start
    reg [6:0]  dev_r;
    reg [15:0] waddr_r;
    reg [7:0]  rd_len_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            busy        <= 0;
            rdata_valid <= 0;
            rdata       <= 0;
            error       <= 0;
            scl_oe      <= 0;
            sda_oe      <= 0;
            bit_cnt     <= 0;
            shift_reg   <= 0;
            bytes_left  <= 0;
            phase       <= 0;
            dev_r       <= 0;
            waddr_r     <= 0;
            rd_len_r    <= 0;
        end else begin
            rdata_valid <= 0;

            case (state)
            // ─── IDLE ──────────────────────────────────────────────────
            IDLE: begin
                scl_oe <= 0; sda_oe <= 0;
                busy   <= 0;
                if (start) begin
                    dev_r    <= dev_addr;
                    waddr_r  <= word_addr;
                    rd_len_r <= rd_len;
                    busy     <= 1;
                    error    <= 0;
                    state    <= START;
                    phase    <= 0;
                end
            end

            // ─── START condition: SDA falls while SCL high ─────────────
            START: begin
                if (clk_tick) begin
                    case (phase)
                    0: begin scl_oe <= 0; sda_oe <= 0; phase <= 1; end // SCL=H SDA=H
                    1: begin sda_oe <= 1; phase <= 2; end               // SDA falls
                    2: begin scl_oe <= 1; phase <= 3; end               // SCL falls
                    3: begin
                        // Prepare device addr + W (bit7..1 = addr, bit0 = 0)
                        shift_reg <= {dev_r, 1'b0};
                        bit_cnt   <= 7;
                        state     <= SEND_DEV_W;
                        phase     <= 0;
                    end
                    endcase
                end
            end

            // ─── Generic byte send ──────────────────────────────────────
            SEND_DEV_W, SEND_ADDRH, SEND_ADDRL, SEND_DEV_R: begin
                if (clk_tick) begin
                    case (phase)
                    0: begin scl_oe <= 1; phase <= 1; end                    // SCL low
                    1: begin sda_oe <= ~shift_reg[7]; phase <= 2; end        // setup SDA
                    2: begin scl_oe <= 0; phase <= 3; end                    // SCL high
                    3: begin
                        if (bit_cnt == 0) begin
                            // Byte sent, release SDA for ACK
                            sda_oe <= 0;
                            scl_oe <= 1;
                            case (state)
                            SEND_DEV_W: state <= ACK_DEV_W;
                            SEND_ADDRH: state <= ACK_ADDRH;
                            SEND_ADDRL: state <= ACK_ADDRL;
                            SEND_DEV_R: state <= ACK_DEV_R;
                            default:    state <= STOP;
                            endcase
                            phase <= 0;
                        end else begin
                            shift_reg <= {shift_reg[6:0], 1'b0};
                            bit_cnt   <= bit_cnt - 1;
                            phase     <= 0;
                        end
                    end
                    endcase
                end
            end

            // ─── ACK slots ─────────────────────────────────────────────
            ACK_DEV_W, ACK_ADDRH, ACK_ADDRL, ACK_DEV_R: begin
                if (clk_tick) begin
                    case (phase)
                    0: begin scl_oe <= 0; phase <= 1; end  // SCL high; sample SDA
                    1: begin
                        if (sda_in) begin error <= 1; state <= STOP; end
                        else begin
                            case (state)
                            ACK_DEV_W: begin
                                shift_reg <= waddr_r[15:8];
                                bit_cnt   <= 7;
                                state     <= SEND_ADDRH;
                            end
                            ACK_ADDRH: begin
                                shift_reg <= waddr_r[7:0];
                                bit_cnt   <= 7;
                                state     <= SEND_ADDRL;
                            end
                            ACK_ADDRL: begin
                                state <= RSTART;
                            end
                            ACK_DEV_R: begin
                                bytes_left <= rd_len_r;
                                bit_cnt    <= 7;
                                shift_reg  <= 0;
                                state      <= READ_BYTE;
                            end
                            endcase
                        end
                        scl_oe <= 1;
                        phase  <= 0;
                    end
                    endcase
                end
            end

            // ─── Repeated START ─────────────────────────────────────────
            RSTART: begin
                if (clk_tick) begin
                    case (phase)
                    0: begin scl_oe <= 1; sda_oe <= 1; phase <= 1; end // SCL=L SDA=L
                    1: begin scl_oe <= 0; phase <= 2; end               // SCL=H SDA=L
                    2: begin sda_oe <= 0; phase <= 3; end               // SDA=H (Sr setup)
                    3: begin
                        sda_oe    <= 1;                                 // SDA falls = repeated START
                        scl_oe    <= 1;
                        shift_reg <= {dev_r, 1'b1};                    // dev addr + R bit
                        bit_cnt   <= 7;
                        state     <= SEND_DEV_R;
                        phase     <= 0;
                    end
                    endcase
                end
            end

            // ─── Read data byte ─────────────────────────────────────────
            READ_BYTE: begin
                if (clk_tick) begin
                    case (phase)
                    0: begin scl_oe <= 1; sda_oe <= 0; phase <= 1; end // SCL low, release SDA
                    1: begin scl_oe <= 0; phase <= 2; end               // SCL high
                    2: begin
                        shift_reg <= {shift_reg[6:0], sda_in};          // sample
                        phase     <= 3;
                    end
                    3: begin
                        if (bit_cnt == 0) begin
                            rdata       <= {shift_reg[6:0], sda_in};
                            rdata_valid <= 1;
                            bytes_left  <= bytes_left - 1;
                            // Send ACK if more bytes, else NACK (last byte)
                            sda_oe <= (bytes_left > 1) ? 1'b1 : 1'b0;
                            state  <= SEND_ACK;
                            phase  <= 0;
                        end else begin
                            bit_cnt <= bit_cnt - 1;
                            phase   <= 0;
                        end
                    end
                    endcase
                end
            end

            // ─── ACK/NACK after read ────────────────────────────────────
            SEND_ACK: begin
                if (clk_tick) begin
                    case (phase)
                    0: begin scl_oe <= 0; phase <= 1; end  // SCL high
                    1: begin scl_oe <= 1; phase <= 2; end  // SCL low
                    2: begin
                        sda_oe <= 0;
                        if (bytes_left == 0) begin
                            state <= STOP;
                        end else begin
                            bit_cnt <= 7;
                            state   <= READ_BYTE;
                        end
                        phase <= 0;
                    end
                    default: phase <= 0;
                    endcase
                end
            end

            // ─── STOP condition: SDA rises while SCL high ───────────────
            STOP: begin
                if (clk_tick) begin
                    case (phase)
                    0: begin scl_oe <= 1; sda_oe <= 1; phase <= 1; end // SCL=L, SDA=L
                    1: begin scl_oe <= 0; phase <= 2; end               // SCL=H
                    2: begin sda_oe <= 0; phase <= 3; end               // SDA rises = STOP
                    3: begin busy <= 0; state <= IDLE; phase <= 0; end
                    endcase
                end
            end

            default: state <= IDLE;
            endcase
        end
    end

endmodule
