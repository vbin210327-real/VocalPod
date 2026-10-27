#!/usr/bin/env python3
"""Generate a small native Xcode project without installing a project generator."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "VocalPod.xcodeproj"
TEAM = "V7439G9SY8"
objects: dict[str, dict] = {}


def ident(label: str) -> str:
    return hashlib.sha1(label.encode()).hexdigest()[:24].upper()


def put(label: str, **properties) -> str:
    identifier = ident(label)
    objects[identifier] = properties
    return identifier


def quote(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./]+", value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def encode(value, depth=0) -> str:
    pad = "\t" * depth
    if isinstance(value, dict):
        lines = ["{"]
        for key, item in value.items():
            lines.append(f"{pad}\t{quote(str(key))} = {encode(item, depth + 1)};")
        lines.append(pad + "}")
        return "\n".join(lines)
    if isinstance(value, (list, tuple)):
        if not value:
            return "()"
        return "(\n" + "".join(f"{pad}\t{encode(item, depth + 1)},\n" for item in value) + pad + ")"
    return quote(str(value))


def configuration_list(label: str, common: dict, extra=None) -> str:
    extra = extra or {}
    configs = []
    for name in ("Debug", "Release"):
        settings = common.copy()
        settings.update(extra.get(name, {}))
        configs.append(put(label + name, isa="XCBuildConfiguration", buildSettings=settings, name=name))
    return put(label + "ConfigurationList", isa="XCConfigurationList",
               buildConfigurations=configs, defaultConfigurationIsVisible=0,
               defaultConfigurationName="Release")


app_target, unit_target, ui_target = map(ident, ("VocalPodTarget", "VocalPodTestsTarget", "VocalPodUITestsTarget"))
project_id = ident("Project")
products = []
groups = []
target_specs = (
    ("VocalPod", app_target, "application", "app"),
    ("VocalPodTests", unit_target, "bundle.unit-test", "xctest"),
    ("VocalPodUITests", ui_target, "bundle.ui-testing", "xctest"),
)

target_common = {
    "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": TEAM,
    "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
    "SDKROOT": "iphoneos",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": "1",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
}

for name, target_id, product_type, extension in target_specs:
    source_dir = ROOT / name
    source_dir.mkdir(exist_ok=True)
    children, source_build_files = [], []
    for path in sorted(source_dir.rglob("*.swift")):
        relative = path.relative_to(source_dir).as_posix()
        file_id = put(name + "/" + relative, isa="PBXFileReference",
                      lastKnownFileType="sourcecode.swift", path=relative, sourceTree="<group>")
        children.append(file_id)
        source_build_files.append(put("Build/" + name + "/" + relative,
                                      isa="PBXBuildFile", fileRef=file_id))
    resource_build_files = []
    if name == "VocalPod":
        info = put("Info.plist", isa="PBXFileReference", lastKnownFileType="text.plist.xml",
                   path="Info.plist", sourceTree="<group>")
        assets = put("Assets.xcassets", isa="PBXFileReference", lastKnownFileType="folder.assetcatalog",
                     path="Assets.xcassets", sourceTree="<group>")
        children.extend((info, assets))
        resource_build_files.append(put("Build/Assets", isa="PBXBuildFile", fileRef=assets))
        if (source_dir / "PrivacyInfo.xcprivacy").exists():
            privacy = put("PrivacyInfo.xcprivacy", isa="PBXFileReference", lastKnownFileType="text.xml",
                          path="PrivacyInfo.xcprivacy", sourceTree="<group>")
            children.append(privacy)
            resource_build_files.append(put("Build/PrivacyInfo", isa="PBXBuildFile", fileRef=privacy))
    groups.append(put(name + "Group", isa="PBXGroup", children=children, path=name, sourceTree="<group>"))
    sources = put(name + "Sources", isa="PBXSourcesBuildPhase", buildActionMask=2147483647,
                  files=source_build_files, runOnlyForDeploymentPostprocessing=0)
    frameworks = put(name + "Frameworks", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647,
                     files=[], runOnlyForDeploymentPostprocessing=0)
    resources = put(name + "Resources", isa="PBXResourcesBuildPhase", buildActionMask=2147483647,
                    files=resource_build_files, runOnlyForDeploymentPostprocessing=0)
    build_phases = [sources, frameworks, resources]
    if name == "VocalPod":
        build_phases.append(put("AppSizeReserve", isa="PBXShellScriptBuildPhase",
                                buildActionMask=2147483647, files=[], inputPaths=[],
                                outputPaths=["$(TARGET_BUILD_DIR)/$(WRAPPER_NAME)/SizeReserve.dat"],
                                runOnlyForDeploymentPostprocessing=0, alwaysOutOfDate=1,
                                name="Target 50 MB app size", shellPath="/bin/sh",
                                shellScript='/usr/bin/python3 "$SRCROOT/Scripts/size_app_bundle.py"\n'))
    product = put(name + "Product", isa="PBXFileReference", explicitFileType=(
        "wrapper.application" if name == "VocalPod" else "wrapper.cfbundle"),
        includeInIndex=0, path=f"{name}.{extension}", sourceTree="BUILT_PRODUCTS_DIR")
    products.append(product)
    settings = target_common | {
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.linfanbin." + name,
    }
    if name == "VocalPod":
        settings.update({
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "CURRENT_PROJECT_VERSION": "1",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "VocalPod/Info.plist",
            "MARKETING_VERSION": "1.0.0",
            "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            "SUPPORTS_MACCATALYST": "NO",
            "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
            "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
            "SWIFT_EMIT_LOC_STRINGS": "NO",
        })
    else:
        settings["GENERATE_INFOPLIST_FILE"] = "YES"
        if name == "VocalPodTests":
            settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
            settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/VocalPod.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/VocalPod"
        else:
            settings["TEST_TARGET_NAME"] = "VocalPod"
    config_list = configuration_list(name, settings)
    dependencies = []
    if name != "VocalPod":
        proxy = put(name + "Proxy", isa="PBXContainerItemProxy", containerPortal=project_id,
                    proxyType=1, remoteGlobalIDString=app_target, remoteInfo="VocalPod")
        dependencies.append(put(name + "Dependency", isa="PBXTargetDependency",
                                target=app_target, targetProxy=proxy))
    objects[target_id] = dict(isa="PBXNativeTarget", buildConfigurationList=config_list,
                             buildPhases=build_phases, buildRules=[],
                             dependencies=dependencies, name=name, productName=name,
                             productReference=product,
                             productType="com.apple.product-type." + product_type)

products_group = put("ProductsGroup", isa="PBXGroup", children=products, name="Products", sourceTree="<group>")
main_group = put("MainGroup", isa="PBXGroup", children=groups + [products_group], sourceTree="<group>")
project_config = configuration_list("Project", {
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
}, {
    "Debug": {"ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0",
              "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
              "ONLY_ACTIVE_ARCH": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
              "SWIFT_OPTIMIZATION_LEVEL": "-Onone"},
    "Release": {"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                "SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": "-O"},
})
objects[project_id] = dict(
    isa="PBXProject",
    attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2660",
                "TargetAttributes": {
                    app_target: {"CreatedOnToolsVersion": "26.6", "DevelopmentTeam": TEAM},
                    unit_target: {"CreatedOnToolsVersion": "26.6", "TestTargetID": app_target},
                    ui_target: {"CreatedOnToolsVersion": "26.6", "TestTargetID": app_target},
                }},
    buildConfigurationList=project_config, compatibilityVersion="Xcode 14.0",
    developmentRegion="zh_CN", hasScannedForEncodings=0, knownRegions=["zh_CN", "en", "Base"],
    mainGroup=main_group, productRefGroup=products_group, projectDirPath="", projectRoot="",
    targets=[app_target, unit_target, ui_target],
)
PROJECT.mkdir(exist_ok=True)
project_data = dict(archiveVersion=1, classes={}, objectVersion=56,
                    objects=objects, rootObject=project_id)
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(project_data) + "\n")


def reference(parent, name: str, target_id: str, extension: str):
    ET.SubElement(parent, "BuildableReference", {
        "BuildableIdentifier": "primary", "BlueprintIdentifier": target_id,
        "BuildableName": f"{name}.{extension}", "BlueprintName": name,
        "ReferencedContainer": "container:VocalPod.xcodeproj",
    })


scheme = ET.Element("Scheme", LastUpgradeVersion="2660", version="1.7")
build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
entries = ET.SubElement(build, "BuildActionEntries")
for name, target_id, _, extension in target_specs:
    attributes = {"buildForTesting": "YES", "buildForRunning": "YES" if name == "VocalPod" else "NO",
                  "buildForProfiling": "YES" if name == "VocalPod" else "NO",
                  "buildForArchiving": "YES" if name == "VocalPod" else "NO",
                  "buildForAnalyzing": "YES" if name == "VocalPod" else "NO"}
    reference(ET.SubElement(entries, "BuildActionEntry", attributes), name, target_id, extension)
test = ET.SubElement(scheme, "TestAction", buildConfiguration="Debug",
                     selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                     selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB",
                     shouldUseLaunchSchemeArgsEnv="YES", codeCoverageEnabled="NO")
testables = ET.SubElement(test, "Testables")
for name, target_id, _, extension in target_specs[1:]:
    reference(ET.SubElement(testables, "TestableReference", skipped="NO"), name, target_id, extension)
launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug",
                       selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                       selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB",
                       launchStyle="0", useCustomWorkingDirectory="NO",
                       ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES",
                       debugServiceExtension="internal", allowLocationSimulation="NO")
reference(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"), "VocalPod", app_target, "app")
profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release",
                        shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="",
                        useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
reference(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), "VocalPod", app_target, "app")
ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
ET.indent(scheme, space="   ")
scheme_dir = PROJECT / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
ET.ElementTree(scheme).write(scheme_dir / "VocalPod.xcscheme", encoding="UTF-8", xml_declaration=True)
print(f"Generated {PROJECT.name} with three native targets; no dependencies installed.")
