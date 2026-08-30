package com.codmes.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClientCompatibilityTest {
    @Test
    fun androidPhoneAndTabletMatchTheirDeclaredFormFactors() {
        val platforms = listOf("macos", "ios", "android", "windows")
        val factors = listOf("phone", "tablet", "desktop")

        assertTrue(ClientCompatibility.supports(platforms, factors, "android", "phone"))
        assertTrue(ClientCompatibility.supports(platforms, factors, "android", "tablet"))
        assertFalse(ClientCompatibility.supports(listOf("android"), listOf("phone"), "windows", "phone"))
    }

    @Test
    fun legacyIPadOSNormalizesToIosTabletWithoutClaimingAndroidSupport() {
        assertTrue(ClientCompatibility.supports(listOf("ipados"), emptyList(), "ios", "tablet"))
        assertFalse(ClientCompatibility.supports(listOf("ipados"), emptyList(), "android", "tablet"))
    }

    @Test
    fun absentCompatibilityMetadataRemainsBackwardCompatible() {
        assertTrue(ClientCompatibility.supports(emptyList(), emptyList(), "android", "phone"))
    }
}
