import java.util.Properties
import java.security.KeyStore
import java.security.cert.X509Certificate

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseProperties = Properties().apply {
    val propertiesFile = rootProject.file("key.properties")
    if (propertiesFile.exists()) propertiesFile.inputStream().use { load(it) }
}
fun signingValue(property: String, environment: String): String? =
    System.getenv(environment)?.takeIf { it.isNotBlank() }
        ?: releaseProperties.getProperty(property)?.takeIf { it.isNotBlank() }
val releaseStore = signingValue("storeFile", "CM_KEYSTORE_PATH")
val releaseStorePassword = signingValue("storePassword", "CM_KEYSTORE_PASSWORD")
val releaseAlias = signingValue("keyAlias", "CM_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "CM_KEY_PASSWORD")
val releaseSigningReady = listOf(releaseStore, releaseStorePassword, releaseAlias, releaseKeyPassword)
    .all { it != null }

val verifyReleaseSigning = tasks.register("verifyReleaseSigning") {
    doLast {
        check(releaseSigningReady) {
            "Release signing is required. Configure android/key.properties or CM_KEYSTORE_PATH, " +
                "CM_KEYSTORE_PASSWORD, CM_KEY_ALIAS and CM_KEY_PASSWORD. Debug signing is forbidden."
        }
        val storeFile = rootProject.file(releaseStore!!)
        check(storeFile.isFile) { "Release keystore does not exist." }
        val keyStore = KeyStore.getInstance(storeFile, releaseStorePassword!!.toCharArray())
        val certificate = keyStore.getCertificate(releaseAlias) as? X509Certificate
        check(certificate != null && keyStore.isKeyEntry(releaseAlias)) { "Release signing alias is invalid." }
        check(!certificate.subjectX500Principal.name.contains("CN=Android Debug", ignoreCase = true)) {
            "Android Debug certificates cannot sign a release."
        }
    }
}
tasks.configureEach {
    if (name == "validateSigningRelease" || name == "assembleRelease" ||
        name == "bundleRelease" || (name.startsWith("package") && name.contains("Release"))) {
        dependsOn(verifyReleaseSigning)
    }
}

android {
    namespace = "com.idoluidoluidolu.watermark"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.idoluidoluidolu.watermark"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24 // ffmpeg_kit_flutter_new requires 24+
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningReady) {
            create("release") {
                storeFile = rootProject.file(releaseStore!!)
                storePassword = releaseStorePassword
                keyAlias = releaseAlias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes {
        release {
            signingConfig = if (releaseSigningReady) signingConfigs.getByName("release") else null
            // 不做 R8 縮減（Flutter 外掛預設會打開，這裡在它之後跑、蓋掉它）：
            // ML Kit 找臉在縮減過的正式版裡一跑就是 NullPointerException（10-25
            // Android 實機：「getClass() on a null object reference」＝R8 內聯後
            // 的空值檢查），它靠反射／JNI 依名字找的東西被縮掉了；iOS、除錯版
            // 沒這個問題。代價是 APK 大幾 MB
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    // SDR 工作檔透過 MediaCodec＋OpenGL 產生，實際 codec 與色調映射
    // 能力依裝置而異（見 MainActivity 的 markcut/prep 通道）。
    implementation("androidx.media3:media3-transformer:1.5.1")
    implementation("androidx.media3:media3-effect:1.5.1")
    implementation("androidx.media3:media3-common:1.5.1")
    // 馬賽克的自動找臉（markcut/face）。模型跟著 App 一起裝（約 +6.9MB），
    // 不靠 Google Play 服務臨時下載：第一次用不用等、沒網路也能找
    implementation("com.google.mlkit:face-detection:16.1.7")
}
