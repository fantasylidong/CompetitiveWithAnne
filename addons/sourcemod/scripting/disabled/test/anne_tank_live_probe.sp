#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <anne_nextbot>

native int NextBotCreatePlayerBotSurvivorBot(const char[] name = NULL_STRING);
native bool CTerrorPlayerRoundRespawn(int client);

public Plugin myinfo = {name="Anne Tank Empty Server Probe", author="AnneHappy", description="Temporary console-only empty-server Tank movement probe", version="1.0"};
int g_TankUser, g_BotUser[4], g_Target, g_Jumps, g_AttackFrames, g_Hits, g_Samples, g_Slow;
float g_Pos[4][3], g_Start, g_End, g_Last[3], g_Distance, g_MaxSpeed, g_MinRange, g_NextRow;
bool g_Running, g_Grounded;
char g_Rows[180][320];
int g_RowCount;

public void OnPluginStart()
{
    RegServerCmd("sm_tankprobe_nav", Cmd_Nav);
    RegServerCmd("sm_tankprobe_run", Cmd_Run);
    RegServerCmd("sm_tankprobe_status", Cmd_Status);
    RegServerCmd("sm_tankprobe_stop", Cmd_Stop);
    RegServerCmd("sm_tankprobe_live", Cmd_Live);
    CreateTimer(0.2, Sample, _, TIMER_REPEAT);
}

bool EmptyServer()
{
    for (int i=1; i<=MaxClients; i++)
        if (IsClientConnected(i) && !IsFakeClient(i)) return false;
    return true;
}

void Cleanup()
{
    g_Running=false;
    int tank=GetClientOfUserId(g_TankUser);
    if (tank && IsClientInGame(tank) && IsFakeClient(tank)) KickClient(tank, "Probe ended");
    g_TankUser=0;
    for(int i=0;i<4;i++)
    {
        int bot=GetClientOfUserId(g_BotUser[i]);
        if(bot && IsClientInGame(bot) && IsFakeClient(bot)) KickClient(bot,"Probe ended");
        g_BotUser[i]=0;
    }
}
public void OnPluginEnd() { Cleanup(); }
public void OnMapEnd() { Cleanup(); }
public void OnClientConnected(int client)
{
    if(!IsFakeClient(client) && (g_TankUser || g_BotUser[0])) Cleanup();
}

public bool TraceIgnoreClients(int entity, int mask)
{
    return entity > MaxClients || entity == 0;
}

bool ClearPoint(float pos[3])
{
    float mins[3]={-32.0,-32.0,0.0}, maxs[3]={32.0,32.0,85.0};
    Handle tr=TR_TraceHullFilterEx(pos,pos,mins,maxs,MASK_PLAYERSOLID,TraceIgnoreClients);
    bool clear=!TR_DidHit(tr);
    delete tr;
    return clear;
}

public Action Cmd_Nav(int args)
{
    char arg[16]; GetCmdArg(1,arg,sizeof(arg));
    float desired=StringToFloat(arg)*L4D2Direct_GetMapMaxFlowDistance()/100.0;
    ArrayList areas=new ArrayList(); L4D_GetAllNavAreas(areas);
    int ids[8]; float scores[8];
    for(int j=0;j<8;j++) scores[j]=999999.0;
    for(int i=0;i<areas.Length;i++)
    {
        Address area=view_as<Address>(areas.Get(i));
        if(L4D_GetNavArea_SpawnAttributes(area)&((1<<7)|(1<<11)|(1<<15)|(1<<16))) continue;
        float size[3],pos[3]; L4D_GetNavAreaSize(area,size);
        if(size[0]<90.0 || size[1]<90.0) continue;
        float flow=L4D2Direct_GetTerrorNavAreaFlow(area);
        if(flow<0.0 || flow>1000000.0) continue;
        float score=FloatAbs(flow-desired);
        if(score>=scores[7]) continue;
        L4D_GetNavAreaCenter(area,pos); pos[2]+=5.0;
        if(!ClearPoint(pos)) continue;
        for(int j=0;j<8;j++) if(score<scores[j])
        {
            for(int k=7;k>j;k--) {scores[k]=scores[k-1]; ids[k]=ids[k-1];}
            scores[j]=score; ids[j]=L4D_GetNavAreaID(area); break;
        }
    }
    delete areas;
    for(int i=0;i<8;i++) if(ids[i])
    {
        Address area=L4D_GetNavAreaByID(ids[i]); float p[3]; L4D_GetNavAreaCenter(area,p);
        PrintToServer("PROBE NAV id=%d flow=%.1f pos=%.1f %.1f %.1f",ids[i],L4D2Direct_GetTerrorNavAreaFlow(area),p[0],p[1],p[2]);
    }
    return Plugin_Handled;
}

