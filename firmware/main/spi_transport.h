/**
 * spi_transport.h — micro-ROS custom transport over SPI to Tang Nano 20K
 *
 * Implements the uxrCustomTransport interface (micro-XRCE-DDS).
 * The SPI slave on the FPGA bridges SPI to the EtherCAT mailbox.
 *
 * SPI frame format (both directions):
 *   Byte 0   : Command
 *              0x01 = Write mailbox (ESP32 → FPGA)
 *              0x02 = Read mailbox  (FPGA  → ESP32)
 *              0x03 = Status query
 *   Byte 1-2 : Payload length (big-endian)
 *   Byte 3…N : Payload
 *   Byte N+1 : CRC-8 (poly 0x07, init 0x00)
 *
 * Wiring (ESP32 DevKit V4 → Tang Nano 20K):
 *   GPIO14 (SCLK) → FPGA spi_sck
 *   GPIO13 (MOSI) → FPGA spi_mosi
 *   GPIO12 (MISO) → FPGA spi_miso
 *   GPIO15 (CS)   → FPGA spi_cs_n
 *   GPIO4  (INT)  ← FPGA spi_int_n  (active-low interrupt)
 */
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "driver/spi_master.h"
#include "driver/gpio.h"

// ── Pin definitions ─────────────────────────────────────────────────────────
#define SPI_TRANSPORT_HOST      SPI2_HOST
#define SPI_TRANSPORT_SCLK_PIN  GPIO_NUM_14
#define SPI_TRANSPORT_MOSI_PIN  GPIO_NUM_13
#define SPI_TRANSPORT_MISO_PIN  GPIO_NUM_12
#define SPI_TRANSPORT_CS_PIN    GPIO_NUM_15
#define SPI_TRANSPORT_INT_PIN   GPIO_NUM_4   // active-low interrupt from FPGA

// ── SPI parameters ──────────────────────────────────────────────────────────
#define SPI_TRANSPORT_CLK_HZ    8000000      // 8 MHz
#define SPI_TRANSPORT_MAX_FRAME 1024         // max payload bytes per transaction

// ── Status flags (returned by CMD_STATUS) ───────────────────────────────────
#define SPI_STATUS_RX_AVAIL     (1 << 0)    // FPGA has data for us
#define SPI_STATUS_TX_READY     (1 << 1)    // FPGA ready to accept

// ── Transport context (passed via uxrCustomTransport.args) ──────────────────
typedef struct {
    spi_device_handle_t spi;    // ESP-IDF SPI device handle
    uint8_t             tx_buf[SPI_TRANSPORT_MAX_FRAME + 4]; // +4 for header/CRC
    uint8_t             rx_buf[SPI_TRANSPORT_MAX_FRAME + 4];
} spi_transport_t;

// ── micro-XRCE-DDS transport callbacks ─────────────────────────────────────
/**
 * Open the SPI transport: initialise SPI bus and device handle.
 * Called once by micro-ROS on startup.
 */
bool spi_transport_open(struct uxrCustomTransport *transport);

/**
 * Close the SPI transport and free resources.
 */
bool spi_transport_close(struct uxrCustomTransport *transport);

/**
 * Write `len` bytes from `buf` to the FPGA mailbox via SPI.
 * Returns number of bytes actually written.
 */
size_t spi_transport_write(struct uxrCustomTransport *transport,
                           const uint8_t *buf, size_t len, uint8_t *err);

/**
 * Read up to `len` bytes from the FPGA mailbox into `buf`.
 * Blocks up to `timeout` milliseconds.
 * Returns number of bytes actually read.
 */
size_t spi_transport_read(struct uxrCustomTransport *transport,
                          uint8_t *buf, size_t len, int timeout, uint8_t *err);

// ── Low-level helpers (also used by unit tests) ─────────────────────────────
uint8_t spi_crc8(const uint8_t *data, size_t len);
esp_err_t spi_cmd_status(spi_device_handle_t spi, uint8_t *flags);
esp_err_t spi_cmd_write(spi_device_handle_t spi, const uint8_t *data, size_t len);
esp_err_t spi_cmd_read(spi_device_handle_t spi, uint8_t *data, size_t len,
                       size_t *read_len);
