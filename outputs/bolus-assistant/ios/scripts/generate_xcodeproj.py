#!/usr/bin/env python3
"""Generate Bolus.xcodeproj for the local-first iOS app.

The app target compiles the SwiftUI layer (`Bolus/**`) together with the
deterministic core (`Sources/BolusCore/**`), so the shipped app has no package
or server dependency. `BolusAppTests` is a hosted unit-test bundle that runs the
SwiftData flows on a simulator. The same core is also tested on its own with
`swift test` (see Package.swift).

Object identifiers are derived from file paths, so re-running the script after
adding or removing files produces a minimal, stable diff:

    python3 ios/scripts/generate_xcodeproj.py
"""
import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'Bolus.xcodeproj'

APP = 'Bolus'
TESTS = 'BolusAppTests'
TEAM = '22U845G3B8'
BUNDLE_ID = 'app.bolus.diary.personal'
DEPLOYMENT_TARGET = '17.0'
MARKETING_VERSION = '2.0.0'
BUILD_NUMBER = '2'

APP_SOURCE_DIRS = ['Bolus', 'Sources/BolusCore']
TEST_SOURCE_DIRS = ['BolusAppTests']
APP_RESOURCES = ['Bolus/Assets.xcassets', 'Bolus/PrivacyInfo.xcprivacy']
# The former server's JSON export, shared with the BolusCore tests (server → iPhone migration).
TEST_RESOURCES = ['Tests/BolusCoreTests/Fixtures/legacy_server_backup.json']
REFERENCE_ONLY = ['Bolus/Info.plist', 'Bolus/Bolus.entitlements']

FILE_TYPES = {
    '.swift': 'sourcecode.swift',
    '.xcassets': 'folder.assetcatalog',
    '.xcprivacy': 'text.xml',
    '.plist': 'text.plist.xml',
    '.entitlements': 'text.plist.entitlements',
    '.json': 'text.json',
}


def oid(*parts):
    return hashlib.md5('|'.join(parts).encode()).hexdigest()[:24].upper()


def q(value):
    value = str(value)
    if re.fullmatch(r'[A-Za-z0-9_./]+', value):
        return value
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def swift_files(directories):
    files = []
    for directory in directories:
        files += sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / directory).rglob('*.swift'))
    if not files:
        raise SystemExit(f'no Swift files in {directories}')
    return files


def render(value, indent):
    pad = '\t' * indent
    if isinstance(value, dict):
        lines = ['{']
        for key, item in value.items():
            lines.append(f'{pad}\t{q(key)} = {render(item, indent + 1)};')
        lines.append(pad + '}')
        return '\n'.join(lines)
    if isinstance(value, list):
        lines = ['(']
        for item in value:
            lines.append(f'{pad}\t{render(item, indent + 1)},')
        lines.append(pad + ')')
        return '\n'.join(lines)
    if isinstance(value, Ref):
        return f'{value.id} /* {value.comment} */'
    return q(value)


class Ref:
    def __init__(self, identifier, comment):
        self.id = identifier
        self.comment = comment


