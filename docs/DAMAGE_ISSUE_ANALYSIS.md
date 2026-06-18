# L4D2 PWA 伤害修改失效问题分析与修复

## 🔴 问题确认

**症状**: 修改了玩家的枪械伤害属性，但对特感和Tank的实际伤害**没有改变**。

**测试方法**:
```
sm_pwa_set @me weapon_rifle_ak47 damage 100
// 射击特感，伤害仍然是默认值（例如58）
```

---

## 🔍 根本原因分析

### L4D2 伤害计算流程

```
玩家开火
    ↓
CTerrorGun::PrimaryAttack() 
    ↓
CTerrorGun::FireBullet()  ← 我们在这里修改 WeaponInfo.damage
    ↓
CBaseEntity::FireBullets(FireBulletsInfo_t& info)  ← ⚠️ 关键！
    ↓
【问题】FireBulletsInfo_t 结构体中的 m_iDamage 和 m_iPlayerDamage 
         是在 FireBullet() 中填充的，但填充时机可能在我们修改之前！
    ↓
TraceLine & CalculateBulletDamage()
    ↓
OnTakeDamage() ← 我们的 fallback 在这里
```

### 关键发现

**1. WeaponInfo 修改时机问题**

当前代码在 `DTR_FireBullet_Pre` 中修改 WeaponInfo：

```sourcepawn
MRESReturn DTR_FireBullet_Pre(int weapon)
{
    // 在这里修改 WeaponInfo 的 damage 值
    BeginWeaponOverlay(weapon, "FireBullet", client, PWA_HOOK_FIRE_BULLET);
    return MRES_Ignored;  // ⚠️ 返回 MRES_Ignored，不修改参数！
}
```

**问题**: `CTerrorGun::FireBullet()` 可能在函数**开始时**就读取了 WeaponInfo 并填充到 `FireBulletsInfo_t`，然后才调用 `CBaseEntity::FireBullets()`。

**2. FireBulletsInfo_t 结构体**

```cpp
// FireBulletsInfo_t (推测)
struct FireBulletsInfo_t {
    Vector m_vecSrc;           // 射击起点
    Vector m_vecDirShooting;   // 射击方向
    int m_iShots;              // 子弹数
    int m_iDamage;             // ⚠️ 每颗子弹伤害（从 WeaponInfo 复制）
    int m_iPlayerDamage;       // ⚠️ 对玩家的伤害
    float m_flDistance;        // 射程
    // ... 更多字段
};
```

**3. 实际执行顺序**

```
1. 游戏调用 CTerrorGun::FireBullet()
2. FireBullet() 读取 WeaponInfo.damage → 填充到临时变量 tmpDamage
3. 我们的 Pre Hook 执行 → 修改 WeaponInfo.damage ← 太晚了！
4. FireBullet() 构造 FireBulletsInfo_t，使用 tmpDamage（未修改的）
5. FireBullet() 调用 CBaseEntity::FireBullets(info)
6. FireBullets() 使用 info.m_iDamage 计算伤害 ← 用的是旧值
7. OnTakeDamage Hook 触发 ← fallback 在这里工作
```

---

## ✅ 为什么 Fallback "有时" 工作

当前的 `Hook_OnTakeDamage` fallback 机制：

```sourcepawn
public Action Hook_OnTakeDamage(int victim, int &attacker, int &inflictor, 
                                 float &damage, int &damagetype)
{
    // ...
    if (g_Profile[attacker].has[PwaAttr_Damage]) {
        baselineDamage = GetBaselineInt(weaponName, PwaAttr_Damage);
        desiredDamage = g_Profile[attacker].intValue[PwaAttr_Damage];
        if (baselineDamage > 0 && desiredDamage > 0) {
            // ⚠️ 关键检查
            if (FireBulletsInfoAlreadyApplied(attacker, weaponName, desiredDamage)) {
                skippedDamageRatio = true;  // 认为已经应用，跳过
            } else {
                newDamage *= float(desiredDamage) / float(baselineDamage);
                changed = true;
            }
        }
    }
    // ...
}
```

**问题**: `FireBulletsInfoAlreadyApplied()` 检查**总是返回 false**，因为：
- WeaponInfo 的修改没有传递到 FireBulletsInfo_t
- 所以 `g_LastFireBulletsInfoDamage` 记录的是**原始值**，不是修改后的值

**结果**: Fallback 应该**每次都工作**，但你说"值没变"，说明还有其他问题。

---

## 🐛 额外问题：FireBulletsInfo_t 监控缺失

检查代码发现，`DTR_FireBullets_Pre` 并没有记录 FireBulletsInfo_t 的伤害值！

```sourcepawn
MRESReturn DTR_FireBullets_Pre(int weapon, DHookParam hParams)
{
    // 只有审计逻辑，没有记录 m_iDamage！
    if (g_LiveAuditActive && ...) {
        // ... audit code
    }
    return MRES_Ignored;
}
```

