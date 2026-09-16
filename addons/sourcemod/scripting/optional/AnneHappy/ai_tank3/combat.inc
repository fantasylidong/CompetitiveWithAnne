#if defined _ai_tank3_combat_included
    #endinput
#endif
#define _ai_tank3_combat_included

// =========================================================================
// 挥拳、通背拳、投石
// =========================================================================

bool Combat_IsClawReady(int tank)
{
    int claw = GetEntPropEnt(tank, Prop_Send, "m_hActiveWeapon");
    if (claw <= 0 || !IsValidEdict(claw) || !HasEntProp(claw, Prop_Send, "m_flNextPrimaryAttack"))
        return false;
    return GetEntPropFloat(claw, Prop_Send, "m_flNextPrimaryAttack") <= GetGameTime();
}

void Combat_PunchLockVision(int tank, const float pos[3], const float targetPos[3])
{
    if (!g_cvPunchLockVision.BoolValue)
        return;

    int claw = GetEntPropEnt(tank, Prop_Send, "m_hActiveWeapon");
    if (claw <= 0 || !IsValidEdict(claw) || !HasEntProp(claw, Prop_Send, "m_flNextPrimaryAttack"))
        return;

    // m_flNextPrimaryAttack 属于 GameTime 时钟域；挥拳刚开始的那一帧把视角对准目标
    float now = GetGameTime();
    float nextAttack = GetEntPropFloat(claw, Prop_Send, "m_flNextPrimaryAttack");
    if (g_Tank[tank].nextAttackTime < now && nextAttack > now)
    {
        float lookAt[3], angles[3];
        MakeVectorFromPoints(pos, targetPos, lookAt);
        GetVectorAngles(lookAt, angles);
        TeleportEntity(tank, NULL_VECTOR, angles, NULL_VECTOR);
    }
    g_Tank[tank].nextAttackTime = nextAttack;
}

bool Combat_LimitThrowDistance(int tank, int &buttons, float dist)
{
    if (!(buttons & IN_ATTACK2) || g_Tank[tank].throwing || g_Tank[tank].rockPendingUntil > GetEngineTime())
        return false;
    if (dist >= g_cvThrowMinDist.FloatValue && dist <= g_cvThrowMaxDist.FloatValue)
        return false;

    buttons &= ~IN_ATTACK2;
    return true;
}

void Combat_SweepFist(int claw, const float start[3], const float end[3])
{
    if (g_hSdkTankClawSweepFist == null)
        return;

    float from[3], to[3];
    from = start;
    to = end;
    SDKCall(g_hSdkTankClawSweepFist, claw, from, to);
}

bool Combat_IsBackFistAllowed(int tank)
{
    if (!IsClientOnGround(tank) || GetEntityMoveType(tank) == MOVETYPE_LADDER)
        return false;
    float expire = g_Tank[tank].backFistExpire;
    return expire > 0.0 && GetEngineTime() <= expire;
}

public void L4D_TankClaw_DoSwing_Post(int tank, int claw)
{
    if (!g_cvEnable.BoolValue || !isAiTank(tank) || claw <= 0 || !IsValidEdict(claw))
        return;
    if (GetEntityMoveType(tank) == MOVETYPE_LADDER)
        return;

    float tankEye[3];
    GetClientEyePosition(tank, tankEye);

    // 骑头者额外向上扫一拳
    bool upSwing = g_cvHeadBlockEnable.BoolValue && g_cvHeadBlockUpSwing.BoolValue && g_cvHeadBlockRideEnable.BoolValue;
    if (upSwing)
    {
        for (int survivor = 1; survivor <= MaxClients; survivor++)
        {
            if (!Riding_IsRiding(tank, survivor) || !Riding_CanPunch(tank, survivor))
                continue;

            float riderChest[3];
            GetClientAbsOrigin(survivor, riderChest);
            riderChest[2] += PLAYER_CHEST;
            Combat_SweepFist(claw, tankEye, riderChest);
            if (log != null)
                log.debugAll("%N up-swing at rider %N", tank, survivor);
        }
    }

    // 通背拳：爪击命中后的窗口内、几乎静止时，顺带扫到身后近处的人
    if (!g_cvBackFist.BoolValue)
        return;

    float velocity[3];
    GetEntPropVector(tank, Prop_Data, "m_vecAbsVelocity", velocity);
    if (AIPathMovement_GetHorizontalSpeed(velocity) > g_cvBackFistAllowMaxSpd.FloatValue || !Combat_IsBackFistAllowed(tank))
        return;

    float fistRange = g_cvBackFistRange.FloatValue >= 0.0 ? g_cvBackFistRange.FloatValue : g_fTankSwingRange;
    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        if (!IsValidSurvivor(survivor) || !IsPlayerAlive(survivor))
            continue;
        if (upSwing && Riding_IsRiding(tank, survivor) && Riding_CanPunch(tank, survivor))
            continue;

        float survivorEye[3];
        GetClientEyePosition(survivor, survivorEye);
        if (GetVectorDistance(tankEye, survivorEye) > fistRange || !clientIsVisibleToClient(tank, survivor))
            continue;
        Combat_SweepFist(claw, survivorEye, survivorEye);
    }
}

