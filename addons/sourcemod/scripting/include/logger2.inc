/*
 * @Author: 夜羽真白
 * @Date: 2023-05-23 00:03 周二
 * @Type: Left 4 Dead 2 Plugin
 * @Description: 日志记录对象
 * @URL: https://github.com/GlowingTree880/L4D2_LittlePlugins
 */

#include <colors.inc>

#define LOGGER_LEVEL_OFF    (1 << 0)
#define LOGGER_LEVEL_DEBUG (1 << 1)
#define LOGGER_LEVEL_INFO   (1 << 2)
#define LOGGER_LEVEL_MESSAGE    (1 << 3)
#define LOGGER_LEVEL_SERVER (1 << 4)
#define LOGGER_LEVEL_ERROR  (1 << 5)

methodmap Logger < Handle
{

    public Logger(const char[] prefix, int level = LOGGER_LEVEL_DEBUG | LOGGER_LEVEL_INFO)
    {
        DataPack dp = new DataPack();
        dp.WriteString(prefix);
        dp.WriteCell(level);
        return view_as<Logger>(dp);
    }

    public void Close()
    {
        DataPack dp = view_as<DataPack>(this);
        delete dp;
    }

    property int level
    {
        public set(int value) {
            DataPack dp = view_as<DataPack>(this);
            dp.Reset();
            
            char prefix[128];
            dp.ReadString(prefix, sizeof(prefix));
            
            dp.Reset();
            dp.WriteString(prefix);
            dp.WriteCell(value);
        }
        public get() {
            DataPack dp = view_as<DataPack>(this);
            dp.Reset();

            char temp[128];
            dp.ReadString(temp, sizeof(temp));
            return dp.ReadCell();
        }
    }

    public void getPrefix(char[] buffer, int maxLength) {
        DataPack dp = view_as<DataPack>(this);
        dp.Reset();
        dp.ReadString(buffer, maxLength);
    }

    public void debugAndInfo(const char[] message, any ...) {
        DataPack dp = view_as<DataPack>(this);
        dp.Reset();
        
        char prefix[128];
        dp.ReadString(prefix, sizeof(prefix));
        int level = dp.ReadCell();
        // 检查日志级别是否开启
        if (level & LOGGER_LEVEL_OFF)
            return;

        char buffer[512];
        VFormat(buffer, sizeof(buffer), message, 3);
        char finalMsg[512];
        FormatEx(finalMsg, sizeof(finalMsg), "[%s]: %s", prefix, buffer);

        if (level & LOGGER_LEVEL_DEBUG) {
            PrintToConsoleAll(finalMsg);
        }
        if (level & LOGGER_LEVEL_INFO) {
            LogMessage(finalMsg);
        }
    }

    /**
    * DEBUG 级别输出, 输出到所有客户端控制台
    * @param message 输出信息
    * @param any 任意数据
    * @return void
    **/
    public void debugAll(const char[] message, any ...)
    {
        DataPack dp = view_as<DataPack>(this);
        dp.Reset();
        
        char prefix[128];
        dp.ReadString(prefix, sizeof(prefix));
        int level = dp.ReadCell();
        // 检查日志级别是否开启
        if (level & LOGGER_LEVEL_OFF)
            return;
        if (!(level & LOGGER_LEVEL_DEBUG))
            return;

        char buffer[512];
        VFormat(buffer, sizeof(buffer), message, 3);
        char finalMsg[512];
        FormatEx(finalMsg, sizeof(finalMsg), "[%s]: %s", prefix, buffer);
        PrintToConsoleAll(finalMsg);
    }

    /**
    * DEBUG 级别输出, 输出到指定客户端控制台
    * @param client 指定客户端
    * @param message 输出信息
    * @param any 任意数据
    * @return void
    **/
    public void debug(int client, const char[] message, any ...)
    {
        if (client < 1 || client >= MaxClients || !IsClientInGame(client) || IsFakeClient(client)) {
            return;
        }

        DataPack dp = view_as<DataPack>(this);
        dp.Reset();
        
        char prefix[128];
        dp.ReadString(prefix, sizeof(prefix));
        int level = dp.ReadCell();
        // 检查日志级别是否开启
        if (level & LOGGER_LEVEL_OFF)
            return;
        if (!(level & LOGGER_LEVEL_DEBUG))
            return;

        char buffer[512];
        VFormat(buffer, sizeof(buffer), message, 4);
        char finalMsg[512];
        FormatEx(finalMsg, sizeof(finalMsg), "[%s]: %s", prefix, buffer);
        PrintToConsole(client, finalMsg);
    }

    /**
    * INFO 级别输出, 输出到 Log 目录日志文件中
    * @param message 输出信息
    * @param any 任意数据
    * @return void
    **/
    public void info(const char[] message, any ...)
    {
        DataPack dp = view_as<DataPack>(this);
        dp.Reset();
        
        char prefix[128];
        dp.ReadString(prefix, sizeof(prefix));
        int level = dp.ReadCell();
        // 检查日志级别是否开启
        if (level & LOGGER_LEVEL_OFF)
            return;
        if (!(level & LOGGER_LEVEL_INFO))
            return;

        char buffer[512];
        VFormat(buffer, sizeof(buffer), message, 3);
        char finalMsg[512];
        FormatEx(finalMsg, sizeof(finalMsg), "[%s]: %s", prefix, buffer);
        LogMessage(finalMsg);
    }

    /**
    * INFO 级别输出, 输出到指定客户端控制台及目录日志文件中
    * @param client 指定客户端
    * @param message 输出信息
    * @param any 任意数据
    * @return void
    **/
    public void infoToClient(int client, const char[] message, any ...)
    {
        if (client < 1 || client >= MaxClients || !IsClientInGame(client) || IsFakeClient(client)) {
            LogMessage("[Logger]: client %d is invalid", client);
            return;
        }
        
        DataPack dp = view_as<DataPack>(this);
        dp.Reset();
        
        char prefix[128];
        dp.ReadString(prefix, sizeof(prefix));
        int level = dp.ReadCell();
        // 检查日志级别是否开启
        if (level & LOGGER_LEVEL_OFF)
            return;
        if (!(level & LOGGER_LEVEL_INFO)) {
            return;
        }

        char buffer[512];
        VFormat(buffer, sizeof(buffer), message, 4);
        char finalMsg[512];
        FormatEx(finalMsg, sizeof(finalMsg), "[%s]: %s", prefix, buffer);
        LogMessage(finalMsg);
        PrintToConsole(client, finalMsg);
    }

    /**
    * MESSAGE 级别输出, 输出到服务器控制台与所有客户端聊天框
    * @param message 输出信息
    * @param any 任意数据
    * @return void
    **/
    public void messageAll(const char[] message, any ...)
    {
        DataPack dp = view_as<DataPack>(this);
        dp.Reset();
        
        char prefix[128];
        dp.ReadString(prefix, sizeof(prefix));
        int level = dp.ReadCell();
        // 检查日志级别是否开启
        if (level & LOGGER_LEVEL_OFF)
            return;
        if (!(level & LOGGER_LEVEL_MESSAGE)) {
            return;
        }

        char buffer[512];
        VFormat(buffer, sizeof(buffer), message, 3);
        char finalMsg[512];
        FormatEx(finalMsg, sizeof(finalMsg), "[%s]: %s", prefix, buffer);
        PrintToServer(finalMsg);
        CPrintToChatAll(finalMsg);
    }

    /**
    * MESSAGE 级别输出, 输出到服务器控制台与指定客户端聊天框
    * @param client 指定客户端
    * @param message 输出信息
    * @param any 任意数据
    * @return void
    **/
    public void message(int client, const char[] message, any ...)
    {
        if (client < 1 || client >= MaxClients || !IsClientInGame(client) || IsFakeClient(client)) {
            PrintToServer("[Logger]: client: %d is invalid", client);
            return;
        }

        DataPack dp = view_as<DataPack>(this);
        dp.Reset();
        
        char prefix[128];
        dp.ReadString(prefix, sizeof(prefix));
        int level = dp.ReadCell();
        // 检查日志级别是否开启
        if (level & LOGGER_LEVEL_OFF)
            return;
        if (!(level & LOGGER_LEVEL_MESSAGE))
            return;

        char buffer[512];
        VFormat(buffer, sizeof(buffer), message, 4);
        char finalMsg[512];
        FormatEx(finalMsg, sizeof(finalMsg), "[%s]: %s", prefix, buffer);
        PrintToServer(finalMsg);
        CPrintToChat(client, finalMsg);
    }

    /**
    * SERVER 级别输出, 输出到服务端控制台
    * @param message 输出信息
    * @param any 任意数据
    * @return void
    **/
    public void server(const char[] message, any ...)
    {
        DataPack dp = view_as<DataPack>(this);
        dp.Reset();
        
        char prefix[128];
        dp.ReadString(prefix, sizeof(prefix));
        int level = dp.ReadCell();
        // 检查日志级别是否开启
        if (level & LOGGER_LEVEL_OFF)
            return;
        if (!(level & LOGGER_LEVEL_SERVER))
            return;
        
        char buffer[512];
        VFormat(buffer, sizeof(buffer), message, 3);
        char finalMsg[512];
        FormatEx(finalMsg, sizeof(finalMsg), "[%s]: %s", prefix, buffer);
        PrintToServer(finalMsg);
    }

    /**
    * ERROR 级别输出, 输出到服务端控制台与 Log 目录错误日志
    * @param message 输出信息
    * @param any 任意数据
    * @return void
    **/
    public void error(const char[] message, any ...)
    {
        DataPack dp = view_as<DataPack>(this);
        dp.Reset();
        
        char prefix[128];
        dp.ReadString(prefix, sizeof(prefix));
        int level = dp.ReadCell();
        // 检查日志级别是否开启
        if (level & LOGGER_LEVEL_OFF)
            return;
        if (!(level & LOGGER_LEVEL_ERROR))
            return;

        char buffer[512];
        VFormat(buffer, sizeof(buffer), message, 3);
        char finalMsg[512];
        FormatEx(finalMsg, sizeof(finalMsg), "[%s]: %s", prefix, buffer);
        PrintToServer(finalMsg);
        LogError(finalMsg);
    }

}