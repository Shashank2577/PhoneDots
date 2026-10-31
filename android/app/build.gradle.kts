plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "ai.phonedots.phonedots"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "ai.phonedots.phonedots"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Desert Ant needs 24; LiteRT-LM and java.time APIs are happiest on 26+.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The shared model store (base_models): the vendor-wide values from the
        // base platform's platform.yaml → sharedModels. Every app of the vendor
        // uses the same two, so they hand each other models instead of
        // downloading them again (apps must be signed with the same key).
        manifestPlaceholders["baseModelsPermission"] = "com.showcase.permission.SHARED_MODELS"
        manifestPlaceholders["baseModelsDiscoveryAction"] = "com.showcase.action.SHARED_MODELS"
    }

    packaging {
        // Large native libraries load straight from the APK; both SDKs ship their own JNI shims.
        jniLibs {
            useLegacyPackaging = true
            pickFirsts.add("lib/arm64-v8a/liblitertlm_jni.so")
            // Real phones only: the Desert Ant libraries are ~56 MB per model per ABI.
            excludes += listOf("lib/x86_64/**", "lib/x86/**", "lib/armeabi-v7a/**")
        }
    }

    signingConfigs {
        // Every app of the vendor signs with the same key, so they share models
        // (the shared store's Android permission is signature-level) and builds
        // update in place: baseApp signing/README.md. This is the vendor's public
        // test key (PhoneDots' old test key, so existing installs update); baseApp
        // keeps it as signing/showcase-test.jks (byte-identical). Not secret: never
        // publish to a store with it.
        create("vendorTest") {
            storeFile = file("phonedots-test.jks")
            storePassword = "phonedots-test"
            keyAlias = "phonedots-test"
            keyPassword = "phonedots-test"
        }
        // Your real release key, from CI secrets (ANDROID_KEYSTORE_BASE64 and friends).
        System.getenv("ANDROID_KEYSTORE_PATH")?.let { keystore ->
            create("release") {
                storeFile = file(keystore)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        // If the test key file is ever missing, fall back to the machine's debug key.
        val vendorTest = signingConfigs.getByName("vendorTest").takeIf { it.storeFile?.exists() == true }
        debug {
            signingConfig = vendorTest ?: signingConfigs.getByName("debug")
        }
        release {
            signingConfig = signingConfigs.findByName("release") ?: vendorTest ?: signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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

val desertAnt = "4.2.1"

dependencies {
    // Gemma on device: https://github.com/google-ai-edge/LiteRT-LM
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.19.0")
    // Specialists: https://github.com/Desert-Ant-Labs/desert-ant-core
    for (model in listOf("voz", "who", "ear", "clear", "redact", "emo", "gist", "eye", "moderator", "tongue")) {
        implementation("ai.desertant:$model:$desertAnt")
    }
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}
