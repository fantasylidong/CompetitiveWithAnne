void PillHintRegression_Assert(bool condition, const char[] message)
{
    if (!condition) {
        ThrowError("PILL_HINT_REGRESSION_FAIL %s", message);
    }
}

void PillHintRegression_Snapshot(const int[] progress, const int[] counts, int spots, int total)
{
    int known;
    for (int spot = 0; spot < spots; spot++) {
        if (progress[spot] >= 0) {
            known += counts[spot];
        }
    }
    ArrayList lines = BuildSpotLines(progress, counts, spots, ", ", "", "", "unknown");
    for (int line = 0; line < lines.Length; line++) {
        char message[MAX_MESSAGE_LENGTH];
        lines.GetString(line, message, sizeof(message));
        LogMessage("PILL_HINT_SCAN_PROGRESS %s", message);
    }
    delete lines;
    LogMessage("PILL_HINT_SCAN_RESULT total=%d known=%d", total, known);
}

public Action PillHintRegression_Command(int args)
{
    for (int client = 1; client <= MaxClients; client++) {
        if (IsClientConnected(client) && !IsFakeClient(client)) {
            PrintToServer("PILL_HINT_REGRESSION_REFUSED humans present");
            return Plugin_Handled;
        }
    }
    char command[16];
    GetCmdArg(1, command, sizeof(command));
    if (StrEqual(command, "scan")) {
        PillHintRegression_Assert(AnnouncePills(), "map flow unavailable");
        return Plugin_Handled;
    }
    int bot = CreateFakeClient("Pill hint regression");
    PillHintRegression_Assert(bot > 0, "test client unavailable");
    int entity = CreateEntityByName("weapon_spawn");
    SetEntProp(entity, Prop_Send, "m_weaponID", WEPID_PAIN_PILLS);
    DispatchSpawn(entity);
    DispatchKeyValue(entity, "count", "3");
    bool correctStack = GetPillCount(entity, 1) == 3;
    SetEntProp(entity, Prop_Data, "m_itemCount", 0);
    bool correctEmpty = GetPillCount(entity, 1) == 0;
    RemoveEntity(entity);
    if (!correctStack || !correctEmpty) {
        KickClient(bot, "Test complete");
        PillHintRegression_Assert(false, "stack or empty pill count");
    }
    static const char languages[][] = {"en", "chi", "zho", "jp", "ko"};
    int progress[80], counts[80];
    for (int spot = 0; spot < sizeof(progress); spot++) {
        progress[spot] = 42;
        counts[spot] = 1;
    }
    int checks;
    for (int language = 0; language < sizeof(languages); language++) {
        int languageId = GetLanguageByCode(languages[language]);
        if (languageId == -1) {
            continue;
        }
        SetClientLanguage(bot, languageId);
        char header[MAX_MESSAGE_LENGTH], continuation[MAX_MESSAGE_LENGTH], separator[16], unknown[32];
        FormatEx(header, sizeof(header), "%T", "PillHint_List", bot, 80, "");
        FormatEx(continuation, sizeof(continuation), "%T", "PillHint_Continue", bot);
        FormatEx(separator, sizeof(separator), "%T", "PillHint_Separator", bot);
        FormatEx(unknown, sizeof(unknown), "%T", "PillHint_Unknown", bot);
        ArrayList lines = BuildSpotLines(progress, counts, sizeof(progress), separator, header, continuation, unknown);
        int percentages, maxBytes;
        bool valid = lines.Length > 1;
        for (int line = 0; line < lines.Length; line++) {
            char message[MAX_MESSAGE_LENGTH];
            lines.GetString(line, message, sizeof(message));
            int length = strlen(message);
            if (length > maxBytes) {
                maxBytes = length;
            }
            valid = valid && length <= PILL_HINT_MESSAGE_BYTES && StrContains(message, "×") == -1 && StrContains(message, "*") == -1;
            for (int offset = 0; offset < length; offset++) {
                if (message[offset] == '%') {
                    percentages++;
                }
            }
        }
        int lineCount = lines.Length;
        delete lines;
        if (!valid || percentages != 80) {
            KickClient(bot, "Test complete");
            PillHintRegression_Assert(false, "multilingual pagination lost entries or exceeded byte budget");
        }
        LogMessage("PILL_HINT_LANGUAGE_PASS language=%s items=%d lines=%d max_bytes=%d", languages[language], percentages, lineCount, maxBytes);
        checks++;
    }
    int mixedProgress[] = {100, -1, 42};
    int mixedCounts[] = {1, 1, 2};
    SortSpots(mixedProgress, mixedCounts, sizeof(mixedProgress));
    ArrayList mixed = BuildSpotLines(mixedProgress, mixedCounts, sizeof(mixedProgress), ", ", "", "", "unknown");
    char result[MAX_MESSAGE_LENGTH];
    mixed.GetString(0, result, sizeof(result));
    bool correctMixed = mixed.Length == 1 && StrEqual(result, "42%, 42%, 100%, unknown");
    delete mixed;
    KickClient(bot, "Test complete");
    PillHintRegression_Assert(correctMixed, "duplicate percentages or unknown ordering");
    PillHintRegression_Assert(checks == 5, "missing installed language");
    LogMessage("PILL_HINT_REGRESSION_PASS languages=%d stacked=3 empty=0 items=80", checks);
    PrintToServer("PILL_HINT_REGRESSION_COMPLETE");
    return Plugin_Handled;
}
