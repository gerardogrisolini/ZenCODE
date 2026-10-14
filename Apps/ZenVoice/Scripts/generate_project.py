#!/usr/bin/env python3
"""Reproduce the standalone baseline project, not manual Xcode customizations.
Do not run over a customized project (deployment/signing/capabilities); patch it instead.
The native WebRTC dependency belongs only to this app, never to the root SwiftPM graph.
"""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent.parent

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

objects = []
def obj(name, text):
    objects.append(f'\t\t{ident(name)} = {{ {text} }};')
    return ident(name)

def refs(names):
    return '(' + ', '.join(ident(n) for n in names) + ', )'

sources = ['Protocol.swift', 'Settings.swift', 'ACPClient.swift', 'AudioIO.swift', 'RealtimeClient.swift', 'DesktopToolClient.swift', 'VoiceBridgeClient.swift', 'SubscriptionClient.swift', 'NativeWebRTCMedia.swift', 'VoiceModel.swift', 'ZenVoiceApp.swift']
testsources = ['Protocol.swift', 'Settings.swift', 'ACPClient.swift', 'RealtimeClient.swift', 'DesktopToolClient.swift', 'VoiceBridgeClient.swift', 'SubscriptionClient.swift', 'NativeWebRTCMedia.swift']
obj('package:WebRTC', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/stasel/WebRTC.git"; requirement = { kind = exactVersion; version = 155.0.0; };')
for source in sources:
    obj('file:' + source, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {source}; sourceTree = "<group>";')
obj('file:test', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ZenVoiceTests.swift; sourceTree = "<group>";')
obj('file:native-test', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NativeWebRTCMediaTests.swift; sourceTree = "<group>";')
obj('group:source', f'isa = PBXGroup; children = {refs(["file:" + s for s in sources])}; path = Sources; sourceTree = "<group>";')
obj('group:test', f'isa = PBXGroup; children = {refs(["file:test", "file:native-test"])}; path = Tests; sourceTree = "<group>";')
obj('product:app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = ZenVoice.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('product:test', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = ZenVoiceTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('group:products', f'isa = PBXGroup; children = {refs(["product:app", "product:test"])}; name = Products; sourceTree = "<group>";')
obj('group:root', f'isa = PBXGroup; children = {refs(["group:source", "group:test", "group:products"])}; sourceTree = "<group>";')
for target, files in [('app', sources), ('test', testsources + ['test', 'native-test'])]:
    builds = []
    for source in files:
        name = f'build:{target}:{source}'
        obj(name, f'isa = PBXBuildFile; fileRef = {ident("file:" + source)};')
        builds.append(name)
    obj('sources:' + target, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(builds)}; runOnlyForDeploymentPostprocessing = 0;')
    obj('package-product:' + target, f'isa = XCSwiftPackageProductDependency; package = {ident("package:WebRTC")}; productName = WebRTC;')
    framework = obj('framework:' + target, f'isa = PBXBuildFile; productRef = {ident("package-product:" + target)};')
    obj('frameworks:' + target, f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({framework}, ); runOnlyForDeploymentPostprocessing = 0;')
    obj('resources:' + target, 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    name = 'ZenVoice' if target == 'app' else 'ZenVoiceTests'
    producttype = 'com.apple.product-type.application' if target == 'app' else 'com.apple.product-type.bundle.unit-test'
    obj('target:' + target, f'isa = PBXNativeTarget; buildConfigurationList = {ident("configlist:" + target)}; buildPhases = {refs(["sources:" + target, "frameworks:" + target, "resources:" + target])}; buildRules = (); dependencies = (); name = {name}; packageProductDependencies = {refs(["package-product:" + target])}; productName = {name}; productReference = {ident("product:" + target)}; productType = "{producttype}";')
for owner in ['project', 'app', 'test']:
    for config in ['Debug', 'Release']:
        settings = {
            'SWIFT_VERSION': '6.0', 'MACOSX_DEPLOYMENT_TARGET': '14.0', 'SDKROOT': 'macosx',
            'SWIFT_STRICT_CONCURRENCY': 'complete', 'SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY': 'YES',
            'OTHER_SWIFT_FLAGS': '"$(inherited) -enable-upcoming-feature MemberImportVisibility"',
            'CLANG_ENABLE_MODULES': 'YES', 'CODE_SIGN_STYLE': 'Automatic',
        }
        if config == 'Debug':
            settings.update({'SWIFT_OPTIMIZATION_LEVEL': '"-Onone"', 'ENABLE_TESTABILITY': 'YES', 'DEBUG_INFORMATION_FORMAT': 'dwarf'})
        else:
            settings.update({'SWIFT_COMPILATION_MODE': 'wholemodule', 'SWIFT_OPTIMIZATION_LEVEL': '"-O"', 'DEBUG_INFORMATION_FORMAT': '"dwarf-with-dsym"'})
        if owner != 'project':
            settings.update({'PRODUCT_NAME': '"$(TARGET_NAME)"', 'GENERATE_INFOPLIST_FILE': 'YES', 'CURRENT_PROJECT_VERSION': '1', 'MARKETING_VERSION': '0.1.0', 'PRODUCT_BUNDLE_IDENTIFIER': 'app.zencode.ZenVoice' + ('.Tests' if owner == 'test' else ''), 'LD_RUNPATH_SEARCH_PATHS': '"$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks"'})
        if owner == 'app':
            settings.update({'INFOPLIST_KEY_LSUIElement': 'YES', 'INFOPLIST_KEY_NSMicrophoneUsageDescription': '"ZenVoice invia il microfono a OpenAI Realtime solo quando attivi la voce."', 'ENABLE_APP_SANDBOX': 'NO', 'ENABLE_HARDENED_RUNTIME': 'YES', 'CODE_SIGN_ENTITLEMENTS': 'ZenVoice.entitlements', 'INFOPLIST_KEY_CFBundleDisplayName': 'ZenVoice', 'INFOPLIST_KEY_LSApplicationCategoryType': '"public.app-category.developer-tools"'})
        if owner == 'test':
            settings.update({'TEST_HOST': '""', 'BUNDLE_LOADER': '""', 'CODE_SIGNING_ALLOWED': 'NO'})
        obj(f'config:{owner}:{config}', 'isa = XCBuildConfiguration; buildSettings = { ' + ' '.join(f'{k} = {v};' for k, v in settings.items()) + f' }}; name = {config};')
    obj('configlist:' + owner, f'isa = XCConfigurationList; buildConfigurations = {refs(["config:" + owner + ":Debug", "config:" + owner + ":Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 2700; LastUpgradeCheck = 2700; }}; buildConfigurationList = {ident("configlist:project")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, it); mainGroup = {ident("group:root")}; productRefGroup = {ident("group:products")}; projectDirPath = ""; projectRoot = ""; packageReferences = {refs(["package:WebRTC"])}; targets = {refs(["target:app", "target:test"])};')
project = root / 'ZenVoice.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + '\n\t};\n\trootObject = ' + ident('project') + ';\n}\n')
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
def reference(target, name, product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target:" + target)}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:ZenVoice.xcodeproj"/>'
app = reference('app', 'ZenVoice', 'ZenVoice.app')
test = reference('test', 'ZenVoiceTests', 'ZenVoiceTests.xctest')
(schemes / 'ZenVoice.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{test}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO" parallelizable="NO">{test}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
