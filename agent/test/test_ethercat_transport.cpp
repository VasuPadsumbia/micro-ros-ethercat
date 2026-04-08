/**
 * test_ethercat_transport.cpp — Google Test unit tests for EtherCATTransport
 *
 * Uses mock_soem.h to stub out SOEM so tests run without hardware.
 *
 * Build with -DBUILD_TESTS=ON:
 *   cmake -B build -DBUILD_TESTS=ON -DSOEM_DIR=soem
 *   cmake --build build
 *   ctest --test-dir build --output-on-failure
 */
#include "mock_soem.h"        // Must come before ethercat_transport.h
#include "ethercat_transport.h"

#include <gtest/gtest.h>
#include <cstring>

using namespace micro_ros_ethercat;

// ── Test fixture ─────────────────────────────────────────────────────────────
class EtherCATTransportTest : public ::testing::Test {
protected:
    void SetUp() override {
        mock_soem_reset();
        transport_ = std::make_unique<EtherCATTransport>("eth0_mock", 1);
    }

    void TearDown() override {
        if (transport_->is_open())
            transport_->close();
    }

    std::unique_ptr<EtherCATTransport> transport_;
};

// ── open/close tests ──────────────────────────────────────────────────────────
TEST_F(EtherCATTransportTest, OpenSucceeds)
{
    EXPECT_TRUE(transport_->open());
    EXPECT_TRUE(transport_->is_open());
}

TEST_F(EtherCATTransportTest, OpenFailsWhenNoInterface)
{
    mock_ec_init_ok = false;
    EXPECT_FALSE(transport_->open());
    EXPECT_FALSE(transport_->is_open());
}

TEST_F(EtherCATTransportTest, OpenFailsWhenNoSlaves)
{
    mock_ec_slaves_found = 0;
    EXPECT_FALSE(transport_->open());
}

TEST_F(EtherCATTransportTest, CloseAfterOpen)
{
    ASSERT_TRUE(transport_->open());
    transport_->close();
    EXPECT_FALSE(transport_->is_open());
}

TEST_F(EtherCATTransportTest, DoubleCloseIsNoop)
{
    ASSERT_TRUE(transport_->open());
    transport_->close();
    transport_->close(); // second close must not crash
    EXPECT_FALSE(transport_->is_open());
}

// ── station address ───────────────────────────────────────────────────────────
TEST_F(EtherCATTransportTest, StationAddressAfterOpen)
{
    ASSERT_TRUE(transport_->open());
    EXPECT_EQ(0x0001, transport_->station_address());
}

TEST_F(EtherCATTransportTest, StationAddressBeforeOpenIsZero)
{
    EXPECT_EQ(0, transport_->station_address());
}

// ── write() tests ─────────────────────────────────────────────────────────────
TEST_F(EtherCATTransportTest, WriteSuccess)
{
    ASSERT_TRUE(transport_->open());
    uint8_t payload[] = {0xDE, 0xAD, 0xBE, 0xEF};
    ssize_t n = transport_->write(payload, sizeof(payload));
    EXPECT_EQ(static_cast<ssize_t>(sizeof(payload)), n);
    EXPECT_EQ(1, mock_mbx_send_calls);
}

TEST_F(EtherCATTransportTest, WriteFailsWhenNotOpen)
{
    uint8_t payload[] = {0x01};
    EXPECT_EQ(-1, transport_->write(payload, sizeof(payload)));
}

TEST_F(EtherCATTransportTest, WriteFailsOnZeroLength)
{
    ASSERT_TRUE(transport_->open());
    EXPECT_EQ(-1, transport_->write(nullptr, 0));
}

TEST_F(EtherCATTransportTest, WriteVoEMailboxHeader)
{
    ASSERT_TRUE(transport_->open());
    uint8_t payload[] = {0x01, 0x02, 0x03};
    transport_->write(payload, sizeof(payload));

    // Verify sent buffer has correct mailbox header
    const MbxHeader *hdr = reinterpret_cast<const MbxHeader *>(mock_mbx_sent_buf);
    EXPECT_EQ(sizeof(payload), hdr->length);
    EXPECT_EQ(VOE_TYPE, hdr->type);
    EXPECT_EQ(0, hdr->address);

    // Verify payload follows header
    EXPECT_EQ(0x01, mock_mbx_sent_buf[MAILBOX_HEADER + 0]);
    EXPECT_EQ(0x02, mock_mbx_sent_buf[MAILBOX_HEADER + 1]);
    EXPECT_EQ(0x03, mock_mbx_sent_buf[MAILBOX_HEADER + 2]);
}

// ── read() tests ──────────────────────────────────────────────────────────────
TEST_F(EtherCATTransportTest, ReadReturnsZeroOnTimeout)
{
    ASSERT_TRUE(transport_->open());
    uint8_t buf[64];
    ssize_t n = transport_->read(buf, sizeof(buf), 10 /*ms*/);
    EXPECT_EQ(0, n); // timeout, not error
}

TEST_F(EtherCATTransportTest, ReadReceivesMailboxPayload)
{
    ASSERT_TRUE(transport_->open());

    // Build a VoE mailbox frame to queue
    uint8_t frame[MAILBOX_SIZE] = {};
    MbxHeader *hdr = reinterpret_cast<MbxHeader *>(frame);
    uint8_t payload[] = {0xCA, 0xFE, 0xBA, 0xBE};
    hdr->length  = sizeof(payload);
    hdr->type    = VOE_TYPE;
    hdr->address = 0;
    memcpy(frame + MAILBOX_HEADER, payload, sizeof(payload));
    mock_soem_queue_recv(frame, MAILBOX_HEADER + sizeof(payload));

    uint8_t buf[64] = {};
    ssize_t n = transport_->read(buf, sizeof(buf), 100 /*ms*/);
    EXPECT_EQ(static_cast<ssize_t>(sizeof(payload)), n);
    EXPECT_EQ(0xCA, buf[0]);
    EXPECT_EQ(0xFE, buf[1]);
    EXPECT_EQ(0xBA, buf[2]);
    EXPECT_EQ(0xBE, buf[3]);
}

TEST_F(EtherCATTransportTest, ReadFailsWhenNotOpen)
{
    uint8_t buf[64];
    EXPECT_EQ(-1, transport_->read(buf, sizeof(buf), 100));
}

TEST_F(EtherCATTransportTest, ReadTruncatesToMaxLen)
{
    ASSERT_TRUE(transport_->open());

    uint8_t frame[MAILBOX_SIZE] = {};
    MbxHeader *hdr = reinterpret_cast<MbxHeader *>(frame);
    hdr->length = 10;
    hdr->type   = VOE_TYPE;
    memset(frame + MAILBOX_HEADER, 0xFF, 10);
    mock_soem_queue_recv(frame, MAILBOX_HEADER + 10);

    uint8_t buf[4] = {};
    ssize_t n = transport_->read(buf, 4, 100);
    EXPECT_EQ(4, n); // truncated to max_len
}

// ── error string test ─────────────────────────────────────────────────────────
TEST_F(EtherCATTransportTest, LastErrorReturnsString)
{
    mock_ec_init_ok = false;
    transport_->open();
    EXPECT_NE(nullptr, transport_->last_error());
    EXPECT_GT(strlen(transport_->last_error()), 0u);
}
