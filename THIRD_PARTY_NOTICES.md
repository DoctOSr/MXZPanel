# 第三方来源说明

MXZ 自有且有权许可的代码采用 AGPL-3.0-only。本项目不通过该许可授予第三方作品的权利；实际复制或修改的第三方部分仍需满足原作者的授权条件。参考思路、参数与实际复制的代码，按具体内容区分。

| 项目 | 作者 / 来源 | 对应内容 | 已核对版本的许可记录 |
| --- | --- | --- | --- |
| [CobaltEssentialsInterface（CEI）](https://github.com/StanleyDudek/CobaltEssentialsInterface) | StanleyDudek / Dudekahedron | 面板按钮 UI 与配色参考 | 未找到项目级许可证 |
| [PowerUps](https://github.com/OfficialLambdax/BeamNG-Powerups) | Neverless / OfficialLambdax | 基米音效播放与音效发射器初始化参考 | 源码头部标注 `License: None` |
| [BeamMP-FloodMod](https://github.com/daniel-w0/BeamMP-FloodMod) | daniel-w0 | 洪水功能封装集成 | 未找到许可证或明确的代码再分发授权 |
| BeamNG.drive 内置 `forceField.lua` | BeamNG.drive | 叛徒力场参数参考 | 游戏原始代码和资源的权利归各自权利人 |

记录日期：2026-11-11。

## 对应位置

- CEI：`client/lua/ge/extensions/mxz.lua` 的按钮三态样式与配色，原始行号 615 起。
- PowerUps：`client/lua/ge/extensions/GForceKO.lua` 的 `createDeathSfx`，原始行号 83 起。
- Flood：`server/mxz/main.lua` 的洪水状态、更新函数及事件处理，原始行号 60、1836、2274 起；客户端控制界面位于 `mxz.lua` 原始行号 929 起，其余相关客户端事件也按同一来源记录。
- `forceField.lua`：`client/lua/ge/extensions/mxz.lua` 原始行号 427 的来源注释及对应力场参数。

上述相关实现保留在本次源码快照中。已检查的上游版本未提供明确的相关再分发许可，本项目目前没有额外授权记录；来源说明不表示第三方部分已改为 AGPL 授权。

## 资源

源码仓库不包含生产客户端内的 `death_0.wav` 至 `death_12.wav`。自行添加的音频应另行确认使用和分发权限，不因播放代码采用 AGPL 而自动获得许可。BeamNG.drive、BeamMP 本体及外部账号认证服务不随仓库分发。

## 异议联系

如相关原作者对本项目中涉及其作品的内容有异议，请通过仓库 Issue 联系我们。我们将在收到通知后立即停止分发并移除对应的代码或资源。
