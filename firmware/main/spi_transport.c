/**
 * spi_transport.c — micro-ROS SPI transport implementation
 *
 * Implements uxrCustomTransport callbacks for micro-XRCE-DDS.
 * See spi_transport.h for protocol and wiring details.
 */
#include "spi_transport.h"

#include <string.h>
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

// micro-ROS custom transport API
#include <uxr/client/transport.h>

static const char *TAG = "spi_transport";

// ── CRC-8 (polynomial 0x07, init 0x00) ──────────────────────────────────────
uint8_t spi_crc8(const uint8_t *data, size_t len)
{
    uint8_t crc = 0x00;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++) {
            crc = (crc & 0x80) ? ((crc << 1) ^ 0x07) : (crc << 1);
        }
    }
    return crc;
}

// ── Low-level SPI transactions ──────────────────────────────────────────────
esp_err_t spi_cmd_status(spi_device_handle_t spi, uint8_t *flags)
{
    uint8_t tx[3] = {0x03, 0x00, 0x00};
    uint8_t rx[3] = {0x00, 0x00, 0x00};

    spi_transaction_t t = {
        .length    = 8 * 3,
        .tx_buffer = tx,
        .rx_buffer = rx,
    };
    esp_err_t err = spi_device_polling_transmit(spi, &t);
    if (err == ESP_OK && flags)
        *flags = rx[2]; // STATUS byte comes back in position of LEN_L
    return err;
}

esp_err_t spi_cmd_write(spi_device_handle_t spi, const uint8_t *data, size_t len)
{
    if (len == 0 || len > SPI_TRANSPORT_MAX_FRAME) return ESP_ERR_INVALID_ARG;

    static uint8_t tx[SPI_TRANSPORT_MAX_FRAME + 4];
    static uint8_t rx[SPI_TRANSPORT_MAX_FRAME + 4];

    tx[0] = 0x01;               // CMD=write
    tx[1] = (len >> 8) & 0xFF;  // LEN_H
    tx[2] = len & 0xFF;         // LEN_L
    memcpy(&tx[3], data, len);
    tx[3 + len] = spi_crc8(tx, 3 + len);

    spi_transaction_t t = {
        .length    = 8 * (3 + len + 1),
        .tx_buffer = tx,
        .rx_buffer = rx,
    };
    return spi_device_polling_transmit(spi, &t);
}

esp_err_t spi_cmd_read(spi_device_handle_t spi, uint8_t *data, size_t max_len,
                       size_t *read_len)
{
    // First query available length via status
    uint8_t flags = 0;
    esp_err_t err = spi_cmd_status(spi, &flags);
    if (err != ESP_OK) return err;
    if (!(flags & SPI_STATUS_RX_AVAIL)) {
        *read_len = 0;
        return ESP_OK;
    }

    // We don't know exact length — use max_len as read length
    // FPGA sends actual data (padded or truncated to our request size)
    size_t req = (max_len > SPI_TRANSPORT_MAX_FRAME) ?
                 SPI_TRANSPORT_MAX_FRAME : max_len;

    static uint8_t tx[SPI_TRANSPORT_MAX_FRAME + 4];
    static uint8_t rx[SPI_TRANSPORT_MAX_FRAME + 4];

    memset(tx, 0x00, sizeof(tx));
    tx[0] = 0x02;              // CMD=read
    tx[1] = (req >> 8) & 0xFF;
    tx[2] = req & 0xFF;

    spi_transaction_t t = {
        .length    = 8 * (3 + req + 1),
        .tx_buffer = tx,
        .rx_buffer = rx,
    };
    err = spi_device_polling_transmit(spi, &t);
    if (err != ESP_OK) return err;

    // rx[0..2] = echo of our header; rx[3..3+req-1] = payload; rx[3+req] = CRC
    uint8_t crc_recv = rx[3 + req];
    uint8_t crc_calc = spi_crc8(rx, 3 + req);

    if (crc_recv != crc_calc) {
        ESP_LOGW(TAG, "CRC mismatch: recv=0x%02X calc=0x%02X", crc_recv, crc_calc);
        *read_len = 0;
        return ESP_ERR_INVALID_CRC;
    }

    size_t actual = (req < max_len) ? req : max_len;
    memcpy(data, &rx[3], actual);
    *read_len = actual;
    return ESP_OK;
}

