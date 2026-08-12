/**
 * Accelerator's SourcePawn include file
 */

#if defined _accelerator_included
 #endinput
#endif
#define _accelerator_included


/**
 * Called when Accelerator is done uploading crash dumps.
 */
forward void Accelerator_OnDoneUploadingCrashes();

/**
 * Returns the number of crashes uploaded.
 *
 * @return					Number of crashes uploaded.
 */
native int Accelerator_GetUploadedCrashCount();

/**
 * Returns if Accelerator is done uploading crashes.
 *
 * @return					True if no more crashes will be uploaded, false if there are still crashes pending upload.
 */
native bool Accelerator_IsDoneUploadingCrashes();

/**
 * Gets a crash's HTTP response from Accelerator's backend server.
 *
 * @note					The response from the server can be anything and there is no guarantee a crash ID will be present.
 * @param index				The crash index, starts at 0 and goes up to Accelerator_GetUploadedCrashCount() - 1;
 * @param buffer			Buffer to store the crash HTTP response.
 * @param size				Size of the buffer parameter.
 * @error					Native called before Accelerator_IsDoneUploadingCrashes() returns true or invalid crash index passed.
 */
native void Accelerator_GetCrashHTTPResponse(int index, char[] buffer, int size);

/**
 * Suppresses processing and uploading crash reports created during a short window.
 *
 * The window is persisted so it survives the crash and applies when the server restarts.
 * Matching dump and metadata files are discarded without being processed or uploaded.
 *
 * @param seconds			Duration of the suppression window (1-180 seconds).
 * @return					True if the suppression window was persisted successfully.
 */
native bool Accelerator_SuppressCrashReports(int seconds);

/**
 * Do not edit below this line!
 */
public Extension __ext_accelerator =
{
	name = "accelerator",
	file = "accelerator.ext",
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

#if !defined REQUIRE_EXTENSIONS
public __ext_accelerator_SetNTVOptional()
{
	MarkNativeAsOptional("Accelerator_GetUploadedCrashCount");
	MarkNativeAsOptional("Accelerator_IsDoneUploadingCrashes");
	MarkNativeAsOptional("Accelerator_GetCrashHTTPResponse");
	MarkNativeAsOptional("Accelerator_SuppressCrashReports");
}
#endif
