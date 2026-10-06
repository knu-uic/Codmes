plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.codmes.android"
    compileSdk = 35
    buildFeatures { buildConfig = true }
    defaultConfig {
        applicationId = "com.codmes.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        val googleWebClientId = providers.environmentVariable("CODMES_GOOGLE_WEB_CLIENT_ID").orElse("").get()
        require(googleWebClientId.isEmpty() || googleWebClientId.matches(Regex("[A-Za-z0-9_-]+\\.apps\\.googleusercontent\\.com"))) {
            "CODMES_GOOGLE_WEB_CLIENT_ID must be a Google OAuth client ID"
        }
        buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", "\"$googleWebClientId\"")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin { jvmToolchain(17) }

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.credentials:credentials:1.6.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.6.0")
    implementation("com.google.android.libraries.identity.googleid:googleid:1.1.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
    // Real JSON implementation for portable journal/HTTP tests (not shipped in APK).
    testImplementation("org.json:json:20260814")
}
