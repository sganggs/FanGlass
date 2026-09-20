# FanGlass

macOS 26 液态玻璃风格的风扇控制软件(Apple Silicon / Intel),原生 SwiftUI 实现,零第三方依赖。

![platform](https://img.shields.io/badge/macOS-26+-blue) ![arch](https://img.shields.io/badge/arch-arm64-green)

## 功能

- **风扇曲线编辑器**:2–8 个可拖拽控制点,单调三次(PCHIP)平滑插值;双击空白添加控制点,右键删除;横轴温度 / 纵轴转速(% 与 RPM 双标)
- **三种控制模式**:系统自动 / 固定转速 / 曲线跟随;一键预设:静音、均衡、性能、全速
- **传感器仪表盘**:启动时自动扫描 SMC 全部温度探头并按 CPU / GPU / SoC / 存储 / 内存 / 电源 / 环境 / 系统 分组,实时数值 + 迷你走势 + 多组历史趋势图
- **菜单栏常驻**:菜单栏实时显示最热传感器温度,点开玻璃面板可查看各组温度、快捷切换模式
- **过热提醒**:任一传感器超过阈值时发送系统通知(阈值可调,可关闭)
- **转速迟滞**:避免转速在边界附近抖动,阈值可调
- **持久化**:配置存于 `~/Library/Application Support/FanGlass/settings.json`

## 液态玻璃 UI

设计手法是"玻璃在边缘,不在背景"(借鉴 macOS Tahoe / visionOS / CleanMyMac X):

- 纯色基底:冷灰蓝 ±2% 明度微渐变,干净不死平
- 顶部一盏**静止的**白色摄影棚灯,所有玻璃表面的高光都与它呼应
- 玻璃卡片:白色半透明填充 + 顶部镜面高光 + 1px 渐变发丝描边 + 上缘镜面细线 + 双层投影(接触/环境)
- 顶部 2.5px 氛围灯带:唯一随温度变色的装饰(蓝→绿→橙→红),既是点缀也是状态指示
- 交互动效:按钮按压 spring 缩放、卡片 hover 描边提亮、分段控件玻璃 pill 滑动、顶栏风扇图标按真实 RPM 旋转
- 温度数字按档位变色(<50 蓝 / <70 绿 / <85 橙 / 更高 红)

## 架构

```
FanGlass.app (SwiftUI, 无需权限)
   │  SMC 读取(IOKit AppleSMC, 温度/转速)
   │  JSON-lines over /var/run/fanglass.sock
   ▼
fanglass-helper (launchd root 守护进程)
   │  SMC 写入(F0Md 强制模式 / F0Tg 目标转速)
   │  hold 模式每秒重断言(macOS 会周期性夺回控制权)
   ▼
AppleSMC
```

**安全机制**

- App 失联 20 秒 → 助手看门狗自动恢复系统控制(已实测 `kill -9` 可恢复)
- 助手收到 SIGTERM/SIGINT → 恢复自动后退出
- 目标转速始终钳制在风扇硬件范围(`F{i}Mn..F{i}Mx`)内
- 正常退出 App(⌘Q / 菜单栏退出)→ 恢复自动(可在设置中关闭)

## 构建与安装

需要:macOS 26 + Command Line Tools(无需完整 Xcode)。

```bash
scripts/build.sh      # 编译 app + 助手,组装 build/FanGlass.app(adhoc 签名)
scripts/install.sh    # 安装特权助手(弹一次管理员授权)
scripts/run.sh        # 构建并启动
scripts/uninstall.sh  # 卸载特权助手
```

App 内"设置 → 特权助手"也可直接安装/重新安装/卸载助手。

## 已知说明

- 传感器标签为按 SMC 键前缀的保守分组(CPU=Tp*、GPU=Tg* 等), Apple Silicon 各机型键表不同,分组自适应
- 温度曲线源可在设置中切换(默认 CPU,可选"最热传感器")
- `tools/probe.swift` 可独立编译运行,用于探查本机 SMC 键
