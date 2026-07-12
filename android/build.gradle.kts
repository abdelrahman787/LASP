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

// Force all library subprojects to compileSdk 35 so that their AndroidX
// transitive deps (which require 34+) do not fail checkAarMetadata.
// gradle.afterProject fires for every project AFTER its own build script
// finishes, so it always wins over whatever compileSdk the plugin set.
gradle.afterProject {
    extensions.findByType<com.android.build.api.dsl.LibraryExtension>()?.run {
        if ((compileSdk ?: 0) < 35) compileSdk = 35
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
