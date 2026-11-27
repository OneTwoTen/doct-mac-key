#!/usr/bin/env swift
//
// enable-input-source.swift — register, enable and select DoctKey as an input
// source, with diagnostics. Compile on the fly:
//
//   swiftc -O scripts/enable-input-source.swift -o /tmp/doctkey-enable-input-source
//   /tmp/doctkey-enable-input-source [--path "/Library/Input Methods/DoctKey.app"]
//
// or run it with the Swift interpreter:
//
//   swift scripts/enable-input-source.swift --path "/Library/Input Methods/DoctKey.app"
//
// On macOS 26+ the input method lives in /Library/Input Methods (system-wide); on older macOS
// in ~/Library/Input Methods. Without --path both locations are tried.
//
// Always exits 0 unless the app bundle is missing.
import Carbon
import Foundation

let sourceID = "com.doct.doctkey"
let modeID = "com.doct.doctkey.mode"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func argumentValue(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    let value = arguments[index + 1]
    return value.hasPrefix("-") ? nil : value
}

func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// Reads a TIS property (CFType) from an input source without leaking it.
func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
}

func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    property(source, key) as? String
}

func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool? {
    property(source, key) as? Bool
}

func inputSourceList(properties: CFDictionary?) -> [TISInputSource] {
    guard let unmanaged = TISCreateInputSourceList(properties, true) else { return [] }
    let array = unmanaged.takeRetainedValue() as NSArray
    return array as? [TISInputSource] ?? []
}

// MARK: - Locate the installed bundle

let arguments = CommandLine.arguments
var candidates: [String] = []
if let customPath = argumentValue("--path", in: arguments) {
    candidates = [expandPath(customPath)]
} else {
    candidates = [
        "/Library/Input Methods/DoctKey.app",          // macOS 26+
        expandPath("~/Library/Input Methods/DoctKey.app") // macOS <= 25
    ]
}

var bundlePathFound: String?
for candidate in candidates {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
       isDirectory.boolValue {
        bundlePathFound = candidate
        break
    }
}

guard let bundlePath = bundlePathFound else {
    fail("DoctKey.app not found. Looked in:\n"
         + candidates.map { "  - " + $0 }.joined(separator: "\n")
         + "\nRun scripts/install.sh first, or pass --path <path-to-DoctKey.app>.")
}

print("DoctKey.app: \(bundlePath)")

// MARK: - 1. Register the bundle with the Text Input Source system

let registerStatus = TISRegisterInputSource(URL(fileURLWithPath: bundlePath) as CFURL)
if registerStatus == noErr {
    print("TISRegisterInputSource: noErr (0)")
} else {
    print("TISRegisterInputSource: \(registerStatus) (error)")
}

// MARK: - 2. Find our sources and print the diagnostic state

let wantedIdentifiers: Set<String> = [sourceID, modeID]
let allSources = inputSourceList(properties: nil)
var sources = allSources.filter { source in
    if let identifier = stringProperty(source, kTISPropertyInputSourceID),
       wantedIdentifiers.contains(identifier) {
        return true
    }
    return false
}

// Fallback: match by bundle id (some TIS builds only expose that).
if sources.isEmpty {
    sources = allSources.filter { source in
        stringProperty(source, kTISPropertyBundleID) == sourceID
    }
}

print("total TIS input sources: \(allSources.count)")
print("matching DoctKey sources: \(sources.count)")
for source in sources {
    let identifier = stringProperty(source, kTISPropertyInputSourceID) ?? "(no id)"
    let enabled = boolProperty(source, kTISPropertyInputSourceIsEnabled) ?? false
    let selected = boolProperty(source, kTISPropertyInputSourceIsSelected) ?? false
    print("  - \(identifier) enabled=\(enabled ? 1 : 0) selected=\(selected ? 1 : 0)")
}

guard let source = sources.first else {
    print("")
    print("Could not find input source \"\(sourceID)\" in the system list.")
    print("Try this:")
    print("  1. Make sure the app is installed: scripts/install.sh")
    print("  2. Log out and back in (or reboot) so macOS rescans the input-source locations.")
    print("  3. Run this script again, or add the source manually in")
    print("     System Settings -> Keyboard -> Text Input -> Input Sources.")
    // The bundle exists: not a failure per the spec.
    exit(0)
}

// MARK: - 3. Enable (and select) the source

let enableStatus = TISEnableInputSource(source)
if enableStatus == noErr {
    print("TISEnableInputSource: noErr (0)")
} else {
    print("TISEnableInputSource: \(enableStatus) (error)")
}

let selectStatus = TISSelectInputSource(source)
if selectStatus == noErr {
    print("TISSelectInputSource: noErr (0)")
} else {
    print("TISSelectInputSource: \(selectStatus) (note: selecting may require an active input context)")
}

if enableStatus == noErr {
    print("")
    print("DoctKey is enabled as an input source (menu bar shows VI / EN when selected).")
} else {
    print("")
    print("DoctKey is registered but could not be enabled automatically.")
    print("System Settings -> Keyboard -> Text Input -> Input Sources -> Edit... -> add DoctKey.")
}

exit(0)
