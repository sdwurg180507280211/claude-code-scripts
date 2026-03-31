# Claude Code 多 Agent 管理脚本

这是 Claude Code 的多供应商多 Agent 管理脚本。

## 脚本说明

| 脚本 | 说明 |
|------|------|
| `cc.sh` | Claude Code 全局供应商切换脚本（单配置版本） |
| `cc-agent.sh` | Claude Code 多 Agent 管理后端 |
| `cc-agent-ui.sh` | 多 Agent 交互式管理界面 |
| `api-keys.conf` | API 密钥配置文件（格式：编号\|名称\|URL\|Token\|模型\|haiku\|sonnet\|small） |

## 快速开始

运行交互式管理界面：

```bash
./cc-agent-ui.sh
```

## 功能特性

- 支持同时运行多个 Agent，每个使用不同供应商/模型
- 每个 Agent 独立配置，互不干扰
- 支持创建/启动/停止/删除/编辑/查看日志
- 主菜单显示运行状态概览
- 支持批量操作（启动全部/停止全部/重启全部）

## 菜单选项

1. **创建新 Agent** - 选择供应商，指定模型创建新 Agent
2. **启动 Agent** - 启动已创建的 Agent（支持全选）
3. **停止 Agent** - 停止运行中的 Agent（支持全选）
4. **查看所有 Agent 状态** - 显示全部 Agent 详细状态
5. **编辑 Agent 配置** - 在编辑器中直接编辑 JSON 配置
6. **删除 Agent** - 永久删除 Agent
7. **查看 Agent 日志** - 查看最近 50 行日志
8. **批量操作** - 启动全部/停止全部/重启全部
0. **退出** - 退出交互式界面

## vs 全局 cc.sh 对比

### 共同点

- 都使用同一个 `claude` 可执行文件
- 都从 `api-keys.conf` 读取供应商配置
- 如果在同一个目录启动，共享文件系统和 git 状态

### 不同点

| 维度 | `cc.sh` (全局切换) | `cc-agent.sh` (多 Agent) |
|------|-------------------|-------------------------|
| **配置位置** | `~/.claude/settings.json` | `~/.claude/agents/<name>.json` |
| **同时运行多个** | ❌ 只能一个全局配置 | ✅ 支持同时多个 Agent |
| **环境影响** | 影响所有新终端会话 | 只影响当前 Agent 进程 |
| **配置修改** | 永久修改全局配置 | 使用临时文件，不修改全局 |

## 共享 vs 独立总结

### 共享内容

- `claude` 程序本身
- 供应商定义 (`api-keys.conf`)
- 文件系统（工作目录文件、git 状态）

### 独立内容

- 每个 Agent 是独立的系统进程（不同 PID）
- 每个 Agent 独立配置（供应商 URL / API Key / 模型）
- 对话历史（内存中的上下文）
- PID 文件 (`~/.claude/agents/pids/`)
- 日志文件 (`~/.claude/agents/logs/`)

## 注意事项

1. **文件修改**：如果两个 Agent 在**同一个 git 仓库**工作，一个 Agent 的 `/rewind` 或文件修改会影响另一个。建议不同任务使用不同目录。

2. **API 配额**：不同供应商不同 Agent 共享同一个 API 配额，注意计费。

3. **安全性**：所有目录权限设置为 `700`，只有你能读取 API 密钥。

## 目录结构

```
~/.claude/
├── settings.json        # 全局配置（cc.sh 使用）
├── agents/              # 多 Agent 目录
│   ├── <name>.json     # Agent 配置
│   ├── pids/           # PID 文件
│   │   └── <name>.pid
│   └── logs/           # 日志文件
│       └── <name>.log
```
