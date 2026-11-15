# 项目架构梳理

> 本文档基于源码梳理项目的开发框架与程序组织结构，供二次开发参考。若与源码不一致，以源码为准。

## 一、项目定位

一个**跨平台、轻量级的 ROS1/ROS2 移动机器人人机交互（HMI）软件**：用 Qt5 图形界面显示机器人地图、位姿、激光、路径、电量、图像等，并提供手动控制、导航目标、重定位、地图/拓扑编辑等交互能力。核心设计目标是**通信层与界面层解耦**——同一套 UI 代码，构建时按环境变量自动选择 ROS1/ROS2/ROSBridge 通信通道。

## 二、技术栈

| 类别 | 技术 |
|------|------|
| 语言/标准 | C++17（C 标准 C99） |
| GUI | Qt5（Core / Widgets / Svg / Concurrent）+ QGraphicsView 体系 |
| 构建 | CMake 3.5+，三方库走 `FetchContent`（Gitee 镜像可加速） |
| 跨版本 ROS | rclcpp(ROS2) / ros(ROS1) / rosbridge2cpp(WebSocket) |
| 布局 | Qt-Advanced-Docking-System (ADS) 4.4.0 停靠面板 |
| 数学 | Eigen3 |
| 图像 | OpenCV + cv_bridge |
| 地图/图像加载 | SDL2 + SDL_image、yaml-cpp |
| 配置 | nlohmann/json（`config.json`） |
| 日志 | easylogging++（封装为 `LOG_INFO/ERROR/WARN`） |
| 测试 | GoogleTest（`AddTest()`，`BUILD_WITH_TEST`） |

## 三、目录与模块组织

```
Ros_Qt5_Gui_App/
├── CMakeLists.txt          # 顶层：依赖、option、add_subdirectory(src/ install/)
├── cmake/                  # FetchContent 获取三方库 + GTest 辅助
│   ├── GetDockWidget.cmake # ADS 停靠库
│   ├── Getnlohmann.cmake   # json
│   ├── GetYamlCpp.cmake    # yaml
│   └── GTestHelper.cmake
├── build.sh / build.bat    # 一键构建脚本（含 Gitee 镜像版 build_cn.*）
├── install/                # 安装规则 + linux/windows 启动脚本(start.sh/.bat)
├── doc/                    # 开发/使用/FAQ 文档
└── src/
    ├── common/   → 共享库 common（日志、配置管理、宏）
    ├── basic/    → 接口库 basic（纯头文件：地图、点、拓扑图、消息枚举）
    ├── core/framework/ → 共享库 framework（MessageBus 发布订阅）
    ├── channel/  → 通信层（核心解耦点，见下文）
    └── app/      → 可执行文件 ros_qt5_gui_app（主窗口 + 显示 + 控件）
```

**链接关系**（`app` 最终链接 `Qt5 + dockwidget + nlohmann + common + basic + framework + channel + OpenCV`）：

```
basic (INTERFACE, 纯头)
   ↑
common (SHARED: logger/config) → 依赖 basic
   ↑
framework (SHARED: MessageBus)  → 依赖 common
   ↑
channel (STATIC: 通道管理) + channel_ros1/ros2/rosbridge (SHARED 插件)
   ↑
app (可执行: Qt UI)
```

## 四、核心架构设计（重点）

### 1. 通信通道插件化 —— `VirtualChannelNode`

`channel/` 是解耦的关键。抽象基类 `VirtualChannelNode`（`virtual_channel_node.h`）定义了统一接口，并**内建一个 30Hz 轮询线程**（`Init()` 起 `process_thread_` 循环调 `Process()`）：

```cpp
virtual bool Start() = 0;   // 初始化 ROS 节点/订阅/发布
virtual bool Stop() = 0;
virtual void Process() {}    // 轮询执行器 spin_some + 周期任务（如 TF 取位姿）
virtual std::string Name() = 0;
```

三个具体实现各自编译成**独立动态库**（`libchannel_ros1.so` / `libchannel_ros2.so` / `libchannel_rosbridge.so`），并通过 `channel_symbol.cpp` 导出 C 符号 `GetChannelInstance()`：

| 通道 | 实现类 | 依赖 | 说明 |
|------|--------|------|------|
| ROS2 | `rclcomm` | rclcpp, tf2_ros, cv_bridge, topology_msgs | 稳定长期维护 |
| ROS1 | `RosNode` | ros, tf, cv_bridge | 基础功能 |
| ROSBridge | `RosbridgeComm` | websocketpp/rosbridge2cpp | WebSocket，支持断线重连（`ReconnectLoop`/独立连接线程），Windows 可用 |

**运行时动态加载**由 `ChannelManager`（`channel_manager.cc`，静态库 `channel`）完成：
- 扫描可执行文件同级 `lib/` 目录，发现 `libchannel_*.so`；
- `channel_type` 配置为 `auto` 时自动选择（非 rosbridge 优先）；
- 用 **`boost::dll`** 加载动态库 → `get("GetChannelInstance")` 取出工厂函数 → 调 `Init()`。

