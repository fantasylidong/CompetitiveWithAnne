# L4D2 近战武器属性系统 - 问题诊断报告

## 🔍 问题描述

用户报告：**近战武器的间隔、轨迹等大部分功能都没办法用**

## 📊 初步诊断

经过代码审查，近战武器属性系统 (`l4d2_pma_native_attrs.sp`) 的代码逻辑**本身是完整的**，包括：

### ✅ 已实现的功能

1. **属性定义** - 6种近战属性
   ```sourcepawn
   PmaAttr_Damage           // 伤害
   PmaAttr_RefireDelay      // 攻击间隔 ⭐
   PmaAttr_WeaponIdleTime   // 武器空闲时间
   PmaAttr_DamageFlags      // 伤害标志
   PmaAttr_RumbleEffect     // 震动效果
   PmaAttr_Decapitates      // 是否斩首
   ```

2. **Hook机制** - L4D_OnStartMeleeSwing forward
   - Pre hook: 修改属性
   - Post hook: 还原属性
   - Transaction管理: 完整的TX系统

3. **属性应用逻辑** - BeginMeleeOverlay/EndMeleeOverlay
   - 读取baseline
   - 应用profile值
   - 自动还原

4. **命令接口**
   - `sm_pma_set` - 设置属性
   - `sm_pma_list` - 查看配置
   - `sm_pma_clear` - 清除配置

## ⚠️ 可能的问题根源

### 问题1: Left4DHooks 近战natives未就绪

**症状检查**:
```sourcepawn
// 每次应用属性前都会检查：
if (!EnsureMeleeNativesReady(0, hookName)) {
    return false;  // ❌ 如果natives未就绪，直接跳过
}
```

**可能原因**:
1. Left4DHooks版本过旧，不支持近战natives
2. 地图未完全加载（`!L4D_HasMapStarted()`）
3. Left4DHooks本身未正确加载

**验证方法**:
```bash
# 检查日志
grep "melee_natives_not_ready\|left4dhooks_unavailable" logs/l4d2_pma_native_attrs.log

# 如果看到这些行，说明natives未就绪
```

---

### 问题2: L4D_OnStartMeleeSwing forward 未触发

**可能原因**:
1. Left4DHooks版本不支持该forward
2. Forward被其他插件阻止
3. 游戏版本不兼容

**验证方法**:
```bash
# 检查日志中是否有 StartMeleeSwing 相关的log
grep "StartMeleeSwing" logs/l4d2_pma_native_attrs.log

# 如果完全没有，说明forward从未触发
```

---

### 问题3: 近战武器名称获取失败

**症状检查**:
```sourcepawn
if (!GetActiveMeleeName(client, meleeName, sizeof(meleeName))) {
    return;  // ❌ 无法获取近战武器名
}
```

**可能原因**:
1. 武器不是 `weapon_melee` classname
2. `m_strMapSetScriptName` 属性为空
3. 武器模型识别失败

**验证方法**:
```bash
# 设置属性并查看日志
sm_pma_set @me baseball_bat damage 100

# 检查日志
grep "profile_set\|tx_begin" logs/l4d2_pma_native_attrs.log

# 如果看到 "tx_begin_empty"，说明条件检查失败
```

---

### 问题4: 属性应用后立即被还原

**症状**:
虽然属性被应用了，但因为某种原因立即被还原，导致实际上没有效果。

**可能原因**:
1. TX系统的frame不平衡
2. EndMeleeOverlay被过早调用
3. 多次swing导致相互覆盖

---

## 🔧 诊断步骤

### 步骤1: 验证Left4DHooks

```bash
# 1. 检查Left4DHooks是否加载
sm plugins list | grep -i left4d

# 2. 检查版本
sm plugins info left4dhooks

# 3. 检查melee natives是否可用
sm plugins info l4d2_pma_native_attrs
# 应该显示 "Natives: 0" 或者具体数量
```

### 步骤2: 启用详细日志

```bash
# 启用日志
sm_cvar l4d2_pma_log 1

# 设置属性
sm_pma_set @me baseball_bat refiredelay 0.1

# 检查配置
sm_pma_list
# 应该显示: Player: melee=baseball_bat refiredelay=0.1

# 挥动近战武器
# 然后检查日志
```

### 步骤3: 查看日志输出

```bash
tail -100 addons/sourcemod/logs/l4d2_pma_native_attrs.log

# 寻找这些关键行：
# 1. "melee_natives_ready ok=1" - natives就绪
# 2. "profile_set ... attr=refiredelay value=0.1" - 属性已设置
# 3. "tx_begin ... hook=StartMeleeSwing changed=1" - 开始应用
# 4. "tx_end ... hook=StartMeleeSwing restored=1" - 成功还原
```

---

## 🐛 已知问题和解决方案

### 可能问题1: Left4DHooks版本过旧

**解决方案**: 更新Left4DHooks到最新版本

最新版本应该包含：
- `L4D_OnStartMeleeSwing` forward
- `L4D2_Get/SetFloatMeleeAttribute` natives
- `L4D2_Get/SetIntMeleeAttribute` natives
- `L4D2_Get/SetBoolMeleeAttribute` natives

**检查方法**:
```bash
grep -n "L4D_OnStartMeleeSwing\|L4D2_.*MeleeAttribute" addons/sourcemod/scripting/include/left4dhooks.inc

# 如果找不到这些，说明版本太旧
```

