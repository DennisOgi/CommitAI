allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Some plugins (e.g. flutter_callkit_incoming) pin a Java 17 *toolchain* just to compile.
// Their bytecode still targets Java 17 via their own compileOptions/jvmTarget, so compiling
// them with the installed JDK (Android Studio's JBR 21) gives the same result and avoids
// needing a second JDK on every build machine.
subprojects {
    val useInstalledJdk: Project.() -> Unit = {
        extensions.findByType<JavaPluginExtension>()?.toolchain?.languageVersion?.let { lv ->
            if (lv.isPresent && lv.get().asInt() < 21) lv.set(JavaLanguageVersion.of(21))
        }
    }
    if (state.executed) useInstalledJdk() else afterEvaluate { useInstalledJdk() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
