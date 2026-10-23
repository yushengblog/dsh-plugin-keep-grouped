# dsh-plugin-keep-grouped

> DeepSeek Harness 插件：工作区路径（尤其是网络路径 / UNC）在启动时暂时不可达时，**让会话仍然留在原工作区分组里**，而不是掉进「未分组」。

---

## 解决什么问题

如果你的工作区指向**网络路径**（UNC，如 `\\server\share\dir`，或映射盘符如 `R:\`），可能会遇到：

> 开机后打开 DSH，工作区里的会话**全部掉进「未分组」**；网络明明是通的，重启 DSH 也时好时坏。

### 根因

DSH 判断「一个会话属于哪个工作区」用的是**路径字符串严格相等**：

```js
candidateMatches(id, path) =
    sessionPaths.get(id) === path || missingSessionPaths.has(id)
```

其中 `sessionPaths` 里的值是 `realpathNormalize(header.cwd)` 的结果。而 `realpathNormalize` 失败时：

| 错误码 | DSH 的处理 | 结果 |
|---|---|---|
| `ENOENT`（路径不存在） | 进 `missingSessionPaths` | ✅ 仍然匹配，留在分组 |
| `ETIMEDOUT` / `ECONNRESET` / `ENETUNREACH` / `EHOSTUNREACH` … | 进 `invalidSessionPaths` | ❌ **不匹配，掉进「未分组」** |

**网络路径在开机时（SMB 尚未就绪、VPN 还没连上、Wi-Fi 还没起来）抛的是后一类错误，不是 `ENOENT`。** 所以会话被踢出分组。

而且 DSH **不会**在网络恢复后自动重算 —— 必须重启 DSH 才能恢复。

### 本插件的做法

不碰 asar、不改 DSH 源码，只在 `workspaceRegistry` 服务就绪后**包装它的 `host.candidateMatches`**：

1. 先走原逻辑（网络正常时行为**完全不变**）；
2. 原逻辑返回 `false` 时，退回「`header.cwd` 与工作区 path 的**原样字符串**比较」。

这样即使 `realpath` 失败，只要会话记录的 `cwd` 与工作区路径字面一致，会话就仍然留在原分组。网络恢复后，原逻辑自然接管。

---

## 安装

### 方式一：从 GitHub 直接装（推荐）

```bash
dsh plugin add github:yushengblog/dsh-plugin-keep-grouped
```

或手动：

```bash
cd "$DSH_HOME/profiles/<你的profile>"
pnpm add github:yushengblog/dsh-plugin-keep-grouped
```

然后把 `dsh-plugin-keep-grouped` 加进 `package.json` 的 `dsh.profile.bundles` 数组：

```json
{
  "dsh": {
    "profile": {
      "bundles": [
        "...",
        "dsh-plugin-keep-grouped"
      ]
    }
  }
}
```

### 方式二：本地目录（开发 / 自用）

```bash
cd "$DSH_HOME/profiles/<你的profile>"
pnpm add link:/path/to/dsh-plugin-keep-grouped
```

同样要加进 `dsh.profile.bundles`。

### 装完

**重启 DSH**。插件加载后日志里会出现：

```
[keep-grouped] 已接管 candidateMatches：工作区路径暂时不可达时，会话仍留在原分组
```

---

## 验证

### 用自带的验证脚本（推荐）

仓库里带了 `verify.ps1`，**路径全部自动探测**（`$env:DSH_HOME` → `~/.dsh`，profile 优先 `desktop`），换机器直接能用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1
# 或指定 profile
powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1 -Profile desktop
```

输出会告诉你：profile 配置是否到位、插件文件是否就位、各工作区路径是否可达、会话数、`workspace.json` 是否被改写。

### 手动验证步骤

1. 重启 DSH，确认日志有 `[keep-grouped] 已接管 candidateMatches...`；
2. 让工作区路径**真的不可达**（断开网络映射 / 停掉做端口转发的服务 / 断网），再重启 DSH；
3. 检查该工作区**会话数仍然 > 0**，且 `workspace.json` 的修改时间没有变新；
4. 恢复网络后无需重启，功能自动恢复正常。

### 复现「路径不可达」的常用做法

```powershell
# 1) 断开网络映射
net use \\server\share /delete

# 2) 停掉做端口转发的服务（例如把 SMB 445 转发到远端的那种）
Stop-Service <服务名>

# 3) 断 Wi-Fi / 拔网线（注意：可能同时影响访问 DSH 本地服务）
```

确认断开成功：`Test-Path \\server\share\dir` 应为 `False`。


---

## 原理细节

### 为什么不用 `missingSessionPaths`

DSH 内部对 `ENOENT` 的处理是「加入 `missingSessionPaths`」，这已经能让会话留在分组里。本插件**不修改这个集合**（它是内部状态），而是直接在 `candidateMatches` 这一层做兜底，副作用最小。

### 为什么不改 `sessionPaths`

`sessionPaths` 存的是 realpath 后的规范化路径，DSH 还用它做别的校验（如 attach 时的 cwd 比对）。往里塞非规范路径可能引发其它问题。所以只在 `candidateMatches` 返回值上做文章。

### 路径比较规则

```js
samePathLoose(left, right) {
  if (left === right) return true;                    // 字面相等
  return trimTrailingSep(left) === trimTrailingSep(right);  // 忽略末尾分隔符
}
```

- **不做**大小写折叠（Windows 上由 DSH 侧保证一致，避免误判）；
- **不做** `realpath` —— 那正是失败的那一步。

### 卸载即恢复

插件用 `ctx.effect` 注册了清理函数，卸载 / 热重载时会还原原始的 `candidateMatches`，不会重复包装。

---

## 兼容性

- 需要 DSH 的 `workspaceRegistry` 服务（`@deepseek-ai/dsh-workspace` 提供），当前所有版本都有；
- 依赖的字段：`registry.host.candidateMatches`、`registry.headers`（`Map`）。
  如果未来 DSH 改了这两个字段名，插件会在日志里警告并**不生效**（不会报错崩溃）。

---

## 已知限制

- 只解决「**路径暂时不可达导致掉分组**」这一个问题；
- 如果工作区路径**永久**改了（比如换了服务器地址），会话仍然需要手动重新归属 —— 这属于真实的数据变更，不该被兜底掩盖；
- 网络路径下的会话**能列出来、能点开**，但如果网络确实没通，读取会话内容仍会失败（这是预期的，插件不改变 I/O 行为）。

---

## 许可

MIT
