# HexTags Lite - 轻量级称号插件

## 简介

这是一个精简版的 HexTags 称号插件，专门为你的服务器优化，去除了不必要的依赖和复杂功能。

### 主要特点

- ✅ **轻量化**：移除了 chat-processor 和 simple-chat-process 依赖
- ✅ **完全兼容**：与现有的 `rpg.sp` 和 `veterans.sp` 完全兼容
- ✅ **简化选择器**：只保留常用的选择器（SteamID、管理员、积分等级）
- ✅ **直接颜色处理**：使用 `colors.inc` 库直接处理颜色
- ✅ **API兼容**：保留所有必要的 Native 函数供其他插件调用

## 安装步骤

1. **编译插件**
   ```bash
   cd addons/sourcemod/scripting
   ./spcomp extend/hextags_lite.sp
   ```

2. **复制文件**
   - 将编译好的 `hextags_lite.smx` 放到 `addons/sourcemod/plugins/` 目录
   - 配置文件 `hextags_lite.cfg` 已经在 `configs/` 目录下

3. **删除旧插件**（如果存在）
   - 删除或禁用 `hextags.smx`
   - 删除或禁用 `chat-processor.smx` 和 `simple-chat-processor.smx`

4. **重启服务器**

## 配置文件说明

配置文件位于：`addons/sourcemod/configs/hextags_lite.cfg`

### 基本结构

```
"HexTags"
{
    "选择器名称"
    {
        "TagName"       "显示的称号名称"
        "ScoreTag"      "<计分板称号>"
        "ChatTag"       "{颜色}[聊天称号]{default}"
        "ChatColor"     "{消息颜色}"
        "NameColor"     "{名字颜色}"
        "ForceTag"      "1"
    }
}
```

### 支持的选择器

| 选择器类型 | 格式 | 示例 | 说明 |
|-----------|------|------|------|
| **默认** | `default` | `default` | 所有玩家的默认称号 |
| **人类玩家** | `human` | `human` | 只匹配真实玩家 |
| **Bot** | `bot` | `bot` | 只匹配AI |
| **SteamID** | `STEAM_X:Y:Z` | `STEAM_1:0:12345678` | 特定玩家 |
| **管理员标志** | 单个字符 | `z`, `b`, `a` | 拥有该标志的管理员 |
| **管理员组** | `@组名` | `@VIP`, `@Admin` | 特定管理员组 |
| **积分等级** | `#积分值` | `#500000`, `#1000000` | 达到该积分的玩家 |

### 支持的颜色

```
{default}      - 默认颜色
{teamcolor}    - 队伍颜色
{red}          - 红色
{green}        - 绿色
{blue}         - 蓝色
{olive}        - 橄榄色
{lightgreen}   - 浅绿色
{purple}       - 紫色
{gold}         - 金色
{orange}       - 橙色
{grey}         - 灰色
{white}        - 白色
```

### 支持的变量

- `{time}` - 当前时间（HH:MM）
- `{score}` - 玩家积分（来自 l4dstats 或 rpg）

## 配置示例

### 1. 管理员称号

```
"z"  // Root 管理员
{
    "TagName"       "超级管理员"
    "ScoreTag"      "<超管>"
    "ChatTag"       "{red}[超管]{default}"
    "ChatColor"     "{default}"
    "NameColor"     "{red}"
    "ForceTag"      "1"
}
```

### 2. 积分等级称号

```
"#500000"  // 50万积分
{
    "TagName"       "资深玩家"
    "ScoreTag"      "<资深>"
    "ChatTag"       "{olive}[资深]{default}"
    "ChatColor"     "{default}"
    "NameColor"     "{olive}"
    "ForceTag"      "1"
}
```

### 3. 特定玩家称号

```
"STEAM_1:0:12345678"
{
    "TagName"       "服主"
    "ScoreTag"      "<服主>"
    "ChatTag"       "{gold}[服主]{default}"
    "ChatColor"     "{gold}"
    "NameColor"     "{gold}"
    "ForceTag"      "1"
}
```

### 4. 使用变量的称号

```
"#1000000"
{
    "TagName"       "百万富翁"
    "ScoreTag"      "<{score}分>"
    "ChatTag"       "{purple}[{score}分]{default}"
    "ChatColor"     "{default}"
    "NameColor"     "{purple}"
    "ForceTag"      "1"
}
```

## 游戏内命令

| 命令 | 说明 | 权限 |
|------|------|------|
| `!tagslist` / `!ch` / `!chenghao` | 打开称号选择菜单 | 所有玩家 |
| `!toggletags` | 切换称号显示/隐藏 | 所有玩家 |
| `!reloadtags` | 重新加载配置 | 管理员 (b标志) |

## 与 RPG 插件的集成

该插件完全兼容你的 `rpg.sp` 插件，rpg 插件可以通过以下方式调用：

```sourcepawn
// 设置玩家的聊天称号
HexTags_SetClientTag(client, ChatTag, "{green}<自定义称号>");

// 设置玩家的计分板称号
HexTags_SetClientTag(client, ScoreTag, "<VIP>");

// 重置玩家称号到配置文件默认
HexTags_ResetClientTag(client);
```

## 积分系统优先级

插件会自动检测可用的积分系统，优先级如下：

1. **l4dstats** (veterans.sp)
2. **rpg** (rpg.sp 的 ClientPoints)

如果两个都可用，优先使用 l4dstats 的积分。

## 常见问题

### Q: 称号不显示怎么办？

A: 检查以下几点：
1. 确认配置文件路径正确
2. 使用 `!reloadtags` 重新加载配置
3. 检查玩家是否匹配配置中的选择器
4. 确认玩家没有使用 `!toggletags` 隐藏称号

### Q: 如何添加多个称号？

A: 玩家只会显示第一个匹配的称号。配置文件中，将更高优先级的称号放在前面。

### Q: 自定义称号功能还在吗？

A: 是的！rpg.sp 中的自定义称号功能（!setch）完全保留，通过调用本插件的 API 实现。

### Q: 为什么移除 chat-processor？

A: chat-processor 过于臃肿，而我们只需要简单的称号和颜色功能，使用 colors 库直接处理更轻量高效。

## 性能对比

| 功能 | 原版 HexTags | HexTags Lite |
|------|-------------|--------------|
| 依赖插件 | 3个+ | 1个 (colors) |
| 代码行数 | ~1400行 | ~400行 |
| 选择器数量 | 15+ | 7个常用 |
| CPU占用 | 较高 | 极低 |
| 配置复杂度 | 复杂 | 简单 |

## 技术支持

如有问题，请检查：
1. SourceMod 错误日志：`logs/errors_YYYYMMDD.log`
2. 插件是否正确加载：`sm plugins list`
3. 配置文件语法是否正确

## 更新日志

### v1.0.0 (2026-06-14)
- 初始版本
- 移除 chat-processor 依赖
- 简化选择器系统
- 完全兼容 rpg.sp 和 veterans.sp
- 使用 colors.inc 处理颜色
