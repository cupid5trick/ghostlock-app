package com.ghostlock.app.domain.usecase

import com.ghostlock.app.domain.model.Cve20210929Status
import com.ghostlock.app.domain.model.IonDeviceSignal
import org.junit.Assert.assertEquals
import org.junit.Test

class AssessCve20210929UseCaseTest {

    @Test
    fun `patch level before fix and detected ION is potentially affected`() {
        val result = AssessCve20210929UseCase.assess("2021-11-04", ionDeviceSignal = IonDeviceSignal.PRESENT)

        assertEquals(Cve20210929Status.POTENTIALLY_AFFECTED, result.status)
    }

    @Test
    fun `fix patch level is vendor reported patched`() {
        val result = AssessCve20210929UseCase.assess("2021-11-05", ionDeviceSignal = IonDeviceSignal.PRESENT)

        assertEquals(Cve20210929Status.VENDOR_REPORTED_PATCHED, result.status)
    }

    @Test
    fun `patch level after fix is vendor reported patched`() {
        val result = AssessCve20210929UseCase.assess("2021-11-06", ionDeviceSignal = IonDeviceSignal.ABSENT)

        assertEquals(Cve20210929Status.VENDOR_REPORTED_PATCHED, result.status)
    }

    @Test
    fun `older patch without ION remains unknown when absent`() {
        val result = AssessCve20210929UseCase.assess("2021-11-04", ionDeviceSignal = IonDeviceSignal.ABSENT)

        assertEquals(Cve20210929Status.UNKNOWN, result.status)
    }

    @Test
    fun `older patch remains unknown when ION cannot be detected`() {
        val result = AssessCve20210929UseCase.assess("2021-11-04", ionDeviceSignal = IonDeviceSignal.UNKNOWN)

        assertEquals(Cve20210929Status.UNKNOWN, result.status)
    }

    @Test
    fun `missing or malformed patch level remains unknown even when ION is detected`() {
        listOf(null, "", "2021-13-01", "2021-02-29", "not-a-date").forEach { patchLevel ->
            val result = AssessCve20210929UseCase.assess(patchLevel, ionDeviceSignal = IonDeviceSignal.PRESENT)

            assertEquals("patch level=$patchLevel", Cve20210929Status.UNKNOWN, result.status)
        }
    }
}