def main():
    app_sources = swift_files(APP_SOURCE_DIRS)
    test_sources = swift_files(TEST_SOURCE_DIRS)
    all_files = app_sources + test_sources + APP_RESOURCES + TEST_RESOURCES + REFERENCE_ONLY
    for path in all_files:
        if not (ROOT / path).exists():
            raise SystemExit(f'missing {path}')

    objects = {}

    def add(identifier, comment, body):
        objects[identifier] = (comment, body)
        return Ref(identifier, comment)

    # File references and the group tree that mirrors the folders on disk.
    file_refs = {}
    groups = {'': []}
    for path in all_files:
        parts = path.split('/')
        for depth in range(1, len(parts)):
            parent, folder = '/'.join(parts[:depth - 1]), '/'.join(parts[:depth])
            if folder not in groups:
                groups[folder] = []
                groups[parent].append(('group', folder))
        name = parts[-1]
        kind = FILE_TYPES[Path(name).suffix]
        file_refs[path] = add(oid('file', path), name, {
            'isa': 'PBXFileReference', 'lastKnownFileType': kind, 'path': name, 'sourceTree': '<group>'})
        groups['/'.join(parts[:-1])].append(('file', path))

    products = {
        APP: add(oid('product', APP), f'{APP}.app', {
            'isa': 'PBXFileReference', 'explicitFileType': 'wrapper.application', 'includeInIndex': '0',
            'path': f'{APP}.app', 'sourceTree': 'BUILT_PRODUCTS_DIR'}),
        TESTS: add(oid('product', TESTS), f'{TESTS}.xctest', {
            'isa': 'PBXFileReference', 'explicitFileType': 'wrapper.cfbundle', 'includeInIndex': '0',
            'path': f'{TESTS}.xctest', 'sourceTree': 'BUILT_PRODUCTS_DIR'}),
    }
    products_group = add(oid('group', 'Products'), 'Products', {
        'isa': 'PBXGroup', 'children': [products[APP], products[TESTS]], 'name': 'Products', 'sourceTree': '<group>'})

    def group_ref(folder):
        children = sorted(groups[folder], key=lambda item: (item[0] != 'group', item[1].lower()))
        refs = [group_ref(name) if kind == 'group' else file_refs[name] for kind, name in children]
        if folder == '':
            return add(oid('group', '<root>'), 'mainGroup', {
                'isa': 'PBXGroup', 'children': refs + [products_group], 'sourceTree': '<group>'})
        name = folder.split('/')[-1]
        return add(oid('group', folder), name, {
            'isa': 'PBXGroup', 'children': refs, 'path': name, 'sourceTree': '<group>'})

    main_group = group_ref('')

    def build_files(paths, phase):
        return [add(oid('build', phase, path), f'{path.split("/")[-1]} in {phase}', {
            'isa': 'PBXBuildFile', 'fileRef': file_refs[path]}) for path in paths]

    def phase(isa, name, target, files):
        return add(oid('phase', target, name), name, {
            'isa': isa, 'buildActionMask': '2147483647', 'files': files, 'runOnlyForDeploymentPostprocessing': '0'})

    common = {'CODE_SIGN_STYLE': 'Automatic', 'DEVELOPMENT_TEAM': TEAM, 'IPHONEOS_DEPLOYMENT_TARGET': DEPLOYMENT_TARGET,
              'SWIFT_VERSION': '5.0', 'TARGETED_DEVICE_FAMILY': '1,2'}
    app_settings = {
        **common,
        'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
        # Theme-coloured alternate icons (AppIcon-<theme>) for UIApplication.setAlternateIconName.
        'ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS': 'YES',
        'CODE_SIGN_ENTITLEMENTS': 'Bolus/Bolus.entitlements',
        'CURRENT_PROJECT_VERSION': BUILD_NUMBER,
        'ENABLE_PREVIEWS': 'YES',
        'GENERATE_INFOPLIST_FILE': 'NO',
        'INFOPLIST_FILE': 'Bolus/Info.plist',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks'],
        'MARKETING_VERSION': MARKETING_VERSION,
        'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE_ID,
        'PRODUCT_NAME': '$(TARGET_NAME)',
        'SWIFT_EMIT_LOC_STRINGS': 'YES',
    }
    test_settings = {
        **common,
        'BUNDLE_LOADER': '$(TEST_HOST)',
        'CURRENT_PROJECT_VERSION': BUILD_NUMBER,
        'GENERATE_INFOPLIST_FILE': 'YES',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'],
        'MARKETING_VERSION': MARKETING_VERSION,
        'PRODUCT_BUNDLE_IDENTIFIER': f'{BUNDLE_ID}.tests',
        'PRODUCT_NAME': '$(TARGET_NAME)',
        'SWIFT_EMIT_LOC_STRINGS': 'NO',
        'TEST_HOST': f'$(BUILT_PRODUCTS_DIR)/{APP}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/{APP}',
    }
    project_base = {
        'ALWAYS_SEARCH_USER_PATHS': 'NO',
        'CLANG_ANALYZER_NONNULL': 'YES',
        'CLANG_CXX_LANGUAGE_STANDARD': 'gnu++20',
        'CLANG_ENABLE_MODULES': 'YES',
        'CLANG_ENABLE_OBJC_ARC': 'YES',
        'CLANG_ENABLE_OBJC_WEAK': 'YES',
        'COPY_PHASE_STRIP': 'NO',
        'ENABLE_STRICT_OBJC_MSGSEND': 'YES',
        'ENABLE_USER_SCRIPT_SANDBOXING': 'YES',
        'GCC_C_LANGUAGE_STANDARD': 'gnu17',
        'GCC_NO_COMMON_BLOCKS': 'YES',
        'IPHONEOS_DEPLOYMENT_TARGET': DEPLOYMENT_TARGET,
        'MTL_FAST_MATH': 'YES',
        'SDKROOT': 'iphoneos',
    }
    project_debug = {
        **project_base,
        'DEBUG_INFORMATION_FORMAT': 'dwarf',
        'ENABLE_TESTABILITY': 'YES',
        'GCC_DYNAMIC_NO_PIC': 'NO',
        'GCC_OPTIMIZATION_LEVEL': '0',
        'GCC_PREPROCESSOR_DEFINITIONS': ['DEBUG=1', '$(inherited)'],
        'MTL_ENABLE_DEBUG_INFO': 'INCLUDE_SOURCE',
        'ONLY_ACTIVE_ARCH': 'YES',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG $(inherited)',
        'SWIFT_OPTIMIZATION_LEVEL': '-Onone',
    }
    project_release = {
        **project_base,
        'DEBUG_INFORMATION_FORMAT': 'dwarf-with-dsym',
        'ENABLE_NS_ASSERTIONS': 'NO',
        'MTL_ENABLE_DEBUG_INFO': 'NO',
        'SWIFT_COMPILATION_MODE': 'wholemodule',
        'SWIFT_OPTIMIZATION_LEVEL': '-O',
        'VALIDATE_PRODUCT': 'YES',
    }

    def config_list(owner, label, debug, release):
        configs = [add(oid('config', owner, name), name, {'isa': 'XCBuildConfiguration', 'buildSettings': dict(sorted(settings.items())),
                                                           'name': name})
                   for name, settings in (('Debug', debug), ('Release', release))]
        return add(oid('configlist', owner), f'Build configuration list for {label}', {
            'isa': 'XCConfigurationList', 'buildConfigurations': configs, 'defaultConfigurationIsVisible': '0',
            'defaultConfigurationName': 'Release'})

    app_target_id = oid('target', APP)
    test_target_id = oid('target', TESTS)
    project_id = oid('project', APP)

    app_target = add(app_target_id, APP, {
        'isa': 'PBXNativeTarget',
        'buildConfigurationList': config_list(APP, f'PBXNativeTarget "{APP}"', app_settings, app_settings),
        'buildPhases': [
            phase('PBXSourcesBuildPhase', 'Sources', APP, build_files(app_sources, 'Sources')),
            phase('PBXFrameworksBuildPhase', 'Frameworks', APP, []),
            phase('PBXResourcesBuildPhase', 'Resources', APP, build_files(APP_RESOURCES, 'Resources')),
        ],
        'buildRules': [], 'dependencies': [], 'name': APP, 'productName': APP,
        'productReference': products[APP], 'productType': 'com.apple.product-type.application',
    })
    proxy = add(oid('proxy', TESTS, APP), 'PBXContainerItemProxy', {
        'isa': 'PBXContainerItemProxy', 'containerPortal': Ref(project_id, 'Project object'), 'proxyType': '1',
        'remoteGlobalIDString': app_target_id, 'remoteInfo': APP})
    dependency = add(oid('dependency', TESTS, APP), 'PBXTargetDependency', {
        'isa': 'PBXTargetDependency', 'target': app_target, 'targetProxy': proxy})
    test_target = add(test_target_id, TESTS, {
        'isa': 'PBXNativeTarget',
        'buildConfigurationList': config_list(TESTS, f'PBXNativeTarget "{TESTS}"', test_settings, test_settings),
        'buildPhases': [
            phase('PBXSourcesBuildPhase', 'Sources', TESTS, build_files(test_sources, 'Sources')),
            phase('PBXFrameworksBuildPhase', 'Frameworks', TESTS, []),
            phase('PBXResourcesBuildPhase', 'Resources', TESTS, build_files(TEST_RESOURCES, 'Resources')),
        ],
        'buildRules': [], 'dependencies': [dependency], 'name': TESTS, 'productName': TESTS,
        'productReference': products[TESTS], 'productType': 'com.apple.product-type.bundle.unit-test',
    })
    add(project_id, 'Project object', {
        'isa': 'PBXProject',
        'attributes': {
            'BuildIndependentTargetsInParallel': '1',
            'LastSwiftUpdateCheck': '2610',
            'LastUpgradeCheck': '2610',
            'TargetAttributes': {
                app_target_id: {'CreatedOnToolsVersion': '26.1',
                                'SystemCapabilities': {'com.apple.HealthKit': {'enabled': '1'}}},
                test_target_id: {'CreatedOnToolsVersion': '26.1', 'TestTargetID': app_target_id},
            },
        },
        'buildConfigurationList': config_list('project', f'PBXProject "{APP}"', project_debug, project_release),
        'compatibilityVersion': 'Xcode 14.0',
        'developmentRegion': 'ru',
        'hasScannedForEncodings': '0',
        'knownRegions': ['ru', 'en', 'Base'],
        'mainGroup': main_group,
        'productRefGroup': products_group,
        'projectDirPath': '',
        'projectRoot': '',
        'targets': [app_target, test_target],
    })

    sections = {}
    for identifier, (comment, body) in objects.items():
        sections.setdefault(body['isa'], []).append((identifier, comment, body))
    out = ['// !$*UTF8*$!', '{', '\tarchiveVersion = 1;', '\tclasses = {', '\t};', '\tobjectVersion = 56;', '\tobjects = {']
    for isa in sorted(sections):
        out.append('')
        out.append(f'/* Begin {isa} section */')
        for identifier, comment, body in sorted(sections[isa]):
            if isa in ('PBXBuildFile', 'PBXFileReference'):
                fields = ' '.join(f'{q(k)} = {render(v, 0)};' for k, v in body.items())
                out.append(f'\t\t{identifier} /* {comment} */ = {{{fields} }};')
            else:
                out.append(f'\t\t{identifier} /* {comment} */ = {render(body, 2)};')
        out.append(f'/* End {isa} section */')
    out += ['\t};', f'\trootObject = {project_id} /* Project object */;', '}', '']
    PROJECT.mkdir(exist_ok=True)
    (PROJECT / 'project.pbxproj').write_text('\n'.join(out), encoding='utf-8')
    write_scheme(app_target_id, test_target_id)
    print(f'{PROJECT.relative_to(ROOT.parent)}: {len(app_sources)} app sources, {len(test_sources)} test sources')


def write_scheme(app_target_id, test_target_id):
    def reference(identifier, product, name):
        return (f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{identifier}" '
                f'BuildableName = "{product}" BlueprintName = "{name}" ReferencedContainer = "container:Bolus.xcodeproj">\n'
                '            </BuildableReference>')
    app_ref = reference(app_target_id, f'{APP}.app', APP)
    test_ref = reference(test_target_id, f'{TESTS}.xctest', TESTS)
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2610"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {app_ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "NO">
            {test_ref}
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {app_ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {app_ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
    path = PROJECT / 'xcshareddata' / 'xcschemes' / f'{APP}.xcscheme'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(scheme, encoding='utf-8')


if __name__ == '__main__':
    main()
