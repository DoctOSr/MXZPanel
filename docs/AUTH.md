# 账号认证服务依赖

此源码保留 A/B 服的账号认证、会话和配额逻辑。后端服务源码不在本次面板发布范围内，示例配置不构成可用的认证后端。

## 连接方式

`server/mxz/lib/account_transport.lua` 仅接受 `http://127.0.0.1:<端口>`。请求为 POST JSON，带 `Authorization: Bearer <每服凭据>` 和 `X-MXZ-Server: <服务器标识>` 请求头。

`account_auth.json` 使用两个字段：

| 字段 | 含义 |
| --- | --- |
| `base_url` | 认证服务的本机 HTTP 地址，无末尾斜线 |
| `token` | 后端签发或登记的每服凭据，至少 32 字符，仅允许字母、数字、下划线和短横线 |

示例使用空令牌，需由部署者填入真实凭据；不要把真实令牌提交到 Git。

## 调用接口

客户端与 BeamMP 服务端之间的事件处理在主文件中；服务端通过以下后端接口完成身份和会话操作：

| 接口 | 用途 |
| --- | --- |
| `/api/game/auth/prepare` | 准备身份认证 |
| `/api/game/auth/finalize` | 完成认证与会话建立 |
| `/api/game/session/heartbeat` | 会话心跳 |
| `/api/game/session/end` | 结束会话 |
| `/api/game/keys/role` | 修改游戏角色记录 |
| `/api/game/commands/pending` | 读取待执行管理命令 |
| `/api/game/commands/ack` | 确认管理命令 |
| `/api/game/stats/<类型>` | 游戏统计上报，具体类型和字段见 `account_runtime.lua` |

通用响应包含 `ok` 布尔值。成功响应的 `data` 必须为对象；失败响应由 `code` 与 `error` 描述。具体请求字段、返回字段与状态转换以 `account_runtime.lua` 和 `account_commands.lua` 的调用点为准，本页不是完整后端实现规范。

当前未提供绕过认证的模式。未接入兼容账号服务时，不能将其描述为即装即用的通用面板。