// ── micro-XRCE-DDS transport callbacks ─────────────────────────────────────
bool spi_transport_open(struct uxrCustomTransport *transport)
{
    spi_transport_t *ctx = (spi_transport_t *)transport->args;

    // Initialise SPI bus
    spi_bus_config_t bus = {
        .miso_io_num   = SPI_TRANSPORT_MISO_PIN,
        .mosi_io_num   = SPI_TRANSPORT_MOSI_PIN,
        .sclk_io_num   = SPI_TRANSPORT_SCLK_PIN,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = SPI_TRANSPORT_MAX_FRAME + 4,
    };
    esp_err_t err = spi_bus_initialize(SPI_TRANSPORT_HOST, &bus, SPI_DMA_CH_AUTO);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "SPI bus init failed: %s", esp_err_to_name(err));
        return false;
    }

    // Add device
    spi_device_interface_config_t dev = {
        .clock_speed_hz = SPI_TRANSPORT_CLK_HZ,
        .mode           = 0,        // CPOL=0, CPHA=0
        .spics_io_num   = SPI_TRANSPORT_CS_PIN,
        .queue_size     = 4,
        .pre_cb         = NULL,
        .post_cb        = NULL,
    };
    err = spi_bus_add_device(SPI_TRANSPORT_HOST, &dev, &ctx->spi);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "SPI add device failed: %s", esp_err_to_name(err));
        return false;
    }

    // Configure INT pin as input
    gpio_config_t int_cfg = {
        .pin_bit_mask = (1ULL << SPI_TRANSPORT_INT_PIN),
        .mode         = GPIO_MODE_INPUT,
        .pull_up_en   = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    gpio_config(&int_cfg);

    ESP_LOGI(TAG, "SPI transport opened (CLK=%d Hz)", SPI_TRANSPORT_CLK_HZ);
    return true;
}

bool spi_transport_close(struct uxrCustomTransport *transport)
{
    spi_transport_t *ctx = (spi_transport_t *)transport->args;
    if (ctx->spi) {
        spi_bus_remove_device(ctx->spi);
        ctx->spi = NULL;
    }
    spi_bus_free(SPI_TRANSPORT_HOST);
    ESP_LOGI(TAG, "SPI transport closed");
    return true;
}

size_t spi_transport_write(struct uxrCustomTransport *transport,
                           const uint8_t *buf, size_t len, uint8_t *err)
{
    spi_transport_t *ctx = (spi_transport_t *)transport->args;

    // Poll TX_READY (up to 10 ms)
    for (int retry = 0; retry < 100; retry++) {
        uint8_t flags = 0;
        if (spi_cmd_status(ctx->spi, &flags) == ESP_OK &&
            (flags & SPI_STATUS_TX_READY)) break;
        vTaskDelay(pdMS_TO_TICKS(1));
        if (retry == 99) {
            ESP_LOGW(TAG, "TX ready timeout");
            *err = 1;
            return 0;
        }
    }

    esp_err_t e = spi_cmd_write(ctx->spi, buf, len);
    if (e != ESP_OK) {
        ESP_LOGE(TAG, "spi_cmd_write failed: %s", esp_err_to_name(e));
        *err = 1;
        return 0;
    }
    *err = 0;
    return len;
}

size_t spi_transport_read(struct uxrCustomTransport *transport,
                          uint8_t *buf, size_t len, int timeout_ms, uint8_t *err)
{
    spi_transport_t *ctx = (spi_transport_t *)transport->args;
    TickType_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(timeout_ms);

    do {
        // Fast path: check INT_N pin (active-low)
        bool int_asserted = (gpio_get_level(SPI_TRANSPORT_INT_PIN) == 0);
        if (!int_asserted) {
            // Also check status register in case pin isn't wired
            uint8_t flags = 0;
            spi_cmd_status(ctx->spi, &flags);
            int_asserted = !!(flags & SPI_STATUS_RX_AVAIL);
        }

        if (int_asserted) {
            size_t actual = 0;
            esp_err_t e = spi_cmd_read(ctx->spi, buf, len, &actual);
            if (e == ESP_OK && actual > 0) {
                *err = 0;
                return actual;
            }
        }

        vTaskDelay(pdMS_TO_TICKS(1));
    } while (xTaskGetTickCount() < deadline);

    *err = 0;
    return 0; // timeout — no data available (not an error in micro-ROS)
}
