plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.echoenglish.echo_english"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.echoenglish.echo_english"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 讯飞 AIUI 只提供 armeabi-v7a / arm64-v8a 两套 so
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDir("src/main/jniLibs")
        }
    }

    // AIUI 的 ivw 词表 / vad 资源必须以未压缩形式放进 apk
    androidResources {
        noCompress += listOf("bin", "jet", "dat")
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            // xrtc 与 AIUI 各自带了一份同名 so 时保留第一份
            pickFirsts += listOf("**/libaiui.so", "**/libvtn_mic1.so")
        }
        resources {
            excludes += listOf("META-INF/LICENSE*", "META-INF/NOTICE*")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

dependencies {
    // 讯飞 AIUI：本地 jar + aar（aar 内已带 jni/*.so，会自动打进 apk）
    implementation(files("libs/AIUI.jar"))
    implementation(files("libs/xrtcsdk.aar"))
}

flutter {
    source = "../.."
}
