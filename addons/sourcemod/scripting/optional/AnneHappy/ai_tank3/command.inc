#if defined _ai_tank3_command_included
    #endinput
#endif
#define _ai_tank3_command_included

// =========================================================================
// CommandABot 生命周期
// BOT_CMD_MOVE 会让 Bot“无条件执行、不再运行任何自身 AI 行为”（left4dhooks BOT_CMD 注释），到点之后就原地站着，
// 直到收到下一条命令或 RESET。1.x 撤离投石只发 MOVE、结束时经常没有 RESET，梯子附近连补发的 ATTACK 都被拦掉，
// Tank 会一直罚站到卡住传送插件介入。插件只在这里发命令，由看门狗保证超时/停滞/上梯/计划结束时一定 RESET。
// =========================================================================

void Command_IssueMove(int tank, const float goal[3])
{
    float destination[3];
    destination = goal;
    L4D2_CommandABot(tank, 0, BOT_CMD_MOVE, destination);

    float timeout = g_cvRetreatTimeout.FloatValue;
    if (timeout < RETREAT_MIN_TIMEOUT)
        timeout = RETREAT_MIN_TIMEOUT;

    float now = GetEngineTime();
    float pos[3];
    GetClientAbsOrigin(tank, pos);
    g_Tank[tank].moveActive = true;
    g_Tank[tank].moveDeadline = now + timeout;
    g_Tank[tank].moveProgressTime = now;
    g_Tank[tank].moveProgressPos = pos;

    if (log != null)
        log.debugAll("%N retreat MOVE -> (%.1f, %.1f, %.1f)", tank, goal[0], goal[1], goal[2]);
}

void Command_Reset(int tank, const char[] reason)
{
    if (!g_Tank[tank].moveActive)
        return;

    g_Tank[tank].moveActive = false;
    if (!IsClientInGame(tank))
        return;

    if (IsFakeClient(tank) && IsPlayerAlive(tank))
        L4D2_CommandABot(tank, 0, BOT_CMD_RESET);
    if (log != null)
        log.debugAll("%N retreat RESET: %s", tank, reason);
}

void Command_Watchdog(int tank, const float pos[3], bool onLadder, float now)
{
    if (!g_Tank[tank].moveActive)
        return;

    if (g_Tank[tank].rockReason != TankRock_HeadBlock)
    {
        Command_Reset(tank, "rock plan ended");
        return;
    }
    if (onLadder)
    {
        Command_Reset(tank, "on ladder");
        return;
    }
    if (now >= g_Tank[tank].moveDeadline)
    {
        Command_Reset(tank, "timeout");
        return;
    }

    if (GetVectorDistance(pos, g_Tank[tank].moveProgressPos) >= RETREAT_STALL_DIST)
    {
        g_Tank[tank].moveProgressTime = now;
        g_Tank[tank].moveProgressPos = pos;
    }
    else if (now - g_Tank[tank].moveProgressTime >= RETREAT_STALL_TIME)
    {
        Command_Reset(tank, "stalled");
    }
}
