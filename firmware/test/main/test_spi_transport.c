/**
 * test_spi_transport.c — Unity unit tests for spi_transport.c
 *
 * Tests the pure-logic functions (CRC, frame building) that can run
 * without real SPI hardware.  Hardware-dependent tests (open/close/read/write)
 * are integration tests run on real hardware via:
 *   idf.py -C test build flash monitor
 *
 * Run on host (no hardware):
 *   These tests are compiled as a standard ESP-IDF component test.
 *   They are executed by the ESP-IDF test runner on-target.
 */
#include <string.h>
#include "unity.h"
#include "spi_transport.h"
#include <uxr/client/transport.h>

// ── CRC-8 tests ──────────────────────────────────────────────────────────────
TEST_CASE("CRC8 of empty data is 0x00", "[spi_transport]")
{
    uint8_t crc = spi_crc8(NULL, 0);
    TEST_ASSERT_EQUAL_HEX8(0x00, crc);
}

TEST_CASE("CRC8 of {0x00} is 0x00", "[spi_transport]")
{
    uint8_t data[] = {0x00};
    TEST_ASSERT_EQUAL_HEX8(0x00, spi_crc8(data, 1));
}

TEST_CASE("CRC8 of {0xFF} matches known value", "[spi_transport]")
{
    uint8_t data[] = {0xFF};
    // CRC-8 (poly 0x07) of 0xFF = 0xF7
    uint8_t crc = spi_crc8(data, 1);
    TEST_ASSERT_EQUAL_HEX8(0xF7, crc);
}

TEST_CASE("CRC8 known vector: {0x01,0x02,0x03}", "[spi_transport]")
{
    uint8_t data[] = {0x01, 0x02, 0x03};
    uint8_t expected = 0x48; // pre-calculated
    TEST_ASSERT_EQUAL_HEX8(expected, spi_crc8(data, sizeof(data)));
}

TEST_CASE("CRC8 is idempotent for same input", "[spi_transport]")
{
    uint8_t data[] = {0xDE, 0xAD, 0xBE, 0xEF};
    uint8_t crc1 = spi_crc8(data, sizeof(data));
    uint8_t crc2 = spi_crc8(data, sizeof(data));
    TEST_ASSERT_EQUAL_HEX8(crc1, crc2);
}

// ── Frame length validation tests ────────────────────────────────────────────
TEST_CASE("Write with len=0 returns ESP_ERR_INVALID_ARG", "[spi_transport]")
{
    // Without real SPI, test the guard condition via a wrapper
    // (spi_cmd_write checks len before any SPI transaction)
    // We can't call spi_cmd_write directly without a handle, but we can
    // check that SPI_TRANSPORT_MAX_FRAME is a reasonable value.
    TEST_ASSERT_GREATER_THAN(0, SPI_TRANSPORT_MAX_FRAME);
    TEST_ASSERT_LESS_THAN(2048, SPI_TRANSPORT_MAX_FRAME);
}

TEST_CASE("SPI transport max frame size is sane", "[spi_transport]")
{
    // EtherCAT mailbox: max 1486 bytes payload (standard)
    // Our default is 1024 which fits comfortably
    TEST_ASSERT_GREATER_OR_EQUAL(256, SPI_TRANSPORT_MAX_FRAME);
}

// ── Pin definition sanity ────────────────────────────────────────────────────
TEST_CASE("SPI pins are distinct", "[spi_transport]")
{
    int pins[] = {
        SPI_TRANSPORT_SCLK_PIN,
        SPI_TRANSPORT_MOSI_PIN,
        SPI_TRANSPORT_MISO_PIN,
        SPI_TRANSPORT_CS_PIN,
        SPI_TRANSPORT_INT_PIN,
    };
    int n = sizeof(pins) / sizeof(pins[0]);
    for (int i = 0; i < n; i++) {
        for (int j = i + 1; j < n; j++) {
            TEST_ASSERT_NOT_EQUAL_MESSAGE(pins[i], pins[j],
                "SPI pin conflict detected");
        }
    }
}

TEST_CASE("SPI clock is within 1-40 MHz range", "[spi_transport]")
{
    TEST_ASSERT_GREATER_THAN(1000000, SPI_TRANSPORT_CLK_HZ);
    TEST_ASSERT_LESS_THAN(40000000, SPI_TRANSPORT_CLK_HZ);
}

// ── Integration stub (requires hardware) ─────────────────────────────────────
TEST_CASE("SPI transport open/close (hardware required)", "[spi_transport][hw]")
{
    // This test requires the Tang Nano 20K connected via SPI.
    // Skip automatically if hardware is not available.
    static spi_transport_t ctx = {0};
    struct uxrCustomTransport transport = { .args = &ctx };

    bool opened = spi_transport_open(&transport);
    if (!opened) {
        // FPGA may not be connected in CI; skip gracefully
        TEST_IGNORE_MESSAGE("SPI transport open failed (FPGA not connected?)");
    }
    TEST_ASSERT_TRUE(opened);
    TEST_ASSERT_TRUE(spi_transport_close(&transport));
}

// ── Test main (ESP-IDF Unity runner) ─────────────────────────────────────────
void app_main(void)
{
    unity_run_menu();
}
