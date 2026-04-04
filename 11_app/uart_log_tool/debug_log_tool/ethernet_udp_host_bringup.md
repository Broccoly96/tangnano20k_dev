# Ethernet UDP Host Bring-Up Note

Date: 2026-03-25.
Target: tangmega60k Ethernet UDP control and log path.

## Purpose

This note prevents a repeated host-side NIC mix-up during
Ethernet UDP bring-up.

The FPGA may be healthy while the host is simply sending packets
through the wrong interface.

## Symptom

Typical failure pattern:

- `eth_udp_reg_tool.py ping` times out
- `192.168.100.2` does not answer on the expected NIC
- another host NIC is actually connected to the board

## Rule

Before assuming FPGA-side failure, always identify the host NIC first.

Use standard host networking commands:

```bash
ip route get 192.168.100.2
ip addr
```

Confirm:

- which NIC the route selects
- which source IPv4 the kernel chooses
- whether that NIC actually has the `192.168.100.x/24` address

Use that IPv4 as `--bind-ip` in later commands.

## Minimum Bring-Up Order

1. Check host NIC selection.

```bash
ip route get 192.168.100.2
ip addr
```

2. Confirm control-plane reachability.

```bash
python3 11_app/debug_log_tool/eth_udp_reg_tool.py \
  --ip 192.168.100.2 \
  --bind-ip 192.168.100.1 \
  ping
```

3. Confirm Ethernet control state.

```bash
python3 11_app/debug_log_tool/eth_udp_reg_tool.py \
  --ip 192.168.100.2 \
  --bind-ip 192.168.100.1 \
  read NET_STATUS
```

Expected decode:

- `active_valid=1`
- `ctrl_plane_enabled=1`

4. Enable UDP log stream if packet log observation is needed.

```bash
python3 11_app/debug_log_tool/eth_udp_reg_tool.py \
  --ip 192.168.100.2 \
  --bind-ip 192.168.100.1 \
  write LOG_STREAM_CONTROL 0x1
```

5. Observe UDP log packets on `50001`.

```bash
python3 11_app/debug_log_tool/uart_log_tool.py \
  --transport udp \
  --udp-bind-ip 0.0.0.0 \
  --udp-bind-port 50001
```

## Notes

- `LOG_STREAM_CONTROL` defaults to `0x0` after reset.
- Therefore:
  control UDP can work while UDP log still appears silent.
- A timeout does not immediately mean the FPGA is broken.
  First compare:
  - `ip route get 192.168.100.2` result
  - actual cable connection
  - `--bind-ip`

## Observed Example

On 2026-03-25:

- `enp4s0` was first checked by mistake
- FPGA traffic was actually on `enp6s0`
- after binding `192.168.100.1/24` on `enp6s0`,
  `ping` returned `status=OK`
- after `write LOG_STREAM_CONTROL 0x1`,
  UDP log packets appeared on `50001/udp`
