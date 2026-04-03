---
title: 【排错实录】BGP/MPLS VPN + ISIS 主备切换故障排查指南
date: 2026-04-04 00:51:00
categories:
- 网络技术
tags:
- HCIE
- BGP
- MPLS VPN
- ISIS
- 故障排查
---

## 前言

4月18日要处理一个主备路由切换失败的故障，项目用的是 **BGP/MPLS VPN + ISIS** 架构。本文按**分层排查**的思路，从底层到上层逐层分析每个阶段可能出现的问题、判断方法和处理方案。

> 本文基于华为设备，适用于 MPLS L3VPN 主备切换场景。

<!-- more -->

## 一、架构与协议分层

在排查之前，先理清各层协议的依赖关系：

```
┌─────────────────────────────────────────────┐
│           第4层：VRRP 主备切换               │  ← 故障最终表现层
├─────────────────────────────────────────────┤
│           第3层：BGP VPNv4                  │  ← VPN 路由能否正确传递
├─────────────────────────────────────────────┤
│           第2层：MPLS / LDP                 │  ← 标签隧道是否建立
├─────────────────────────────────────────────┤
│           第1层：ISIS 底层                  │  ← 底层路由是否可达
└─────────────────────────────────────────────┘

⚠️ 原则：底层不通，上层必不通
```

**排查顺序**：第1层 → 第2层 → 第3层 → 第4层

---

## 二、第1层：ISIS 底层故障排查

### 2.1 ISIS 邻居起不来

**可能原因**：

| 原因 | 表现 | 判断方法 |
|------|------|----------|
| 链路物理问题 | 接口 down | `display interface brief` |
| Level 不匹配 | 邻居永远 Init | `display isis peer` State=Init |
| 区域 ID 不匹配 | L1 邻居 up 但路由缺失 | `display isis lsdb` |
| 认证不通过 | 邻居反复闪断 | `display isis error` |
| Circuit ID 冲突 | 邻居闪断 | `display isis interface` |

**排查命令**：
```bash
# 1. 查看全局 ISIS 状态
display isis peer

# 2. 查看接口 ISIS 状态
display isis interface

# 3. 查看邻接关系详细信息
display isis adjacency

# 4. 查看 ISIS 错误计数
display isis error
```

**处理方案**：

```bash
# 1. 确保 Level 匹配
# PE1 配置（Level-2 only）
isis 1
 is-level level-2
 network-entity 49.0001.0000.0000.1001.00

# P 路由器（Level-1-2）
isis 1
 is-level level-1-2
 network-entity 49.0001.0000.0000.0010.00

# 2. 确保区域 ID 匹配（L1 区域需要一致）
# 如果是 L2 互联，区域 ID 可以不同但需要正确的路由渗透

# 3. 检查认证（两端一致）
interface GigabitEthernet0/0/1
 isis authentication-mode simple plain Huawei123
```

---

### 2.2 ISIS 邻居 up 但路由缺失

**可能原因**：

| 原因 | 表现 | 判断方法 |
|------|------|----------|
| Cost/Metric 过大 | 路由 cost 为 0x3F（最大） | `display isis route` cost 值 |
| L1 路由未渗透到 L2 | L2 看不到 L1 的明细路由 | `display isis route` |
| 接口 PASSIVE | ISIS 不发送 HELLO | `display isis interface` |

**排查命令**：
```bash
# 查看 ISIS 路由表
display isis route

# 查看 LSDB 数据库
display isis lsdb

# 查看接口 Cost
display isis interface
```

**处理方案**：
```bash
# 1. 检查 Cost 配置
interface GigabitEthernet0/0/1
 isis cost 10 level-2

# 2. 开启路由渗透（L1-2 路由器）
isis 1
 import-route isis level-2 into level-1
 import-route isis level-1 into level-2

# 3. 确认接口不是 PASSIVE
isis 1
 undo isis passive
```

---

## 三、第2层：MPLS / LDP 故障排查