> 这一套让"换通信后端"只改配置或换动态库，UI 层完全无感。

**通道选择时机**：顶层 `CMakeLists` 有 `BUILD_WITH_CHANNEL_AUTO`（默认 ON），按 `ROS_VERSION` 环境变量自动 `add_subdirectory(ros1/ros2)`；`rosbridge` 恒编译。

### 2. 进程内消息总线 —— `Framework::MessageBus`

这是**连接通信层与 UI 层**的中枢（`core/framework/`），一个单例发布-订阅总线，对外只有三个宏：

```cpp
PUBLISH(topic, data)      // 发布任意类型数据
SUBSCRIBE(topic, cb)      // 类型安全订阅（lambda 自动推导参数类型）
UNSUBSCRIBE(topic, id)
```

关键机制：
- **类型擦除 + 类型检查**：回调存为 `TypedCallback<T>`（继承 `CallbackBase`），发布时按 `typeid(T)` 匹配，类型不符则告警跳过（避免 `std::any_cast` 崩溃）。
- **跨线程安全**：`ThreadSafeCallbackExecutor::Execute()` 判断若不在 Qt 主线程，则用 `QTimer::singleShot(0, app, func)` 把回调**投递回主线程**执行——保证 UI 控件只能在主线程更新。
- 消息主题用 `basic/msg/msg_info.h` 的 `MsgId` 枚举 + `MSG_ID_*` 宏（如 `MSG_ID_ROBOT_POSE`、`MSG_ID_SET_NAV_GOAL_POSE`、`MSG_ID_IMAGE`…）。

**完整数据流**（以"显示机器人在地图上的位姿"为例）：

```
ROS 话题 /map /odom /scan ...
   │  (rclcomm 的 ROS 订阅回调)
   ▼  PUBLISH(MSG_ID_ROBOT_POSE, pose)      ← 通信层发布到 MessageBus
MessageBus ──QTimer 投递主线程──▶
   ▼  SUBSCRIBE(MSG_ID_ROBOT_POSE, ...)     ← UI 层(MainWindow/DisplayManager)订阅
更新 ViewManager / DisplayManager / 控件
   │
   │  反向(用户交互)：点地图设目标 →
   ▼  PUBLISH(MSG_ID_SET_NAV_GOAL_POSE, pose)
   ▼  rclcomm 的 SUBSCRIBE 收到 → PubNavGoal() → 发布到 ROS /goal_pose
```

> 注意：ROS 消息类型（`nav_msgs::Odometry` 等）只在 channel 层出现，**UI 层只见到 `basic::RobotPose/RobotState/LaserScan/OccupancyMap` 等自研数据结构**，彻底隔离了 ROS 头文件。

### 3. 显示层 —— QGraphicsView 自绘体系

`app/display/` 是 UI 的核心，采用"管理器 + 工厂 + 可复用图层"的分层：

| 组件 | 职责 |
|------|------|
| `VirtualDisplay` | **图层基类**（同时是 `QObject` + `QGraphicsItem`），封装平移/缩放/旋转、父子关系（`children_`/`parent_ptr_`）、鼠标交互、边界矩形、场景坐标变换。所有可视元素都继承它 |
| `FactoryDisplay` | **图层工厂**（单例），统一创建/获取/增删/聚焦图层，维护 `total_display_map_` |
| `DisplayManager` | **显示总控**：持有地图数据 `OccupancyMap`、机器人位姿、焦点图层；负责地图↔场景↔世界多套坐标互转（`wordPose2Scene`/`scenePoseToMap`…）；发起重定位/导航/地图编辑模式 |
| `SceneManager` | 继承 `QGraphicsScene`，**鼠标/键盘事件分发**，实现地图编辑（移动/擦除/画线/加点/画笔/区域/拓扑连线），并带**命令模式撤销/重做**（`MapEditCommand`，历史 50 步） |
| `ViewManager` | 继承 `QGraphicsView`，工具栏（聚焦机器人、加点按钮、工具尺寸滑条、坐标显示） |

具体图层（均继承 `VirtualDisplay`）：`DisplayOccMap`(占用栅格地图)、`DisplayCostMap`(局部/全局代价地图)、`DisplayPath`(全局/局部路径)、`LaserPoints`(激光点)、`RobotShape`(机器人，支持配置轮廓/椭圆)、`PointShape`(导航点/拓扑点)、`TopologyLine`(拓扑连线)、`DisplayDemo`。

> 地图/路径/激光等数据从 MessageBus 到达后，由对应图层 `UpdatePose`/重绘 `QGraphicsItem`，渲染在 `SceneManager` 的场景里。

### 4. 主窗口 —— `MainWindow`

