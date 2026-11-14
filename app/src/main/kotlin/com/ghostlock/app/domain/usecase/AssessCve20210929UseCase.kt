package com.ghostlock.app.domain.usecase

import com.ghostlock.app.domain.model.Cve20210929Assessment
import com.ghostlock.app.domain.model.Cve20210929Status
import com.ghostlock.app.domain.model.IonDeviceSignal
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** Classifies public device indicators without testing or exercising the vulnerability. */
internal object AssessCve20210929UseCase {
    private const val FixSecurityPatchLevel = "2021-11-05"
    private const val PatchLevelPattern = "yyyy-MM-dd"

    fun assess(securityPatchLevel: String?, ionDeviceSignal: IonDeviceSignal): Cve20210929Assessment {
        val patchLevel = securityPatchLevel?.takeIf(::isValidPatchLevel)
        val status = when {
            patchLevel == null -> Cve20210929Status.UNKNOWN
            patchLevel >= FixSecurityPatchLevel -> Cve20210929Status.VENDOR_REPORTED_PATCHED
            ionDeviceSignal == IonDeviceSignal.PRESENT -> Cve20210929Status.POTENTIALLY_AFFECTED
            else -> Cve20210929Status.UNKNOWN
        }
        return Cve20210929Assessment(
            status = status,
            securityPatchLevel = securityPatchLevel?.takeIf(String::isNotBlank),
            ionDeviceSignal = ionDeviceSignal,
        )
    }

    private fun isValidPatchLevel(value: String): Boolean {
        val formatter = SimpleDateFormat(PatchLevelPattern, Locale.ROOT).apply {
            isLenient = false
            timeZone = TimeZone.getTimeZone("UTC")
        }
        val position = ParsePosition(0)
        val parsed: Date = formatter.parse(value, position) ?: return false
        return position.index == value.length && formatter.format(parsed) == value
    }
}
