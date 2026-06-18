# 🎯 L4D2 近战武器完整使用指南

## 📦 插件架构

你有**两个独立的近战武器插件**：

### 1️⃣ l4d2_pma_native_attrs.sp - 基础属性

**功能**: 修改近战武器的基础属性（伤害、攻击速度等）

**可修改属性**:
- `damage` - 伤害值
- `refiredelay` - 攻击间隔（数值越小攻击越快）
- `weaponidletime` - 武器空闲时间
- `damageflags` - 伤害标志
- `rumbleeffect` - 震动效果
- `decapitates` - 是否斩首

**命令格式**:
```bash
sm_pma_set <target> <melee_name> <attr> <value> [attr value]...
sm_pma_clear <target>
sm_pma_list
```

### 2️⃣ l4d2_pma_trace_attrs.sp - 轨迹/范围属性

**功能**: 修改近战武器的攻击范围和轨迹

**可修改属性**:
- `range` - 攻击范围（默认70.0）
- `dirscale` - 方向缩放
- `yawbias` - 偏航偏移

**命令格式**:
```bash
sm_pma_trace_attr_set <target> <melee_name> <attr> <value> [attr value]...
sm_pma_trace_attr_clear <target>
sm_pma_trace_attr_list
sm_pma_trace_attr_status
```

---

## 🎮 完整使用示例

### 场景1: 超快攻击速度 + 高伤害

```bash
# 拿起小刀（knife）

# 设置快速攻击和高伤害
sm_pma_set @me knife refiredelay 0.05 damage 500

# 查看配置
sm_pma_list

# 预期效果：
# - 攻击速度非常快（可以疯狂点击）
# - 每次攻击500伤害（一刀秒普通感染者）
```

### 场景2: 超远攻击范围

```bash
# 拿起棒球棍

# 设置超远范围
sm_pma_trace_attr_set @me baseball_bat range 200

# 查看配置
sm_pma_trace_attr_list

# 预期效果：
# - 可以从很远的距离击中敌人（默认70，现在200）
```

### 场景3: 组合使用 - 终极近战

```bash
# 拿起武士刀（katana）

# 设置基础属性
sm_pma_set @me katana refiredelay 0.03 damage 1000

# 设置轨迹属性
sm_pma_trace_attr_set @me katana range 150

# 查看配置
sm_pma_list
sm_pma_trace_attr_list

# 预期效果：
# - 攻击极快（0.03秒间隔）
# - 伤害超高（1000）
# - 范围超远（150）
# = 近战之神模式！
```

### 场景4: 清除所有设置

```bash
# 清除基础属性
sm_pma_clear @me

# 清除轨迹属性
sm_pma_trace_attr_clear @me

# 恢复默认
```

---

## 🔍 你之前的测试问题

### 问题诊断

从日志看：
1. ❌ **从未使用 `sm_pma_set` 设置过属性**
2. ❌ **从未使用 `sm_pma_trace_attr_set` 设置过范围**
3. ✅ 只有 `profile_clear`（清除命令）
4. ✅ 两个插件都正常工作，只是没有配置

### 日志应该显示什么

**正确使用后的日志**:

```
# l4d2_pma_native_attrs.log 应该有:
profile_set source=command client=1 melee=knife attr=refiredelay value=0.05
tx_begin ... hook=StartMeleeSwing changed=1 summary=refiredelay=0.05
(不是 tx_begin_empty 和 changed=0)

# l4d2_pma_trace_attrs.log 应该有:
profile_set source=command client=1 melee=knife attr=range value=150
test_collision_pre ... range_changed=1 old_range=70.0 new_range=150.0
(不是只有 profile_clear)
```

---

## 📝 快速测试脚本

创建文件: `melee_full_test.cfg`

