package com.ghostlock.app.domain.usecase

import com.ghostlock.app.domain.model.IonProbeIoctlStatus
import com.ghostlock.app.domain.model.IonProbeOpenStatus
import com.ghostlock.app.domain.model.IonProbePathStatus
import com.ghostlock.app.domain.model.IonProbePermissionStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ParseIonProbeOutputUseCaseTest {

    @Test
    fun `parses successful heap query`() {
        val result = ParseIonProbeOutputUseCase.parse("ION_PROBE\tPRESENT\tALLOWED\tOPENED\tSUPPORTED\t4")

        assertEquals(IonProbePathStatus.PRESENT, result?.path)
        assertEquals(IonProbePermissionStatus.ALLOWED, result?.readPermission)
        assertEquals(IonProbeOpenStatus.OPENED, result?.open)
        assertEquals(IonProbeIoctlStatus.SUPPORTED, result?.heapQuery)
        assertEquals(4, result?.heapCount)
    }

    @Test
    fun `parses absent node with later stages not tested`() {
        val result = ParseIonProbeOutputUseCase.parse("ION_PROBE\tABSENT\tNOT_TESTED\tNOT_TESTED\tNOT_TESTED\t-")

        assertEquals(IonProbePathStatus.ABSENT, result?.path)
        assertEquals(IonProbePermissionStatus.NOT_TESTED, result?.readPermission)
        assertEquals(IonProbeOpenStatus.NOT_TESTED, result?.open)
        assertEquals(IonProbeIoctlStatus.NOT_TESTED, result?.heapQuery)
    }

    @Test
    fun `rejects malformed or inconsistent results`() {
        listOf(
            null,
            "",
            "ION_PROBE\\tPRESENT\\tALLOWED\\tOPENED\\tSUPPORTED\\t1",
            "ION_PROBE\tPRESENT\tALLOWED\tOPENED\tSUPPORTED\t-",
            "ION_PROBE\tPRESENT\tALLOWED\tOPENED\tFAILED\t1",
        ).forEach { output -> assertNull(ParseIonProbeOutputUseCase.parse(output)) }
    }
}