public Action Cmd_Run(int args)
{
    if(!EmptyServer()) { PrintToServer("PROBE refused: human connected"); return Plugin_Handled; }
    if(g_TankUser || g_BotUser[0]) { PrintToServer("PROBE stop previous run first"); return Plugin_Handled; }
    if(args!=3) {PrintToServer("PROBE usage: sm_tankprobe_run survivorNav tankNav seconds");return Plugin_Handled;}
    char arg[16]; GetCmdArg(1,arg,sizeof(arg)); Address dest=L4D_GetNavAreaByID(StringToInt(arg));
    GetCmdArg(2,arg,sizeof(arg)); Address start=L4D_GetNavAreaByID(StringToInt(arg));
    GetCmdArg(3,arg,sizeof(arg)); float duration=StringToFloat(arg);
    if(start==Address_Null || dest==Address_Null || duration<5.0 || duration>120.0) return Plugin_Handled;
    float anchor[3],tankpos[3]; L4D_GetNavAreaCenter(dest,anchor); L4D_GetNavAreaCenter(start,tankpos);
    anchor[2]+=5.0; tankpos[2]+=5.0;
    if(!ClearPoint(anchor) || !ClearPoint(tankpos) || !L4D2_NavAreaBuildPath(start,dest,6000.0,3,false))
    {PrintToServer("PROBE rejected: obstructed point or no nav path");return Plugin_Handled;}
    // Spread the stationary targets over nearby clear nav centers, away from spawn/checkpoint areas.
    ArrayList areas=new ArrayList(); L4D_GetAllNavAreas(areas); g_Pos[0]=anchor;
    int count=1;
    for(int i=0;i<areas.Length && count<4;i++)
    {
        Address area=view_as<Address>(areas.Get(i)); float p[3]; L4D_GetNavAreaCenter(area,p); p[2]+=5.0;
        if(L4D_GetNavArea_SpawnAttributes(area)&((1<<7)|(1<<11)|(1<<15)|(1<<16))) continue;
        if(GetVectorDistance(p,anchor)>300.0 || FloatAbs(p[2]-anchor[2])>30.0 || !ClearPoint(p)) continue;
        bool separate=true;
        for(int j=0;j<count;j++) if(GetVectorDistance(p,g_Pos[j])<85.0) separate=false;
        if(!separate || !L4D2_NavAreaBuildPath(dest,area,500.0,2,false)) continue;
        g_Pos[count++]=p;
    }
    delete areas;
    if(count<4) {PrintToServer("PROBE rejected: insufficient survivor space");return Plugin_Handled;}
    // Only start on a genuinely empty server; never adopt or remove someone else's bots.
    for(int i=1;i<=MaxClients;i++) if(IsClientInGame(i) && GetClientTeam(i)>=2)
    {PrintToServer("PROBE rejected: existing team clients");return Plugin_Handled;}
    float zero[3];
    for(int j=0;j<4;j++)
    {
        int bot=NextBotCreatePlayerBotSurvivorBot(NULL_STRING);
        if(bot<=0) {Cleanup();return Plugin_Handled;}
        g_BotUser[j]=GetClientUserId(bot); ChangeClientTeam(bot,2);
        if(!IsPlayerAlive(bot)) CTerrorPlayerRoundRespawn(bot);
        TeleportEntity(bot,g_Pos[j],zero,zero);
        SetEntityHealth(bot,30000);
        SDKHook(bot,SDKHook_OnTakeDamage,OnDamage);
    }
    int tank=L4D2_SpawnTank(tankpos,zero);
    if(tank<=0) {Cleanup();return Plugin_Handled;}
    g_TankUser=GetClientUserId(tank); SetEntityHealth(tank,30000);
    g_Start=GetGameTime();g_End=g_Start+duration;g_NextRow=g_Start;g_Last=tankpos;
    g_Jumps=0;g_AttackFrames=0;g_Hits=0;g_Samples=0;g_Slow=0;g_Target=0;
    g_Distance=0.0;g_MaxSpeed=0.0;g_MinRange=999999.0;g_RowCount=0;g_Grounded=true;g_Running=true;
    PrintToServer("PROBE START tank=%d survivorNav=%d tankNav=%d travel=%.1f duration=%.1f",g_TankUser,L4D_GetNavAreaID(dest),L4D_GetNavAreaID(start),L4D2_NavAreaTravelDistance(tankpos,anchor,false),duration);
    return Plugin_Handled;
}

