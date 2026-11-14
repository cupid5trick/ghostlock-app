package com.ghostlock.app.domain.usecase

import com.ghostlock.app.domain.model.IonDeviceProbe
import com.ghostlock.app.domain.model.IonProbeIoctlStatus
import com.ghostlock.app.domain.model.IonProbeOpenStatus
import com.ghostlock.app.domain.model.IonProbePathStatus
import com.ghostlock.app.domain.model.IonProbePermissionStatus

/** Parses the single-line result emitted by the native read-only ION probe. */
internal object ParseIonProbeOutputUseCase {
    fun parse(output: String?): IonDeviceProbe? {
        val fields = output?.split('\t') ?: return null
        if (fields.size != 6 || fields[0] != "ION_PROBE") return null

        val path = enumValueOrNull<IonProbePathStatus>(fields[1]) ?: return null
        val permission = enumValueOrNull<IonProbePermissionStatus>(fields[2]) ?: return null
        val open = enumValueOrNull<IonProbeOpenStatus>(fields[3]) ?: return null
        val ioctl = enumValueOrNull<IonProbeIoctlStatus>(fields[4]) ?: return null
        val heapCount = fields[5].toIntOrNull()?.takeIf { it >= 0 }
        if (ioctl == IonProbeIoctlStatus.SUPPORTED && heapCount == null) return null
        if (ioctl != IonProbeIoctlStatus.SUPPORTED && fields[5] != "-") return null

        return IonDeviceProbe(
            path = path,
            readPermission = permission,
            open = open,
            heapQuery = ioctl,
            heapCount = heapCount,
        )
    }

    private inline fun <reified T : Enum<T>> enumValueOrNull(value: String): T? =
        enumValues<T>().firstOrNull { it.name == value }
}
