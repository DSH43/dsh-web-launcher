# DSH Web Launcher

把 [DSH](https://github.com/deepseek-ai/deepseek-harness) 的 Web 界面做成一个 macOS App：双击启动 `dsh web`，关窗时把 host 停掉。不用 Electron，界面走系统自带的 WebKit，App 本体不到 1 MB。

> 非官方工具，和 DeepSeek / DSH 官方没有隶属关系。App 图标取自 DSH Web 的图标资源，仅用于标识这个启动器，不在本仓库的 MIT 许可范围内。

## 为什么不用 DSH Desktop

Desktop 是完整的 Electron 运行时，装完 2 GB 多。它管的那套事情里，这个启动器只做三件：起 host、显示页面、关窗收尾。三件都能用系统 WebKit + 一个子进程做完。

## 要求

- macOS 13 或更新
- Xcode Command Line Tools（`swiftc`）
- Node.js
- 一份构建好的 DSH 源码检出，至少要有 `apps/cli/lib/bin.js`

## 构建与安装

```sh
git clone https://github.com/DSH43/dsh-web-launcher.git
cd dsh-web-launcher
./scripts/build.sh          # 产出 dist/DSH Web.app
./scripts/install.sh        # 编译并复制到 ~/Applications
```

装好后从 `~/Applications` 或访达双击 **DSH Web**。第一次启动会写配置文件。

## 配置

配置文件：`~/.dsh/web-launcher.json`，第一次启动自动生成。路径支持 `~`。

```json
{
  "node": "/opt/homebrew/bin/node",
  "cli": "~/Code/deepseek-harness/apps/cli/lib/bin.js",
  "cwd": "~/Documents/workspace-ds",
  "host": "127.0.0.1",
  "port": 3080,
  "extraArgs": [],
  "env": {}
}
```

| 字段 | 用途 |
|---|---|
| `node` | 跑 dsh CLI 的 node 可执行文件 |
| `cli` | dsh 源码检出里的 `apps/cli/lib/bin.js` |
| `cwd` | host 的工作目录，影响新建会话的默认工作区 |
| `host` | 绑定地址，默认只绑本机回环 |
| `port` | 监听端口，默认 3080 |
| `extraArgs` | 追加给 `dsh web` 的参数 |
| `env` | 额外注入给 host 的环境变量，键值对 |

也可以临时用环境变量覆盖，主要给测试用：

- `DSH_LAUNCHER_NODE`
- `DSH_LAUNCHER_CLI`
- `DSH_LAUNCHER_PORT`

启动器会先取登录 shell 的 `PATH` 再传给 host，所以 Finder 里启动也能用 nvm、pyenv、Homebrew 这些路径。需要额外环境变量时写进 `env`。

**端口不要和正在跑的 `dsh web` 撞车。** 启动器自己起 host，DSH 没有单实例锁，两个 host 会写同一份会话存储。所以端口被占用时启动器直接报错退出，不会悄悄再起一个。要用启动器，先把终端里的 `dsh web` 停掉。

## 行为

1. 启动 `node <cli> web --no-open --host <host> --port <port>`，工作目录是 `cwd`。
2. 从 stdout 里取 `dsh web: http://127.0.0.1:PORT/?token=…`，用 WKWebView 打开。token 是一次性的，所以每次都现取，不依赖旧 cookie。
3. 关窗、Cmd+Q、`kill -TERM` 都走同一个退出路径：先 SIGTERM 让 host 优雅收尾（DSH 有 5 秒超时），超时再 SIGKILL。host 停掉之后 App 才退出。
4. 60 秒内没等到 URL 视为启动失败，停掉 host 并显示错误页，附 stderr 和日志路径。
5. 下载走 `~/Downloads`，外部链接交给系统浏览器；JS 的 alert/confirm/prompt 用原生弹窗。

日志：`~/Library/Logs/DSH Web Launcher.log`，菜单里「显示 → 打开日志」直接打开。

## 在启动器里升级 DSH

启动器给 host 设置 `DSH_LAUNCHER=1`。`dsh-version-check` 0.3.1 起会认这个变量：升级时照常停掉 host，但不自己 `nohup ./start.sh` 起新进程，也不开浏览器。

启动器这边看到 host 退出后，先看 `$DSH_HOME/state/dsh-version-check/upgrade/building` 在不在。在，就显示「DSH 正在升级」，每 2 秒看一次；锁消失就重启自己的子进程，重新取 token 加载页面。升级期间关掉窗口也没关系：构建进程是 detached 的，会继续跑完，而且不会再起 host，下次打开 App 就是新版本。

插件版本低于 0.3.1 时没有这个判断，升级完会自己起一个 host。启动器这边会显示端口占用或服务退出，`关窗就停`不成立。先把 `dsh-version-check` 同步/重装到 0.3.1 以上，再在启动器里升级。

## 兼容性与限制

- 界面是 WKWebView（Safari 内核），不是 Chrome。DSH 的常规功能都正常；Chrome 扩展不可用，个别依赖 Chromium 行为的边缘功能可能有差异。
- 登录类 popup 会交给系统浏览器打开，登录完成后不会回灌到这个 App 的会话。
- 拖拽文件上传在 WKWebView 下可能不灵，用附件的文件选择按钮。
- 启动器被强制杀掉（活动监视器、`kill -9`）时来不及收尾，host 会成为孤儿进程。清理：
  ```sh
  pkill -f "bin.js web --no-open --host"
  ```
  正常关窗和 Cmd+Q 不受影响。
- 关窗立刻停 host，正在跑的 agent 任务会中断。这是「关窗就停」的代价。
- 依赖 DSH 源码检出的目录结构和 `apps/cli/lib/bin.js`；全局 npm 安装的 DSH 需要自己把 `cli` 指到对应的入口。

## 目录

```
Sources/main.swift        启动器全部逻辑
Info.plist                App 元数据与 ATS 例外
assets/AppIcon.icns       从 DSH 图标生成的 App 图标
scripts/build.sh          编译 + 组装 .app
scripts/install.sh        安装到 ~/Applications
scripts/make-icon.sh      重新生成 AppIcon.icns
scripts/smoke.sh          生命周期自检：起、取 URL、关、查进程
```

## 卸载

```sh
rm -rf ~/Applications/DSH\ Web.app
rm -f ~/.dsh/web-launcher.json
```

## 许可

代码使用 MIT 许可，见 `LICENSE`。`assets/AppIcon.icns` 来自 DSH 的图标资源，版权归上游，仅作为本启动器的标识使用。