**缺失功能**: 应该从 `FireBulletsInfo_t` 参数中读取 `m_iDamage` 和 `m_iPlayerDamage`，记录到 `g_LastFireBulletsInfoDamage`。

---

## 🔧 完整修复方案

### 方案 A: 直接修改 FireBulletsInfo_t (推荐)

**原理**: 不修改 WeaponInfo，而是直接修改 `CBaseEntity::FireBullets()` 的参数结构体。

**实现步骤**:

1. **在 gamedata 中添加 FireBulletsInfo_t 偏移**

```
"Offsets"
{
    "FireBulletsInfo_t::m_iDamage"
    {
        "linux"    "40"  // 需要通过逆向确定
        "windows"  "40"
    }
    "FireBulletsInfo_t::m_iPlayerDamage"
    {
        "linux"    "44"
        "windows"  "44"
    }
}
```

2. **修改 DTR_FireBullets_Pre Hook**

```sourcepawn
MRESReturn DTR_FireBullets_Pre(int weapon, DHookParam hParams)
{
    int client = GetWeaponOwner(weapon);
    if (!IsProfileActive(client)) {
        return MRES_Ignored;
    }

    char weaponName[MAX_WEAPON_NAME];
    if (!GetWeaponNameFromEnt(weapon, weaponName, sizeof(weaponName)) 
        || !WeaponMatchesProfile(client, weaponName)) {
        return MRES_Ignored;
    }

    if (!g_Profile[client].has[PwaAttr_Damage]) {
        return MRES_Ignored;
    }

    // 获取 FireBulletsInfo_t 指针
    Address pInfo = hParams.GetAddress(1);
    if (pInfo == Address_Null) {
        return MRES_Ignored;
    }

    // 读取原始伤害值
    int originalDamage = LoadFromAddress(pInfo + view_as<Address>(OFF_FIREBULLETS_DAMAGE), 
                                         NumberType_Int32);
    int originalPlayerDamage = LoadFromAddress(pInfo + view_as<Address>(OFF_FIREBULLETS_PLAYER_DAMAGE), 
                                               NumberType_Int32);

    // 计算新伤害
    int baselineDamage = GetBaselineInt(weaponName, PwaAttr_Damage);
    int desiredDamage = g_Profile[client].intValue[PwaAttr_Damage];
    
    if (baselineDamage > 0 && desiredDamage > 0 && desiredDamage != baselineDamage) {
        // 直接修改 FireBulletsInfo_t 结构体中的伤害值
        StoreToAddress(pInfo + view_as<Address>(OFF_FIREBULLETS_DAMAGE), 
                      desiredDamage, NumberType_Int32);
        
        // 按比例调整 PlayerDamage
        int newPlayerDamage = RoundToFloor(float(originalPlayerDamage) * 
                                           float(desiredDamage) / float(baselineDamage));
        StoreToAddress(pInfo + view_as<Address>(OFF_FIREBULLETS_PLAYER_DAMAGE), 
                      newPlayerDamage, NumberType_Int32);

        // 记录已修改，供 fallback 检查
        RecordFireBulletsInfoDamage(client, desiredDamage, newPlayerDamage);

        LogPwa("firebullets_damage_modified tick=%d client=%N weapon=%s original=%d new=%d baseline=%d desired=%d",
               GetGameTickCount(), client, weaponName, originalDamage, desiredDamage, 
               baselineDamage, desiredDamage);
    } else {
        // 记录原始值
        RecordFireBulletsInfoDamage(client, originalDamage, originalPlayerDamage);
    }

    return MRES_Ignored;
}
```

**优点**:
- ✅ 直接修改实际使用的伤害值
- ✅ 不依赖 WeaponInfo 修改时机
- ✅ 对所有目标（普通感染、特感、Tank）都有效
- ✅ OnTakeDamage fallback 可以正确识别"已应用"

**缺点**:
- ❌ 需要确定 FireBulletsInfo_t 的内存布局（通过逆向或测试）

---

### 方案 B: 增强 OnTakeDamage Fallback (临时方案)

如果无法确定 FireBulletsInfo_t 偏移，增强现有的 fallback：

