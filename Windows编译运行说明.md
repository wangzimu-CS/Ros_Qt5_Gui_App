# Ros_Qt5_Gui_App Windows 本地编译与运行说明

> 本文档记录 2026-11-16 在本机（Windows x64，用户 `Administrator`）上完成
> 分支选择 → 环境检查 → 依赖安装 → 编译 → 运行验证的全过程：
> 实际使用的环境、编译操作流程、遇到的问题及解决方式、以及最终产物的运行方法。
> （Linux/Ubuntu 版本见根目录《编译运行说明.md》）

## 环境总览

| 项目 | 版本 / 位置 |
|------|-------------|
| 操作系统 | Windows x64（Git Bash 作为命令行环境） |
| 编译器 | MSVC 14.51（Visual Studio 2026 Community v18.10.3，安装在 `D:\Program Files\Microsoft Visual Studio\18\Community`） |
| CMake | VS 2026 自带（`...\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`，为 CMake 4.x 系列） |
| vcpkg | `D:\vcpkg`（环境变量 `VCPKG_ROOT` 已指向此处，triplet `x64-windows`） |
| 项目路径 | `c:\cppproject\Ros_Qt5_Gui_App` |
| 代码分支 | `chunyunEQinLinux`（最新提交 `3f918cc`，2026-11-15） |
| Python | 3.10.11（仅调试辅助用） |

## 一、分支选择（为什么用 chunyunEQinLinux）

对各分支按最新提交时间梳理的结论：

| 分支 | 最新提交 | 时间 | 说明 |
|------|----------|------|------|
| **chunyunEQinLinux** | 提交设备配置文件 | 2026-11-15 | **最新**，包含 master 全部历史，保留完整 Windows 构建链路（build.bat / vcpkg.json / install/windows） |
| master | README 修复 | 2026-05-19 | 稳定基线，带 v1.0.7 系列标签 |
| origin/dev | Merge dev | 2025-10-29 | 落后于 master |
| windows_devel | 转向灯功能 | 2020-12-09 | 早期 Windows 适配分支，已完全并入 master |

分支名带 "inLinux" 只是后期在该分支上为春云设备做了 Linux 调试，Windows 构建支持并未移除。

```bash
git checkout chunyunEQinLinux
```

## 二、编译操作流程

### 2.1 一键编译脚本

项目自带 `build.bat`（四步：vcpkg 依赖 → CMake 配置 → 并行编译 → 安装 + 拷贝运行时 DLL），
但它假设 VS 装在 C 盘且使用系统默认 vcpkg。本机实际情况不同（VS 在 D 盘、需要规避 VS 自带 vcpkg），
因此新增了一个薄封装脚本 `run_build.bat` 放在项目根目录：

```bat
@echo off
call "D:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat" -arch=x64
rem VS bundles a vcpkg under its own spaced path, which breaks MSVC link lines;
rem force the project's vcpkg at D:\vcpkg (no spaces)
set "VCPKG_ROOT=D:\vcpkg"
set "VCPKG_OVERLAY_PORTS=c:\cppproject\Ros_Qt5_Gui_App\vcpkg-overlay"
rem yaml-cpp (FetchContent) declares cmake_minimum_required < 3.5; CMake 4 needs this opt-in
set "CMAKE_EXTRA_ARGS=-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_SHARED_LINKER_FLAGS=/MAP /DEBUG"
cd /d c:\cppproject\Ros_Qt5_Gui_App
build.bat
```

> 说明：`/MAP /DEBUG` 两个链接旗标是崩溃排查期间加的（生成符号表），调试完可从
> `CMAKE_EXTRA_ARGS` 中去掉，不影响功能。

执行方式（在 Git Bash 中）：

```bash
cmd //c run_build.bat
```

或在"x64 Native Tools Command Prompt"里直接运行 `run_build.bat`。

### 2.2 vcpkg overlay port

项目根目录新增 `vcpkg-overlay/qt5-base/`——从 `D:\vcpkg\ports\qt5-base` 复制的一份
端口副本，用于把 Qt 升级到 5.15.19（原因见问题 2）。通过环境变量
`VCPKG_OVERLAY_PORTS` 挂载，不改动 `D:\vcpkg` 本体。

