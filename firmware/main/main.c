/**
 * main.c — micro-ROS firmware for ESP32 DevKit V4
 *
 * Architecture:
 *   micro-ROS node runs on ESP32 with a custom SPI transport.
 *   The SPI transport talks to the Tang Nano 20K FPGA (EtherCAT slave).
 *   The FPGA tunnels micro-ROS frames over EtherCAT to the PC agent.
 *
 * Published topics:
 *   /esp32/status  (std_msgs/String)  — heartbeat + sensor data
 *
 * Subscribed topics:
 *   /esp32/cmd     (std_msgs/String)  — commands from ROS 2
 *
 * Build:
 *   cd firmware && idf.py build
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"

// micro-ROS ESP-IDF component
#include <rcl/rcl.h>
#include <rcl/error_handling.h>
#include <rclc/rclc.h>
#include <rclc/executor.h>
#include <std_msgs/msg/string.h>
#include <rmw_microros/rmw_microros.h>
#include <rmw_microros/custom_transport.h>

// Custom SPI transport
#include "spi_transport.h"

static const char *TAG = "micro_ros_main";

// ── Error handling macros ────────────────────────────────────────────────────
#define RCCHECK(fn) do { \
    rcl_ret_t rc = (fn); \
    if (rc != RCL_RET_OK) { \
        ESP_LOGE(TAG, "RCL error %d at %s:%d", (int)rc, __FILE__, __LINE__); \
        goto error; \
    } \
} while (0)

#define RCSOFTCHECK(fn) do { \
    rcl_ret_t rc = (fn); \
    if (rc != RCL_RET_OK) { \
        ESP_LOGW(TAG, "RCL soft error %d at %s:%d", (int)rc, __FILE__, __LINE__); \
    } \
} while (0)

// ── Global ROS entities ──────────────────────────────────────────────────────
static rcl_publisher_t   g_pub;
static rcl_subscription_t g_sub;
static std_msgs__msg__String g_pub_msg;
static std_msgs__msg__String g_sub_msg;
static char g_pub_buf[128];
static char g_sub_buf[128];
static uint32_t g_seq = 0;

// ── Subscription callback ────────────────────────────────────────────────────
static void subscription_callback(const void *msg_in)
{
    const std_msgs__msg__String *msg = (const std_msgs__msg__String *)msg_in;
    ESP_LOGI(TAG, "Received cmd: %.*s",
             (int)msg->data.size, msg->data.data);
}

// ── micro-ROS task ────────────────────────────────────────────────────────────
static void micro_ros_task(void *arg)
{
    // ── Transport setup ───────────────────────────────────────────────────
    static spi_transport_t spi_ctx = {0};

    // micro-ROS custom transport: register our SPI callbacks
    rmw_uros_set_custom_transport(
        true,               // framing = true (micro-XRCE-DDS serial framing)
        (void *)&spi_ctx,
        spi_transport_open,
        spi_transport_close,
        spi_transport_write,
        spi_transport_read
    );

    // ── Wait for agent ────────────────────────────────────────────────────
    ESP_LOGI(TAG, "Waiting for micro-ROS agent over EtherCAT SPI...");
    while (rmw_uros_ping_agent(500, 3) != RMW_RET_OK) {
        ESP_LOGW(TAG, "Agent not reachable, retrying...");
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
    ESP_LOGI(TAG, "Agent connected!");

    // ── Initialise RCL ───────────────────────────────────────────────────
    rcl_allocator_t allocator = rcl_get_default_allocator();
    rclc_support_t  support;
    RCCHECK(rclc_support_init(&support, 0, NULL, &allocator));

    rcl_node_t node;
    RCCHECK(rclc_node_init_default(&node, "esp32_ethercat_node", "", &support));

    // Publisher
    RCCHECK(rclc_publisher_init_default(
        &g_pub, &node,
        ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, String),
        "/esp32/status"));

    // Subscriber
    g_sub_msg.data.data     = g_sub_buf;
    g_sub_msg.data.capacity = sizeof(g_sub_buf);
    g_sub_msg.data.size     = 0;
    RCCHECK(rclc_subscription_init_default(
        &g_sub, &node,
        ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, String),
        "/esp32/cmd"));

    // Executor
    rclc_executor_t executor;
    RCCHECK(rclc_executor_init(&executor, &support.context, 1, &allocator));
    RCCHECK(rclc_executor_add_subscription(
        &executor, &g_sub, &g_sub_msg, &subscription_callback, ON_NEW_DATA));

    // ── Publish message buffer ────────────────────────────────────────────
    g_pub_msg.data.data     = g_pub_buf;
    g_pub_msg.data.capacity = sizeof(g_pub_buf);

    ESP_LOGI(TAG, "micro-ROS node started");

    // ── Spin loop ─────────────────────────────────────────────────────────
    while (true) {
        // Publish heartbeat
        snprintf(g_pub_buf, sizeof(g_pub_buf),
                 "ESP32 alive seq=%lu uptime=%lums",
                 (unsigned long)g_seq++,
                 (unsigned long)(esp_timer_get_time() / 1000));
        g_pub_msg.data.size = strlen(g_pub_buf);

        RCSOFTCHECK(rcl_publish(&g_pub, &g_pub_msg, NULL));

        // Spin executor (process incoming callbacks)
        RCSOFTCHECK(rclc_executor_spin_some(&executor, RCL_MS_TO_NS(10)));

        vTaskDelay(pdMS_TO_TICKS(100)); // 10 Hz publish rate
    }

error:
    ESP_LOGE(TAG, "micro-ROS task failed; restarting in 3 s...");
    vTaskDelay(pdMS_TO_TICKS(3000));
    esp_restart();
}

// ── App entry point ───────────────────────────────────────────────────────────
void app_main(void)
{
    ESP_LOGI(TAG, "micro-ROS EtherCAT node starting");
    ESP_LOGI(TAG, "  SPI CLK = %d Hz", SPI_TRANSPORT_CLK_HZ);
    ESP_LOGI(TAG, "  SCLK  = GPIO%d", SPI_TRANSPORT_SCLK_PIN);
    ESP_LOGI(TAG, "  MOSI  = GPIO%d", SPI_TRANSPORT_MOSI_PIN);
    ESP_LOGI(TAG, "  MISO  = GPIO%d", SPI_TRANSPORT_MISO_PIN);
    ESP_LOGI(TAG, "  CS    = GPIO%d", SPI_TRANSPORT_CS_PIN);
    ESP_LOGI(TAG, "  INT_N = GPIO%d", SPI_TRANSPORT_INT_PIN);

    xTaskCreate(micro_ros_task, "micro_ros_task",
                16 * 1024,  // 16 KiB stack
                NULL,
                5,          // priority
                NULL);
}