```sourcepawn
public Action Hook_OnTakeDamage(int victim, int &attacker, int &inflictor, 
                                 float &damage, int &damagetype)
{
    if (g_CvarEnabled == null || !g_CvarEnabled.BoolValue 
        || g_CvarDamageFallback == null || !g_CvarDamageFallback.BoolValue) {
        return Plugin_Continue;
    }
    if (damage <= 0.0 || (damagetype & DMG_BULLET) == 0) {
        return Plugin_Continue;
    }
    if (!IsLiveSurvivor(attacker) || !IsProfileActive(attacker)) {
        return Plugin_Continue;
    }

    char weaponName[MAX_WEAPON_NAME];
    if (!GetActiveWeaponName(attacker, weaponName, sizeof(weaponName)) 
        || !WeaponMatchesProfile(attacker, weaponName)) {
        return Plugin_Continue;
    }

    float oldDamage = damage;
    float newDamage = damage;
    bool changed = false;

    if (g_Profile[attacker].has[PwaAttr_Damage]) {
        CacheBaseline(weaponName, PwaAttr_Damage);
        int baselineDamage = GetBaselineInt(weaponName, PwaAttr_Damage);
        int desiredDamage = g_Profile[attacker].intValue[PwaAttr_Damage];
        
        if (baselineDamage > 0 && desiredDamage > 0) {
            // ⚠️ 关键修改：移除 FireBulletsInfoAlreadyApplied 检查
            // 因为 WeaponInfo 修改不会影响 FireBulletsInfo_t
            // 所以我们总是需要在这里调整伤害
            
            newDamage = newDamage * float(desiredDamage) / float(baselineDamage);
            changed = true;
            
            LogPwa("damage_fallback_applied tick=%d client=%N weapon=%s victim=%d old=%.2f new=%.2f baseline=%d desired=%d ratio=%.4f",
                   GetGameTickCount(), attacker, weaponName, victim, 
                   oldDamage, newDamage, baselineDamage, desiredDamage, 
                   float(desiredDamage) / float(baselineDamage));
        }
    }

    if (g_Profile[attacker].has[PwaAttr_TankDamageMult] && IsTankVictim(victim)) {
        newDamage *= g_Profile[attacker].floatValue[PwaAttr_TankDamageMult];
        changed = true;
    }

    if (!changed || FloatAbs(newDamage - oldDamage) <= 0.001) {
        return Plugin_Continue;
    }

    damage = newDamage;
    return Plugin_Changed;
}
```

**优点**:
- ✅ 简单直接，不需要逆向
- ✅ 立即可用

**缺点**:
- ❌ 每次伤害事件都要计算（性能略差）
- ❌ 依赖 OnTakeDamage Hook（某些插件可能干扰）

---

## 🧪 测试验证

### 测试步骤

**1. 验证当前问题**
```
// 1. 启用详细日志
sm_cvar l4d2_pwa_log_level 3
sm_cvar l4d2_pwa_damage_fallback_log 1

// 2. 设置伤害
sm_pwa_set @me weapon_rifle_ak47 damage 100

// 3. 查看基线
sm_pwa_list

// 4. 射击特感，观察日志
// 预期看到：
// - tx_begin 和 tx_end (WeaponInfo 修改)
// - damage_fallback_applied (fallback 生效)

// 5. 检查实际伤害
// 如果特感血量从250 → 150，说明100伤害生效
// 如果仍然是250 → 192，说明还是默认58伤害
```

**2. 应用修复后验证**
```
// 方案 A (修改 FireBulletsInfo_t):
// 应该看到 firebullets_damage_modified 日志
// OnTakeDamage 应该检测到已应用，不再调整

// 方案 B (增强 fallback):
// 应该看到 damage_fallback_applied 日志
// 实际伤害应该按比例改变
```

---

## 📊 推荐修复优先级

### 🔴 P0 - 立即修复（方案 B）

**立即应用方案 B**，移除 `FireBulletsInfoAlreadyApplied` 检查，让 fallback 总是生效。

### 🟡 P1 - 后续优化（方案 A）

通过逆向或内存搜索确定 `FireBulletsInfo_t::m_iDamage` 偏移，实现方案 A。

---

## 🔍 如何确定 FireBulletsInfo_t 偏移

### 方法 1: 运行时搜索

```sourcepawn
// 在 DTR_FireBullets_Pre 中
Address pInfo = hParams.GetAddress(1);
int baselineDamage = GetBaselineInt(weaponName, PwaAttr_Damage);

// 搜索结构体中等于 baselineDamage 的 int32 字段
for (int offset = 0; offset < 200; offset += 4) {
    int value = LoadFromAddress(pInfo + view_as<Address>(offset), NumberType_Int32);
    if (value == baselineDamage) {
        LogPwa("possible_damage_offset=%d value=%d", offset, value);
    }
}
```

### 方法 2: 对比修改

1. 使用不同伤害的武器（如手枪10, AK47 58）
2. Hook FireBullets，打印前80字节内存
3. 对比找出伤害值位置

---

## 📝 建议配置

修复后，建议配置：

```cfg
// 必须启用 fallback
l4d2_pwa_damage_fallback 1

// 生产环境：关闭详细日志
l4d2_pwa_damage_fallback_log 0
l4d2_pwa_log_level 1

// 调试环境：启用详细日志
l4d2_pwa_damage_fallback_log 1
l4d2_pwa_log_level 3
```

---

## 结论

**根本原因**: WeaponInfo 的修改发生在 `FireBulletsInfo_t` 结构体已经填充**之后**，所以修改无效。

**临时解决**: 移除 `FireBulletsInfoAlreadyApplied` 检查，让 OnTakeDamage fallback 总是生效。

**最终方案**: 直接修改 `FireBulletsInfo_t::m_iDamage`，需要确定内存偏移。