// 爪击命中刷新通背拳窗口（石头命中不算）
void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (!IsValidSurvivor(victim) || !isAiTank(attacker))
        return;

    char weapon[64];
    event.GetString("weapon", weapon, sizeof(weapon));
    if (StrEqual(weapon, "tank_rock", false))
        return;

    bool isClaw = StrEqual(weapon, "tank_claw", false) || StrEqual(weapon, "tank", false);
    if (!isClaw)
    {
        int claw = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
        if (claw > 0 && IsValidEdict(claw))
        {
            char className[64];
            GetEntityClassname(claw, className, sizeof(className));
            isClaw = StrEqual(className, "weapon_tank_claw", false);
        }
    }
    if (!isClaw)
        return;

    State_EnsureOwner(attacker);
    g_Tank[attacker].backFistExpire = GetEngineTime() + g_cvBackFistWindow.FloatValue;
}

// =========================================================================
// 投石动画：识别出手、跳砖
// =========================================================================

void Anim_EnsureHook(int tank)
{
    if (!g_bAnimHooked[tank])
        g_bAnimHooked[tank] = AnimHookEnable(tank, INVALID_FUNCTION, Anim_TankPost);
}

void Anim_RemoveHook(int client)
{
    if (!g_bAnimHooked[client])
        return;

    g_bAnimHooked[client] = false;
    if (IsClientInGame(client))
        AnimHookDisable(client, INVALID_FUNCTION, Anim_TankPost);
}

void Frame_RemoveAnimHook(any client)
{
    if (client > 0 && client <= MaxClients && !g_bAnimHooked[client] && IsClientInGame(client))
        AnimHookDisable(client, INVALID_FUNCTION, Anim_TankPost);
}