> ISIS 正常后，才能建立 MPLS LSP

### 3.1 LDP 会话无法建立

**可能原因**：

| 原因 | 表现 | 判断方法 |
|------|------|----------|
| LSR ID 不一致 | LDP 会话一直 Init | `display mpls ldp session` |
| 传输地址不可达 | LDP 会话 Down | `display mpls ldp peer` |
| 标签空间冲突 | LDP 会话 Connect | `display mpls ldp interface` |
| 认证不匹配 | LDP 会话 Down | `display mpls ldp session` 有 Auth failed 计数 |

**排查命令**：
```bash
# 1. 查看 LDP 会话状态
display mpls ldp session

# 2. 查看 LDP 对等体
display mpls ldp peer

# 3. 查看 LDP 接口
display mpls ldp interface

# 4. 测试 LSR ID 连通性
ping 1.1.1.1  # LSR ID
```

**典型输出解读**：
```
[LDP Session]
Session ID: 1.1.1.1:0 - 2.2.2.2:0
Status: Operational        ← 正常
Role: Active              ←主动端
```

```
Status: Connect           ← 异常，传输地址不通
Status: Init              ← 异常，正在协商
```

**处理方案**：
```bash
# 1. 确保 LSR ID 可达
mpls lsr-id 1.1.1.1

# 2. 在接口下使能 MPLS 和 LDP
interface GigabitEthernet0/0/1
 mpls enable
 mpls ldp enable

# 3. 检查标签空间（默认每接口）
display mpls ldp interface

# 4. 配置 LDP 认证
mpls ldp
 password-refresh-interval 86400
```

---

### 3.2 LSP 建立不完整

**可能原因**：

| 原因 | 表现 | 判断方法 |
|------|------|----------|
| 中间路由器缺失 MPSL | LSP 在中间断开 | `display mpls lsp` 有 gap |
| 标签保持模式问题 | LSP 不稳定 | `display mpls lsp` 反复震荡 |
| PHP（倒数第二跳弹出）未使能 | LSP 最后一跳不弹出 | traceroute 最后一跳无标签 |

**排查命令**：
```bash
# 1. 查看完整 LSP
display mpls lsp

# 2. 测试 LSP 连通性（带标签）
traceroute mpls ipv4 3.3.3.3 32

# 3. 查看标签转发表
display mpls routing-table
```

**处理方案**：
```bash
# 1. 确保所有 P/PE 路由器都配置了 MPLS
mpls enable
mpls lsr-id x.x.x.x

# 2. 确保 LDP 在所有链路接口使能
# 建议在 backbone 所有接口都使能

# 3. 调整 PHP 行为
mpls
 label advertise per-domain   # 按需分发标签
```

---

## 四、第3层：BGP VPNv4 故障排查

> MPLS LSP 正常后，才能传递 VPN 路由

### 4.1 BGP VPNv4 邻居起不来

**可能原因**：

| 原因 | 表现 | 判断方法 |
|------|------|----------|
| address-family vpnv4 未使能 | BGP 邻居 up 但 VPNv4 down | `display bgp vpnv4 all peer` |
| 地址簇协商失败 | 邻居一直 Idle | `display bgp peer` |
| MD5 认证失败 | 邻居反复 reconnect | `display bgp peer error` |

**排查命令**：
```bash
# 1. 查看 VPNv4 邻居
display bgp vpnv4 all peer

# 2. 查看详细邻居信息
display bgp vpnv4 all peer verbose

# 3. 查看地址族配置
display bgp vpnv4 all peer | include Established
```

**处理方案**：
```bash
# 1. 使能 VPNv4 地址族
bgp 64512
 peer 10.0.1.2 as-number 64512
 #
 address-family vpnv4
  peer 10.0.1.2 enable
  peer 10.0.1.2 next-hop-local    # 下一跳保持本地
```

---

### 4.2 RT Import/Export 不匹配

**可能原因**：