### 2.3 编译时间参考

首次全量编译约 40~60 分钟（其中 qt5-base 从源码编译占大头，约 20~40 分钟；
其余 100 个依赖包大部分能命中二进制缓存）。后续增量编译只需几分钟。

### 2.4 编译产物

| 产物 | 路径 |
|------|------|
| 主程序 | `build\install\bin\ros_qt5_gui_app.exe` |
| 业务 DLL | `common.dll`、`framework.dll`、`bin\lib\channel_rosbridge.dll` |
| Qt/boost/opencv 等运行时 | vcpkg 的 DLL 与 Qt 插件已由 build.bat 自动拷入 `bin\` |
| 启动脚本 | `build\install\bin\start.bat` |

## 三、遇到的问题与解决方案（按时间线）

### 问题 1：VS 自带 vcpkg 路径含空格，依赖链接失败

- **现象**：vcpkg 安装 harfbuzz 时报 `LNK1181: 无法打开输入文件 "Files\Microsoft\.obj"`。
- **原因**：VS 2026 的 `VsDevCmd.bat` 会把 `VCPKG_ROOT` 强制改成 VS 自带的
  `D:\Program Files\...\VC\vcpkg`。该路径含空格，meson/ninja 生成的链接命令行中
  `/LIBPATH:D:/Program Files/...` 被按空格拆断，把 `Files/Microsoft` 当成了输入文件。
- **解决**：在 `run_build.bat` 中于调用 VsDevCmd **之后**显式 `set "VCPKG_ROOT=D:\vcpkg"`，
  强制使用无空格路径的本机 vcpkg。**教训：vcpkg 安装路径一定不要含空格。**

### 问题 2：qt5-base 5.15.16 与新 MSVC 14.51 STL 不兼容

- **现象**：vcpkg 编译 qt5-base 时报 `error C2653: "stdext": 不是类或命名空间名称`
  （`qvector.h` / `qcompilerdetection.h`），随后 `LNK1181` 连锁失败。
- **原因**：老版 Qt 源码使用 `stdext::make_checked_array_iterator`（被弃用的 MSVC 扩展），
  VS 2026 的 STL 已将其彻底移除，`stdext` 命名空间不复存在。
- **排查过程**：最初尝试手写 patch 去改 `qcompilerdetection.h` 中的宏，但两次均报
  `corrupt patch at`（手写 unified diff 的行数计数/行尾格式不可靠）。
- **最终解决**：改用 overlay port 把 qt5-base 升到 **5.15.19**——该版本已自带防护
  （`qcompilerdetection.h` 中 `#if _MSC_VER < 1938` 时才定义 stdext 宏），**无需任何补丁**，
  把误加的补丁从 overlay 端口移除后一次通过。
- **教训**：
  1. 遇到新编译器编老代码报"符号找不到"，先怀疑标准库 API 被移除，优先升级依赖版本而非打补丁；
  2. 手写 unified diff 极易出错，要打补丁应从源码副本用 `git diff --no-index` 生成。

### 问题 3：CMake 4 移除老版 `cmake_minimum_required` 兼容性

- **现象**：项目 CMake 配置阶段在 FetchContent 拉取 yaml-cpp 后报
  `Compatibility with CMake < 3.5 has been removed from CMake`，配置失败。
- **原因**：项目 `cmake/GetYamlCpp.cmake` 用 FetchContent 固定版本拉取的 yaml-cpp，
  其 CMakeLists 声明了 `cmake_minimum_required(x.y)`（<3.5），CMake 4 已移除该兼容层。
- **解决**：给 CMake 传 `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`（已固化在 `run_build.bat`
  的 `CMAKE_EXTRA_ARGS` 中）。

### 问题 4：Git Bash 中 `cmake` 不在 PATH

- **现象**：在 Git Bash 里直接执行 `cmake` 报 command not found（VsDevCmd 只在 cmd 会话中生效）。
- **解决**：凡涉及 CMake 的操作都通过 `run_build.bat`（cmd 环境，已加载 VS 开发环境）执行；
  或使用 VS 自带 cmake 的完整路径。另注意：脱离 `run_build.bat` 手动执行 cmake 配置时，
  vcpkg 会在项目 `build\vcpkg_installed` 里重装依赖并失败（缺少 VS 环境且安装根目录不同），
  **务必经 `run_build.bat` 统一入口**。

