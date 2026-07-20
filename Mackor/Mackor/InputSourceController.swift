import Foundation
import Carbon.HIToolbox

struct InputSourceSwitchReceipt: Equatable {
    let fromInputSourceID: String
    let toInputSourceID: String
    let selectedSourceGeneration: UInt64
}

/// Carbon의 전역 입력 소스 상태를 작은 인터페이스 뒤에 둬서 선택 정책을
/// 실제 시스템 상태를 바꾸지 않는 단위 테스트로 검증할 수 있게 합니다.
protocol InputSourceSystem: AnyObject {
    var currentInputSourceID: String? { get }
    var currentASCIICapableInputSourceID: String? { get }

    func refreshSelectableInputSources()
    func canSelectInputSource(withID sourceID: String) -> Bool
    @discardableResult
    func selectInputSource(withID sourceID: String) -> Bool
}

final class CarbonInputSourceSystem: InputSourceSystem {
    private var selectableSourcesByID: [String: TISInputSource] = [:]

    init() {
        refreshSelectableInputSources()
    }

    var currentInputSourceID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return Self.inputSourceID(of: source)
    }

    var currentASCIICapableInputSourceID: String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardInputSource()?
            .takeRetainedValue() else {
            return nil
        }
        return Self.inputSourceID(of: source)
    }

    func refreshSelectableInputSources() {
        guard let sources = TISCreateInputSourceList(nil, false)?
            .takeRetainedValue() as? [TISInputSource] else {
            selectableSourcesByID = [:]
            return
        }

        var refreshedSources: [String: TISInputSource] = [:]
        for source in sources {
            guard Self.booleanProperty(kTISPropertyInputSourceIsEnabled, of: source),
                  Self.booleanProperty(kTISPropertyInputSourceIsSelectCapable, of: source),
                  let sourceID = Self.inputSourceID(of: source) else {
                continue
            }
            refreshedSources[sourceID] = source
        }
        selectableSourcesByID = refreshedSources
    }

    func canSelectInputSource(withID sourceID: String) -> Bool {
        selectableSource(withID: sourceID) != nil
    }

    @discardableResult
    func selectInputSource(withID sourceID: String) -> Bool {
        guard let source = selectableSource(withID: sourceID),
              TISSelectInputSource(source) == noErr,
              let selectedID = currentInputSourceID else {
            return false
        }
        return selectedID.caseInsensitiveCompare(sourceID) == .orderedSame
    }

    private func selectableSource(withID sourceID: String) -> TISInputSource? {
        selectableSourcesByID.first { storedID, _ in
            storedID.caseInsensitiveCompare(sourceID) == .orderedSame
        }?.value
    }

    private static func inputSourceID(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceID
        ) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func booleanProperty(
        _ property: CFString,
        of source: TISInputSource
    ) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, property) else {
            return false
        }
        let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        return (value as? NSNumber)?.boolValue ?? false
    }
}

/// 교정 방향을 실제 macOS 입력 소스로 해석합니다. 탐색 결과는 adapter가
/// 미리 캐시하므로 이벤트 탭에서는 TISSelectInputSource 한 번만 실행합니다.
final class InputSourceController {
    static let koreanTwoSetInputSourceID = "com.apple.inputmethod.Korean.2SetKorean"
    static let supportedLatinInputSourceIDs = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.US",
    ]

    private let system: InputSourceSystem
    private var lastSupportedLatinInputSourceID: String?
    private var lastObservedInputSourceID: String?
    private var inputSourceChangeGeneration: UInt64 = 0

    init(system: InputSourceSystem = CarbonInputSourceSystem()) {
        self.system = system
        noteCurrentInputSource(system.currentInputSourceID)
    }

    var currentInputSourceID: String? {
        system.currentInputSourceID
    }

    func refreshSelectableInputSources() {
        system.refreshSelectableInputSources()
        noteCurrentInputSource(system.currentInputSourceID)
    }

    func noteCurrentInputSource(_ sourceID: String?) {
        guard let sourceID else { return }

        if lastObservedInputSourceID?.caseInsensitiveCompare(sourceID) != .orderedSame {
            inputSourceChangeGeneration &+= 1
            lastObservedInputSourceID = sourceID
        }

        if Self.supportedLatinInputSourceIDs.contains(where: {
            $0.caseInsensitiveCompare(sourceID) == .orderedSame
        }) {
            lastSupportedLatinInputSourceID = sourceID
        }
    }

    func switchInputSource(for direction: CorrectionDirection) -> InputSourceSwitchReceipt? {
        guard let fromID = system.currentInputSourceID else { return nil }
        noteCurrentInputSource(fromID)

        let targetID: String?
        switch direction {
        case .latinToKorean:
            targetID = system.canSelectInputSource(withID: Self.koreanTwoSetInputSourceID)
                ? Self.koreanTwoSetInputSourceID
                : nil

        case .koreanToLatin:
            targetID = preferredLatinInputSourceID()
        }

        guard let targetID,
              fromID.caseInsensitiveCompare(targetID) != .orderedSame,
              system.selectInputSource(withID: targetID),
              let selectedID = system.currentInputSourceID,
              selectedID.caseInsensitiveCompare(targetID) == .orderedSame else {
            return nil
        }

        noteCurrentInputSource(selectedID)
        return InputSourceSwitchReceipt(
            fromInputSourceID: fromID,
            toInputSourceID: selectedID,
            selectedSourceGeneration: inputSourceChangeGeneration
        )
    }

    /// 사용자가 교정 뒤 입력 소스를 따로 바꿨다면 그 선택을 덮어쓰지 않습니다.
    @discardableResult
    func restoreInputSource(_ receipt: InputSourceSwitchReceipt) -> Bool {
        guard let currentID = system.currentInputSourceID else { return false }
        noteCurrentInputSource(currentID)

        guard inputSourceChangeGeneration == receipt.selectedSourceGeneration,
              currentID.caseInsensitiveCompare(receipt.toInputSourceID) == .orderedSame,
              system.canSelectInputSource(withID: receipt.fromInputSourceID),
              system.selectInputSource(withID: receipt.fromInputSourceID) else {
            return false
        }
        noteCurrentInputSource(receipt.fromInputSourceID)
        return true
    }

    private func preferredLatinInputSourceID() -> String? {
        var candidates: [String] = []
        if let lastSupportedLatinInputSourceID {
            candidates.append(lastSupportedLatinInputSourceID)
        }
        if let asciiID = system.currentASCIICapableInputSourceID {
            candidates.append(asciiID)
        }
        candidates.append(contentsOf: Self.supportedLatinInputSourceIDs)

        var seen: Set<String> = []
        return candidates.first { candidate in
            let normalized = candidate.lowercased()
            guard seen.insert(normalized).inserted,
                  Self.supportedLatinInputSourceIDs.contains(where: {
                      $0.caseInsensitiveCompare(candidate) == .orderedSame
                  }) else {
                return false
            }
            return system.canSelectInputSource(withID: candidate)
        }
    }
}