---

### 可能问题2: 近战属性修改被游戏引擎忽略

**分析**: 类似PWA的FireBulletsInfo问题，近战属性可能也需要在特定时机修改

**当前机制**:
```
L4D_OnStartMeleeSwing (Pre)
  ↓
修改 MeleeWeaponInfo 属性
  ↓
游戏引擎执行挥击逻辑
  ↓
L4D_OnStartMeleeSwing_Post
  ↓
还原 MeleeWeaponInfo 属性
```

**潜在问题**: 
MeleeWeaponInfo 的值可能在 forward 触发**之前**就已经被读取到局部变量了。

**验证方法**:
查看 `/Users/morzlee/Documents/GitHub/l4d2Weapon` 中的反编译代码，检查近战挥击流程。

---

### 可能问题3: 属性索引错误

**检查属性定义**:
```sourcepawn
static PmaAttrDef g_AttrDefs[PmaAttr_Count] =
{
    { AttrKind_Float, "damage", view_as<int>(L4D2FMWA_Damage), true, true },
    { AttrKind_Float, "refiredelay", view_as<int>(L4D2FMWA_RefireDelay), true, false },
    { AttrKind_Float, "weaponidletime", view_as<int>(L4D2FMWA_WeaponIdleTime), true, false },
    { AttrKind_Int, "damageflags", view_as<int>(L4D2IMWA_DamageFlags), true, false },
    { AttrKind_Int, "rumbleeffect", view_as<int>(L4D2IMWA_RumbleEffect), true, false },
    { AttrKind_Bool, "decapitates", view_as<int>(L4D2BMWA_Decapitates), true, false }
};
```

**验证**: 确认 left4dhooks.inc 中的枚举值定义正确

```bash
grep "L4D2FMWA_RefireDelay\|L4D2FMWA_WeaponIdleTime" addons/sourcemod/scripting/include/left4dhooks.inc

# 应该输出：
# L4D2FMWA_Damage,         // 0
# L4D2FMWA_RefireDelay,    // 1
# L4D2FMWA_WeaponIdleTime, // 2
```

---

## 🧪 测试脚本

创建测试文件: `pma_diagnostic_test.cfg`

```cfg
echo "==================================="
echo "L4D2 PMA Diagnostic Test"
echo "==================================="

// 启用日志
sm_cvar l4d2_pma_log 1

// 测试1: 检查natives
sm plugins info l4d2_pma_native_attrs
echo "Check if 'Status: Running' and natives are available"

// 测试2: 设置简单属性
sm_pma_clear @me
sm_pma_set @me baseball_bat damage 100
sm_pma_list

echo "If you see 'Player: melee=baseball_bat damage=100', profile is set correctly"

// 测试3: 设置RefireDelay
sm_pma_set @me baseball_bat refiredelay 0.1
sm_pma_list

echo "Now swing the baseball bat rapidly"
echo "If RefireDelay works, you should be able to swing MUCH faster"

// 测试4: 检查日志
echo "Check logs/l4d2_pma_native_attrs.log for:"
echo "  - 'tx_begin hook=StartMeleeSwing changed=1'"
echo "  - 'tx_end hook=StartMeleeSwing restored=1'"

echo "==================================="
echo "Diagnostic test loaded"
echo "==================================="
```

---

## 💡 临时解决方案（如果forward不工作）

如果 `L4D_OnStartMeleeSwing` forward 不工作，可以尝试：

### 方案A: 使用 DHooks detour

类似PWA的做法，直接detour近战相关函数。

**需要逆向的函数**:
- `CTerrorMeleeWeapon::StartMeleeSwing()`
- `CTerrorMeleeWeapon::DoSwing()`

**优点**: 不依赖Left4DHooks的forward
**缺点**: 需要gamedata

### 方案B: 永久修改（不还原）

如果TX系统有问题，可以改为永久修改模式：
- 设置属性时直接修改MeleeWeaponInfo
- 不使用TX系统自动还原
- 切换武器或玩家断线时手动还原

---

## 📝 需要用户提供的信息

为了准确诊断问题，请提供：

1. **日志文件**
   ```bash
   # 执行测试后，提供日志
   cat addons/sourcemod/logs/l4d2_pma_native_attrs.log | tail -200
   ```

2. **Left4DHooks版本**
   ```bash
   sm plugins info left4dhooks
   ```

3. **测试结果**
   ```bash
   # 执行以下命令并报告结果
   sm_pma_set @me baseball_bat refiredelay 0.1
   sm_pma_list
   # 然后挥动棒球棍，观察攻击速度是否变快
   ```

4. **控制台输出**
   - 执行命令时的任何错误信息
   - `sm plugins info l4d2_pma_native_attrs` 的输出

---

## 🎯 下一步行动

### 立即检查

1. ✅ 检查 Left4DHooks 是否加载
2. ✅ 验证 melee natives 是否可用
3. ✅ 启用日志并测试
4. ✅ 查看日志输出

### 如果问题确认

根据诊断结果选择对应的修复方案：
- **Natives未就绪** → 更新Left4DHooks
- **Forward不触发** → 考虑使用DHooks detour
- **属性立即被还原** → 检查TX系统逻辑
- **属性修改无效** → 需要逆向分析时机问题（类似FireBulletsInfo）

---

**诊断报告创建日期**: 2026-06-15  
**需要用户反馈**: 日志文件和测试结果
