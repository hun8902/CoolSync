plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "app.coolsync"
    compileSdk = 36
    defaultConfig { applicationId = "app.coolsync"; minSdk = 31; targetSdk = 36; versionCode = providers.gradleProperty("coolsyncBuild").orNull?.toInt() ?: 1049; versionName = "0.3.0" }
    signingConfigs { create("distribution") {
        storeFile = System.getenv("COOLSYNC_KEYSTORE")?.let { file(it) }
        storePassword = System.getenv("COOLSYNC_STORE_PASSWORD")
        keyAlias = System.getenv("COOLSYNC_KEY_ALIAS") ?: "androiddebugkey"
        keyPassword = System.getenv("COOLSYNC_KEY_PASSWORD")
    } }
    buildTypes { getByName("release") { if(System.getenv("COOLSYNC_KEYSTORE") != null) signingConfig=signingConfigs.getByName("distribution") } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies { implementation("androidx.exifinterface:exifinterface:1.4.2"); implementation("com.journeyapps:zxing-android-embedded:4.3.0") }
