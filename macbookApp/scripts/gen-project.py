#!/usr/bin/env python3
"""Generates macbookApp/SSH2VPNMac.xcodeproj/project.pbxproj from the iOS project.

The Mac project mirrors the iPhone one 1:1 (same phases, same VPNCore via the
local SPM package, same shared sources by reference) with these deltas:
  - macOS platform (SDK macosx, MACOSX_DEPLOYMENT_TARGET 13.0, no device family)
  - targets SSH2VPNMac (app) + PacketTunnelMac (SYSTEM extension, not appex)
  - bundle ids com.ssh2vpn.mac[.packet-tunnel]
  - shared sources resolve via group path ../Iphone/App (Iphone/ untouched)
  - Mac-local files live in Mac/ (SSH2VPNMacApp, view forks, AdsStub, plists)
  - no GoogleMobileAds (iOS-only SDK); SystemExtensions.framework linked
Re-run after pulling iOS project changes: ./scripts/gen-project.py
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
IOS_PBX = os.path.join(ROOT, "..", "Iphone", "SSH2VPN.xcodeproj", "project.pbxproj")
OUT_PBX = os.path.join(ROOT, "SSH2VPNMac.xcodeproj", "project.pbxproj")


def die(msg):
    print("gen-project: FATAL: " + msg, file=sys.stderr)
    sys.exit(1)


def sub_once(text, old, new):
    if old not in text:
        die("pattern not found: %r" % old[:90])
    return text.replace(old, new, 1)


def main():
    with io.open(IOS_PBX, encoding="utf-8") as f:
        t = f.read()

    # --- 0. sanity: template version drift is fine, anchors must exist
    for anchor in ["SSH2VPNApp.swift", "AdsManager.swift", "GoogleMobileAds",
                   "com.ssh2vpn.app.packet-tunnel", "IPHONEOS_DEPLOYMENT_TARGET"]:
        if anchor not in t:
            die("template anchor missing: " + anchor)

    # --- 1. file renames (longest first to avoid substring collisions)
    t = t.replace("com.ssh2vpn.app.packet-tunnel", "com.ssh2vpn.mac.packet-tunnel")
    t = t.replace("com.ssh2vpn.app", "com.ssh2vpn.mac")
    t = t.replace("SSH2VPNApp.swift", "SSH2VPNMacApp.swift")
    t = t.replace("SSH2VPNPacketTunnel.entitlements", "PacketTunnelMac.entitlements")
    t = t.replace("SSH2VPN.entitlements", "SSH2VPNMac.entitlements")
    t = t.replace("PacketTunnel.appex", "PacketTunnelMac.systemextension")
    t = t.replace("SSH2VPN.app", "SSH2VPNMac.app")

    # --- 2. drop GoogleMobileAds (iOS-only SDK)
    t = sub_once(t,
        "\t\tC50000010000000000000020 /* XCRemoteSwiftPackageReference \"swift-package-manager-google-mobile-ads\" */,\n",
        "")
    t = sub_once(t,
        "/* Begin XCRemoteSwiftPackageReference section */\n"
        "\t\tC50000010000000000000020 /* XCRemoteSwiftPackageReference \"swift-package-manager-google-mobile-ads\" */ = {\n"
        "\t\t\tisa = XCRemoteSwiftPackageReference;\n"
        "\t\t\trepositoryURL = \"https://github.com/googleads/swift-package-manager-google-mobile-ads.git\";\n"
        "\t\t\trequirement = {\n"
        "\t\t\t\tkind = exactVersion;\n"
        "\t\t\t\tversion = 13.3.0;\n"
        "\t\t\t};\n"
        "\t\t};\n"
        "/* End XCRemoteSwiftPackageReference section */\n\n",
        "")
    t = sub_once(t,
        "\t\tC10000010000000000000020 /* GoogleMobileAds */ = {\n"
        "\t\t\tisa = XCSwiftPackageProductDependency;\n"
        "\t\t\tpackage = C50000010000000000000020 /* XCRemoteSwiftPackageReference \"swift-package-manager-google-mobile-ads\" */;\n"
        "\t\t\tproductName = GoogleMobileAds;\n"
        "\t\t};\n",
        "")
    t = sub_once(t,
        "\t\tC30000010000000000000020 /* GoogleMobileAds in Frameworks */ = {isa = PBXBuildFile; productRef = C10000010000000000000020 /* GoogleMobileAds */; };\n",
        "")
    t = sub_once(t, "\t\t\t\tC30000010000000000000020 /* GoogleMobileAds in Frameworks */,\n", "")
    t = sub_once(t, "\t\t\t\tC10000010000000000000020 /* GoogleMobileAds */,\n", "")

    # --- 3. drop AdsManager.swift everywhere (Mac uses AdsStub.swift instead)
    t = sub_once(t,
        "\t\tA10000010000000000000051 /* AdsManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000010000000000000051 /* AdsManager.swift */; };\n",
        "")
    t = sub_once(t,
        "\t\tA20000010000000000000051 /* AdsManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AdsManager.swift; sourceTree = \"<group>\"; };\n",
        "")
    t = sub_once(t, "\t\t\t\tA20000010000000000000051 /* AdsManager.swift */,\n", "")
    t = sub_once(t, "\t\t\t\tA10000010000000000000051 /* AdsManager.swift in Sources */,\n", "")

    # --- 4. platform: iphoneos -> macosx
    t = t.replace('SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";', "SUPPORTED_PLATFORMS = macosx;")
    t = "\n".join(l for l in t.split("\n") if "TARGETED_DEVICE_FAMILY" not in l)
    t = t.replace("IPHONEOS_DEPLOYMENT_TARGET = 18.0;", "MACOSX_DEPLOYMENT_TARGET = 13.0;")
    t = sub_once(t, "\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n", "")
    t = sub_once(t, "\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n", "")

    # --- 5. local package lives one level up from the Mac project
    t = t.replace('XCLocalSwiftPackageReference "."', 'XCLocalSwiftPackageReference "../Iphone"')
    t = sub_once(t, "\t\t\trelativePath = .;\n", "\t\t\trelativePath = ../Iphone;\n")

    # --- 6. config file locations
    t = t.replace("CODE_SIGN_ENTITLEMENTS = App/SSH2VPNMac.entitlements;",
                  "CODE_SIGN_ENTITLEMENTS = Mac/SSH2VPNMac.entitlements;")
    t = t.replace("CODE_SIGN_ENTITLEMENTS = App/PacketTunnelMac.entitlements;",
                  "CODE_SIGN_ENTITLEMENTS = Mac/PacketTunnelMac.entitlements;\n"
                  "\t\t\t\tENABLE_APP_SANDBOX = YES;\n"
                  "\t\t\t\tMACH_O_TYPE = mh_execute;")
    t = t.replace("INFOPLIST_FILE = App/Info.plist;", "INFOPLIST_FILE = Mac/Info.plist;")
    t = t.replace('INFOPLIST_FILE = "App/PacketTunnel-Info.plist";',
                  'INFOPLIST_FILE = "Mac/PacketTunnel-Info.plist";')

    # --- 7. target/product renames
    t = t.replace("Build configuration list for PBXNativeTarget \"SSH2VPN\"",
                  "Build configuration list for PBXNativeTarget \"SSH2VPNMac\"")
    t = t.replace("Build configuration list for PBXNativeTarget \"PacketTunnel\"",
                  "Build configuration list for PBXNativeTarget \"PacketTunnelMac\"")
    t = sub_once(t, "/* SSH2VPN */ = {", "/* SSH2VPNMac */ = {")
    t = sub_once(t, "/* PacketTunnel */ = {", "/* PacketTunnelMac */ = {")
    t = t.replace("name = SSH2VPN;", "name = SSH2VPNMac;")
    t = t.replace("productName = SSH2VPN;", "productName = SSH2VPNMac;")
    t = t.replace("name = PacketTunnel;", "name = PacketTunnelMac;")
    t = t.replace("productName = PacketTunnel;", "productName = PacketTunnelMac;")
    t = t.replace("remoteInfo = PacketTunnel;", "remoteInfo = PacketTunnelMac;")
    t = t.replace("/* PacketTunnel */", "/* PacketTunnelMac */")
    t = t.replace("/* SSH2VPN */", "/* SSH2VPNMac */")
    t = t.replace('"SSH2VPN"', '"SSH2VPNMac"')

    # --- 8. extension becomes a SYSTEM extension (macOS 10.15+ requirement
    # for packet-tunnel providers; PlugIns-style appex no longer loads)
    n_app_ext = t.count('"com.apple.product-type.app-extension"')
    if n_app_ext != 1:
        die("expected exactly 1 app-extension productType, found %d" % n_app_ext)
    t = t.replace('"com.apple.product-type.app-extension"',
                  '"com.apple.product-type.system-extension"')
    t = t.replace('explicitFileType = "wrapper.app-extension"',
                  'explicitFileType = "wrapper.system-extension"')
    t = t.replace("/* Embed Foundation Extensions */", "/* Embed System Extensions */")
    t = t.replace('name = "Embed Foundation Extensions";', 'name = "Embed System Extensions";')
    # .systemextension must live in Contents/Library/SystemExtensions
    # (PlugIns-style appex won't load on macOS 10.15+), but Copy Files has no
    # SystemExtensions destination — so the whole Copy Files block becomes a
    # Run Script phase.
    t = sub_once(t, chr(10).join([
        '\t\tA60000010000000000000001 /* Embed System Extensions */ = {',
        '\t\t\tisa = PBXCopyFilesBuildPhase;',
        '\t\t\tbuildActionMask = 2147483647;',
        '\t\t\tdstPath = "";',
        '\t\t\tdstSubfolderSpec = 13;',
        '\t\t\tfiles = (',
        '\t\t\t\tA10000010000000000000005 /* PacketTunnelMac.systemextension in Embed Foundation Extensions */,',
        '\t\t\t);',
        '\t\t\tname = "Embed System Extensions";',
        '\t\t\trunOnlyForDeploymentPostprocessing = 0;',
        '\t\t};',
    ]) + chr(10), chr(10).join([
        '\t\tB60000010000000000000001 /* Embed System Extensions */ = {',
        '\t\t\tisa = PBXShellScriptBuildPhase;',
        '\t\t\tbuildActionMask = 2147483647;',
        '\t\t\tfiles = (',
        '\t\t\t);',
        '\t\t\tinputPaths = (',
        '\t\t\t);',
        '\t\t\tname = "Embed System Extensions";',
        '\t\t\toutputPaths = (',
        '\t\t\t);',
        '\t\t\trunOnlyForDeploymentPostprocessing = 0;',
        '\t\t\tshellPath = /bin/sh;',
        '\t\t\tshellScript = "SRC=\\"${TARGET_BUILD_DIR}/PacketTunnelMac.systemextension\\"\\nDST=\\"${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}/Contents/Library/SystemExtensions\\"\\nmkdir -p \\"$DST\\"\\nrm -rf \\"$DST/PacketTunnelMac.systemextension\\"\\ncp -R \\"$SRC\\" \\"$DST/\\"\\n";',
        '\t\t\tshowEnvVarsInLog = 0;',
        '\t\t};',
    ]) + chr(10))
    t = sub_once(t,
        '\t\t\t\tA60000010000000000000001 /* Embed System Extensions */,\n',
        '\t\t\t\tB60000010000000000000001 /* Embed System Extensions */,\n')
    t = sub_once(t,
        '\t\tA10000010000000000000005 /* PacketTunnelMac.systemextension in Embed Foundation Extensions */ = {isa = PBXBuildFile; fileRef = A20000010000000000000008 /* PacketTunnelMac.systemextension */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };\n',
        '')
    t = sub_once(t,
        "\t\tA70000010000000000000002 /* App */ = {",
        "\t\tA70000010000000000000002 /* Shared */ = {")
    t = sub_once(t,
        "\t\tA70000010000000000000003 /* App */ = {",
        "\t\tA70000010000000000000003 /* SharedTunnel */ = {")
    # group paths now point at the untouched iPhone tree
    n_path_app = t.count("\t\t\tpath = App;")
    if n_path_app != 2:
        die("expected 2 'path = App;' group paths, found %d" % n_path_app)
    t = t.replace("\t\t\tpath = App;", "\t\t\tpath = ../Iphone/App;")

    # move Mac-local refs out of the shared groups into the new Mac group
    moved_from_shared = [
        "A20000010000000000000001 /* SSH2VPNMacApp.swift */,\n",
        "A20000010000000000000003 /* RootView.swift */,\n",
        "A20000010000000000000041 /* DiagnosticsConsoleSidebarView.swift */,\n",
        "A20000010000000000000043 /* DocsView.swift */,\n",
        "A20000010000000000000046 /* AddServerChooserView.swift */,\n",
        "A20000010000000000000047 /* ImportCredentialsView.swift */,\n",
        "A20000010000000000000005 /* Info.plist */,\n",
        "A20000010000000000000009 /* SSH2VPNMac.entitlements */,\n",
    ]
    for line in moved_from_shared:
        t = sub_once(t, "\t\t\t\t" + line, "")
    moved_from_tunnel = [
        "A20000010000000000000006 /* PacketTunnel-Info.plist */,\n",
        "A20000010000000000000010 /* PacketTunnelMac.entitlements */,\n",
    ]
    for line in moved_from_tunnel:
        t = sub_once(t, "\t\t\t\t" + line, "")

    # new AdsStub file ref + build file
    t = sub_once(t,
        "/* End PBXBuildFile section */",
        "\t\tA100000100000000000000A0 /* AdsStub.swift in Sources */ = {isa = PBXBuildFile; fileRef = A200000100000000000000A0 /* AdsStub.swift */; };\n"
        "\t\tA100000100000000000000A1 /* SystemExtensionGate.swift in Sources */ = {isa = PBXBuildFile; fileRef = A200000100000000000000A1 /* SystemExtensionGate.swift */; };\n"
        "\t\tB10000010000000000000001 /* SystemExtensions.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = B30000010000000000000001 /* SystemExtensions.framework */; };\n"
        "\t\tA100000100000000000000B0 /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = A200000100000000000000B0 /* Assets.xcassets */; };\n"
        "/* End PBXBuildFile section */")
    t = sub_once(t,
        "/* End PBXFileReference section */",
        "\t\tA200000100000000000000A0 /* AdsStub.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AdsStub.swift; sourceTree = \"<group>\"; };\n"
        "\t\tA200000100000000000000A1 /* SystemExtensionGate.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SystemExtensionGate.swift; sourceTree = \"<group>\"; };\n"
        "\t\tB30000010000000000000001 /* SystemExtensions.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = SystemExtensions.framework; path = System/Library/Frameworks/SystemExtensions.framework; sourceTree = SDKROOT; };\n"
        "\t\tA200000100000000000000B0 /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; };\n"
        "/* End PBXFileReference section */")

    # new Mac group
    mac_group = (
        "\t\tA70000010000000000000008 /* Mac */ = {\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        "\t\t\t\tA20000010000000000000001 /* SSH2VPNMacApp.swift */,\n"
        "\t\t\t\tA200000100000000000000A0 /* AdsStub.swift */,\n"
        "\t\t\t\tA200000100000000000000A1 /* SystemExtensionGate.swift */,\n"
        "\t\t\t\tA200000100000000000000A2 /* SystemExtensionMain.swift */,\n"
        "\t\t\t\tA20000010000000000000003 /* RootView.swift */,\n"
        "\t\t\t\tA20000010000000000000041 /* DiagnosticsConsoleSidebarView.swift */,\n"
        "\t\t\t\tA20000010000000000000043 /* DocsView.swift */,\n"
        "\t\t\t\tA20000010000000000000046 /* AddServerChooserView.swift */,\n"
        "\t\t\t\tA20000010000000000000047 /* ImportCredentialsView.swift */,\n"
        "\t\t\t\tA20000010000000000000005 /* Info.plist */,\n"
        "\t\t\t\tA20000010000000000000006 /* PacketTunnel-Info.plist */,\n"
        "\t\t\t\tA20000010000000000000009 /* SSH2VPNMac.entitlements */,\n"
        "\t\t\t\tA20000010000000000000010 /* PacketTunnelMac.entitlements */,\n"
        "\t\t\t\tA200000100000000000000B0 /* Assets.xcassets */,\n"
        "\t\t\t);\n"
        "\t\t\tpath = Mac;\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n"
    )
    t = sub_once(t, "/* End PBXGroup section */", mac_group + "/* End PBXGroup section */")
    t = sub_once(t,
        "\t\t\t\tA70000010000000000000002 /* App */,\n",
        "\t\t\t\tA70000010000000000000002 /* Shared */,\n"
        "\t\t\t\tA70000010000000000000008 /* Mac */,\n")

    # SystemExtensionMain.swift (entry point) into the extension target
    t = sub_once(t,
        "/* End PBXBuildFile section */",
        "\t\tA100000100000000000000A2 /* SystemExtensionMain.swift in Sources */ = {isa = PBXBuildFile; fileRef = A200000100000000000000A2 /* SystemExtensionMain.swift */; };\n"
        "/* End PBXBuildFile section */")
    t = sub_once(t,
        "/* End PBXFileReference section */",
        "\t\tA200000100000000000000A2 /* SystemExtensionMain.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SystemExtensionMain.swift; sourceTree = \"<group>\"; };\n"
        "/* End PBXFileReference section */")
    t = sub_once(t,
        "\t\t\t\tA10000010000000000000017 /* PacketTunnelPacketLoop.swift in Sources */,\n",
        "\t\t\t\tA10000010000000000000017 /* PacketTunnelPacketLoop.swift in Sources */,\n"
        "\t\t\t\tA100000100000000000000A2 /* SystemExtensionMain.swift in Sources */,\n")

    # AdsStub + SystemExtensionGate into app Sources phase
    t = sub_once(t,
        "\t\t\t\tA10000010000000000000047 /* ImportCredentialsView.swift in Sources */,\n",
        "\t\t\t\tA10000010000000000000047 /* ImportCredentialsView.swift in Sources */,\n"
        "\t\t\t\tA100000100000000000000A0 /* AdsStub.swift in Sources */,\n"
        "\t\t\t\tA100000100000000000000A1 /* SystemExtensionGate.swift in Sources */,\n")

    # Assets.xcassets into app Resources phase
    t = sub_once(t,
        "\t\tA60000010000000000000007 /* Resources */ = {\n",
        "\t\tA60000010000000000000007 /* Resources */ = {\n"
        "\t\t\t\tA100000100000000000000B0 /* Assets.xcassets in Resources */,\n")

    # SystemExtensions.framework into app Frameworks phase
    t = sub_once(t,
        "\t\tA60000010000000000000002 /* Frameworks */ = {\n"
        "\t\t\tisa = PBXFrameworksBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        "\t\t\t\tC30000010000000000000003 /* VPNCore in Frameworks */,\n",
        "\t\tA60000010000000000000002 /* Frameworks */ = {\n"
        "\t\t\tisa = PBXFrameworksBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        "\t\t\t\tC30000010000000000000003 /* VPNCore in Frameworks */,\n"
        "\t\t\t\tB10000010000000000000001 /* SystemExtensions.framework in Frameworks */,\n")

    with io.open(OUT_PBX, "w", encoding="utf-8", newline="") as f:
        f.write(t)
    print("gen-project: wrote " + OUT_PBX)


if __name__ == "__main__":
    main()