| 原因 | 表现 | 判断方法 |
|------|------|----------|
| Import RT 缺失 | PE 收到路由但不放入 VRF | `display bgp vpnv4 vpn-instance <name> routing-table` |
| Export RT 缺失 | 对端 PE 收不到路由 | `display bgp vpnv4 all routing-table` |
| RT 值写错 | 路由无法互通 | 核对两端 RT 值 |

**排查命令**：
```bash
# 1. 查看 VPN 实例配置
display ip vpn-instance verbose

# 2. 查看 VPN 实例的 RT 值
display ip vpn-instance verbose | include RT

# 3. 查看 BGP VPNv4 路由表
display bgp vpnv4 all routing-table
```

**典型案例**：

```
# Site A PE 配置
ip vpn-instance SiteA
 route-distinguisher 100:1
 vpn-target 100:1 export-ext-community
 vpn-target 100:2 import-ext-community   ← 错误！应该是 100:1

# Site B PE 配置
ip vpn-instance SiteB
 route-distinguisher 200:1
 vpn-target 200:1 export-extcommunity
 vpn-target 200:2 import-ext-community   ← 对端 Import 也要匹配
```

**处理方案**：
```bash
# 确保 Import RT 包含对端的 Export RT
# Site A：
vpn-target 100:1 export-ext-community
vpn-target 200:1 import-ext-community  ← 接收 Site B 的路由

# Site B：
vpn-target 200:1 export-ext-community
vpn-target 100:1 import-ext-community  ← 接收 Site A 的路由
```

---

### 4.3 VPN 路由注入失败

**可能原因**：

| 原因 | 表现 | 判断方法 |
|------|------|----------|
| CE 路由未发布到 PE | PE 路由表为空 | `display ip routing-table vpn-instance <name>` |
| AS 号不匹配 | BGP 路由被拒绝 | `display bgp error` |
| Route Policy 过滤 | 部分路由丢失 | `display bgp vpnv4 all routing-table statistics` |

**排查命令**：
```bash
# 1. 查看 VRF 路由表
display ip routing-table vpn-instance <name>

# 2. 查看从 CE 收到的路由
display bgp vpnv4 vpn-instance <name> routing-table import

# 3. 查看 BGP 错误日志
display bgp error
```

---

## 五、第4层：VRRP 主备切换故障

> 路由正常，但主备切换不生效

### 5.1 VRRP 状态异常

**可能原因**：

| 原因 | 表现 | 判断方法 |
|------|------|----------|
| VRRP 未配置 track | 主链路 down 但 VRRP 仍为 Master | `display vrrp interface` State=Master |
| Priority 配置错误 | 主备优先级倒置 | `display vrrp interface` priority 值 |
| 抢占模式关闭 | 主设备恢复后无法抢回 | `display vrrp interface` preempt-mode=Off |

**排查命令**：
```bash
# 1. 查看 VRRP 状态
display vrrp interface

# 2. 查看 VRRP 统计
display vrrp interface verbose

# 3. 查看 track 状态
display vrrp interface track
```

**处理方案**：
```bash
# 1. 配置 track 上行链路（核心！）
interface GigabitEthernet0/0/1
 vrrp vrid 1 virtual-ip 192.168.1.254
 vrrp vrid 1 priority 120
 vrrp vrid 1 track interface GigabitEthernet0/0/0 reduced 50
 # ↑ 当 GigabitEthernet0/0/0 down 时，priority 降 50

# 2. 确保抢占模式开启
vrrp vrid 1 preempt-mode timer delay 0

# 3. 配置 BFD 联动（毫秒级切换）
vrrp vrid 1 track bfd-session session-name bfd1 reduced 60
```

---

### 5.2 VRRP 与 BGP/MPLS 联动失效

**可能原因**：

| 原因 | 表现 | 判断方法 |
|------|------|----------|
| BFD 未配置 | 链路 down 后收敛慢（分钟级） | `display bfd session all` |
| VRRP 联动 BGP 未配置 | 切换后路由不更新 | 检查配置 |
| Track 与实际链路不匹配 | VRRP 切了但流量仍走原路 | `display vrrp interface` track 状态 |

