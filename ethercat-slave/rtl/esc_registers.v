// ============================================================================
// esc_registers.v — EtherCAT Slave Controller register file
//
// Implements the standard ESC register space (ETG.1000.4 Table 1):
//   0x0000–0x000F  Fixed info (ROM): type, revision, RAM size, port descriptor
//   0x0010–0x0011  Configured station address (RW)
//   0x0012–0x0013  Configured station alias (from EEPROM)
//   0x0100–0x0101  DL Control
//   0x0110–0x0111  DL Status
//   0x0120–0x0121  AL Control   (master writes desired state)
//   0x0130–0x0131  AL Status    (slave writes current state)
//   0x0134–0x0135  AL Status Code
//   0x0200         PDI Control
//   0x0204–0x0207  EEPROM access registers
//   0x0500–0x0507  SII EEPROM interface registers
//   0x0800–0x087F  SyncManager 0-7 (8 bytes each, 8 SMs max)
//   0x1000–0x1FFF  Process data RAM (4 KiB, dual-port)
//
// All registers are accessed as bytes.  The EtherCAT datagram processor
// in ethercat_slave.v provides the byte address + read/write strobe.
// ============================================================================
module esc_registers (
    input  wire        clk,
    input  wire        rst_n,

    // EtherCAT datagram port
    input  wire [15:0] ec_addr,
    input  wire [7:0]  ec_wdata,
    output reg  [7:0]  ec_rdata,
    input  wire        ec_wr,
    input  wire        ec_rd,

    // SPI/PDI port (for mailbox access to process data RAM)
    input  wire [15:0] pdi_addr,
    input  wire [7:0]  pdi_wdata,
    output reg  [7:0]  pdi_rdata,
    input  wire        pdi_wr,
    input  wire        pdi_rd,

    // EEPROM interface
    output reg  [15:0] eeprom_word_addr,
    output reg         eeprom_req,
    input  wire [15:0] eeprom_rdata,
    input  wire        eeprom_ack,

    // AL state machine outputs
    output reg  [3:0]  al_control,   // desired state from master (bits 3:0)
    output reg  [3:0]  al_status,    // current state (written by app logic)
    input  wire [3:0]  al_state_in,  // application sets current AL state
    input  wire [15:0] al_status_code_in,

    // Station address
    output reg  [15:0] station_addr,

    // DL control / status
    output reg  [7:0]  dl_ctrl,
    input  wire [7:0]  dl_status_in,

    // SyncManager configurations (8 SMs × 8 bytes)
    output wire [63:0] sm_cfg [0:7]  // {start_addr[15:0], len[15:0], ctrl[7:0], status[7:0], act[7:0], pdi_ctrl[7:0]}
);

    // ── ROM: fixed registers ──────────────────────────────────────────────
    // ESC type 0x11 = IP Core with 2 ports
    // Revision 0x01, Build 0x0001
    // FMMU supported = 8, SM supported = 8
    // RAM size = 0x10 (4 KiB / 256 B units = 16)
    // Port 0: MII, Port 1: MII
    localparam [7:0] ESC_TYPE     = 8'h11;
    localparam [7:0] ESC_REVISION = 8'h01;
    localparam [7:0] ESC_BUILD_L  = 8'h01;
    localparam [7:0] ESC_BUILD_H  = 8'h00;
    localparam [7:0] ESC_FMMU_N   = 8'h08;
    localparam [7:0] ESC_SM_N     = 8'h08;
    localparam [7:0] ESC_RAM_SIZE = 8'h10;
    localparam [7:0] ESC_PORT_DESC= 8'h0A; // Port0=MII, Port1=MII

    // ── Writable registers (single-cycle write) ───────────────────────────
    reg [7:0]  station_addr_r [0:1];
    reg [7:0]  station_alias_r[0:1];
    reg [7:0]  dl_ctrl_r      [0:1];
    reg [7:0]  al_ctrl_r      [0:1];
    reg [7:0]  eeprom_ctrl_r  [0:3]; // 0x0500–0x0503
    reg [7:0]  eeprom_addr_r  [0:1]; // 0x0504–0x0505

    // SyncManager registers: 8 SMs × 8 bytes
    reg [7:0]  sm_r [0:7][0:7];

    // Process data RAM (4 KiB)
    reg [7:0]  pd_ram [0:4095];

    // ── EEPROM shadow (first 128 words cached) ────────────────────────────
    reg [7:0]  eeprom_cache [0:255]; // 128 words = 256 bytes
    reg        eeprom_cache_valid;
    reg [7:0]  eeprom_fetch_idx;
    reg        eeprom_busy;

    // ── Output wiring ─────────────────────────────────────────────────────
    assign al_control   = al_ctrl_r[0][3:0];
    assign station_addr = {station_addr_r[1], station_addr_r[0]};
    assign dl_ctrl      = dl_ctrl_r[0];

    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : sm_out
            assign sm_cfg[g] = {sm_r[g][7], sm_r[g][6], sm_r[g][5], sm_r[g][4],
                                sm_r[g][3], sm_r[g][2], sm_r[g][1], sm_r[g][0]};
        end
    endgenerate

    // ── EtherCAT register read ────────────────────────────────────────────
    always @(*) begin
        ec_rdata = 8'hFF;
        casez (ec_addr)
        // Fixed info
        16'h0000: ec_rdata = ESC_TYPE;
        16'h0001: ec_rdata = ESC_REVISION;
        16'h0002: ec_rdata = ESC_BUILD_L;
        16'h0003: ec_rdata = ESC_BUILD_H;
        16'h0004: ec_rdata = ESC_FMMU_N;
        16'h0005: ec_rdata = ESC_SM_N;
        16'h0006: ec_rdata = ESC_RAM_SIZE;
        16'h0007: ec_rdata = ESC_PORT_DESC;
        16'h0008: ec_rdata = 8'h00; // ESC features lo
        16'h0009: ec_rdata = 8'h00; // ESC features hi
        // Station address
        16'h0010: ec_rdata = station_addr_r[0];
        16'h0011: ec_rdata = station_addr_r[1];
        16'h0012: ec_rdata = station_alias_r[0];
        16'h0013: ec_rdata = station_alias_r[1];
        // DL Control/Status
        16'h0100: ec_rdata = dl_ctrl_r[0];
        16'h0101: ec_rdata = dl_ctrl_r[1];
        16'h0110: ec_rdata = dl_status_in;
        16'h0111: ec_rdata = 8'h00;
        // AL Control
        16'h0120: ec_rdata = al_ctrl_r[0];
        16'h0121: ec_rdata = al_ctrl_r[1];
        // AL Status
        16'h0130: ec_rdata = {4'h0, al_state_in};
        16'h0131: ec_rdata = 8'h00;
        16'h0134: ec_rdata = al_status_code_in[7:0];
        16'h0135: ec_rdata = al_status_code_in[15:8];
        // EEPROM SII registers
        16'h0500: ec_rdata = eeprom_ctrl_r[0];
        16'h0501: ec_rdata = eeprom_ctrl_r[1];
        16'h0502: ec_rdata = eeprom_ctrl_r[2];
        16'h0503: ec_rdata = eeprom_ctrl_r[3];
        16'h0504: ec_rdata = eeprom_addr_r[0];
        16'h0505: ec_rdata = eeprom_addr_r[1];
        16'h0506: ec_rdata = eeprom_cache_valid ?
                             eeprom_cache[{eeprom_addr_r[0][6:0], 1'b0}] : 8'hFF;
        16'h0507: ec_rdata = eeprom_cache_valid ?
                             eeprom_cache[{eeprom_addr_r[0][6:0], 1'b1}] : 8'hFF;
        // SyncManagers 0x0800-0x087F
        16'h08??: begin
            ec_rdata = sm_r[ec_addr[6:3]][ec_addr[2:0]];
        end
        // Process data RAM
        16'h1???: ec_rdata = pd_ram[ec_addr[11:0]];
        default: ec_rdata = 8'hFF;
        endcase
    end

    // ── EtherCAT register write ───────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            station_addr_r[0] <= 8'h00; station_addr_r[1] <= 8'h00;
            station_alias_r[0]<= 8'h00; station_alias_r[1]<= 8'h00;
            dl_ctrl_r[0]      <= 8'h00; dl_ctrl_r[1]      <= 8'h00;
            al_ctrl_r[0]      <= 8'h01; al_ctrl_r[1]      <= 8'h00; // INIT state
            eeprom_ctrl_r[0]  <= 8'h00; eeprom_ctrl_r[1]  <= 8'h00;
            eeprom_ctrl_r[2]  <= 8'h00; eeprom_ctrl_r[3]  <= 8'h00;
            eeprom_addr_r[0]  <= 8'h00; eeprom_addr_r[1]  <= 8'h00;
            eeprom_req        <= 0;
            eeprom_busy       <= 0;
            eeprom_cache_valid<= 0;
            eeprom_fetch_idx  <= 0;
        end else begin
            eeprom_req <= 0;

            if (ec_wr) begin
                casez (ec_addr)
                16'h0010: station_addr_r[0] <= ec_wdata;
                16'h0011: station_addr_r[1] <= ec_wdata;
                16'h0100: dl_ctrl_r[0]      <= ec_wdata;
                16'h0101: dl_ctrl_r[1]      <= ec_wdata;
                16'h0120: al_ctrl_r[0]      <= ec_wdata;
                16'h0121: al_ctrl_r[1]      <= ec_wdata;
                16'h0504: eeprom_addr_r[0]  <= ec_wdata;
                16'h0505: eeprom_addr_r[1]  <= ec_wdata;
                16'h0502: begin
                    // EEPROM read command: bit0=1
                    if (ec_wdata[0]) begin
                        eeprom_word_addr <= {eeprom_addr_r[1], eeprom_addr_r[0]};
                        eeprom_req       <= 1;
                    end
                end
                16'h08??: sm_r[ec_addr[6:3]][ec_addr[2:0]] <= ec_wdata;
                16'h1???: pd_ram[ec_addr[11:0]] <= ec_wdata;
                default:;
                endcase
            end

            // Cache EEPROM read result
            if (eeprom_ack) begin
                eeprom_cache[{eeprom_addr_r[0][6:0], 1'b0}] <= eeprom_rdata[7:0];
                eeprom_cache[{eeprom_addr_r[0][6:0], 1'b1}] <= eeprom_rdata[15:8];
                eeprom_cache_valid <= 1;
                // Update status: clear busy bit
                eeprom_ctrl_r[1]  <= 8'h80; // eeprom loaded, no error
            end
        end
    end

    // ── PDI (SPI slave) port — process data RAM access ────────────────────
    always @(*) begin
        pdi_rdata = 8'hFF;
        if (pdi_rd && pdi_addr[15:12] == 4'h1)
            pdi_rdata = pd_ram[pdi_addr[11:0]];
    end

    always @(posedge clk) begin
        if (pdi_wr && pdi_addr[15:12] == 4'h1)
            pd_ram[pdi_addr[11:0]] <= pdi_wdata;
    end

    // Drive AL status output
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            al_status <= 4'h1; // INIT
        else
            al_status <= al_state_in;
    end

endmodule
