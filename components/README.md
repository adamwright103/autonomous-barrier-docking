# Components

Each directory here is a **git submodule**: a pinned commit of another repository,
not a copy of its files. If a directory looks empty, the submodules are not
initialised yet:

```bash
git submodule update --init --recursive
```

| Directory | Repository | What it is |
|---|---|---|
| `conv-chart/` | [KaelinGraf/Conv-ChArT](https://github.com/KaelinGraf/Conv-ChArT) | The perception model: training, evaluation and the Stage-3 pose pipeline |
| `ros-stack/` | [KaelinGraf/Conv-ChArT-Wireless-Inference](https://github.com/KaelinGraf/Conv-ChArT-Wireless-Inference) | The ROS 2 runtime: camera driver, inference node, serial bridge, interfaces, QoS, Pi containers |
| `firmware/` | [adamwright103/p4p_arduino](https://github.com/adamwright103/p4p_arduino) | Arduino Mega 2560 firmware: drive mixing, IMU, watchdog, serial API |
| `control/` | — | **Not created yet.** EKF + MPC. It may become a fourth submodule here or additional packages inside `ros-stack`; see the root README's Status section. |

Commit in a component repository, not here — this repository only records *which*
commit of each component belongs to a given system state. To move a pin forward:

```bash
git submodule update --remote components/<name>
git commit -am "bump <name> to <short sha>"
```