Action Anim_TankPost(int tank, int &sequence)
{
    if (!isAiTank(tank))
    {
        // 不在钩子自己的回调里摘钩，下一帧再摘
        if (tank > 0 && tank <= MaxClients && g_bAnimHooked[tank])
        {
            g_bAnimHooked[tank] = false;
            RequestFrame(Frame_RemoveAnimHook, tank);
        }
        return Plugin_Continue;
    }

    if (sequence < TANK_THROW_SEQUENCE_MIN || sequence > TANK_THROW_SEQUENCE_MAX || g_Tank[tank].throwing)
        return Plugin_Continue;

    g_Tank[tank].throwing = true;
    // 出手已经开始：结束投石计划，瞄准目标留给 OnRelease；残留的撤离命令由看门狗下一帧 RESET
    if (g_Tank[tank].rockReason != TankRock_None)
        RockPlan_Clear(tank, true);
    if (g_cvJumpRock.BoolValue)
        Combat_JumpRock(tank);
    CreateTimer(THROW_STATE_POLL_INTERVAL, Timer_PollThrowState, GetClientUserId(tank), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

Action Timer_PollThrowState(Handle timer, any userId)
{
    int tank = GetClientOfUserId(userId);
    if (tank <= 0)
        return Plugin_Stop;

    if (isAiTank(tank))
    {
        int sequence = GetEntProp(tank, Prop_Data, "m_nSequence");
        if (sequence >= TANK_THROW_SEQUENCE_MIN && sequence <= TANK_THROW_SEQUENCE_MAX)
            return Plugin_Continue;
    }

    g_Tank[tank].throwing = false;
    g_Tank[tank].rockAimUser = 0;
    g_Tank[tank].rockPendingUntil = 0.0;
    return Plugin_Stop;
}

void Combat_JumpRock(int tank)
{
    if (GetEntityMoveType(tank) != MOVETYPE_WALK || !IsClientOnGround(tank) || Riding_FindRider(tank) > 0)
        return;

    // 梯子口、高台边沿起跳会把 Tank 从上梯/下落路线上弹开
    float pos[3];
    GetClientAbsOrigin(tank, pos);
    if (Movement_IsLadderZone(tank, pos))
        return;
    if (g_TankPath[tank].fresh && g_TankPath[tank].blockHopDist >= 0.0 && g_TankPath[tank].blockHopDist <= LADDER_HOP_MARGIN)
        return;

    float velocity[3];
    GetEntPropVector(tank, Prop_Data, "m_vecAbsVelocity", velocity);
    velocity[2] += JUMP_SPEED_Z;
    TeleportEntity(tank, NULL_VECTOR, NULL_VECTOR, velocity);
}

// =========================================================================
// 投石出手：瞄准、仰角、提前量
// =========================================================================

bool Combat_SolveThrowPitch(const float from[3], const float to[3], float speed, float gravity, float &pitch)
{
    float dx = AIPathMovement_GetDistance2D(from, to);
    float dz = to[2] - from[2];
    if (dx < 1.0 || speed <= 0.0 || gravity <= 0.0)
        return false;

    float speedSquared = speed * speed;
    float delta = speedSquared * speedSquared - gravity * (gravity * dx * dx + 2.0 * dz * speedSquared);
    if (delta < 0.0)
    {
        if (log != null)
            log.debugAll("rock unreachable: dist=%.1f dh=%.1f v=%.1f g=%.1f", dx, dz, speed, gravity);
        return false;
    }

    // 取低抛解
    pitch = RadToDeg(ArcTangent((speedSquared - SquareRoot(delta)) / (gravity * dx)));
    return pitch > -89.0 && pitch < 89.0;
}

int Combat_FindNearestVisibleRockTarget(int tank)
{
    float tankEye[3];
    GetClientEyePosition(tank, tankEye);

    int best = -1;
    float bestDist = 0.0;
    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        if (!IsValidSurvivor(survivor) || !IsPlayerAlive(survivor) || IsClientIncapped(survivor) || isPinnedByHunterOrCharger(survivor))
            continue;
        if (!clientIsVisibleToClient(tank, survivor))
            continue;

        float survivorEye[3];
        GetClientEyePosition(survivor, survivorEye);
        float dist = GetVectorDistance(tankEye, survivorEye);
        if (best == -1 || dist < bestDist)
        {
            best = survivor;
            bestDist = dist;
        }
    }
    return best;
}

public Action L4D_TankRock_OnRelease(int tank, int rock, float vecPos[3], float vecAng[3], float vecVel[3], float vecRot[3])
{
    if (!g_cvEnable.BoolValue || !isAiTank(tank) || !IsValidEntity(rock) || !HasEntProp(rock, Prop_Data, "m_flGravity"))
        return Plugin_Continue;

    // 强制投石计划指定的目标优先，否则按目标调整规则选
    int aimTarget = 0;
    if (g_Tank[tank].rockPendingUntil > GetEngineTime())
        aimTarget = GetClientOfUserId(g_Tank[tank].rockAimUser);
    g_Tank[tank].rockAimUser = 0;
    g_Tank[tank].rockPendingUntil = 0.0;

    if (!IsValidSurvivor(aimTarget) || !IsPlayerAlive(aimTarget))
    {
        aimTarget = Target_GetCurrent(tank);
        if (g_cvRockTargetAdjust.BoolValue)
        {
            int nearest = Combat_FindNearestVisibleRockTarget(tank);
            if (nearest > 0)
                aimTarget = nearest;
        }
    }
    if (!IsValidSurvivor(aimTarget) || !IsPlayerAlive(aimTarget))
        return Plugin_Continue;

    static ConVar throwForce, svGravity;
    if (throwForce == null)
        throwForce = FindConVar("z_tank_throw_force");
    if (svGravity == null)
        svGravity = FindConVar("sv_gravity");

    float throwSpeed = throwForce == null ? DEFAULT_THROW_FORCE : throwForce.FloatValue;
    float gravityScale = GetEntPropFloat(rock, Prop_Data, "m_flGravity");
    if (gravityScale <= 0.0)
        gravityScale = 1.0;
    float gravity = (svGravity == null ? DEFAULT_SV_GRAVITY : svGravity.FloatValue) * gravityScale;

    float targetPos[3], targetVelocity[3];
    GetClientAbsOrigin(aimTarget, targetPos);
    targetPos[2] += PLAYER_CHEST;
    GetEntPropVector(aimTarget, Prop_Data, "m_vecAbsVelocity", targetVelocity);

    float pitch;
    if (!Combat_SolveThrowPitch(vecPos, targetPos, throwSpeed, gravity, pitch))
    {
        // 水平距离几乎为 0（骑头原地投）时弹道公式会除零，直接瞄准目标
        if (AIPathMovement_GetDistance2D(vecPos, targetPos) >= 1.0)
            return Plugin_Continue;

        float direct[3];
        MakeVectorFromPoints(vecPos, targetPos, direct);
        if (NormalizeVector(direct, direct) <= 0.0)
            return Plugin_Continue;
        ScaleVector(direct, throwSpeed);
        vecVel = direct;
        return Plugin_Changed;
    }

    // 以出手点为起点按飞行时间给水平提前量，再对提前点重解一次仰角
    float horizontalSpeed = throwSpeed * Cosine(DegToRad(pitch));
    float flightTime = horizontalSpeed > 1.0 ? AIPathMovement_GetDistance2D(vecPos, targetPos) / horizontalSpeed : 0.0;
    float predicted[3];
    predicted[0] = targetPos[0] + targetVelocity[0] * flightTime;
    predicted[1] = targetPos[1] + targetVelocity[1] * flightTime;
    predicted[2] = targetPos[2];
    float predictedPitch;
    if (Combat_SolveThrowPitch(vecPos, predicted, throwSpeed, gravity, predictedPitch))
        pitch = predictedPitch;
    else
        predicted = targetPos;

    float aimAngles[3], direction[3];
    aimAngles[0] = -pitch;
    aimAngles[1] = RadToDeg(ArcTangent2(predicted[1] - vecPos[1], predicted[0] - vecPos[0]));
    aimAngles[2] = 0.0;
    GetAngleVectors(aimAngles, direction, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(direction, direction);
    ScaleVector(direction, throwSpeed);
    vecVel = direction;
    return Plugin_Changed;
}
