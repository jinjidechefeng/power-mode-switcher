# PowerMode · Windows 电源模式一键切换

一个单文件 `.bat` 小工具：显示当前电源 / 显示 / 显卡状态，一键在「极致续航」和「极致性能」两种模式间切换，并可完整还原原始设置。

不需要安装任何东西，双击即可运行（会自动申请管理员权限）。

```
  ============================================================
                     PowerMode  电源模式切换工具
  ============================================================

  时间     : 2026-11-05 13:22:06
  电源     : 电池 33%  预计 2 小时 15 分钟
  电源计划 : 平衡
  屏幕     : 2560 x 1600 @ 240 Hz
  刷新率   : 60 / 144 / 240 Hz
  息屏     : 接 20 分钟 / 电池 30 秒
  CPU      : 接 100% / 电池 50%
  节能     : 100%
  色温     : 暖色
  模式     : 极致续航
  显卡     : AMD Radeon 780M Graphics（集显）
             NVIDIA GeForce RTX 5060 Laptop GPU（独显，已禁用）
  配置文件 : 默认

  [1] 极致续航
  [2] 极致性能
  [3] 启用独立显卡
  [4] 恢复原始设置
  [5] 配置文件
  [0] 退出
```

状态栏只显示当前值。用电池时那一行是按**当前放电功率**估算的剩余时间：读取 `RemainingCapacity ÷ DischargeRate`（三次采样的平均值），不显示瓦数；拿不到放电功率时才退回系统自带的估算。

## 两种模式

### [1] 极致续航（笔记本不插电时用）

| 项目 | 默认动作 |
| --- | --- |
| 息屏 | 电池供电时等待 **30 秒**（接电源时不动） |
| 电池节能 | `ESBATTTHRESHOLD` 设为 100%，即电池供电时节能模式常开 |
| 电源模式 | 叠加切换到「最佳能效」；老系统自动退回「节能」电源计划 |
| CPU 上限 | 电池供电时 50% |
| 刷新率 | 每块屏幕各自降到当前分辨率下 **不超过 60Hz** 的最接近模式 |
| 屏幕 | 压低蓝通道，调成暖黄色 |
| 独立显卡 | **禁用**（省掉独显的待机功耗），可关 |

### [2] 极致性能（插电游戏 / 渲染用）

| 项目 | 默认动作 |
| --- | --- |
| 电源模式 | 叠加切换到「最佳性能」 |
| CPU | 上限与下限都锁 **100%**，保持最高频率 |
| 刷新率 | 每块屏幕各自跳到最高刷新率 |
| 屏幕色温 | 恢复正常 |
| 独立显卡 | 如果之前被本工具禁用，自动重新启用 |
| 息屏 / 节能 | 自动撤销续航模式改过的值 |

### [4] 恢复原始设置

切换任一模式前，脚本会把原始值备份到 `%LOCALAPPDATA%\PowerModeTool\`：

* `backup.json` —— 电源方案、各电源设置、每块屏幕的原始刷新率
* `gamma_original.bin` —— 原始色温曲线
* `gpu_disabled.json` —— 被本工具禁用的显卡

选 `[4]` 会把上面所有内容写回。

## 配置文件

菜单 `[5]` 或 `PowerMode.bat --write-config` 会在脚本旁边生成 `PowerMode.ini`。所有阈值都可以改，改完重启工具生效。仓库里带了一份默认模板。

```ini
EcoMonitorTimeoutSec=30      ; 电池息屏秒数，0 = 从不
ApplyTimeoutsToAC=0          ; 息屏时间是否也用于接电源状态
EcoCpuMaxPercent=50          ; 电池 CPU 上限
EcoRefreshMaxHz=60           ; 续航模式刷新率上限
EcoWarmScreen=1              ; 是否开启暖色
EcoWarmGreen=0.93            ; 暖色强度（越小越黄）
EcoWarmBlue=0.62
EcoBatterySaver=1            ; 是否开启电池节能
EcoBatterySaverThreshold=100
EcoDisableGpu=1              ; 续航模式是否禁用独显
PerfCpuMinPercent=100
PerfCpuMaxPercent=100
ApplyRefreshToAllDisplays=1  ; 0 = 只改主屏
ConfirmGpuDisable=1          ; 禁用独显前是否询问
PauseOnFinish=1              ; 结束后是否等待回车
```

## 命令行

适合放进计划任务或快捷方式：

```
PowerMode.bat               交互菜单
PowerMode.bat --status      只显示状态
PowerMode.bat --eco         直接应用极致续航
PowerMode.bat --perf        直接应用极致性能
PowerMode.bat --restore     恢复原始设置
PowerMode.bat --gpu off     只禁用独显
PowerMode.bat --gpu on      只启用独显
PowerMode.bat --list-gpus   列出显示适配器及识别结果
PowerMode.bat --write-config  生成配置文件
PowerMode.bat --help        帮助

    --no-gpu    本次不禁用独显
    --yes       跳过确认，不等待回车