### 问题 5：启动即段错误（common.dll 内空指针虚调用）—— 本文档最重要的排查

- **现象**：`build\install\bin\start.bat` 双击闪退；直接运行 exe 约 0.2 秒后
  `exit=139`（SIGSEGV）。日志停在 rosbridge 通道启动处
  （`rosbridge_comm.cpp:98 Starting ROSBridge connection...` 附近）。
- **排查路径**（层层排除法）：
  1. 先排除脚本问题：`bin\start.bat` 内容正确，直接运行 exe 同样崩溃 → 程序自身问题；
  2. 排除网络因素：写了一个假 rosbridge WebSocket 服务（`fake_rosbridge.py`，监听 9090），
     程序**照样崩**，且假服务根本没收到连接 → 与 rosbridge 是否在线无关；
  3. 排除配置问题：`config.json` 存在且解析成功（显示话题均从配置生效）；
  4. 从 Windows 事件日志（`事件查看器 → Windows 日志 → Application`，来源 Application Error）
     拿到关键信息：**故障模块 common.dll**，异常代码 0xC0000005，偏移 0x5bf29/0x49430；
  5. WinDbg 在线安装被 403 拒绝，改用无调试器方案：
     - 注册表启用 WER 本地转储（见 §五），复现崩溃拿到 `ros_qt5_gui_app.exe.<pid>.dmp`；
     - `pip install minidump pefile capstone`，解析 dump 得到异常地址与寄存器
       （`Rbx=0`，`mov rax,[rbx]` 取虚表时崩溃——典型的空指针虚函数调用）；
     - 重链时加 `/MAP /DEBUG` 生成 `build\Release\common.map`，把 RVA 对照符号表；
     - 反汇编显示崩溃点是日志分发路径上的虚调用（对 `logBuilder` 之类的空成员做 `->build()`）。
- **根因**：easylogging++ 以**非线程安全模式**编译（全项目未定义 `ELPP_THREAD_SAFE`）。
  程序启动时主 GUI 线程与新建的 rosbridge 连接线程（`ConnectAsync`）**并发写日志**，
  数据竞争破坏日志库内部状态，导致空指针虚调用。与 config.json、rosbridge 是否在线均无关，
  属于确定性必现 bug。
- **解决**：在 `src/common/logger/easylogging++.h` 头部（include guard 之后）统一定义：

  ```c
  #ifndef ELPP_THREAD_SAFE
  #define ELPP_THREAD_SAFE
  #endif
  ```

  必须写在头文件里（而不是某个 target 的编译选项里），保证所有包含该头的
  翻译单元（exe/common/framework/channel 各 DLL）布局一致，避免引入 ODR 问题。
- **验证**：重新编译后配合假 rosbridge 服务运行 12 秒以上无崩溃（此前 0.2 秒即崩），
  日志正常、WebSocket 通道成功建立。

### 问题 6：start.bat 错位副本导致"找不到 exe"

- **现象**：双击 `build\install\start.bat`（顶层目录那份）启动不起来，提示的 exe 路径不对。
- **原因**：`bin\start.bat` 与顶层 `start.bat` 内容相同，但 `%APP_DIR%` 按脚本所在目录解析，
  顶层那份会去 `install\`（而非 `install\bin\`）找 `ros_qt5_gui_app.exe`。
  顶层那份是调试期间被手动复制出来的多余副本。
- **解决**：一律使用 `build\install\bin\start.bat`；顶层的错位副本应删除。
  （CMake 安装规则 `install/CMakeLists.txt` 只会把 start.bat 装进 `bin`，顶层的不是构建产物。）

### 问题 7：调试器不可用时的替代手段

- WinDbg 通过 winget 安装时下载被 403 拒绝，本机也无 cdb。
- 替代方案（全部开源工具、无需管理员调试器）：
  - **事件日志**：`Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error'}`
    直接给出故障模块 + 偏移；
  - **WER 本地转储**：注册表启用后崩溃自动落盘完整 dump；
  - **Python 解析 dump**：`minidump` 提取异常地址/寄存器/线程栈，`pefile` 做 RVA→文件偏移，
    `capstone` 反汇编崩溃指令；
  - **`/MAP` 链接旗标**：生成符号表后可用脚本把 RVA 映射回最近的符号。

