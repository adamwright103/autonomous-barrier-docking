# System architecture

Companion to the overview diagram in the [root README](../README.md). This page is
the authoritative description of what talks to what, over which transport, carrying
which message, at which rate.

---

## 1. Connection table

| From | To | Transport | Carries | Rate |
|---|---|---|---|---|
| camera | Conv-ChArT inference | WiFi | images | 10 Hz |
| Conv-ChArT inference | EKF | WiFi | pose | 10 Hz |
| EKF | MPC | wired (same host) | state | — |
| MPC | serial bridge | wired (same host) | velocity | — |
| serial bridge | firmware | wired (USB serial) | commands | — |
| firmware | serial bridge | wired (USB serial) | telemetry | 50 Hz |
| serial bridge | EKF | wired (same host) | telemetry | 50 Hz |
| firmware | mecanum base | wired | PWM | — |
| mecanum base | camera | physical motion | robot motion | continuous |

"Wired (same host)" means intra-host ROS 2 DDS on the Pi. "WiFi" means DDS across
the LAN between the Pi and the laptop, with `ROS_AUTOMATIC_DISCOVERY_RANGE=SUBNET`
and `network_mode: host` on the Pi container so discovery sees the real interface.

The last row is not a cable. It is the physical feedback path that makes the system
a closed loop: the base moves, the camera moves with it, the next image differs,
the next pose differs. Every other edge is an implementation detail; this one is
the plant.

---

## 2. ROS interface contract

This is the contract the planned control nodes must meet. Every message type below
already exists in `convchart_interfaces`.

### Published by `p4p_camera/camera_node` (Pi)

| Interface | Kind | Type | Notes |
|---|---|---|---|
| `image` | topic | `sensor_msgs/CompressedImage` | 640×480 mono8, PNG-encoded, 10 Hz. Format string `mono8; png compressed mono8`. The pose pipeline's own downscale is the identity at this size. |
| `camera_info` | topic | `sensor_msgs/CameraInfo` | Intrinsics, loaded from `camera_info_url`. |
| `image_full_res` | **service** | `convchart_interfaces/GetFullResImage` | One 1600×1200 mono PNG on demand. Encoding costs a quarter of the 10 Hz budget, so it is never on the stream path — calibration and single-shot diagnostics only. The request carries `max_age` so a client cannot silently calibrate on a stale frame. |

### Published by `convchart_ros/convchart` (GPU laptop)

| Interface | Kind | Type |
|---|---|---|
| `inference_result` | topic | `convchart_interfaces/RosInferenceResult` |

`RosInferenceResult` is built for a filter rather than for a viewer, and the EKF is
expected to use all of it:

| Field | Meaning for the filter |
|---|---|
| `pose` | `geometry_msgs/PoseWithCovariance` — the primary solution |
| `covariance_valid` | `false` means the covariance is a fallback, not measured. Do not trust it as a measurement weight. |
| `rms` | Reprojection RMS of the pose solve |
| `num_used` | How many of the 16 corners survived the lattice gate |
| `reason` | **Non-empty means the result is invalid.** Check this before anything else. |
| `ambiguous` | The planar-pose two-fold ambiguity was not resolved; `pose_alt` is the other branch, and the filter should compute surprise against both rather than picking one blind. |
| `pose_alt`, `covariance_valid_alt`, `rms_alt`, `num_used_alt` | The alternate branch, same semantics |

### Published by `p4p_serial_bridge/serial_bridge` (Pi)

| Interface | Kind | Type | Notes |
|---|---|---|---|
| `drive/telemetry` | topic | `convchart_interfaces/DriveTelemetry` | 50 Hz, one decoded CSV row from the Mega. |
| `imu/data` | topic | `sensor_msgs/Imu` | Optional, same cadence. |
| `drive/status` | topic | `convchart_interfaces/DriveStatus` | Bridge-side link and command health. Transient-local durability, so a late-starting node learns the current state immediately instead of waiting a tick. |
| `~/arm` | **service** | `std_srvs/SetBool` | Arm / disarm. |

### Subscribed by `p4p_serial_bridge/serial_bridge` (Pi)

| Interface | Kind | Type | Notes |
|---|---|---|---|
| `cmd_vel` | topic | `geometry_msgs/Twist` | **The MPC's output, and the system's single control input.** |

---

## 3. Two things a controller author must get right

