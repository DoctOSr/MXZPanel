# MXZ 面板

MXZ 的 BeamMP 游戏内面板与配套服务端源码，基于 2026-11-11 核对的 A/B 服在用版本整理。

面板包含职业选择、传送、车辆生成与颜色调整、叛徒玩法、洪水控制，以及 GForceKO 的过载昏迷、死亡状态和音效播放功能。客户端使用 BeamNG 的 Lua 扩展、ImGui 与 UI app；服务端使用 BeamMP Lua API。

## 目录

```text
client/             客户端模组内容，构建后位于 MXZ.zip 根目录
server/mxz/         服务端插件，安装到 Resources/Server/mxz/
examples/           配置和传送点示例，不含生产凭据或玩家数据
scripts/build.py    客户端打包脚本，使用 Python 标准库
docs/INSTALL.md     安装、外部依赖和音效说明
docs/AUTH.md        账号认证接口依赖
THIRD_PARTY_NOTICES.md  参考来源及第三方许可范围
LICENSE             GNU AGPL v3 完整正文
```

## 开始使用

需要 BeamNG.drive、BeamMP 客户端和 BeamMP 服务端。当前服务端认证传输使用 Linux/POSIX shell 与 `curl`，并依赖独立的本机账号认证服务。该后端不包含在本仓库内，配置示例本身不能完成账号登录；具体接口见 [账号认证依赖](docs/AUTH.md)。

先阅读 [安装说明](docs/INSTALL.md)，然后在仓库根目录运行：

```sh
python scripts/build.py
```

输出为 `dist/MXZ.zip`。默认不包含 13 个基米音效文件；播放代码保持原样，需自行提供有权使用的音效，详见安装说明。此源码快照沿用 A/B 服的现有玩法和认证逻辑，未改造成可独立运行的通用服主管理系统。

## 开源许可

Copyright (c) 2026 MXZ contributors

本项目有权许可的客户端、服务端代码采用 **GNU AGPL v3（AGPL-3.0-only，仅第 3 版）**，详见 [LICENSE](LICENSE)。第三方代码与资源的权利及许可范围见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

允许使用、修改和商用。分发本许可覆盖的程序或衍生版本时，应遵守相应的许可声明和对应源码提供要求；修改后的版本若供用户通过网络远程交互，须向这些用户显著提供免费获取该版本对应源码的途径。以 LICENSE 正文为准。

## 参考与致谢

MXZ 面板的按钮 UI 与配色参考了 CobaltEssentialsInterface（CEI）；基米音效播放实现参考了 PowerUps；洪水功能封装集成自 BeamMP-FloodMod；叛徒力场参数参考了 BeamNG 内置的 forceField.lua。感谢上述项目及作者的工作。

如相关原作者对本项目中涉及其作品的内容有异议，请通过仓库 Issue 联系我们。我们将在收到通知后立即停止分发并移除对应的代码或资源。

## 版本与验证

首次公开版本为 2026-11-11 的 A/B 服源码快照，未另行赋予玩法版本号。原有 `app.json` 内的组件版本保持不变。验证记录及限制见 [CHANGELOG.md](CHANGELOG.md)。
