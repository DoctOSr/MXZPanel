# 安装与构建

这是 A/B 服面板的源码快照，当前保留正式账号认证流程，需要独立账号服务配合。请先完成 [AUTH.md](AUTH.md) 所列依赖，再进行可运行部署。

## 环境

- 合法安装的 BeamNG.drive 和 BeamMP 客户端。
- 支持当前 Lua 插件 API 的 BeamMP 服务端。服务端代码依赖 `MP`、`FS`、`Util` 等宿主 API。
- 服务端为 Linux/POSIX 环境，需 `sh`、`curl`、`mkdir`、`chmod`、`find`、`mv`。
- 构建脚本使用 Python 3.9 或更高版本，无额外依赖。
- 本次公开源码未完成新的游戏内兼容性验证，未承诺最低游戏或 BeamMP 版本。

## 客户端打包

在仓库根目录运行：

```sh
python scripts/build.py
```

脚本将 `client/` 的内容放在 `dist/MXZ.zip` 根目录，并附带 LICENSE、来源说明和源码获取说明。不要把 `client/` 这一层目录包入模组根目录。

默认输出没有基米音频。若需要音效，将有权分发的文件放入一个单独目录，名称必须为 `death_0.wav` 至 `death_12.wav`，然后运行：

```sh
python scripts/build.py --audio-dir /path/to/licensed-audio
```

音频将位于 ZIP 的 `art/sound/GForceKO/` 下。音频缺失时，原有代码仍会尝试播放对应路径；声音播放结果未作新的实机验证。

## 服务端目录

1. 将 `server/mxz/` 复制到 BeamMP 服务端的 `Resources/Server/mxz/`。
2. 创建 `Resources/Server/mxz/settings/`。
3. 将 `examples/account_auth.example.json` 复制为 `Resources/Server/mxz/settings/account_auth.json`，填写本机服务地址及该服务器的凭据。
4. 将 `examples/server_settings.example.json` 复制为同目录下的 `server_settings.json`，按需调整配额。
5. 将 `examples/points.example.txt` 复制为 `Resources/Server/mxz/points.txt`，填写当前地图的实际传送点。
6. 如使用旧卡密兼容文件，创建 `Resources/Server/keyAuth/keys.txt`。该文件不会替代当前独立账号服务的身份和权限判断。
7. 将构建的 `MXZ.zip` 放入 `Resources/Client/`。

插件根据工作目录名 `BeamMP-Server-<标识>` 推导服务器标识，账号服务必须识别同一标识；例如工作目录 `BeamMP-Server-Example` 对应 `Example`。从服务端工作目录启动 BeamMP 服务端。

`server_settings.json` 的普通位与舰长位配额分别控制并发激活人数，不能代替 BeamMP 自身的最大连接人数配置。示例缺省不限制这两类配额；填入非负整数可启用限额。

## 数据与配置

运行时会生成 `state.json`、认证请求临时文件、激活用量和统计文件。这些文件、真实令牌及玩家数据均不应提交至源码仓库。

生产服务器的状态、积分、传送点、卡密、账号配置和历史备份均未随本源码分发。网页地图观察器属于另一套部署集成，未装入本次服务端目录。

## 源码提供

分发本许可覆盖的程序或修改版时，按 AGPL 提供对应源码。修改版若允许用户远程网络交互，应在用户可见的位置显著提供对应源码获取途径，并确保指向部署版本的实际源码及必要构建材料；仅提供上游未修改版本的链接不能代替这些义务。详见 LICENSE 第 6、13 条。
