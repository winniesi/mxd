# mxd

一个给 **Logitech MX Anywhere 3S**（macOS，蓝牙直连）用的轻量后台进程，用来替代 [Mouser](https://github.com/TomBadash/Mouser) 等带图形界面的鼠标驱动软件。

- 原生 Swift 编写，约 600 行，没有图形界面，只读一个 JSON 配置文件
- 由 launchd 托管，开机自动运行，异常退出后会被自动拉起
- 事件驱动，不做轮询；实测常驻内存约 3MB，`leaks` 检查 0 泄露（Mouser 约 180MB，而且会持续增长）

## 功能

| 按键 | 行为 |
|---|---|
| Mode shift 键（滚轮下方） | 在**鼠标所在的显示器**上切到下一个桌面（Space），在最后一个桌面上按会回到第一个；多显示器时把鼠标移过去就能立即生效，不用先点击 |
| 中键（按下滚轮） | 打开 Mission Control |
| 后退 / 前进 | 在 Finder、Safari 中改发 Cmd+[ / Cmd+]；其他 app（Chrome、Arc、Firefox 等）原样透传，由 app 自己处理 |
| 滚轮 | 固定为 free spin（不再在棘轮和 free spin 之间切换） |
| DPI | 1000 |

实现方式：

- Mode shift 键、滚轮模式、DPI：通过 IOHIDManager 用 Logitech **HID++ 2.0** 协议直接和鼠标通信，用到的特性有 `0x1B04` REPROG_CONTROLS_V4（把 CID `0x00C4` 的按键事件转交给 mxd）、`0x2111`/`0x2110` SMART_SHIFT、`0x2201` ADJUSTABLE_DPI。
- 中键、后退、前进：通过 CGEventTap 拦截。
- 鼠标断开重连或 Mac 从睡眠唤醒后，自动重新下发上述设置。

## 安装

需要 macOS 13 或更高版本，并已安装 Xcode Command Line Tools（`xcode-select --install`）。

1. 如果在用 Mouser / Logi Options+，先退出，并关掉它们的登录启动项，否则会和 mxd 抢同一个按键。
2. 克隆并安装：

```bash
git clone https://github.com/winniesi/mxd.git
```

```bash
cd mxd && ./scripts/install.sh
```

安装脚本会依次完成：

- 编译出 release 版本，打包成 `~/Applications/mxd.app` 并签名：钥匙串里有 Apple Development / Developer ID 证书就用证书签名，没有就用 ad-hoc 签名；
- 如果 `~/.config/mxd/config.json` 不存在，写入一份默认配置；
- 安装 LaunchAgent `~/Library/LaunchAgents/com.winniesi.mxd.plist` 并启动它。

3. 授予权限：打开 **系统设置 → 隐私与安全性**，在 **辅助功能** 和 **输入监控** 两项里都打开 `mxd`（列表里没有的话点「+」，添加 `~/Applications/mxd.app`）。然后重启 mxd：

```bash
launchctl kickstart -k gui/$UID/com.winniesi.mxd
```

> 用证书签名时，重新编译不会让权限失效。如果用的是 ad-hoc 签名，每次重新编译安装后签名都会变，需要在这两个权限列表里把 mxd 删掉后重新添加。

卸载：

```bash
./scripts/uninstall.sh
```

## 配置

配置文件在 `~/.config/mxd/config.json`（模板见 [config.example.json](config.example.json)）：

```json
{
  "dpi": 1000,
  "wheel": "freespin",
  "modeShift": "cycle_desktops",
  "middle": "mission_control",
  "backForward": { "keyboardNavApps": ["com.apple.finder", "com.apple.Safari"] }
}
```

| 字段 | 可选值 |
|---|---|
| `dpi` | 整数，例如 `1000`；设为 `null` 表示不修改鼠标上的 DPI |
| `wheel` | `freespin` / `ratchet` / `unchanged` |
| `modeShift` | `cycle_desktops` / `mission_control` / `none` |
| `middle` | `mission_control` / `cycle_desktops` / `passthrough` |
| `backForward.keyboardNavApps` | 一组 bundle id，这些 app 的后退/前进会改发 Cmd+[ / Cmd+] |

查某个 app 的 bundle id：`osascript -e 'id of app "Finder"'`

改完配置后重启 mxd 即可生效，不需要重新编译，也不需要重新授权：

```bash
launchctl kickstart -k gui/$UID/com.winniesi.mxd
```

## 日志与排错

mxd 用 `os_log` 输出日志（subsystem `com.winniesi.mxd`），不写日志文件。注意 zsh 里的 `log` 是内建命令，需要写成 `/usr/bin/log`。

实时查看日志：

```bash
/usr/bin/log stream --predicate 'subsystem == "com.winniesi.mxd"'
```

查看最近一小时的日志：

```bash
/usr/bin/log show --last 1h --predicate 'subsystem == "com.winniesi.mxd"' --style compact
```

正常启动时日志大致如下：

```
event tap installed
matched MX Anywhere 3S (usage page 0x1)
MX Anywhere 3S: divert mode-shift button (reprog idx 10) ok
MX Anywhere 3S: wheel freespin (0x2111 idx 15) ok
MX Anywhere 3S: dpi 1000 (idx 14) ok
MX Anywhere 3S ready
```

- mxd 没在运行（`pgrep -x mxd` 没有输出），并且 `launchctl print gui/$UID/com.winniesi.mxd` 提示找不到服务：多半是在 **系统设置 → 通用 → 登录项与扩展 → 允许在后台** 里把它关掉了。用证书签名时，这一项显示的是**证书上的开发者名字**，而不是 mxd，很容易误关。打开后系统会自动重新加载 mxd，也可以运行 `sfltool dumpbtm | grep -A3 com.winniesi.mxd` 确认状态是 `allowed`。
- 日志出现 `IOHIDManagerOpen failed` 或 `event tap creation failed`：权限没有给，或者重新编译后权限失效了。
- 不按鼠标也能测试 mode shift 键的动作：`kill -USR1 $(pgrep -x mxd)`，日志里会出现一行 `cycle: cursor display … space i/n, menu bar display …`。
- 想在前台调试：先运行 `launchctl bootout gui/$UID/com.winniesi.mxd` 停掉后台的 mxd，再运行 `~/Applications/mxd.app/Contents/MacOS/mxd --verbose`。

## 监控内存

查看内存占用（phys_footprint 和「活动监视器」里显示的「内存」是同一个数）：

```bash
footprint -p $(pgrep -x mxd) | grep phys_footprint
```

检查内存泄露：

```bash
leaks $(pgrep -x mxd) | grep "leaks for"
```

查看 RSS（KB）和 CPU 占用：

```bash
ps -o rss=,%cpu= -p $(pgrep -x mxd)
```

如果想长期观察，可以每 10 分钟往文件里记一条，过几天看数值有没有增长：

```bash
while true; do echo "$(date '+%F %T') $(footprint -p $(pgrep -x mxd) | awk '/phys_footprint:/{print $2,$3}')" >> ~/mxd-mem.log; sleep 600; done
```

## 限制

- 只测试过 MX Anywhere 3S **蓝牙直连**（HID++ 设备索引 `0xFF`）；通过 Bolt / Unifying 接收器连接的情况未支持。按产品名包含 "MX Anywhere" 来匹配设备。
- 切换桌面靠模拟 Ctrl+← / Ctrl+→，需要在 系统设置 → 键盘 → 键盘快捷键 → 调度中心 里开启这两个快捷键（系统默认开启）。
- 判断当前在哪个桌面用到了 SkyLight 的私有只读接口 `CGSCopyManagedDisplaySpaces`。

## 代码结构

```
Sources/mxd/
  main.swift      启动、权限检查、监听系统唤醒、进入 run loop
  Config.swift    读取 JSON 配置
  HIDPP.swift     IOHIDManager + HID++ 2.0 协议
  EventTap.swift  拦截中键 / 后退 / 前进
  Actions.swift   Mission Control、切换桌面、模拟快捷键
scripts/          install.sh / uninstall.sh
Resources/        Info.plist、LaunchAgent plist
```

## License

MIT
