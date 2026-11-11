# MXZ 面板

MXZ 是用于 BeamMP 的游戏内管理面板，包含客户端模组和配套服务端插件。

## 功能

- 职业选择、玩家传送与管理员操作。
- 车辆生成、颜色调整和车辆控制。
- 叛徒玩法与洪水控制。
- GForceKO 过载昏迷、死亡状态与基米音效播放。

客户端使用 Lua、ImGui 和 UI app，服务端使用 BeamMP Lua API。

## 安装

在仓库根目录运行：

```sh
python scripts/build.py
```

将生成的 `dist/MXZ.zip` 放入服务端的 `Resources/Client/`，将 `server/mxz/` 放入 `Resources/Server/mxz/`。

服务端需要 Linux 环境、`curl` 和独立账号认证服务。配置文件与传送点示例位于 `examples/`。基米音频需自行添加。

详细步骤见 [安装说明](docs/INSTALL.md)，账号接口见 [认证服务说明](docs/AUTH.md)。

## 目录

```text
client/          客户端模组
server/mxz/      服务端插件
examples/        配置与传送点示例
scripts/         打包脚本
docs/            使用文档
```

## 参考与致谢

按钮 UI 与配色参考 CEI，基米音效播放参考 PowerUps，洪水功能封装集成自 BeamMP-FloodMod，叛徒力场参数参考 BeamNG 内置的 forceField.lua。

项目链接、作者与来源说明见 [参考与致谢](THIRD_PARTY_NOTICES.md)。

## 许可

本项目自有代码采用 [AGPL-3.0-only](LICENSE) 许可。