```

示例（开机自动进入续航模式，静默执行）：

```bat
PowerMode.bat --eco --yes
```

## 换一台电脑也能用

脚本不依赖任何本机特有的分辨率、刷新率或 GPU 型号，全部运行时探测：

* **刷新率**：用 `EnumDisplaySettings` 枚举**每块屏幕**在当前分辨率下的全部模式，续航取不超过配置上限的最接近值，性能取最高值；没有 60Hz 就自动降到次高。
* **显示器**：`EnumDisplayDevices` 枚举所有活动屏幕，默认全部调整（`ApplyRefreshToAllDisplays=0` 可只改主屏）。
* **显卡**：用 `Get-PnpDevice -Class Display` 抓取全部显示适配器（没有该模块时退回 `Win32_PnPEntity`），再按名称规则分类：
  * 独显：GeForce / Quadro / Tesla / Radeon RX / Radeon Pro / FirePro / Radeon VII / Intel Arc / Iris Xe MAX
  * 集显：Intel HD/UHD/Iris、Radeon Graphics / Vega / Radeon xxxM、Adreno、Mali、Apple M 系列
  * 虚拟：MuMu、VMware、Hyper-V、VirtualBox、Parsec、ToDesk、Sunlogin、Microsoft Remote/Basic Display 等
* **电源设置**：直接读写 `HKLM\...\Power\User\PowerSchemes` 注册表，不解析本地化的 `powercfg /query` 输出，中英文系统都一样。
* **电源模式**：优先用 `powercfg /overlaysetactive`（Win10 1709+ 的「最佳能效 / 最佳性能」），不支持时自动退回切换「节能 / 高性能」电源计划，并在恢复时切回原方案。
* **剩余时间**：用 `root\wmi\BatteryStatus` 的 `RemainingCapacity ÷ DischargeRate` 估算，字段缺失或为 0 时退回 `PowerStatus.BatteryLifeRemaining`；没有电池的台式机上直接不显示。
* **兼容旧备份**：能读取 v1 格式的 `backup.json`（`Items` / `Refresh` 字段）。

## 禁用独显的安全规则

禁用 PnP 显卡有风险，脚本做了几道保险：

1. 只处理被识别为**独显**的适配器，虚拟显卡和识别不准的一律跳过。
2. 如果启用中的显卡只剩独显（例如 MUX 切到独显直连），**拒绝禁用**，避免黑屏。
3. 想禁用时先把清单打印出来并询问确认（`ConfirmGpuDisable=0` 或 `--yes` 可跳过）。
4. 禁用了哪块会记进 `gpu_disabled.json`，`[4]`、`--gpu on`、`--perf` 都会把它重新启用。

即便如此，**禁用独显仍可能导致正在使用该显卡的程序崩溃或桌面闪一下**，介意的话在配置里设 `EcoDisableGpu=0`。

## 已知限制

* 暖色用的是显卡 gamma 校色，不是系统「夜间模式」——Windows 没有公开的命令行开关。**HDR 模式下可能不生效**。
* 色温只作用于主显示器对应的 DC，多屏不一致时其他屏可能没有色温变化。
* 需要 Windows 10 / 11 与 Windows PowerShell 5.1（系统自带）。Windows 8.1 部分可用。
* 「最佳能效 / 最佳性能」依赖电源模式叠加，少数 OEM 定制系统不支持，此时自动退回电源计划切换。
* 极致性能模式把 CPU 下限锁 100% 会让笔记本风扇变吵、温度变高，介意就用 `[4]` 还原。

## License

MIT
