# Known Limitations

## Hardware Limitations

### EtherCAT Slave Implementation
- **Store-and-forward only**: The ESC (`ethercat_slave.v`) buffers a complete
  Ethernet frame (up to 2048 bytes) before processing. This adds latency
  compared to a cut-through ESC (like the LAN9252 ASIC). Typical added latency:
  ~70 µs at 100 Mbps for a 1500-byte frame.

- **Single slave only**: Port 1 (DP83848 #2) is not actively forwarded in
  this implementation. Daisy-chaining multiple slaves requires adding
  Port 1 MAC forwarding logic in `ethercat_slave.v`.

- **No FMMU support**: Fieldbus Memory Management Unit (logical address mapping)
  is not implemented. Only fixed-address (FPRD/FPWR) and broadcast (BRD/BWR)
  commands are fully supported. LRD/LWR datagrams are silently passed without
  modification.

- **No Distributed Clocks (DC)**: EtherCAT Distributed Clock synchronisation
  (IEEE 1588 derivative) is not implemented. This limits synchronisation
  accuracy to EtherCAT cycle jitter (~1 ms typical).

- **Mailbox only — no PDO**: Cyclic Process Data Objects (PDOs) are not mapped.
  All micro-ROS data goes through the mailbox (VoE), which is not intended for
  high-rate cyclic data. Maximum sustainable rate is approximately 200 Hz with
  small payloads under ideal conditions.

- **ESC register subset**: Only the most critical ESC registers are implemented.
  Some optional registers (e.g. watchdog, DC registers, ECAT event request)
  return 0xFF. Some EtherCAT masters may complain about missing registers.

### SPI Transport
- **No DMA**: SPI transfers use `spi_device_polling_transmit` (blocking, no DMA).
  For payloads > 512 bytes at 8 MHz, this occupies the CPU for ~0.5 ms.

- **Single SPI transaction per micro-ROS frame**: Large XRCE-DDS frames are
  not fragmented automatically. Maximum payload is `SPI_TRANSPORT_MAX_FRAME`
  (1024 bytes). micro-ROS default MTU is 512 bytes, so this is rarely hit.

- **No SPI flow control**: If the FPGA SPI slave is not ready (TX_READY=0) and
  the retry timeout expires (10 ms), the write fails and micro-ROS retransmits.

### EEPROM / ESI
- **Vendor ID is a placeholder**: `0x0059414D` is not a registered EtherCAT
  vendor ID. Register at https://www.ethercat.org to obtain a real vendor ID
  before deploying in a product.

- **EEPROM write not supported**: The I2C master only reads the AT24C256.
  To update the ESI, program the EEPROM externally with an I2C programmer.

## Software Limitations

### micro-ROS
- **No Quality-of-Service control**: micro-ROS uses default QoS settings.
  Best-effort delivery is acceptable for telemetry; command topics should
  use reliable QoS (configurable in micro-ROS, not currently set).

- **Node lifecycle not implemented**: The ESP32 node does not use the ROS 2
  managed lifecycle. It restarts `esp_restart()` on fatal errors.

- **Single executor**: One rclc executor handles all subscriptions sequentially.
  For multiple high-rate subscriptions, use multiple executors or increase
  priority.

### Agent
- **No reconnection logic**: If the EtherCAT slave goes offline (power cycle,
  cable disconnect), the agent must be restarted manually. Automatic
  reconnection is not implemented.

- **Relay loop is a stub**: `soem_bridge.cpp` implements a demo relay loop
  that prints received bytes. Full integration with the micro-ros-agent library
  requires linking against `micro_ros_agent` and instantiating the agent with
  a custom transport callback.

- **Single slave only**: The bridge connects to slave 1 only. Multi-slave
  support requires modifications to `EtherCATTransport` and `SoemBridge`.

## Known Issues

| Issue | Severity | Workaround |
|-------|----------|-----------|
| Gowin nextpnr timing closure may fail at high utilisation | Low | Use Gowin IDE synthesiser which has better timing optimization |
| `spi_crc8` test vector for `{0x01,0x02,0x03}` is hardcoded | Low | Regenerate expected value with a reference implementation if polynomial is changed |
| AT24C256 word address is restricted to 14 bits | Low | Only the lower 14 bits of the word address are used; upper bits ignored |
| MDIO PHY address assumes PHY0=0, PHY1=1 | Medium | Verify strap resistors on DP83848 set PHYADDR to 0 and 1 respectively |

## Roadmap (Not Yet Implemented)

- [ ] Distributed Clocks (DC) for µs-level synchronisation
- [ ] FMMU for logical PDO addressing
- [ ] EoE (Ethernet over EtherCAT) for IP networking over EtherCAT
- [ ] Cut-through frame forwarding (lower latency)
- [ ] Watchdog timer (auto-revert to SAFE-OP on communication loss)
- [ ] CoE (CANopen over EtherCAT) for standard object dictionary
- [ ] Multi-slave daisy-chain (Port 1 forwarding)
- [ ] Agent automatic reconnection loop
- [ ] FPGA PLL for 100 MHz system clock (higher SPI and I2C rates)
- [ ] Hardware-in-the-loop (HIL) CI pipeline