`app/mainwindow.cpp` 是组装中心：
- 创建 `ChannelManager` → `openChannel()` 动态加载通道 → `registerChannel()` 注册各 MessageBus 订阅（odom/位姿/电量/图像/diagnostic…）；
- 用 **ADS (Qt-Advanced-Docking-System)** 搭建可停靠布局：速度控制、导航目标表、电池、相机图像（多路 `RatioLayoutedFrame`）、配置、诊断等 Dock；
- 把用户操作转成 `PUBLISH`（手动速度 `MSG_ID_SET_ROBOT_SPEED`、导航目标、重定位、拓扑保存）；
- 窗口状态用 `QSettings` 存/恢复（`SaveState/RestoreState`）；
- 地图加载/保存（`LoadMap` + `OccupancyMap::Load/Save`，支持 yaml+图像）。

### 5. 配置层 —— `Config::ConfigManager`

`common/config/`，单例，序列化 `config.json`（nlohmann/json）。`ConfigRoot` 含：显示配置 `display_config`、相机 `images`、机器人轮廓 `robot_shape_config`、键值 `key_value`、通道 `channel_config`（含 `channel_type` + rosbridge ip/port）、地图 `map_config`。通道构造函数里用 `SET_DEFAULT_TOPIC_NAME` 把 ROS 话题名写进配置（如 `/map`、`/odom`、`/cmd_vel`、`/scan`…），实现**话题可配置**。

### 6. 基础数据层 —— `basic/`（纯头文件 INTERFACE 库）

- `point/point.h` `point_type.h`：`Point`、`OrientedPoint`(= `RobotPose`)、`RobotPath`、`RobotSpeed`、`RobotState`、`LaserScan`；
- `map/occupancy_map.h`：`OccupancyMap`（Eigen 矩阵存栅格 + `MapConfig` 分辨率/原点），含 yaml 加载/保存、图像保存(SDL)、坐标互转；
- `map/topology_map.h`：`TopologyMap`（点集 + `routes` 有向图 + 属性），nlohmann 序列化，含路径查找/代价算法（`algorithm/algorithm.h`）；
- `msg/msg_info.h` + `str_enum.h`：消息 ID 枚举（`DECLARE_ENUM/DEFINE_ENUM` 宏生成枚举↔字符串）；
- `msg/diagnostic_snapshot.h`：诊断数据结构。

## 五、线程模型

```
┌─────────────────────────────────────────────┐
│  Qt 主线程 (QApplication::exec)               │
│  - 所有 UI 控件、QGraphicsView 渲染          │
│  - MessageBus 回调(经 QTimer 投递)在这里执行  │
└──────────────▲──────────────────────────────┘
               │ QTimer::singleShot(0) 跨线程投递
┌──────────────┴──────────────────────────────┐
│  通道轮询线程 (VirtualChannelNode 内建)       │
│  - rclcpp MultiThreadedExecutor spin_some()  │
│  - ROS 订阅回调 → PUBLISH 到 MessageBus      │
└─────────────────────────────────────────────┘
```

- 所有重活（ROS 回调、TF 查询、spin）都在通道线程；
- **任何要碰 UI 的数据都经 MessageBus → QTimer 投回主线程**，规避 Qt 跨线程更新控件的崩溃；
- rosbridge 额外有连接/重连线程。

## 六、构建与产物

- 产物：可执行 `ros_qt5_gui_app`（`build/`），动态库（`framework.so`、`common.so`、`channel_*.so`）输出到 `build/lib/`，RPATH 设 `$ORIGIN:$ORIGIN/lib`，故 `start.sh` 直接可跑；
- `make install` 安装到 `install/bin/`（启动脚本随之复制）；
- CI（`.github/workflows/`）覆盖 ROS melodic/noetic/foxy/galactic/humble + Windows，出 Release 二进制包。

## 七、设计亮点与可改进点

**亮点**
- **通道插件化 + MessageBus**：通信后端可插拔，UI 零耦合 ROS 头文件，是整套架构的精髓；
- **类型安全 + 线程安全**的进程内总线，`typeid` 检查 + 主线程投递，避免 `any_cast` 崩溃与跨线程 UI 问题；
- 显示层"图层基类 + 工厂 + 管理器 + 场景/视图分离"，扩展新图层成本低；
- 命令模式实现地图编辑撤销/重做。

**可关注点**
- `MsgId` 用宏 + `std::string` 作 topic，`SUBSCRIBE` 依赖 lambda 参数类型推导，回调必须是**单参数** lambda；
- `MainWindow` 体量较大（1000+ 行），组装逻辑集中，后续可拆控制器；
- `basic` 以 INTERFACE 纯头库存在，SDL/Eigen 等依赖经其接口传递；
- 文档 `doc/development.md` 里贴的目录结构是**旧版**（`mainwindow/`、`plugin/`），实际代码已演进为 `app/` 且无 `plugin/`，以源码为准。
