# Hardware

The platform the software in this project runs on. Everything below is taken from
the component repositories. What the code does not record — geometry, power, and
the mechanical design — is listed at the end and is available on request.

---

## Compute

| | |
|---|---|
| On-robot computer | Raspberry Pi 5, ROS 2 Jazzy (in Docker, `linux/arm64`) |
| Off-board inference | GPU laptop, ROS 2 Jazzy, ONNX Runtime |
| Microcontroller | Arduino Mega 2560 — FQBN `arduino:avr:mega:cpu=atmega2560` |
| Pi ↔ laptop | WiFi, same subnet, `ROS_DOMAIN_ID` 42 by default, `rmw_cyclonedds_cpp` |
| Pi ↔ Mega | USB serial, 115200 baud 8N1 (`/dev/ttyACM0` by default) |

The split is deliberate: only the perception network needs a discrete GPU, and it
is the one thing that can tolerate a dropped packet. The filter, the controller and
the watchdog all stay on hardware that is physically attached to the robot.

---

## Sensing

### Camera — Arducam OV2311

| | |
|---|---|
| Interface | CSI, via `libcamera` / Picamera2 (Arducam pivariety fork) |
| Stream mode | 640×480 mono8, PNG-encoded, 10 Hz — what the pose pipeline consumes |
| Full-resolution mode | 1600×1200 mono, on demand via the `image_full_res` service |
| Host requirement | `camera_auto_detect=0` and `dtoverlay=arducam-pivariety` in `config.txt` |

A global-shutter monochrome sensor suits the task: the pose estimator works on a
single intensity channel, and a global shutter avoids rolling-shutter skew on the
corners while the base is moving.

The driver has three backends — `picam` (the real sensor), `v4l2`, and `mock` for
development without hardware.

### IMU — BNO085

| | |
|---|---|
| Bus | I2C, address `0x4A` |
| Pins | SDA = 20, SCL = 21 (Mega) |
| Report rate | 100 Hz, resampled into the 50 Hz telemetry row |
| Mode | Game rotation vector — **no magnetometer** |

Consequences of the no-magnetometer choice: heading is relative, not absolute, and
it drifts slowly. It is reported as continuous unwrapped yaw that never wraps at
±π, because the filter differentiates it. The firmware also counts spontaneous
BNO085 resets and ships that count in every telemetry row; it should stay at zero.

---

## Drive

| | |
|---|---|
| Configuration | 4× mecanum wheels |
| Actuators | Continuous-rotation servos |
| Pins (Mega) | 46 = left-front, 47 = left-rear, 50 = right-rear, 51 = right-front |
| Control | Body-twist command mixed to four wheel speeds on the Mega |
| Saturation | Uniform scaling — if a command exceeds wheel capability all three axes scale by the same factor, preserving commanded direction, and `SAT` is flagged |

Uniform scaling rather than per-wheel clipping matters for a docking manoeuvre:
clipping one wheel changes the direction of travel, which is exactly the thing a
docking controller cannot tolerate. Scaling all three axes together keeps the
heading of the motion and loses only its magnitude.

**Body frame** (right-handed, matching the IMU heading sign):

| Axis | Positive direction |
|---|---|
| `Vx` | forward, m/s |
| `Vy` | left, m/s |
| `Wz` | anticlockwise viewed from above, rad/s |

---

## Fiducial target

| | |
|---|---|
| Pattern | 5×5 ChArUco board, 16 inner corners |
| Detection | All 16 corners detected and identified in a single network pass, across an 8× apparent-scale range |
| Pose solve | Undistort → RANSAC lattice fit → recovery → `SOLVEPNP_IPPE` |
| Illumination | Active, with lit/dark differencing in the deployment domain |
| Physical square size | recorded in CAD — available on request |
| Mounting on the barrier | recorded in CAD — available on request |

---

## Held outside this repository

The following are recorded in the project's CAD models and written report, which
are internal and not published here:

- Chassis dimensions and wheel geometry — needed for the mecanum mixing constants
  and for the MPC model
- Battery, power distribution, and nominal voltages
- Barrier segment specification and docking coupler geometry
- Active illumination hardware
- Mechanical drawings and CAD
- Risk assessment

Available on request: open an issue, or get in touch with
[@adamwright103](https://github.com/adamwright103).

---

## Safety interlocks

Three independent layers in the firmware, in order of severity:

1. **Boots disarmed.** Power-on and reset both land in a state where no velocity
   command can move the robot until an explicit `E`. Arming zeroes stored velocity,
   so the robot cannot lurch off on a stale command.
2. **400 ms command watchdog.** No velocity command inside the window and the
   firmware zeroes the wheels and raises `TIMEOUT`. `V,0,0,0` is a hold that keeps
   feeding the watchdog; silence is not a hold.
3. **Software e-stop.** `S` disarms and zeroes immediately; velocity commands are
   ignored until the next `E`.

The serial bridge mirrors `want_armed` against the firmware's reported `armed`. If
the two disagree for longer than one telemetry period, an arm or disarm was lost on
the wire — and nothing else in the system will say so.
