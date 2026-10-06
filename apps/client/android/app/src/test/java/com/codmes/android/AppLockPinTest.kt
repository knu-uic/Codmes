package com.codmes.android

import org.junit.Assert.*
import org.junit.Test

class AppLockPinTest {
    @Test fun acceptsOnlyFourASCIIDigits() {
        assertTrue(AppLockPin.valid("0123"))
        listOf("", "123", "12345", "１２３４", "1a34").forEach { assertFalse(AppLockPin.valid(it)) }
    }
    @Test fun hashesAreSaltedAndRejectWrongPIN() {
        val first = AppLockPin.encode("0123")
        assertFalse(first.contentEquals(AppLockPin.encode("0123")))
        assertTrue(AppLockPin.verify("0123", first))
        assertFalse(AppLockPin.verify("9999", first))
        assertFalse(AppLockPin.verify("0123", ByteArray(1)))
    }
}