## 四、运行方法

### 4.1 配置 rosbridge 地址

程序通过 WebSocket 连接 rosbridge 服务器（不直连 ROS2，也不要求 rosbridge 必须在小车上，
跑在机器人、WSL2 或任一可达机器上均可）。地址在 `build\install\bin\config.json`：

```json
"channel_config": {
  "channel_type": "auto",
  "rosbridge_config": { "ip": "127.0.0.1", "port": "9090" }
}
```

连小车时把 `ip` 改为小车 IP。地图、雷达、位姿等话题名也在同一文件的 `display_config` 中配置。

### 4.2 小车侧启动 rosbridge（ROS2）

```bash
sudo apt install ros-$ROS_DISTRO-rosbridge-suite
ros2 launch rosbridge_server rosbridge_websocket_launch.xml
```

### 4.3 启动程序

```powershell
cd build\install\bin
.\start.bat
```

或直接双击 `bin\start.bat`。**不要**双击 `build\install\` 顶层的 start.bat（问题 6）。

### 4.4 无小车本机调试（假 rosbridge）

项目根目录提供了 `fake_rosbridge.py`（基于 Python `websockets` 库，需
`pip install websockets`），监听 `ws://127.0.0.1:9090`、接受连接并回送状态消息，
可让 UI 完整启动、通道正常建立，仅无真实数据：

```bash
python fake_rosbridge.py   # 保持运行
# 另开终端运行 build\install\bin\start.bat
```

## 五、调试技巧汇总（本项目实测有效）

1. **不要靠双击 start.bat 排查崩溃**：它用 `start ""` 分离进程，窗口一闪即关、看不到输出。
   直接在终端运行 `build\install\bin\ros_qt5_gui_app.exe` 看日志与退出码
   （`exit=139` 段错误、`exit=124` 被 timeout 正常终止）。
2. **崩溃信息三件套**：事件日志（故障模块+偏移）→ WER dump（完整现场）→ `/MAP` 符号表（RVA 对函数）。
3. **WER 本地转储开启方式**（本次已配置，需清理见 §六）：
   `HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps` 下设
   `DumpFolder`（保存目录）、`DumpType=2`（完整 dump）。
4. **stdout 重定向时 C++ 的 `std::cout` 是全缓冲的**，段错误会丢失缓冲内容——
   分析崩溃日志时要以 easylogging 的 LOG 行（即时落盘）为准，别相信 cout 的最后几行。
5. **日志库线程安全**：多线程程序务必定义 `ELPP_THREAD_SAFE`（见问题 5），
   该宏必须全编译单元一致，放在头文件里最保险。

## 六、本次留下的调试痕迹（可清理）

| 位置 | 用途 | 处理建议 |
|------|------|----------|
| `run_build.bat` | 编译入口（含环境修正与 CMake 参数） | 保留；正式编译可去掉 `/MAP /DEBUG` |
| `vcpkg-overlay\qt5-base\` | 把 Qt 升到 5.15.19 的 overlay 端口 | **必须保留**（否则回退 5.15.16 重新崩溃） |
| `fake_rosbridge.py` | 无车调试用假服务 | 保留，调试利器 |
| `crashdumps\` | WER dump 输出目录 | 可删 |
| 注册表 LocalDumps 配置 | 崩溃自动转储 | 不再需要时可删除该键 |
| `build\install\start.bat`（顶层） | 错位的启动脚本 | **应删除**，防止误点 |
| `.tmp-patch\` | 手写补丁排查过程的中间产物 | 可删 |

## 七、验证结果

- 编译：`build.bat` 四步全部通过（`Build completed successfully`）；
- 运行：假 rosbridge 环境下主窗口正常初始化，消息总线订阅 22 个话题，
  自动加载 `channel_rosbridge.dll`，WebSocket 通道建立成功，连续运行无崩溃；
- 连接真实小车（rosbridge_server）后即可显示地图、雷达、位姿、路径等数据。
