---
title: "OpenClaw Exec 权限故障排查全流程"
date: 2026-04-14 22:49:00
tags: [OpenClaw, exec, 权限, 故障排查, DevOps]
categories: 技术文档
---

# OpenClaw Exec 权限故障排查全流程

## 前言

本文记录一次 OpenClaw Gateway 的 exec 权限全面失效故障的完整排查过程，从现象分析到最终解决，记录了踩坑和绕坑的完整思路，供后续维护参考。

## 故障现象

用户反馈：通过 Telegram 或 Control UI 访问 OpenClaw 时，AI 助手（dog_assistant）完全没有 exec 权限。所有命令都返回：

```
error: exec denied: allowlist miss
```

即使是 `echo test` 这样的基本命令也无法执行。

## 影响范围

- 无法执行任何 shell 命令
- 无法检查 cron 任务状态
- 无法安装 skills
- 无法访问文件系统
- 无法重启 Gateway
- **死循环**：修复需要 exec，但 exec 被阻止

## 故障时间线

| 时间 | 事件 |
|------|------|
| 2026-04-11 | 用户升级到 OpenClaw 2026.4.10 |
| 2026-04-11-14 | exec 权限被配置阻止，无法执行任何命令 |
| 2026-04-14 22:19 | 用户手动修改配置文件，exec 部分恢复 |
| 2026-04-14 22:20 | 验证成功，系统恢复正常 |

## 问题根源分析

### 1. OpenClaw 4.x 与 3.x 的 exec 配置差异

OpenClaw 4.x 版本的 exec 权限逻辑与 3.x 有显著变化：

| 版本 | exec 配置方式 |
|------|--------------|
| 3.x | 简单的 allow/deny |
| 4.x | 多层检查：config 层 + agent 层 + exec-policy 层 |

### 2. 配置冲突导致权限失效

配置文件中的 `tools.exec.security` 被设置为不兼容的模式，导致 OpenClaw 拒绝所有 exec 命令。

### 3. 死循环困境

```
exec 被阻止 → 无法修改配置 → 配置错误 → 重启后还是被阻止
```

## 排查步骤

### Step 1：确认问题现象

```bash
# 测试 exec 是否可用
echo "test"
```

如果返回 `exec denied: allowlist miss`，说明 exec 权限被阻止。

### Step 2：检查配置文件

查看 `~/.openclaw/openclaw.json` 中的 exec 相关配置：

```bash
cat ~/.openclaw/openclaw.json | grep -A 10 "exec"
```

### Step 3：检查 OpenClaw 版本

```bash
openclaw --version
```

### Step 4：检查 Gateway 状态

```bash
openclaw status
```

### Step 5：尝试诊断命令

如果 exec 部分可用，尝试：

```bash
openclaw exec-policy show
```

这个命令可以显示每个 agent 的 exec 策略配置。

## 解决方案

### 方案一：重置配置文件（推荐）

删除配置文件，让 OpenClaw 重新生成默认配置：

```bash
rm ~/.openclaw/openclaw.json
openclaw gateway restart
```

**注意**：这会丢失所有自定义配置，需要重新配置。

### 方案二：手动修改配置文件

编辑 `~/.openclaw/openclaw.json`，找到 `tools.exec` 部分，修改配置：

```json
{
  "tools": {
    "exec": {
      "security": "full"
    }
  }
}
```

然后重启 Gateway：

```bash
openclaw gateway restart
```

### 方案三：使用 exec-policy 命令修改

```bash
openclaw exec-policy set dog_assistant --security full
openclaw gateway restart
```

## 预防措施

### 1. 定期备份配置文件

在修改任何配置之前，先备份：

```bash
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak
```

### 2. 理解配置层级

OpenClaw 4.x 的 exec 权限检查有多个层级：

```
┌─────────────────────────────────────┐
│         Config Layer                │
│   (tools.exec.security in json)      │
├─────────────────────────────────────┤
│         Agent Layer                  │
│   (agents.<name>.tools.exec)         │
├─────────────────────────────────────┤
│       Exec-Policy Layer              │
│   (openclaw exec-policy show)        │
└─────────────────────────────────────┘

三层取最严格设置
```

### 3. 不要轻易修改 security 设置

除非完全理解后果，否则不要将 `security` 设置为 `full` 或 `deny`。

### 4. 验证后再重启

在修改配置后，先用 `openclaw config list` 验证配置是否正确，再重启 Gateway。

## 关键命令速查

| 命令 | 用途 |
|------|------|
| `openclaw --version` | 检查版本 |
| `openclaw status` | 查看系统状态 |
| `openclaw config list` | 列出所有配置 |
| `openclaw exec-policy show` | 显示 exec 策略 |
| `openclaw gateway restart` | 重启 Gateway |
| `openclaw cron list` | 列出 cron 任务 |
| `openclaw skills list` | 列出已安装 skills |

## 常见问题

**Q1：为什么重启 Gateway 不能解决问题？**

A1：因为配置文件本身就是错的，重启后还是加载同样的错误配置。

**Q2：为什么 `echo test` 这样的命令也被阻止？**

A2：OpenClaw 的 exec 检查是全局的，一旦 `security` 设置为不允许的模式，所有 exec 命令都会被阻止，包括最基本命令。

**Q3：如何避免死循环？**

A3：在修改配置之前，先用 `openclaw config list` 验证配置是否正确。如果配置已经损坏，只能通过手动编辑文件或删除重置的方式修复。

## 总结

这次故障的根本原因是 OpenClaw 4.x 版本的 exec 配置逻辑发生了变化，导致原有的配置不再适用。

关键教训：
1. **不要轻易修改 exec security 设置**
2. **修改配置前务必备份**
3. **理解 OpenClaw 的多层权限检查机制**
4. **遇到死循环时，删除重置是最稳妥的方案**

---

*原创内容，版权所有。转载时请注明出处。*