**`DriveTelemetry.applied` is not `cmd_vel`.** It is the twist the chassis actually
acted on, after uniform saturation scaling. It reads zero while disarmed or while
the firmware watchdog is expired, and it is scaled down when the command exceeded
what the wheels can deliver (`saturated` set). A predictor must use `applied`, not
the request — otherwise "why isn't the robot doing what I said" becomes a guessing
game instead of a subtraction.

**`heading_rad` is continuous and never wraps.** It is unwrapped yaw, deliberately
not normalised into (−π, π], because the filter takes differences of it. Do not
normalise it. It is relative rather than absolute: the BNO085's game rotation
vector uses no magnetometer, so it drifts slowly and has no north.

`mega_t_ms` is `millis()` at the last IMU sample as the Mega sees it — quantised to
the BNO's 100 Hz report rate, so slightly older than `header.stamp`, and it wraps
every 49.7 days. Use it to order samples, never as a ROS time.

---

## 4. Serial link

115200 baud 8N1 over USB, line-oriented, full duplex — telemetry keeps streaming
while commands arrive.

**Pi → Mega**

| Command | Effect |
|---|---|
| `E` | Arm. Zeroes any stored velocity, so a fresh `V` is always required. |
| `S` | Disarm and zero immediately — the software e-stop. |
| `V,<Vx>,<Vy>,<Wz>` | Set body twist, held until the next `V`, the watchdog, or `S`. |

Blank lines and lines starting with `#` are ignored and are not counted as errors,
so a captured telemetry log can be replayed at the robot without tripping the error
counter.

**Mega → Pi**, 50 Hz CSV:

```
t_ms,heading_rad,yaw_rate_dps,vx,vy,wz,flags,resets,bad
```

Lines starting with `#` are human-readable status, not data; the Pi-side parser
skips them. `flags` is a bitfield: `1 ARMED`, `2 TIMEOUT`, `4 SAT`. `flags=1` is
normal driving, `flags=3` is armed but starved of commands, `flags=0` is disarmed.

The firmware sends `yaw_rate` in deg/s on the wire; the bridge republishes it as
REP-103 rad/s in `DriveTelemetry`.

**Body frame** — right-handed, and it matches the IMU heading sign: `Vx` forward,
`Vy` left, `Wz` anticlockwise from above. A positive `Wz` makes `heading_rad`
increase. Verified by rotation test rather than assumed.

---

## 5. Link-health states

`DriveStatus.state` is the one place the distinction below is visible, and a
supervisor should act on it:

| State | Meaning |
|---|---|
| `NO_LINK` (0) | Port not open: missing device, no permission, or an I/O error dropped it. The bridge retries. |
| `NO_TELEMETRY` (1) | Port open, nothing arriving. Either the Mega is still booting (it resets on DTR when the port opens) or it has gone quiet mid-run. |
| `DISARMED` (2) | Streaming but not armed. The firmware parses velocity in this state and acts on none of it. |
| `STALLED` (3) | Armed with no fresh `cmd_vel`; the bridge sends zeros on the controller's behalf to keep the watchdog fed. |
| `RUNNING` (4) | Armed and acting on a fresh `cmd_vel`. A commanded zero is `RUNNING`, not `STALLED` — the controller is alive and asking the robot to hold still. |

`STALLED` versus a commanded zero is the one failure that the firmware telemetry
cannot show: both look like `applied = 0` while armed.

---

## 6. QoS

`convchart_qos` is the single place both ends of the wireless link agree on QoS —
image, inference-result, command, telemetry and status profiles live there rather
than being restated per node. Changing a profile in one node and not the other is
the classic way to get silent non-delivery across a lossy link, so neither end
declares its own.

---

## 7. Deployment

The Pi side runs in Docker (`compose.yaml` in the ROS stack repo), ROS 2 Jazzy on
`linux/arm64`:

- `network_mode: host` — DDS discovery with the laptop needs the real LAN interface.
- `CAP_SYS_NICE` and `rtprio: 99` — `SCHED_FIFO` for the fixed-rate filter loop.
- The Arduino is passed through as a device, which means **compose will not start
  the container if the Arduino is absent**. There are two services for this reason:
  `pi` for the default case and `pi-camera` (profile `camera`) for the camera
  bring-up, which also needs `/dev/dma_heap`, the media controller, and
  `/run/udev` mounted read-only — libcamera enumerates through udev and, without
  it, reports no cameras at all while saying nothing about udev.

Camera bring-up also needs `camera_auto_detect=0` and `dtoverlay=arducam-pivariety`
in the host's `config.txt`.

See `docker/README.md` in the ROS stack repository for the full environment.
