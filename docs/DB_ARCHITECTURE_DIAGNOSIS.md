# 🔍 L4D2 玩家属性系统 - 数据库架构诊断

## 📦 系统架构

你的系统使用**数据库驱动**的属性配置，而不是手动命令！

### 架构图

```
数据库 (MySQL/SQLite)
  ↓
l4d2_player_attr_db.sp (协调器)
  ↓ 从数据库加载配置
  ↓ 调用 natives
  ├─→ PWA_SetAttrString() → l4d2_pwa_native_attrs.sp (枪械)
  ├─→ PMA_SetAttrString() → l4d2_pma_native_attrs.sp (近战)
  └─→ PMATrace_SetAttrString() → l4d2_pma_trace_attrs.sp (轨迹)
  └─→ PMAAttackSeg_SetAttrString() → l4d2_pma_attackseg_attrs.sp (攻击段)
```

### 工作流程

```
1. 玩家加入服务器
   ↓
2. l4d2_player_attr_db 查询数据库
   ↓ 根据 SteamID/auth 查找玩家配置
   ↓
3. 找到配置行 (target_type=pma, item=knife, attr=refiredelay, value=0.05)
   ↓
4. 调用 PMA_SetAttrString(client, "knife", "refiredelay", "0.05", false)
   ↓
5. l4d2_pma_native_attrs 设置 profile
   ↓ 日志: profile_set source=native ...
   ↓
6. 玩家挥刀
   ↓ tx_begin ... changed=1 ✅
```

---

## 🔍 问题诊断

### 从日志分析

你的日志显示：
- ❌ **没有 profile_set source=native** 
- ❌ 只有 profile_clear source=native
- ⚠️ tx_begin_empty（profile是空的）

### 可能的原因

#### 1. 数据库插件未加载

```bash
# 检查插件是否加载
sm plugins list | grep player_attr
```

**预期输出**:
```
[XX] "L4D2 Player Attr DB Coordinator Private" (0.1.5-private)
```

如果没有输出，说明插件未加载。

---

#### 2. 数据库未连接

```bash
# 检查数据库状态
sm_pattrdb_status
```

**预期输出**:
```
[PATTR-DB] enabled=1 connected=1 rows=XX ...
```

**如果 connected=0**:
- 检查 `databases.cfg` 中的数据库配置
- 检查日志中的 `db_connect_failed` 错误

---

#### 3. 数据库中没有配置数据

```bash
# 检查缓存的配置行数
sm_pattrdb_status
```

**预期输出**:
```
rows=10 (或其他非0数字)
```

**如果 rows=0**:
- 数据库表为空
- 或者查询条件不匹配（SteamID、mode、weapon_config等）

---

#### 4. 许可证验证失败

```bash
# 检查许可证
sm_private_license_status
```

**预期输出**:
```
licensed=1 validated=1
```

如果失败，所有私有插件都不会工作。

---

#### 5. Native不可用

```bash
# 检查natives是否可用
sm_pattrdb_status
```

**预期输出**:
```
natives pwa=1 pma=1 trace=1 attackseg=1
```

**如果 pma=0**:
- l4d2_pma_native_attrs.sp 未加载
- 或者加载顺序错误

---

## 🔧 诊断步骤

### 步骤1: 检查插件加载

```bash
sm plugins list | grep -E "player_attr|pma_native|pwa_native"
```

**应该看到**:
```
[XX] "L4D2 Player Attr DB Coordinator Private" (running)
[XX] "L4D2 PMA Native Attrs Private" (running)
[XX] "L4D2 PWA Native Attrs Private" (running)
[XX] "L4D2 PMA Melee Trace Attrs Private" (running)
```

---

### 步骤2: 检查数据库状态

```bash
sm_pattrdb_status
```

**关键信息**:
- `enabled=1` - 插件已启用
- `connected=1` - 数据库已连接
- `rows=X` - 缓存了X行配置（**如果是0就有问题**）
- `natives pma=1` - PMA native可用

---

### 步骤3: 检查数据库内容

如果 `rows=0`，需要检查数据库：

```sql
-- 查看表结构
DESCRIBE l4d2_player_attr_profiles;

-- 查看所有配置
SELECT * FROM l4d2_player_attr_profiles;

-- 查看特定玩家的配置（假设你的SteamID是 STEAM_1:0:12345678）
SELECT * FROM l4d2_player_attr_profiles 
WHERE auth = 'STEAM_1:0:12345678' 
   OR auth = '*';

-- 查看近战相关配置
SELECT * FROM l4d2_player_attr_profiles 
WHERE target_type = 'pma';
```

---

### 步骤4: 手动重载数据库

```bash
# 强制重载数据库
sm_pattrdb_reload

# 再次检查状态
sm_pattrdb_status

# 手动应用配置到自己
sm_pattrdb_apply @me

# 查看日志
# 应该看到 profile_set source=native
```

---

### 步骤5: 查看详细日志