```cfg
echo "==================================="
echo "L4D2 Melee Complete Test"
echo "==================================="

// 清除所有配置
sm_pma_clear @me
sm_pma_trace_attr_clear @me

echo "Step 1: Pick up a knife"
echo "Press ENTER when ready..."
wait 300

// 测试1: 基础属性
echo ""
echo "Test 1: Fast Attack + High Damage"
sm_pma_set @me knife refiredelay 0.05 damage 500
sm_pma_list
echo "▲ Should show: Player: melee=knife refiredelay=0.05 damage=500"
echo "Now swing the knife rapidly - it should be MUCH faster!"
wait 500

// 测试2: 轨迹属性
echo ""
echo "Test 2: Extended Range"
sm_pma_trace_attr_set @me knife range 150
sm_pma_trace_attr_list
echo "▲ Should show range=150"
echo "Now try hitting zombies from farther away!"
wait 500

// 测试3: 组合效果
echo ""
echo "Test 3: Ultimate Melee Mode"
echo "You should now have:"
echo "  - Super fast attacks (refiredelay 0.05)"
echo "  - High damage (500)"
echo "  - Extended range (150)"
echo "Try it out!"
wait 1000

// 清除
echo ""
echo "Clearing all settings..."
sm_pma_clear @me
sm_pma_trace_attr_clear @me
echo "Settings cleared - back to normal"

echo "==================================="
echo "Test Complete!"
echo "==================================="
```

---

## 🎯 常见近战武器名称

```
knife           - 小刀（默认）
baseball_bat    - 棒球棍
cricket_bat     - 板球拍
crowbar         - 撬棍
electric_guitar - 电吉他
fireaxe         - 消防斧
frying_pan      - 平底锅
golfclub        - 高尔夫球杆
katana          - 武士刀
machete         - 砍刀
tonfa           - 警棍
shovel          - 铲子
pitchfork       - 干草叉
```

---

## ⚙️ 属性范围建议

### 基础属性（native_attrs）

```bash
# refiredelay - 攻击间隔
默认: 0.5-1.0
推荐: 0.05-0.2（快速攻击）
极限: 0.01（超快，可能卡顿）

# damage - 伤害
默认: 250-350
推荐: 500-1000（高伤害）
极限: 10000（秒杀一切）

# weaponidletime - 空闲时间
默认: 2.0-3.0
推荐: 0.1-0.5（快速收回）
```

### 轨迹属性（trace_attrs）

```bash
# range - 攻击范围
默认: 70.0
推荐: 100-150（远程）
极限: 300（超远，可能不合理）

# dirscale - 方向缩放
默认: 1.0
推荐: 0.8-1.5（调整轨迹宽度）

# yawbias - 偏航偏移
默认: 0.0
推荐: -30 到 +30（调整攻击角度）
```

---

## 🐛 故障排查

### 问题1: 设置了但没效果

```bash
# 1. 确认插件加载
sm plugins list | grep pma

# 2. 查看配置
sm_pma_list
sm_pma_trace_attr_list

# 3. 检查日志
tail -50 logs/l4d2_pma_native_attrs.log
tail -50 logs/l4d2_pma_trace_attrs.log

# 4. 确认武器名正确
# 使用 @active 自动匹配当前武器
sm_pma_set @me @active refiredelay 0.05
```

### 问题2: 范围修改不生效

检查 `l4d2_pma_trace_attrs` 的配置：

```bash
# 检查是否允许向量修改
sm_cvar l4d2_pma_trace_attr_allow_vector_change

# 如果是0，改成1
sm_cvar l4d2_pma_trace_attr_allow_vector_change 1
```

---

## 📊 总结

### 之前的问题

- ❌ 你从未使用过 `sm_pma_set` 设置属性
- ❌ 你从未使用过 `sm_pma_trace_attr_set` 设置范围
- ✅ 两个插件都工作正常，只是没有配置

### 现在的解决方案

```bash
# 1. 设置攻击速度和伤害
sm_pma_set @me knife refiredelay 0.05 damage 500

# 2. 设置攻击范围
sm_pma_trace_attr_set @me knife range 150

# 3. 测试
# 挥动小刀，应该能感觉到明显变化

# 4. 查看日志确认
grep "profile_set\|tx_begin.*changed=1" logs/l4d2_pma_native_attrs.log
grep "profile_set\|range_changed=1" logs/l4d2_pma_trace_attrs.log
```

---

**现在去试试吧！应该能正常工作了！** 🎮⚔️
