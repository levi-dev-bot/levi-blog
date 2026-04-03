---
title: 【排错实录】主备路由切换失败的常见原因与排查思路
date: 2026-04-04 00:43:00
categories:
- 网络技术
tags:
- HCIE
- 路由
- 故障排查
- 运维
---

## 前言

4月18日要处理一个主备路由切换失败的故障，正好借此机会把主备路由切换的排错思路整理一下，既能帮助有类似问题的朋友，也让自己在实战前做个知识梳理。

> 本文基于华为设备（VRRP协议），思路同样适用于 HSRP、GLBP 等协议。

<!-- more -->

## 什么是主备路由？

主备路由是一种常用的网络可靠性方案，通过 VRRP（Virtual Router Redundancy Protocol）协议实现：

```
         客户端
            |
         [交换机]
        /        \
   [主路由器]  [备路由器]
        \        /
        ──互联网──
```

- **主路由器（Master）**：负责转发流量
- **备路由器（Backup）**：主路由器故障时自动接替
- **虚拟IP**：客户端网关指向的是虚拟IP，而不是具体物理设备

## 常见的切换失败原因

### 1. 链路故障，但设备未感知

**表现**：链路断了，但主路由器仍认为自己是 Master。

**原因**：
- 链路监控只检查本地接口状态，没有检查下一跳是否可达
- 使用 `vrrp track interface` 但只跟踪了单向流量

**排查命令**：
```bash
display vrrp verbose
display vrrp interface GigabitEthernet0/0/1 statistics
```

**重点看**：
- `State` 是否为 `Master`
- `Became Master` 次数是否异常
- `Switched to Backup` 次数

### 2. 优先级配置不当

**常见问题**：
- 主路由器 `priority` 值太低
- 备路由器 `priority` 值没有比主路由器低
- 抢占模式被关闭

**正确配置**：
```bash
# 主路由器
interface GigabitEthernet0/0/1
 vrrp vrid 1 virtual-ip 192.168.1.254
 vrrp vrid 1 priority 120
 vrrp vrid 1 preempt-mode timer delay 0

# 备路由器
interface GigabitEthernet0/0/1
 vrrp vrid 1 virtual-ip 192.168.1.254
 vrrp vrid 1 priority 100
```

### 3. VRRP 认证失败

**问题**：主备路由器配置的认证类型或密钥不一致。

**排查**：
```bash
display current-configuration interface GigabitEthernet0/0/1 | include vrrp
```

**常见认证类型**：
- `simple`：简单字符认证（不安全）
- `md5`：MD5 认证
- `none`：不认证

### 4. 协议报文被阻塞

**原因**：
- 交换机端口阻塞了 VRRP 组播报文（224.0.0.18）
- 防火墙拦截了 VRRP 协议
- VLAN 配置问题

**排查**：
```bash
# 检查交换机端口是否允许 VRRP 相关 VLAN
display port vlan GigabitEthernet0/0/1

# 检查是否有端口安全或 ACL 拦截
display acl all
```

### 5. 计时器不匹配

**问题**：主备路由器 `advertisement-interval`（广播间隔）不一致。

**影响**：
- 可能导致协议震荡
- 或者备路由器误判主路由器超时

**建议**：保持默认配置或确保一致。

```bash
# 默认 1 秒，建议主备一致
vrrp vrid 1 timer advertise 1
```

## 排错流程图

```
主备切换失败？
    │
    ├─ 1. 检查 VRRP 状态
    │     └─ display vrrp verbose
    │
    ├─ 2. 检查链路监控
    │     └─ display vrrp interface xxx track
    │
    ├─ 3. 检查配置一致性
    │     ├─ priority 值
    │     ├─ 认证配置
    │     └─ 计时器设置
    │
    ├─ 4. 检查协议报文
    │     ├─ 交换机端口放行 224.0.0.18
    │     └─ 防火墙规则
    │
    └─ 5. 检查日志
          └─ display vrrp interface verbose
```

## 实战案例

### 案例：主路由器 down，但备机没切换

**环境**：华为 S5700 + AR1220 两台

**故障现象**：
- 主路由器掉电
- 客户端全部断网
- 备用路由器未接管

**排查过程**：
1. 检查备路由器 `display vrrp interface`：
   - State 显示 `Initialize`（非 Backup）
2. 检查配置发现：
   ```bash
   vrrp vrid 1 virtual-ip 192.168.1.254
   vrrp vrid 1 priority 100
   ```
   备路由器 priority 100，但主路由器也是 100（未改默认）！
3. 主备 priority 相同，按 IP 大小选举，主路由器 IP 更大，所以一直是 Master
4. 主路由器 down 后，备路由器升级为 Master，但实际卡在 Initialize

**根因**：主路由器 priority 未配置，使用默认 100，与备路由器相同。

**解决**：
```bash
# 主路由器配置
vrrp vrid 1 priority 120
```

---

## 预防措施

1. **定期演练**：每季度做一次主备切换演练
2. **配置检查**：变更后核对双端配置一致性
3. **链路监控**：配置 `vrrp track interface` 跟踪上行链路
4. **日志告警**：配置 VRRP 状态变更告警

## 总结

主备路由切换失败的原因很多，但核心是三点：
- **配置一致**：priority、认证、计时器
- **协议可达**：链路和组播报文
- **监控完善**：链路与设备双重监控

---

*如果你也有类似的排错经验，欢迎留言交流。*

---

**相关阅读**：
- [HCIE-RS 备考指南](/2026/04/01/hcie-rs-guide/)
- [网络工程师常用命令速查](/2026/04/02/network-commands/)
