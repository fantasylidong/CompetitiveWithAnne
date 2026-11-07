// Upstream extension: https://github.com/Crimson-DawnLight/L4D2MutiMod/tree/main/extensions/sendtable
// Upstream plugin:    https://github.com/ExpCharacter/oh-my-l4d2-plugins/tree/main/l4d2_ammo_bit_widener_ext
// Local docs:         extensions/sendtable/README.md
#if defined _SENDTABLE_INC_
	#endinput
#endif
#define _SENDTABLE_INC_

#define SENDTABLE_LIB "sendtable"

/**
 * SendTable / SendProp 的运行期改写。
 *
 * @note 必须在客户端连接前应用 (OnPluginStart 时机即可); 已连接的客户端不会更新。
 * @note 只支持 DPT_Int: unsigned 范围 0 .. 2^bits-1; signed 范围 -2^(bits-1) .. 2^(bits-1)-1。
 */
methodmap SendTable {
	/**
	 * 修改网络属性的位宽。
	 *
	 * @param netClass      网络类名, 如 "CTerrorPlayer"
	 * @param propName      属性名, 如 "m_iHealth"
	 * @param bits          目标位宽 (1..31)
	 * @param expectedBits  期望的当前位宽, 不匹配则不改; 0 = 不校验
	 * @return              成功 true
	 */
	public static native bool SetBits(const char[] netClass, const char[] propName, int bits, int expectedBits = 0);

	/**
	 * 容器 (DataTable) 版: 把该表下所有整型元素统一改宽。
	 * 适用于 m_iAmmo、CTerrorPlayerResource.m_iHealth 这类数组属性; 校验失败时一个元素都不改。
	 *
	 * @param netClass      网络类名
	 * @param tableName     容器属性名
	 * @param bits          目标位宽 (1..31)
	 * @param expectedBits  期望的当前位宽; 0 = 不校验
	 * @return              成功 true
	 */
	public static native bool SetElementBits(const char[] netClass, const char[] tableName, int bits, int expectedBits = 0);

	/**
	 * 读取位宽。DataTable 容器返回首元素的位宽。
	 *
	 * @param netClass      网络类名
	 * @param propName      属性名
	 * @return              位宽; -1 = 找不到
	 */
	public static native int GetBits(const char[] netClass, const char[] propName);
}

public __ext_sendtable_SetNTVOptional()
{
#if !defined REQUIRE_EXTENSIONS
	MarkNativeAsOptional("SendTable.SetBits");
	MarkNativeAsOptional("SendTable.SetElementBits");
	MarkNativeAsOptional("SendTable.GetBits");
#endif
}

public Extension __ext_sendtable =
{
	name = "SendTable Modify Manager",
	file = "sendtable.ext",
#if defined AUTOLOAD_EXTENSIONS
	autoload = 1,
#else
	autoload = 0,
#endif
#if defined REQUIRE_EXTENSIONS
	required = 1,
#else
	required = 0,
#endif
};
