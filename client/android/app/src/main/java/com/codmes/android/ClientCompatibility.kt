package com.codmes.android

object ClientCompatibility {
    fun supports(
        declaredPlatforms: List<String>,
        declaredFormFactors: List<String>,
        currentPlatform: String,
        currentFormFactor: String
    ): Boolean {
        val normalizedPlatforms = declaredPlatforms
            .map(::normalize)
            .map { if (it == "ipados") "ios" else it }
            .distinct()
        val normalizedFormFactors = if (declaredFormFactors.isNotEmpty()) {
            declaredFormFactors.map(::normalize).distinct()
        } else {
            legacyFormFactors(declaredPlatforms)
        }
        return (normalizedPlatforms.isEmpty() || normalize(currentPlatform) in normalizedPlatforms) &&
            (normalizedFormFactors.isEmpty() || normalize(currentFormFactor) in normalizedFormFactors)
    }

    private fun legacyFormFactors(platforms: List<String>): List<String> =
        platforms.mapNotNull {
            when (normalize(it)) {
                "macos" -> "desktop"
                "ios" -> "phone"
                "ipados" -> "tablet"
                else -> null
            }
        }.distinct()

    private fun normalize(value: String) = value.trim().lowercase()
}
