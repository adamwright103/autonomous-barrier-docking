# System architecture

Companion to the diagram in the [root README](../README.md): what runs where, what talks to what
and at which rate, and how the system stops safely. It describes the pinned commits; each
component's own README has the detail.

---

## 1. Machines and nodes

| Machine | Executable (package) | Repository | Job |
|---|---|---|---|
| Raspberry Pi 5 | `camera_node` (`p4p_camera`) | holonomic_mpc_ekf | Arducam OV2311: 640 × 480 mono PNG stream at 15 Hz, full-resolution stills on request |
| Raspberry Pi 5 | `imu_node` (`p4p_imu`) | holonomic_mpc_ekf | BNO085 on the Pi's I2C bus at 150 Hz |
| Raspberry Pi 5 | `ekf_node` (`dock_control`) | holonomic_mpc_ekf | Docking EKF, stepped by every IMU sample, corrected by every pose |
| Raspberry Pi 5 | `mpc_node` (`dock_control`) | holonomic_mpc_ekf | Supervisor and MPC, one tick every 50 ms |
| Raspberry Pi 5 | `serial_bridge` (`p4p_serial_bridge`) | holonomic_mpc_ekf | Owns the USB serial link to the Mega |
| Raspberry Pi 5 | `dock_logger` (`dock_control`) | holonomic_mpc_ekf | Records one bag per docking attempt, without the camera stream |
| GPU laptop | `inference` (`convchart_ros`) | Conv-ChArT-Wireless-Inference | Conv-ChArT on ONNX Runtime: each frame in, one pose out |
| GPU laptop | `image_relay`, `telemetry` (`convchart_ros`) | Conv-ChArT-Wireless-Inference | One copy of each frame across the Wi-Fi; the live dashboard and its arming controls |
| Arduino Mega 2560 | firmware | p4p_arduino | Wheel mixing, calibration, watchdog, 50 Hz telemetry |

`p4p_bringup`'s `pi.launch.py` starts the Pi's nodes in order: the camera and the IMU, then the
serial bridge once `imu/data` streams, then the EKF, the MPC, the static transforms and the logger
once `drive/status` shows the Mega streaming. With `rt:=true`, the default, the camera, the EKF and
the MPC each run on their own core at `SCHED_FIFO` priority 50, and everything else shares core 0.
On the laptop, `convchart.launch.py task:=infer` starts the inference node with the dashboard, and
the image relay whenever more than one node reads the camera.

---

## 2. Topics and services

| Interface | Type | From | To | Rate |
|---|---|---|---|---|
| `image` | `sensor_msgs/CompressedImage` | camera | inference, dashboard (through the relay) | 15 Hz, Wi-Fi |
| `camera_info` | `sensor_msgs/CameraInfo` | camera | | 15 Hz |
| `image_full_res` (service) | `convchart_interfaces/GetFullResImage` | camera | calibration GUI | on request |
| `inference_result` | `convchart_interfaces/RosInferenceResult` | inference | EKF, dashboard | 15 Hz, Wi-Fi |
| `imu/data` | `sensor_msgs/Imu` | IMU | EKF | 150 Hz |
| `dock/estimate` | `dock_msgs/DockEstimate` | EKF | MPC, dashboard | every IMU sample |
| `fiducial/fix` | `dock_msgs/FiducialFix` | EKF | MPC, dashboard | every pose |
| `cmd_vel` | `geometry_msgs/Twist` | MPC | serial bridge, EKF, dashboard | 20 Hz |
| `dock/stage` | `dock_msgs/DockStage` | MPC | EKF, dashboard, logger | 20 Hz |
| `dock/mpc_info` | `dock_msgs/MpcInfo` | MPC | dashboard | 20 Hz |
| `drive/status` | `convchart_interfaces/DriveStatus` | serial bridge | MPC, dashboard | periodic and on every change |
| `drive/telemetry` | `convchart_interfaces/DriveTelemetry` | serial bridge | logger | 50 Hz |
| `serial_bridge/arm` (service) | `std_srvs/SetBool` | serial bridge | dashboard, operator | |
| `dock/arm` (service) | `std_srvs/SetBool` | MPC | dashboard, operator | |
| TF `target` → `base_link` | | EKF | | 20 Hz |

`cmd_vel` is the system's single control input. The EKF also reads it to tell when the robot is
meant to be still, and holds the velocity at zero then. It reads `dock/stage` to start
estimating when docking is armed (with 2 s of IMU zeroing, so keep the robot still) and to idle when
it is disarmed.

---

## 3. The perception link

- **Frames.** 640 × 480 mono8 PNG at 15 Hz, about 110 kB a frame. The OV2311's 1600 × 1200 window
  is downscaled by exactly 2.5 on the Pi, which is also the detector's input size. PNG, never
  JPEG: the refiner reads sub-pixel offsets, which compression artefacts would bias.
