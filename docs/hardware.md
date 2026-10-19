# Hardware

The scale prototype the docking sequence runs on, and the full-scale module it stands in for.
Calibration constants change from run to run, so they are left to the component repositories
(`config.h` in p4p_arduino, `config/dock_demo.yaml` in holonomic_mpc_ekf, `cfg/cfg.yaml` in
Conv-ChArT-Wireless-Inference).

---

## Scale prototype

| Item | Part | Role |
|---|---|---|
| Computer | Raspberry Pi 5, ROS 2 Jazzy in Docker | Camera and IMU nodes, EKF, supervisor and MPC, serial bridge |
| Microcontroller | Arduino Mega 2560 running p4p_arduino | Wheel mixing with a deadband and gain per wheel and direction, uniform saturation, 400 ms watchdog, 50 Hz telemetry |
| Drive | Four 55 mm mecanum wheels on continuous-rotation servos, wheel centres 153 × 178 mm apart | Holonomic base; wheel speeds are open loop, with no encoders |
| Camera | Arducam OV2311 (Pivariety): 2 MP, global shutter, monochrome, on the CSI port, 135 mm ahead of the chassis centre | 640 × 480 images at 15 Hz |
| IMU | BNO085 (Adafruit 4754 breakout) on the Pi's I2C bus | Acceleration and yaw rate for the EKF, at 150 Hz |
| Inference host | Laptop with an NVIDIA RTX 4060, ONNX Runtime | Conv-ChArT poses, over the university Wi-Fi or a direct 5 GHz link |
| Coupler | The 1:4 printed coupler (45 mm wide) on a printed spring | Captures and latches; the spring stands in for the full-scale absorber |
| Target | Fixed printed stand: the mating 1:4 coupler below a 5 × 5 ChArUco board | Stationary docking target |
| Power | 7.4 V LiPo batteries for the servos and the Mega; a USB-C power bank for the Pi | |
| Size | 232 × 232 mm in plan, 215 mm high | |

### Docking board

A 5 × 5 ChArUco board (`DICT_5X5_50`, markers 0.7 of the square, 16 inner corners), printed on
A4 with 40.5 mm squares. The print is `docs/board_5x5_200mm_A4.pdf` in
Conv-ChArT-Wireless-Inference, made by its `tools/board_pdf.py`. Only the board centre's position
and the yaw of its normal are used, so it can be mounted at any rotation in its own plane. The
docked pose is calibrated by docking against the coupler and recording the poses
(`marker_m` and `marker_psi0_deg` in `config/dock_demo.yaml`).

---

## Wiring

| Link | Detail |
|---|---|
| Pi to Mega | USB serial, `/dev/ttyACM0`, 115200 baud 8N1 |
| Pi to BNO085 | I2C bus 1 (`/dev/i2c-1`): SDA on GPIO2 (pin 3), SCL on GPIO3 (pin 5), Vin from 5 V; address `0x4A`; bus at 400 kHz |
| Pi to camera | CSI ribbon on CAM/DISP 1, with `dtoverlay=arducam-pivariety` and `camera_auto_detect=0` |
| Mega to servos | Four servo channels on pins 46, 47, 50 and 51. Which wheel each channel drives is set in `config.h` (`PIN_*` and `DRIVE_CHANNELS_ROTATED`); the firmware README explains the mapping |

---

## Frames

| Frame | Definition |
|---|---|
| `base_link` | The chassis centre: x forward, y left, z up. A positive yaw rate turns the robot anticlockwise seen from above. |
| `pi_camera` | The camera's optical frame, placed from `base_link` by the mounting in `config/dock_demo.yaml` |
| `target` | Fixed to the docking target, with its origin at the docked position of the chassis centre and x pointing into the target, so the docked pose is (0, 0, 0) |

The EKF estimates the robot's x, y, heading and velocity in `target`. The drive command is a body
twist in `base_link` (`vx` forward, `vy` left, `wz` anticlockwise), which the firmware mixes to the
four wheels.

---

## Full-scale module (design)

| | |
|---|---|
| Envelope | 998 × 598 × 812 mm, the existing barrier units; about 600 kg working mass |
| Structure | Concrete barrier top on a steel base, with a coupler on each end face |
| Drive | Four mecanum wheels, with a 35 mm ride-height stroke that lowers the block onto the road when parked |
| Sensing | Fiducial board and camera for docking, IMU, LiDAR, and RTK-GNSS with dual-antenna heading for navigation across the deck |
| Coupler | Genderless, Scharfenberg-type: a cone, a recess, a bar and a spring-returned hook on each face; latches passively and releases from either side |
| Capture window | ±48 mm horizontal and ±20° in yaw, scaled from single-axis tests on 1:4 printed couplers |
| Docking impact | A hydraulic absorber behind the coupler pivot cuts the peak force of a 0.5 m/s docking fault from 226 kN to about 2.3 kN |
