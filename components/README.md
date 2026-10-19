# Components

Each directory here is a **git submodule**: a pinned commit of another repository, not a copy of
its files. If a directory looks empty, the submodules are not initialised yet:

```bash
git submodule update --init --recursive
```

| Directory | Repository | What it is |
|---|---|---|
| `Conv-ChArT/` | [KaelinGraf/Conv-ChArT](https://github.com/KaelinGraf/Conv-ChArT) | The perception model: synthetic training data, the detector and refiner networks, and the pose pipeline |
| `Conv-ChArT-Wireless-Inference/` | [KaelinGraf/Conv-ChArT-Wireless-Inference](https://github.com/KaelinGraf/Conv-ChArT-Wireless-Inference) | The laptop's inference node and dashboard, the shared ROS 2 interfaces and QoS, and the Pi's container |
| `holonomic_mpc_ekf/` | [KaelinGraf/holonomic_mpc_ekf](https://github.com/KaelinGraf/holonomic_mpc_ekf) | The docking EKF, supervisor and MPC, and the Pi's camera, IMU and serial-bridge nodes |
| `p4p_arduino/` | [adamwright103/p4p_arduino](https://github.com/adamwright103/p4p_arduino) | The Arduino Mega 2560 firmware: wheel mixing and calibration, watchdog, serial protocol |

The directories keep the repositories' own names on purpose. The Pi's `compose.yaml` mounts
`../holonomic_mpc_ekf` from beside `Conv-ChArT-Wireless-Inference`, and Arduino builds a sketch
only from a folder named after its `.ino` file, here `p4p_arduino`.

Commit in a component repository, not here: this repository only records *which* commit of each
component belongs to a given system state. To move a pin forward:

```bash
git submodule update --remote components/<name>
git commit -am "bump <name> to <short sha>"
```

Then update that component's commit link in the root README.