- **Timing.** Each frame is stamped when the Pi reads it, and the pose comes back with that stamp.
  The EKF rolls back to that time, applies the pose there and replays the steps since, so a late
  pose leaves the state an on-time one would have. Over the trials the delay from stamp to pose
  had a median of 120 ms over the university Wi-Fi, with spikes to 1.87 s.
- **Noise.** The inference node attaches a measured, range-dependent covariance to each pose
  rather than the pipeline's own analytic one, and flags it invalid outside the range it was
  fitted over. The EKF carries it through the camera mounting into the filter, with the heading's
  standard deviation floored at 1°.
- **Ambiguity.** A planar board seen nearly head-on fits two poses almost equally well. The
  pipeline flags this (`ambiguous`, with the second solution in `pose_alt`), and the EKF fuses
  whichever is closer to its estimate. A gate on the normalised innovation rejects gross errors.
- **QoS and DDS.** The image and pose profiles, the two that cross the Wi-Fi, are defined once in
  `convchart_qos`, so the two ends cannot disagree. Both machines run CycloneDDS on the same
  `ROS_DOMAIN_ID` (42 by default) with the profiles in Conv-ChArT-Wireless-Inference's
  `docker/ros/`: `cyclonedds.xml` (multicast discovery, unicast data) or `cyclonedds_peers.xml`
  (unicast only, for networks that block multicast).

---

## 4. Safety interlocks

From the outermost layer in:

1. **Nothing arms itself.** The launch files arm nothing. The operator arms the drive
   (`serial_bridge/arm`) and then the docking (`dock/arm`), from the dashboard or by service call.
2. **Supervisor.** The robot holds once the last accepted pose is 0.5 s old, or after two missed
   MPC ticks (a solver fallback or a blown 25 ms budget). It aborts after 2 s of holding, once the
   estimate is more than 100 ms old, if the drive is disarmed or stops responding, or once a
   position standard deviation exceeds 50 mm. Once docked it stops commanding, so the controller
   never pushes against the coupler.
3. **Serial bridge.** It resends the newest `cmd_vel` to the Mega at 50 Hz and sends zeros once
   that command is older than 100 ms (`cmd_timeout`). `drive/status` tells a stalled controller
   (`STALLED`) from a deliberate hold (`RUNNING` with a zero command), which the firmware's
   telemetry alone cannot show.
4. **Firmware.** The Mega boots disarmed, and arming zeroes any stored velocity, so the robot cannot
   set off on a stale command. Without a velocity command for 400 ms it stops the wheels and flags
   `TIMEOUT`. `S` disarms at once, the software e-stop.

---

## 5. Serial link

USB at 115200 baud, 8N1, line-oriented and full duplex. The firmware README has the full
specification.

| Pi → Mega | Effect |
|---|---|
| `E` | Arm, zeroing any stored velocity |
| `S` | Disarm and stop at once |
| `V,<vx>,<vy>,<wz>` | Body velocity in m/s and rad/s, held until the next `V`, the watchdog or `S` |

Mega → Pi: lines starting with `#` are status text; every other line is a 50 Hz CSV row:

```
t_ms,heading_rad,yaw_rate_dps,vx,vy,wz,flags,resets,bad,req_vx,req_vy,req_wz,us_lf,us_rf,us_lr,us_rr
```

`vx,vy,wz` is the velocity the firmware is applying (zero while disarmed or timed out, scaled
down when saturated), `req_*` the last command as received, and `us_*` the pulse written to each
servo channel. `flags` is a bitfield: `1 ARMED`, `2 TIMEOUT`, `4 SAT`. The heading and gyro columns
have no sensor behind them on this robot, since the IMU moved to the Pi.

---

## 6. Deployment

- **Pi.** ROS 2 Jazzy in Docker (`linux/arm64`), built from Conv-ChArT-Wireless-Inference's
  `compose.yaml`: host networking for DDS discovery, `SYS_NICE` and `rtprio 99` for the real-time
  cores, and the Arduino (`/dev/ttyACM0`) and the I2C bus (`/dev/i2c-1`) passed through. The
  container will not start without either device. The `pi-camera` service (profile `camera`) adds
  the camera devices. holonomic_mpc_ekf is mounted at `/controller_ws`, from `../holonomic_mpc_ekf`
  unless `CONTROLLER_WS` says otherwise.
- **Pi host.** `camera_auto_detect=0`, `dtoverlay=arducam-pivariety`, `dtparam=i2c_arm=on` and
  `dtparam=i2c_arm_baudrate=400000` in `config.txt`; `docker/host-setup-pi.sh` installs the service
  that configures the camera pipeline at boot.
- **Laptop.** ROS 2 Jazzy and ONNX Runtime on the GPU, with `convchart_interfaces`,
  `convchart_qos` and `convchart_ros` built, and `dock_msgs` for the dashboard's estimator and
  controller panels. Both machines must build the same interface definitions.
