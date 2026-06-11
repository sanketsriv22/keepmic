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

    var inputChannelCount: Int {
        var addr = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
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

/// Device-name comparison tolerant of the curly apostrophe macOS puts in
/// device names ("Sanket’s AirPods Max") vs. the ASCII one users type.
func deviceNamesMatch(_ a: String, _ b: String) -> Bool {
    normalizedDeviceName(a).caseInsensitiveCompare(normalizedDeviceName(b)) == .orderedSame
}

private func normalizedDeviceName(_ name: String) -> String {
    name.replacingOccurrences(of: "\u{2019}", with: "'")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