**排查命令**：
```bash
# 1. 查看 BFD 会话
display bfd session all

# 2. 查看 VRRP 与接口 track 关系
display vrrp interface verbose | include Track

# 3. 测试主备切换
# 在主设备上 shutdown 主链路接口，观察备设备切换时间
```

**处理方案**：
```bash
# 1. 配置 BFD 毫秒级检测
bfd
#

# CE 与 PE 间配置 BFD
bfd bfd1 bind peer-ip 10.0.1.2 source-ip 10.0.1.1
 discriminator local 1
 discriminator remote 2
 min-tx-interval 100
 min-rx-interval 100
#

# VRRP 联动 BFD
interface GigabitEthernet0/0/1
 vrrp vrid 1 track bfd-session bfd1 reduced 60
```

---

## 六、排错总流程

按层级逐层排查，遵循**底层优先**原则：

```
① 物理层检查
│   └─ 光模块/光纤/网线是否正常
│
② ISIS 底层（第1层）
├─ ISIS 邻居状态 → display isis peer
├─ ISIS 接口状态 → display isis interface
├─ ISIS 路由可达 → display isis route
└─ ISIS Cost 配置 → display isis interface cost
│
③ MPLS/LDP（第2层）
├─ LDP 会话状态 → display mpls ldp session
├─ LSP 完整性 → display mpls lsp
├─ 标签分发正常 → display mpls ldp peer
└─ PHP 行为 → traceroute mpls
│
④ BGP VPNv4（第3层）
├─ VPNv4 邻居 → display bgp vpnv4 all peer
├─ RT/Import → display ip vpn-instance verbose
├─ 路由表 → display bgp vpnv4 all routing-table
└─ 路由注入 → display ip routing-table vpn-instance
│
⑤ VRRP 主备（第4层）
├─ VRRP 状态 → display vrrp interface
├─ Track 配置 → display vrrp interface track
├─ BFD 会话 → display bfd session all
└─ 切换延迟 → shutdown 主链路测试
```

---

## 七、实战案例

### 故障现象
主 PE（PE1）掉电，CE 无法切换到备用 PE（PE2），流量中断。

### 排查过程

**Step 1：检查 CE VRRP 状态**
```
[CE] display vrrp interface GigabitEthernet0/0/0
VRRP State: Master
Virtual IP: 192.168.1.254
Priority: 120
```
→ State 是 Master，但流量不通

**Step 2：检查 CE 上行链路**
```
[CE] display interface GigabitEthernet0/0/0
Physical link: down
```
→ 物理链路 down，但 VRRP 仍为 Master

**Step 3：检查 VRRP 配置**
```bash
[CE] display current-configuration interface GigabitEthernet0/0/0
vrrp vrid 1 virtual-ip 192.168.1.254
vrrp vrid 1 priority 120
# ← 问题：没有配置 track！
```

### 根因
VRRP 没有 track 上行链路，当 CE 上行链路 down 时，VRRP 仍为 Master，但流量已经不通了。

### 解决方案
```bash
[CE] interface GigabitEthernet0/0/0
 vrrp vrid 1 track interface GigabitEthernet0/0/1 reduced 50
```

---

## 八、预防建议

| 措施 | 说明 |
|------|------|
| **BFD 毫秒检测** | 链路故障时 BGP/LDP 快速收敛 |
| **VRRP Track 链路** | 主链路 down 时自动降低 priority |
| **定期演练** | 每季度做一次主备切换演练 |
| **监控告警** | VRRP 状态变更、ISIS 邻居 down 时告警 |
| **配置备份** | 双端配置保持一致，使用 config-sync |

---

*4月18日实战顺利！*

---

**相关阅读**：
- [HCIE-RS 备考指南](/2026/04/01/hcie-rs-guide/)
- [华为 VRRP 配置详解](/2026/04/02/vrrp-config/)
