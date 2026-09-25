import CoreAudio
import Foundation

private let systemObject = AudioObjectID(kAudioObjectSystemObject)

private func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

struct AudioDevice: Equatable {
    let id: AudioDeviceID

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool { lhs.id == rhs.id }

    var name: String {
        cfStringProperty(kAudioObjectPropertyName) ?? "Unknown device"
    }

    var uid: String? {
        cfStringProperty(kAudioDevicePropertyDeviceUID)
    }

    var modelUID: String? {
        cfStringProperty(kAudioDevicePropertyModelUID)
    }

    var transportType: UInt32 {
        var addr = propertyAddress(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    var isBluetooth: Bool {
        let transport = transportType
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }

    /// Current input data source (a four-char code), if the device has one.
    /// Intel Macs flip the built-in mic's source to 'emic' when a headset is
    /// plugged into the jack; Apple Silicon Macs publish a separate device.
    var inputDataSource: UInt32? {
        var addr = propertyAddress(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// A mic on wired earbuds or a wired headset: the headphone-jack mic, or
    /// a USB device with both input and output (USB-C earbuds, USB headsets).
    /// Some USB headsets, like USB-C EarPods, publish the mic and the
    /// headphones as two devices that share a model UID, so a sibling with
    /// output counts too. USB webcams have no output, so they don't count.
    var isWiredHeadsetMic: Bool {
        guard hasInput else { return false }
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            if inputDataSource == fourCC("emic") { return true }
            let lowered = name.lowercased()
            return lowered.contains("external") || lowered.contains("headset")
        case kAudioDeviceTransportTypeUSB:
            if outputChannelCount > 0 { return true }
            guard let model = modelUID else { return false }
            return AudioSystem.allDevices.contains {
                $0 != self && $0.transportType == kAudioDeviceTransportTypeUSB
                    && $0.modelUID == model && $0.outputChannelCount > 0
            }
        default:
            return false
        }
    }

    /// The Mac's own internal mic (not the headphone-jack mic).
    var isInternalMic: Bool { isBuiltIn && hasInput && !isWiredHeadsetMic }

    /// Loopback/aggregate devices (BlackHole, multi-output setups, …) — never
    /// suitable as an automatic mic fallback.
    var isVirtual: Bool {
        let transport = transportType
        return transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
    }

    var transportName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuity"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypePCI: return "pci"
        case kAudioDeviceTransportTypeFireWire: return "firewire"
        default: return "other"
        }
    }

    /// Rank used when picking a fallback input: lower is better. Physical,
    /// always-present devices first; virtual/aggregate devices last.
    var fallbackRank: Int {
        if isWiredHeadsetMic { return -1 }
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return 0
        case kAudioDeviceTransportTypeUSB: return 1
        case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire: return 2
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return 3
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual: return 5
        default: return 4
        }
    }

    var inputChannelCount: Int { channelCount(scope: kAudioDevicePropertyScopeInput) }
    var outputChannelCount: Int { channelCount(scope: kAudioDevicePropertyScopeOutput) }

    private func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var addr = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let listPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, listPtr) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(listPtr).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    var hasInput: Bool { inputChannelCount > 0 }

    private func cfStringProperty(_ selector: AudioObjectPropertySelector) -> String? {
        var addr = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

enum AudioSystem {
    static var allDevices: [AudioDevice] {
        var addr = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { AudioDevice(id: $0) }
    }

    static var inputDevices: [AudioDevice] {
        allDevices.filter { $0.hasInput }
    }

    static var defaultInput: AudioDevice? {
        var addr = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return AudioDevice(id: id)
    }

    static var defaultOutput: AudioDevice? {
        var addr = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return AudioDevice(id: id)
    }

    @discardableResult
    static func setDefaultInput(_ device: AudioDevice) -> Bool {
        var addr = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        var id = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(systemObject, &addr, 0, nil, size, &id) == noErr
    }

    static func addListener(
        _ selector: AudioObjectPropertySelector,
        queue: DispatchQueue,
        handler: @escaping () -> Void
    ) {
        var addr = propertyAddress(selector)
        AudioObjectAddPropertyListenerBlock(systemObject, &addr, queue) { _, _ in handler() }
    }
}

private func fourCC(_ code: String) -> UInt32 {
    code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

/// Device-name comparison tolerant of the curly apostrophe macOS puts in
/// device names ("Sanket’s AirPods Max") vs. the ASCII one users type.
func deviceNamesMatch(_ a: String, _ b: String) -> Bool {
    normalizedDeviceName(a).caseInsensitiveCompare(normalizedDeviceName(b)) == .orderedSame
}

private func normalizedDeviceName(_ name: String) -> String {
    name.replacingOccurrences(of: "\u{2019}", with: "'")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