public Action OnDamage(int victim,int &attacker,int &inflictor,float &damage,int &type)
{
    if(g_Running && attacker==GetClientOfUserId(g_TankUser)) g_Hits++;
    return Plugin_Continue;
}
public Action L4D2_OnChooseVictim(int infected, int &target)
{
    if(g_Running && infected==GetClientOfUserId(g_TankUser)) g_Target=target;
    return Plugin_Continue;
}
public Action OnPlayerRunCmd(int client,int &buttons,int &impulse,float vel[3],float angles[3],int &weapon)
{
    if(!g_Running) return Plugin_Continue;
    for(int j=0;j<4;j++) if(GetClientOfUserId(g_BotUser[j])==client)
    {
        buttons=0;vel[0]=0.0;vel[1]=0.0;vel[2]=0.0;
        return Plugin_Changed;
    }
    return Plugin_Continue;
}
public void OnPlayerRunCmdPost(int client,int buttons,int impulse,const float vel[3],const float angles[3],int weapon,int subtype,int cmdnum,int tickcount,int seed,const int mouse[2])
{
    if(g_Running && client==GetClientOfUserId(g_TankUser) && (buttons&(IN_ATTACK|IN_ATTACK2))) g_AttackFrames++;
}
public void OnGameFrame()
{
    if(!g_Running) return;
    float zero[3];
    for(int j=0;j<4;j++)
    {
        int bot=GetClientOfUserId(g_BotUser[j]);
        if(bot && IsClientInGame(bot) && IsPlayerAlive(bot))
        {
            SetEntityMoveType(bot,MOVETYPE_WALK);
            float current[3];GetClientAbsOrigin(bot,current);
            if(GetVectorDistance(current,g_Pos[j])>12.0) TeleportEntity(bot,g_Pos[j],NULL_VECTOR,zero);
        }
    }
    int tank=GetClientOfUserId(g_TankUser);
    if(!tank || !IsClientInGame(tank)) return;
    bool grounded=(GetEntityFlags(tank)&FL_ONGROUND)!=0;
    float v[3];GetEntPropVector(tank,Prop_Data,"m_vecVelocity",v);
    if(g_Grounded && !grounded && v[2]>50.0) g_Jumps++;
    g_Grounded=grounded;
}
public Action Sample(Handle timer)
{
    if(!g_Running) return Plugin_Continue;
    int tank=GetClientOfUserId(g_TankUser);
    if(!tank || !IsClientInGame(tank) || !IsPlayerAlive(tank) || !EmptyServer()) {Cleanup();return Plugin_Continue;}
    float now=GetGameTime(),p[3],v[3];GetClientAbsOrigin(tank,p);GetEntPropVector(tank,Prop_Data,"m_vecVelocity",v);
    float speed=SquareRoot(v[0]*v[0]+v[1]*v[1]);
    g_Distance+=GetVectorDistance(p,g_Last);g_Last=p;
    if(speed>g_MaxSpeed) g_MaxSpeed=speed;
    float range=999999.0;
    for(int j=0;j<4;j++) {float d=GetVectorDistance(p,g_Pos[j]);if(d<range)range=d;}
    if(range<g_MinRange)g_MinRange=range;
    g_Samples++;if(speed<10.0 && range>200.0)g_Slow++;
    if(now>=g_NextRow && g_RowCount<180)
    {
        g_NextRow=now+0.99;
        int count,index,traverse;bool complete;float age;int type=-1;float goal[3],fwd[3],length,dist;Address nav;
        bool path=AnneNextBot_GetPathSnapshotInfo(tank,count,index,complete,age);
        if(path)AnneNextBot_GetPathSegment(tank,index,nav,traverse,goal,type,fwd,length,dist);
        Format(g_Rows[g_RowCount++],320,"t=%.1f pos=%.0f,%.0f,%.0f speed=%.0f range=%.0f target=%d jumps=%d attack=%d hits=%d path=%d/%d age=%.2f type=%d goal=%.0f,%.0f,%.0f",now-g_Start,p[0],p[1],p[2],speed,range,g_Target,g_Jumps,g_AttackFrames,g_Hits,index,count,age,type,goal[0],goal[1],goal[2]);
    }
    if(now>=g_End) {Cleanup();PrintToServer("PROBE FINISHED: sm_tankprobe_status for results");}
    return Plugin_Continue;
}
public Action Cmd_Status(int args)
{
    PrintToServer("PROBE WORLD intro=%d leftSafe=%d time=%.1f",L4D_IsInIntro(),L4D_HasAnySurvivorLeftSafeArea(),GetGameTime());
    for(int i=1;i<=MaxClients;i++) if(IsClientInGame(i) && IsPlayerAlive(i))
    {
        char weapon[64]; GetClientWeapon(i,weapon,sizeof(weapon));
        PrintToServer("PROBE CLIENT idx=%d team=%d hp=%d flags=%d ghost=%d incap=%d weapon=%s",i,GetClientTeam(i),GetClientHealth(i),GetEntityFlags(i),GetEntProp(i,Prop_Send,"m_isGhost"),GetEntProp(i,Prop_Send,"m_isIncapacitated"),weapon);
        PrintToServer("PROBE STATE idx=%d move=%d nextattack=%.2f",i,GetEntityMoveType(i),GetEntPropFloat(i,Prop_Send,"m_flNextAttack"));
    }
    PrintToServer("PROBE SUMMARY running=%d jumps=%d attackFrames=%d hits=%d moved=%.0f maxSpeed=%.0f minRange=%.0f slowFar=%.1fs samples=%d",g_Running,g_Jumps,g_AttackFrames,g_Hits,g_Distance,g_MaxSpeed,g_MinRange,float(g_Slow)*0.2,g_Samples);
    for(int i=0;i<g_RowCount;i++)PrintToServer("%s",g_Rows[i]);
    return Plugin_Handled;
}
public Action Cmd_Stop(int args) {Cleanup();PrintToServer("PROBE STOPPED");return Plugin_Handled;}
public Action Cmd_Live(int args)
{
    if(!EmptyServer())return Plugin_Handled;
    L4D_ForceVersusStart();
    PrintToServer("PROBE forced versus start");
    return Plugin_Handled;
}
