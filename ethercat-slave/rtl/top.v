// ============================================================================
// top.v — Tang Nano 20K top-level: micro-ROS EtherCAT Slave
//
// Instantiates:
//   mdio_ctrl      — PHY initialisation (Port 0 only)
//   mii_mac        — MII MAC for PHY0 (Port 0)
//   ethercat_slave — EtherCAT datagram processing
//   esc_registers  — ESC register file + process data RAM
//   mailbox        — SM0/SM1 mailbox buffers
//   spi_slave      — SPI slave bridge to ESP32
//   i2c_master     — AT24C256 EEPROM for ESI data
//
// Clock domains:
//   clk_27  — 27 MHz XTAL (Tang Nano 20K)
//   tx_clk0 — 25 MHz from PHY0 TX_CLK (MII TX)
//   rx_clk0 — 25 MHz from PHY0 RX_CLK (MII RX)
//
// Single-slave topology: Port 1 removed (no downstream slave).
// Pin assignments: see constraints/tang_nano_20k.cst
// ============================================================================
module top (
    // ── System clock / reset ──────────────────────────────────────────
    input  wire        clk_27,
    input  wire        btn_rst_n,   // active-low reset button (Tang Nano User BTN)

    // ── PHY0 MII (Port 0 — connects to EtherCAT master) ──────────────
    input  wire        p0_tx_clk,
    output wire [3:0]  p0_txd,
    output wire        p0_tx_en,
    output wire        p0_tx_er,

    input  wire        p0_rx_clk,
    input  wire [3:0]  p0_rxd,
    input  wire        p0_rx_dv,
    input  wire        p0_rx_er,

    output wire        p0_mdc,
    inout  wire        p0_mdio,
    output wire        p0_rst_n,

    // ── SPI slave (to ESP32) ──────────────────────────────────────────
    input  wire        spi_sck,
    input  wire        spi_mosi,
    output wire        spi_miso,
    input  wire        spi_cs_n,
    output wire        spi_int_n,   // active-low interrupt to ESP32

    // ── I2C (to AT24C256 EEPROM) ─────────────────────────────────────
    output wire        i2c_scl,
    inout  wire        i2c_sda,

    // ── Status LEDs (Tang Nano 20K: 6 LEDs, active-low) ─────────────
    output wire [5:0]  led_n
);

    // ── Reset synchroniser ────────────────────────────────────────────────
    reg [3:0] rst_sync;
    wire      rst_n = rst_sync[3];

    always @(posedge clk_27 or negedge btn_rst_n) begin
        if (!btn_rst_n)
            rst_sync <= 4'b0000;
        else
            rst_sync <= {rst_sync[2:0], 1'b1};
    end

    // Hold PHYs in reset for first 32 cycles, then release
    reg [5:0] phy_rst_cnt;
    reg       phy_rst_done;
    always @(posedge clk_27 or negedge rst_n) begin
        if (!rst_n) begin
            phy_rst_cnt  <= 0;
            phy_rst_done <= 0;
        end else if (!phy_rst_done) begin
            if (&phy_rst_cnt) phy_rst_done <= 1;
            else phy_rst_cnt <= phy_rst_cnt + 1;
        end
    end

    assign p0_rst_n = phy_rst_done;
    assign p1_rst_n = phy_rst_done;

    // ── MDIO controller ───────────────────────────────────────────────────
    wire mdio_init_done;
    wire mdio0_oe, mdio0_out;
    wire mdio1_oe, mdio1_out;

    mdio_ctrl mdio_u (
        .clk        (clk_27),
        .rst_n      (rst_n),
        .init_done  (mdio_init_done),
        .mdc0       (p0_mdc),
        .mdio0_oe   (mdio0_oe),
        .mdio0_out  (mdio0_out),
        .mdio0_in   (p0_mdio),
        .mdc1       (p1_mdc),
        .mdio1_oe   (mdio1_oe),
        .mdio1_out  (mdio1_out),
        .mdio1_in   (p1_mdio)
    );

    // MDIO open-drain: drive low via OE, release for high
    assign p0_mdio = mdio0_oe ? (mdio0_out ? 1'bz : 1'b0) : 1'bz;
    assign p1_mdio = mdio1_oe ? (mdio1_out ? 1'bz : 1'b0) : 1'bz;

    // ── MII MAC Port 0 ────────────────────────────────────────────────────
    wire [7:0]  p0_rx_data;
    wire        p0_rx_valid, p0_rx_last, p0_rx_fcs_ok, p0_rx_ready;
    wire [7:0]  p0_tx_data_w;
    wire        p0_tx_valid_w, p0_tx_last_w, p0_tx_sof_w, p0_tx_ready_w;

    mii_mac mac0 (
        .sys_clk  (clk_27),
        .rst_n    (rst_n),
        .tx_clk   (p0_tx_clk),
        .txd      (p0_txd),
        .tx_en    (p0_tx_en),
        .tx_er    (p0_tx_er),
        .rx_clk   (p0_rx_clk),
        .rxd      (p0_rxd),
        .rx_dv    (p0_rx_dv),
        .rx_er    (p0_rx_er),
        .tx_data  (p0_tx_data_w),
        .tx_valid (p0_tx_valid_w),
        .tx_ready (p0_tx_ready_w),
        .tx_last  (p0_tx_last_w),
        .tx_sof   (p0_tx_sof_w),
        .rx_data  (p0_rx_data),
        .rx_valid (p0_rx_valid),
        .rx_last  (p0_rx_last),
        .rx_fcs_ok(p0_rx_fcs_ok),
        .rx_ready (p0_rx_ready)
    );

    // Port 1 MAC (instantiated but only connected when Port 1 open)
    // For single-slave use, Port 1 can be left unconnected.
    // txd/tx_en driven to 0, rx ignored.
    assign p1_txd   = 4'h0;
    assign p1_tx_en = 1'b0;
    assign p1_tx_er = 1'b0;

    // ── ESC register file ─────────────────────────────────────────────────
    wire [15:0] esc_addr;
    wire [7:0]  esc_wdata, esc_rdata;
    wire        esc_wr, esc_rd;

    wire [15:0] station_addr;
    wire [3:0]  al_control;
    wire [3:0]  al_state;
    wire [15:0] al_status_code;
    wire [7:0]  dl_ctrl;
    wire [7:0]  dl_status;

    wire [15:0] eeprom_word_addr;
    wire        eeprom_req;
    wire [15:0] eeprom_rdata;
    wire        eeprom_ack;

    wire [511:0] sm_cfg; // 8 SMs × 64 bits, flat packed — Verilog-2001 compatible

    esc_registers esc_regs (
        .clk              (clk_27),
        .rst_n            (rst_n),
        .ec_addr          (esc_addr),
        .ec_wdata         (esc_wdata),
        .ec_rdata         (esc_rdata),
        .ec_wr            (esc_wr),
        .ec_rd            (esc_rd),
        .pdi_addr         (16'h0000),
        .pdi_wdata        (8'h00),
        .pdi_rdata        (),
        .pdi_wr           (1'b0),
        .pdi_rd           (1'b0),
        .eeprom_word_addr (eeprom_word_addr),
        .eeprom_req       (eeprom_req),
        .eeprom_rdata     (eeprom_rdata),
        .eeprom_ack       (eeprom_ack),
        .al_control       (al_control),
        .al_status        (),
        .al_state_in      (al_state),
        .al_status_code_in(al_status_code),
        .station_addr     (station_addr),
        .dl_ctrl          (dl_ctrl),
        .dl_status_in     (dl_status),
        .sm_cfg           (sm_cfg)
    );

    // ── EtherCAT slave core ───────────────────────────────────────────────
    wire sm0_written, sm1_read;

    ethercat_slave ec_slave (
        .clk          (clk_27),
        .rst_n        (rst_n),
        .p0_rx_data   (p0_rx_data),
        .p0_rx_valid  (p0_rx_valid),
        .p0_rx_last   (p0_rx_last),
        .p0_rx_fcs_ok (p0_rx_fcs_ok),
        .p0_rx_ready  (p0_rx_ready),
        .p0_tx_data   (p0_tx_data_w),
        .p0_tx_valid  (p0_tx_valid_w),
        .p0_tx_last   (p0_tx_last_w),
        .p0_tx_sof    (p0_tx_sof_w),
        .p0_tx_ready  (p0_tx_ready_w),
        .esc_addr     (esc_addr),
        .esc_wdata    (esc_wdata),
        .esc_rdata    (esc_rdata),
        .esc_wr       (esc_wr),
        .esc_rd       (esc_rd),
        .station_addr (station_addr),
        .al_control   (al_control),
        .al_state     (al_state),
        .al_status_code(al_status_code),
        .sm0_written  (sm0_written),
        .sm1_read     (sm1_read),
        .dl_status    (dl_status)
    );

    // ── Mailbox controller ────────────────────────────────────────────────
    wire [7:0]  spi_rx_data;
    wire        spi_rx_valid, spi_rx_ack;
    wire [7:0]  spi_tx_data_mbox;
    wire        spi_tx_valid_mbox, spi_tx_start_mbox;
    wire [15:0] spi_tx_len_mbox;
    wire        mbox_out_ready, mbox_in_ready;

    mailbox #(
        .MBX_OUT_BASE(16'h1000),
        .MBX_OUT_SIZE(16'd256),
        .MBX_IN_BASE (16'h1100),
        .MBX_IN_SIZE (16'd256)
    ) mbox (
        .clk           (clk_27),
        .rst_n         (rst_n),
        .ec_addr       (esc_addr),
        .ec_wdata      (esc_wdata),
        .ec_rdata      (),        // mbox rdata merged in esc_registers
        .ec_wr         (esc_wr),
        .ec_rd         (esc_rd),
        .sm0_written   (sm0_written),
        .sm1_read      (sm1_read),
        .spi_rx_data   (spi_rx_data),
        .spi_rx_valid  (spi_rx_valid),
        .spi_rx_ack    (spi_rx_ack),
        .spi_tx_data   (spi_tx_data_mbox),
        .spi_tx_valid  (spi_tx_valid_mbox),
        .spi_tx_start  (spi_tx_start_mbox),
        .spi_tx_len    (spi_tx_len_mbox),
        .mbox_out_ready(mbox_out_ready),
        .mbox_in_ready (mbox_in_ready),
        .int_n         (spi_int_n)
    );

    // ── SPI slave ─────────────────────────────────────────────────────────
    spi_slave spi (
        .sys_clk        (clk_27),
        .rst_n          (rst_n),
        .spi_sck        (spi_sck),
        .spi_mosi       (spi_mosi),
        .spi_miso       (spi_miso),
        .spi_cs_n       (spi_cs_n),
        .mbox_wr_valid  (spi_tx_valid_mbox),
        .mbox_wr_data   (spi_tx_data_mbox),
        .mbox_wr_len    (spi_tx_len_mbox),
        .mbox_wr_start  (spi_tx_start_mbox),
        .mbox_rd_req    (spi_rx_ack),
        .mbox_rd_data   (spi_rx_data),
        .mbox_rd_valid  (spi_rx_valid),
        .mbox_rd_empty  (~mbox_out_ready),
        .status_rx_avail(mbox_out_ready),
        .status_tx_ready(~mbox_in_ready)
    );

    // ── I2C master + AT24C256 EEPROM ─────────────────────────────────────
    wire scl_oe, sda_oe, sda_out;
    wire i2c_busy, i2c_rdata_valid;
    wire [7:0] i2c_rdata;

    // EEPROM SII read controller (reads 16-bit words on request)
    reg         eeprom_read_pending;
    reg [15:0]  eeprom_word_addr_r;
    reg [15:0]  eeprom_buf;
    reg         eeprom_ack_r;
    reg [1:0]   eeprom_byte_cnt;

    assign eeprom_rdata = eeprom_buf;
    assign eeprom_ack   = eeprom_ack_r;

    always @(posedge clk_27 or negedge rst_n) begin
        if (!rst_n) begin
            eeprom_read_pending <= 0;
            eeprom_word_addr_r  <= 0;
            eeprom_buf          <= 0;
            eeprom_ack_r        <= 0;
            eeprom_byte_cnt     <= 0;
        end else begin
            eeprom_ack_r <= 0;
            if (eeprom_req && !i2c_busy) begin
                eeprom_read_pending <= 1;
                eeprom_word_addr_r  <= eeprom_word_addr;
                eeprom_byte_cnt     <= 0;
            end
            if (i2c_rdata_valid) begin
                if (eeprom_byte_cnt == 0)
                    eeprom_buf[7:0] <= i2c_rdata;
                else begin
                    eeprom_buf[15:8] <= i2c_rdata;
                    eeprom_ack_r     <= 1;
                    eeprom_read_pending <= 0;
                end
                eeprom_byte_cnt <= eeprom_byte_cnt + 1;
            end
        end
    end

    i2c_master #(.CLK_DIV(67)) i2c (
        .clk        (clk_27),
        .rst_n      (rst_n),
        .start      (eeprom_req),
        .dev_addr   (7'h50),          // AT24C256: A2A1A0=000 → 0x50
        .word_addr  ({1'b0, eeprom_word_addr[14:0]}), // byte address = word×2
        .rd_len     (8'd2),            // read 2 bytes per word
        .busy       (i2c_busy),
        .rdata_valid(i2c_rdata_valid),
        .rdata      (i2c_rdata),
        .error      (),
        .scl_oe     (scl_oe),
        .scl_in     (i2c_scl),
        .sda_oe     (sda_oe),
        .sda_in     (i2c_sda)
    );

    // Open-drain I2C outputs
    assign i2c_scl = scl_oe ? 1'b0 : 1'bz;
    assign i2c_sda = sda_oe ? 1'b0 : 1'bz;

    // ── LED status ────────────────────────────────────────────────────────
    // LED0: power on
    // LED1: MDIO init done
    // LED2: EtherCAT operational (OP state)
    // LED3: mailbox out ready (data for ESP32)
    // LED4: mailbox in ready  (data for master)
    // LED5: unused
    assign led_n[0] = 1'b0;               // always on
    assign led_n[1] = ~mdio_init_done;
    assign led_n[2] = ~(al_state == 4'h8);
    assign led_n[3] = ~mbox_out_ready;
    assign led_n[4] = ~mbox_in_ready;
    assign led_n[5] = 1'b1;               // off

endmodule
