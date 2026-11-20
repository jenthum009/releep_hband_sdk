import AVFoundation
import CallKit
import Foundation

/// SOS detection for watches that send nothing over BLE when SOS is pressed and
/// only dial the SOS contact through call Bluetooth (seen on VANTA) — the iOS
/// counterpart of the Android CallSosDetector.
///
/// A new outgoing call while the phone's audio route is the saved watch's
/// Bluetooth HFP port is reported as SOS. No permission is needed; the phone
/// number is never available. On by default; switch off with
/// [HBandSession.callSosDetection].
///
/// Runs only while the guard is monitoring, and iOS only delivers call changes
/// while the app process runs (foreground, or background kept alive by the BLE
/// link). [checkOngoingCalls] catches a call still in progress when the app
/// wakes up again.
final class CallSosDetector: NSObject, CXCallObserverDelegate {

    static let shared = CallSosDetector()

    /// Called on the main thread when the watch placed a call.
    var onSos: (() -> Void)?

    private var observer: CXCallObserver?
    private var handled = Set<UUID>()

    /// The audio route switches to the watch a moment after the call starts.
    private static let routeChecks = 8
    private static let routeCheckInterval: TimeInterval = 0.5

    var isRunning: Bool { observer != nil }

    func start() {
        guard observer == nil, HBandSession.callSosDetection else { return }
        let o = CXCallObserver()
        o.setDelegate(self, queue: .main)
        observer = o
        // Calls already going on when the guard starts are not SOS.
        handled = Set(o.calls.map { $0.uuid })
        NSLog("[HBandCallSos] Call-based SOS detection started")
    }

    func stop() {
        observer?.setDelegate(nil, queue: nil)
        observer = nil
        handled.removeAll()
    }

    /// Re-checks the live calls (e.g. when the app becomes active again).
    func checkOngoingCalls() {
        observer?.calls.forEach { onCall($0) }
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        onCall(call)
    }

    private func onCall(_ call: CXCall) {
        if call.hasEnded {
            handled.remove(call.uuid)
            return
        }
        guard call.isOutgoing, !handled.contains(call.uuid) else { return }
        handled.insert(call.uuid)
        checkRoute(call.uuid, attempt: 1)
    }

    private func checkRoute(_ uuid: UUID, attempt: Int) {
        guard isRunning, observer?.calls.contains(where: { $0.uuid == uuid && !$0.hasEnded }) == true else { return }
        if isWatchCallRoute() {
            onSos?()
            return
        }
        guard attempt < CallSosDetector.routeChecks else {
            NSLog("[HBandCallSos] Outgoing call ignored: watch is not the call audio route")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CallSosDetector.routeCheckInterval) { [weak self] in
            self?.checkRoute(uuid, attempt: attempt + 1)
        }
    }

    private func isWatchCallRoute() -> Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        let name = HBandSession.name.trimmingCharacters(in: .whitespaces).lowercased()
        return (route.inputs + route.outputs).contains { port in
            port.portType == .bluetoothHFP &&
                (name.isEmpty || port.portName.lowercased().contains(name))
        }
    }
}