```bash
# 查看数据库协调器日志
tail -100 addons/sourcemod/logs/l4d2_player_attr_db.log

# 关键日志行：
# - db_connect_ok - 数据库连接成功
# - db_load_ok rows=X - 加载了X行
# - apply_client ... applied=X - 应用了X个属性
```

---

## 📊 数据库表结构

根据代码分析，数据库表应该是这样的：

```sql
CREATE TABLE l4d2_player_attr_profiles (
    auth VARCHAR(64),           -- SteamID 或 "*" (通配符)
    mode VARCHAR(64),           -- 模式名称 或 "*"
    target_type VARCHAR(16),    -- "pma", "pwa", "trace", "attackseg"
    item VARCHAR(64),           -- 武器/近战名称 (如 "knife", "weapon_rifle_ak47")
    attr VARCHAR(64),           -- 属性名称 (如 "refiredelay", "damage")
    value VARCHAR(64),          -- 属性值 (如 "0.05", "500")
    priority INT,               -- 优先级（数字越大越优先）
    enabled INT                 -- 是否启用（1=启用，0=禁用）
);
```

### 示例数据

```sql
-- 给所有玩家设置小刀的快速攻击
INSERT INTO l4d2_player_attr_profiles 
VALUES ('*', '*', 'pma', 'knife', 'refiredelay', '0.05', 100, 1);

-- 给所有玩家设置小刀的高伤害
INSERT INTO l4d2_player_attr_profiles 
VALUES ('*', '*', 'pma', 'knife', 'damage', '500', 100, 1);

-- 给特定玩家设置AK47的高伤害
INSERT INTO l4d2_player_attr_profiles 
VALUES ('STEAM_1:0:12345678', '*', 'pwa', 'weapon_rifle_ak47', 'damage', '100', 100, 1);
```

---

## 🎯 快速修复方案

### 方案A: 检查数据库是否有数据

```bash
# 1. 检查状态
sm_pattrdb_status

# 2. 如果 rows=0，说明数据库是空的
# 需要添加配置数据到数据库

# 3. 重载并应用
sm_pattrdb_reload
sm_pattrdb_apply @me
```

---

### 方案B: 临时使用手动命令（绕过数据库）

如果数据库有问题，可以临时使用手动命令：

```bash
# 禁用数据库协调器
sm_cvar l4d2_player_attr_db_enable 0

# 使用手动命令
sm_pma_set @me knife refiredelay 0.05 damage 500

# 应该能看到效果
```

---

### 方案C: 创建测试数据

如果数据库是空的，创建测试数据：

```sql
-- 连接到数据库
mysql -u username -p database_name

-- 或者 SQLite
sqlite3 path/to/database.db

-- 插入测试数据（所有玩家、所有模式、小刀快速攻击）
INSERT INTO l4d2_player_attr_profiles 
(auth, mode, target_type, item, attr, value, priority, enabled)
VALUES 
('*', '*', 'pma', 'knife', 'refiredelay', '0.05', 100, 1),
('*', '*', 'pma', 'knife', 'damage', '500', 100, 1),
('*', '*', 'pma', 'baseball_bat', 'refiredelay', '0.1', 100, 1),
('*', '*', 'trace', 'knife', 'range', '150', 100, 1);

-- 然后在游戏中重载
```

```bash
sm_pattrdb_reload
sm_pattrdb_status
# 应该看到 rows=4

sm_pattrdb_apply @me
# 应该在日志中看到 profile_set source=native
```

---

## 📝 需要你提供的信息

为了精确诊断，请提供：

### 1. 插件加载状态

```bash
sm plugins list | grep -E "player_attr|pma|pwa"
```

### 2. 数据库状态

```bash
sm_pattrdb_status
```

### 3. 数据库日志

```bash
cat addons/sourcemod/logs/l4d2_player_attr_db.log | tail -100
```

### 4. 数据库配置

```bash
cat addons/sourcemod/configs/databases.cfg | grep -A 10 sourcebans
# 或者你使用的数据库配置名
```

### 5. 数据库内容（如果可以访问）

```sql
SELECT * FROM l4d2_player_attr_profiles LIMIT 20;
```

---

## 🎯 预期的工作流程（正常情况）

```
1. 服务器启动
   → l4d2_player_attr_db 连接数据库
   → 日志: db_connect_ok

2. 加载配置
   → 查询数据库表
   → 日志: db_load_ok rows=X

3. 玩家加入
   → 根据SteamID/mode/weapon_config查找配置
   → 日志: apply_client ... applied=Y

4. 调用natives
   → PMA_SetAttrString(client, "knife", "refiredelay", "0.05", false)
   → 日志（在 l4d2_pma_native_attrs.log）: profile_set source=native

5. 玩家挥刀
   → 日志: tx_begin ... changed=1
   → 属性生效 ✅
```

---

## 💡 总结

**问题根源**: 
- 不是代码问题
- 是数据库配置问题
- 要么数据库未连接
- 要么数据库表是空的

**下一步**:
提供上面要求的5个信息，我就能精确定位问题！

---

**创建日期**: 2026-06-15  
**系统**: 数据库驱动的玩家属性系统
