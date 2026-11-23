group = "dev.baseplatform.base_models"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "dev.baseplatform.base_models"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 26 // java.nio.file and java.time in SharedModelStore
        // No manifestPlaceholders here: a library's own values are filled in when
        // the library is built and would beat the app's. Each app sets the real
        // ones from platform.yaml (./base check enforces them).
    }

    testOptions {
        unitTests {
            // Off: the tests are plain JVM code, and the test manifest would need the
            // placeholders that only an app may set.
            isIncludeAndroidResources = false
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    // Real org.json for JVM unit tests (android.jar only has stubs).
    testImplementation("org.json:json:20250517")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
