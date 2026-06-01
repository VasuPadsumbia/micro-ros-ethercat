// ============================================================================
// top.v — Tang Nano 20K top-level: micro-ROS EtherCAT Slave (single-port)
//
// Instantiates:
//   mdio_ctrl      — PHY0 initialisation
//   mii_mac        — MII MAC for PHY0 (Port 0, master-facing)
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
// Pin assignments: see constraints/tang_nano_20k.cst
// Configuration  : see rtl/slave_config.vh (generated from config.in)
// ============================================================================
`include "slave_config.vh"

module top (
    // ── System clock / reset ──────────────────────────────────────────────
    input  wire        clk_27,
    input  wire        btn_rst_n,    // active-low reset button

    // ── PHY0 MII — LEFT header (high-speed data) ──────────────────────────
    input  wire        p0_tx_clk,    // 25 MHz TX clock FROM PHY → FPGA
    output wire [3:0]  p0_txd,       // nibble data FPGA → PHY
    output wire        p0_tx_en,     // transmit enable

    input  wire        p0_rx_clk,    // 25 MHz RX clock FROM PHY → FPGA
    input  wire [3:0]  p0_rxd,       // received nibble PHY → FPGA
    input  wire        p0_rx_dv,     // receive data valid
    input  wire        p0_rx_er,     // receive error

    // ── PHY0 management — RIGHT header ────────────────────────────────────
    output wire        p0_mdc,       // MDIO clock (≤ 2.5 MHz)
    inout  wire        p0_mdio,      // MDIO data (open-drain)
    output wire        p0_rst_n,     // active-low PHY reset

    // ── SPI slave (to ESP32) — RIGHT header ───────────────────────────────
    input  wire        spi_sck,
    input  wire        spi_mosi,
    output wire        spi_miso,
    input  wire        spi_cs_n,
    output wire        spi_int_n,    // active-low interrupt to ESP32

    // ── I2C master (to AT24C256 EEPROM) — RIGHT header ────────────────────
    inout  wire        i2c_scl,      // open-drain (4.7 kΩ pull-up required)
    inout  wire        i2c_sda,      // open-drain (4.7 kΩ pull-up required)

    // ── Onboard status LEDs (active-low, no external wiring) ──────────────
    output wire [5:0]  led_n
);

    // ── Reset synchroniser (2-FF) ─────────────────────────────────────────
    reg [3:0] rst_sync;
    wire      rst_n = rst_sync[3];

    always @(posedge clk_27 or negedge btn_rst_n) begin
        if (!btn_rst_n)
            rst_sync <= 4'b0000;
        else
            rst_sync <= {rst_sync[2:0], 1'b1};
    end

    // Hold PHY in reset until FPGA is stable (~2 µs @ 27 MHz for 64 cycles)
    reg [5:0] phy_rst_cnt;
    reg       phy_rst_done;

    always @(posedge clk_27 or negedge rst_n) begin
        if (!rst_n) begin
            phy_rst_cnt  <= 6'd0;
            phy_rst_done <= 1'b0;
        end else if (!phy_rst_done) begin
            if (&phy_rst_cnt)
                phy_rst_done <= 1'b1;
            else
                phy_rst_cnt <= phy_rst_cnt + 1'b1;
        end
    end

    assign p0_rst_n = phy_rst_done;

    // ── MDIO controller ───────────────────────────────────────────────────
    wire mdio_init_done;
    wire mdio0_oe, mdio0_out;

    mdio_ctrl #(.MDC_DIV(`MDC_DIV)) mdio_u (
        .clk        (clk_27),
        .rst_n      (rst_n),
        .init_done  (mdio_init_done),
        .mdc        (p0_mdc),
        .mdio_oe    (mdio0_oe),
        .mdio_out   (mdio0_out),
        .mdio_in    (p0_mdio)
    );

    // MDIO open-drain: drive 0 via tristate buffer, release for 1
    assign p0_mdio = mdio0_oe ? (mdio0_out ? 1'bz : 1'b0) : 1'bz;

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
        .tx_er    (),            // not driven — PHY ignores when low
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

    wire [511:0] sm_cfg;

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
        .MBX_OUT_BASE(`MBX_OUT_BASE),
        .MBX_OUT_SIZE(`MBX_OUT_SIZE),
        .MBX_IN_BASE (`MBX_IN_BASE),
        .MBX_IN_SIZE (`MBX_IN_SIZE)
    ) mbox (
        .clk           (clk_27),
        .rst_n         (rst_n),
        .ec_addr       (esc_addr),
        .ec_wdata      (esc_wdata),
        .ec_rdata      (),
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

    reg         eeprom_read_pending;
    reg [15:0]  eeprom_word_addr_r;
    reg [15:0]  eeprom_buf;
    reg         eeprom_ack_r;
    reg [1:0]   eeprom_byte_cnt;

    assign eeprom_rdata = eeprom_buf;
    assign eeprom_ack   = eeprom_ack_r;

    always @(posedge clk_27 or negedge rst_n) begin
        if (!rst_n) begin
            eeprom_read_pending <= 1'b0;
            eeprom_word_addr_r  <= 16'd0;
            eeprom_buf          <= 16'd0;
            eeprom_ack_r        <= 1'b0;
            eeprom_byte_cnt     <= 2'd0;
        end else begin
            eeprom_ack_r <= 1'b0;
            if (eeprom_req && !i2c_busy) begin
                eeprom_read_pending <= 1'b1;
                eeprom_word_addr_r  <= eeprom_word_addr;
                eeprom_byte_cnt     <= 2'd0;
            end
            if (i2c_rdata_valid) begin
                if (eeprom_byte_cnt == 2'd0)
                    eeprom_buf[7:0]  <= i2c_rdata;
                else begin
                    eeprom_buf[15:8] <= i2c_rdata;
                    eeprom_ack_r     <= 1'b1;
                    eeprom_read_pending <= 1'b0;
                end
                eeprom_byte_cnt <= eeprom_byte_cnt + 2'd1;
            end
        end
    end

    i2c_master #(.CLK_DIV(`I2C_CLK_DIV)) i2c (
        .clk        (clk_27),
        .rst_n      (rst_n),
        .start      (eeprom_req),
        .dev_addr   (`EEPROM_I2C_ADDR),
        .word_addr  ({1'b0, eeprom_word_addr[14:0]}), // byte addr = word×2
        .rd_len     (8'd2),
        .busy       (i2c_busy),
        .rdata_valid(i2c_rdata_valid),
        .rdata      (i2c_rdata),
        .error      (),
        .scl_oe     (scl_oe),
        .scl_in     (i2c_scl),
        .sda_oe     (sda_oe),
        .sda_in     (i2c_sda)
    );

    // Open-drain I2C: pull low via OE, float for high
    assign i2c_scl = scl_oe ? 1'b0 : 1'bz;
    assign i2c_sda = sda_oe ? 1'b0 : 1'bz;

    // ── LED status (active-low) ───────────────────────────────────────────
    // LED0: FPGA powered (always on)
    // LED1: PHY MDIO init complete
    // LED2: EtherCAT in OPERATIONAL state
    // LED3: Mailbox data pending for ESP32 (SM0 written by master)
    // LED4: Mailbox data ready for master (SM1 written by ESP32)
    // LED5: spare / error indicator
    assign led_n[0] = 1'b0;
    assign led_n[1] = ~mdio_init_done;
    assign led_n[2] = ~(al_state == 4'h8);
    assign led_n[3] = ~mbox_out_ready;
    assign led_n[4] = ~mbox_in_ready;
    assign led_n[5] = 1'b1;

endmodule
