/**
 * main.cpp — micro-ROS EtherCAT agent entry point
 *
 * Usage:
 *   sudo ./micro_ros_ethercat_agent --iface eth0 [--slave 1]
 *
 * Requires root (or CAP_NET_RAW) for raw socket access via SOEM.
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <getopt.h>
#include <unistd.h>

#include "soem_bridge.h"

static void print_usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s --iface <eth_interface> [--slave <n>]\n"
            "\n"
            "  --iface   Ethernet interface for EtherCAT (e.g. eth0)\n"
            "  --slave   EtherCAT slave number (default: 1)\n"
            "\n"
            "Requires root or CAP_NET_RAW for SOEM raw socket.\n",
            prog);
}

int main(int argc, char **argv)
{
    if (geteuid() != 0) {
        fprintf(stderr,
                "Warning: not running as root. "
                "SOEM requires raw socket access.\n"
                "Run with: sudo %s ...\n\n", argv[0]);
    }

    // ── Argument parsing ─────────────────────────────────────────────────
    const char *iface    = nullptr;
    int         slave_n  = 1;

    static const struct option long_opts[] = {
        {"iface",  required_argument, nullptr, 'i'},
        {"slave",  required_argument, nullptr, 's'},
        {"help",   no_argument,       nullptr, 'h'},
        {nullptr,  0,                 nullptr,  0 },
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "i:s:h", long_opts, nullptr)) != -1) {
        switch (opt) {
        case 'i': iface   = optarg;          break;
        case 's': slave_n = atoi(optarg);    break;
        case 'h': print_usage(argv[0]);      return 0;
        default:  print_usage(argv[0]);      return 1;
        }
    }

    if (!iface) {
        fprintf(stderr, "Error: --iface is required\n\n");
        print_usage(argv[0]);
        return 1;
    }

    if (slave_n < 1) {
        fprintf(stderr, "Error: --slave must be >= 1\n");
        return 1;
    }

    printf("═══════════════════════════════════════════════════════\n");
    printf(" micro-ROS EtherCAT Agent\n");
    printf(" Interface : %s\n", iface);
    printf(" Slave     : %d\n", slave_n);
    printf("═══════════════════════════════════════════════════════\n\n");

    // ── Run bridge ───────────────────────────────────────────────────────
    micro_ros_ethercat::SoemBridge bridge(iface, slave_n);
    int rc = bridge.run();

    printf("Agent exited with code %d\n", rc);
    return rc;
}
