import Foundation
import VeepooBleSDK

/// Watch ↔ phone call features: contacts / SOS contacts, the SOS call count and the
/// watch's call Bluetooth (Classic / HFP). When SOS is pressed the watch itself dials
/// its SOS contacts through the phone, so call Bluetooth must be paired and connected.
///
/// iOS cannot pair Bluetooth Classic from an app: `connectBt` switches the watch's call
/// Bluetooth on and the user pairs it in Settings → Bluetooth.
final class PhoneFeatures {

    static let shared = PhoneFeatures()

    private static let opTimeout: TimeInterval = 15

    /// Receives every call-Bluetooth state change.
    var btListener: (([String: Any?]) -> Void)?

    private var btStatus: VPDeviceBTState?
    private var btOpen: Bool?
    private var audioOpen: Bool?
    private var opRunning = false

    private init() {}

    private var manager: HBandManager { HBandManager.shared }
    private var model: VPPeripheralModel? { manager.ble.peripheralModel }

    // MARK: - Call Bluetooth

    /// Hooks the SDK's BT state block (call once the peripheral manager exists).
    func attach() {
        manager.ble.peripheralManage?.vpbtConnectStateChangeBlock = { [weak self] state, btSwitchOpen, mediaSwitchOpen in
            DispatchQueue.main.async { self?.onBtState(state, btSwitchOpen, mediaSwitchOpen) }
        }
    }

    func reset() {
        btStatus = nil
        btOpen = nil
        audioOpen = nil
    }

    func btState() -> [String: Any?] {
        let status: String?
        switch btStatus {
        case .connected?: status = "connected"
        case .advertising?: status = "broadcasting"
        case .disConnect?: status = "disconnected"
        default: status = nil
        }
        return [
            "supported": btSupported,
            "known": btStatus != nil,
            "status": status,
            "btOpen": btOpen,
            "audioOpen": audioOpen,
            "hasPairInfo": nil,
            "link": nil,
            "manualPairing": true,
        ]
    }

    private var btSupported: Bool {
        btStatus != nil || (model?.deviceBTInfoData?.count ?? 0) > 0
    }

    func connectBt() -> String? {
        guard manager.isReady, let peripheral = manager.ble.peripheralManage else { return "NOT_READY" }
        guard btSupported else { return "UNSUPPORTED" }
        peripheral.veepooSDK_openDeviceBTSwitch()
        return nil
    }

    private func onBtState(_ state: VPDeviceBTState, _ switchOpen: Bool, _ mediaOpen: Bool) {
        let previous = btStatus
        btStatus = state
        btOpen = switchOpen
        audioOpen = mediaOpen
        if previous != state {
            manager.note(state == .connected
                ? "Call Bluetooth connected — SOS calls go through this phone"
                : "Call Bluetooth not connected — the watch cannot place SOS calls (pair it in Settings → Bluetooth)")
        }
        btListener?(btState())
    }

    // MARK: - Contacts

    func contactSupport() -> [String: Any] {
        let type = Int(model?.contactType ?? 0)
        return ["contacts": type > 0, "sosContacts": type == 2 || type == 3, "contactType": type]
    }

    private var sosSupported: Bool { (contactSupport()["sosContacts"] as? Bool) ?? false }

    func readContacts(_ done: @escaping ([[String: Any]]?, String?) -> Void) {
        contactOp(.read, VPDeviceContactsModel(), done)
    }

    func addContact(name: String, phone: String, sos: Bool, _ done: @escaping ([[String: Any]]?, String?) -> Void) {
        if sos && !sosSupported { return done(nil, "UNSUPPORTED") }
        let contact = VPDeviceContactsModel()
        contact.nickName = name
        contact.phoneNumber = phone
        contact.isSOS = sos
        contactOp(.add, contact, done)
    }

    func deleteContact(id: Int, _ done: @escaping ([[String: Any]]?, String?) -> Void) {
        withContact(id, done) { contact in self.contactOp(.delete, contact, done) }
    }

    func setSosContact(id: Int, enabled: Bool, _ done: @escaping ([[String: Any]]?, String?) -> Void) {
        guard sosSupported else { return done(nil, "UNSUPPORTED") }
        withContact(id, done) { contact in
            contact.isSOS = enabled
            self.contactOp(.edit, contact, done)
        }
    }

    private func withContact(_ id: Int, _ done: @escaping ([[String: Any]]?, String?) -> Void,
                             _ op: @escaping (VPDeviceContactsModel) -> Void) {
        rawContactOp(.read, VPDeviceContactsModel()) { list, error in
            if let error = error { return done(nil, error) }
            guard let contact = list?.first(where: { Int($0.contactID) == id }) else { return done(nil, "NOT_FOUND") }
            op(contact)
        }
    }

    /// Runs an op; non-read ops re-read the list so callers get ids assigned by the watch.
    private func contactOp(_ code: VPDeviceContactsOpCode, _ contact: VPDeviceContactsModel,
                           _ done: @escaping ([[String: Any]]?, String?) -> Void) {
        rawContactOp(code, contact) { list, error in
            if let error = error { return done(nil, error) }
            if code == .read { return done(list?.map(Self.toMap), nil) }
            self.rawContactOp(.read, VPDeviceContactsModel()) { list, error in
                done(list?.map(Self.toMap), error)
            }
        }
    }

    private func rawContactOp(_ code: VPDeviceContactsOpCode, _ contact: VPDeviceContactsModel,
                              _ done: @escaping ([VPDeviceContactsModel]?, String?) -> Void) {
        if let error = precheck() { return done(nil, error) }
        guard let peripheral = manager.ble.peripheralManage else { return done(nil, "NOT_READY") }
        let finish = begin(done)
        peripheral.veepooSDKSettingDeviceContacts(with: code, opModel: contact, toID: 0) { state, list in
            DispatchQueue.main.async {
                switch state {
                case .complete: finish(list, nil)
                case .failure: finish(nil, "FAILED")
                case .noFunction: finish(nil, "UNSUPPORTED")
                default: break // reading…
                }
            }
        }
    }

    // MARK: - SOS call times

    func readSosCallTimes(_ done: @escaping ([String: Any]?, String?) -> Void) {
        callTimesOp(.read, 0, done)
    }

    func setSosCallTimes(_ times: Int, _ done: @escaping ([String: Any]?, String?) -> Void) {
        callTimesOp(.setting, times, done)
    }

    private func callTimesOp(_ code: VPSOSOperationType, _ times: Int, _ done: @escaping ([String: Any]?, String?) -> Void) {
        guard sosSupported else { return done(nil, "UNSUPPORTED") }
        if let error = precheck() { return done(nil, error) }
        guard let peripheral = manager.ble.peripheralManage else { return done(nil, "NOT_READY") }
        let finish = begin(done)
        peripheral.veepooSDKSettingDeviceContactsSOSInfo(withOpCode: code, times: Int32(times)) { state, value, min, max in
            DispatchQueue.main.async {
                switch state {
                case .complete:
                    finish(code == .read
                        ? ["times": Int(value), "min": Int(min), "max": Int(max)]
                        : ["times": times], nil)
                case .failure: finish(nil, "FAILED")
                case .noFunction: finish(nil, "UNSUPPORTED")
                default: break
                }
            }
        }
    }

    // MARK: - Default SOS call count

    /// SOS call count given to a newly paired watch. The factory value is often 3, so
    /// one SOS press made the watch dial its contact three times.
    static let defaultSosCallTimes = 1
    private static let defaultMaxAttempts = 5
    private static let defaultRetryDelay: TimeInterval = 20
    private var defaultAttempts = 0

    /// Session ready: once per paired watch, set the SOS call count to
    /// [defaultSosCallTimes]. A count changed later (setSosCallTimes) is kept.
    func onSessionReady() {
        defaultAttempts = 0
        // Let the first sync / app commands start first.
        scheduleDefaultSosCallTimes(after: 5)
    }

    private func scheduleDefaultSosCallTimes(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.applyDefaultSosCallTimes()
        }
    }

    private func applyDefaultSosCallTimes() {
        guard manager.isReady, let watch = HBandSession.scanId, !watch.isEmpty,
              HBandSession.sosDefaultAppliedFor != watch else { return }
        defaultAttempts += 1
        readSosCallTimes { [weak self] value, error in
            guard let self = self else { return }
            guard let value = value else { return self.defaultFailed(watch, error) }
            let current = value["times"] as? Int ?? 0
            let low = max(value["min"] as? Int ?? 1, 1)
            let high = value["max"] as? Int ?? 0
            let wanted = high >= low ? min(max(Self.defaultSosCallTimes, low), high) : Self.defaultSosCallTimes
            if current == wanted {
                HBandSession.sosDefaultAppliedFor = watch
                NSLog("HBand SOS call times already %d", current)
                return
            }
            self.setSosCallTimes(wanted) { _, error in
                if let error = error { return self.defaultFailed(watch, error) }
                HBandSession.sosDefaultAppliedFor = watch
                NSLog("HBand SOS call times: %d -> %d (range %d-%d)", current, wanted, low, high)
                self.manager.note("SOS call count set to \(wanted) (was \(current))")
            }
        }
    }

    private func defaultFailed(_ watch: String, _ error: String?) {
        NSLog("HBand SOS call times default failed: %@ (attempt %d)", error ?? "nil", defaultAttempts)
        switch error {
        case "UNSUPPORTED":
            HBandSession.sosDefaultAppliedFor = watch // nothing to set on this watch
        case "BUSY", "TIMEOUT", "FAILED":
            if defaultAttempts < Self.defaultMaxAttempts { scheduleDefaultSosCallTimes(after: Self.defaultRetryDelay) }
        default:
            break // NOT_READY → tried again at the next session ready
        }
    }

    // MARK: - Plumbing

    private func precheck() -> String? {
        guard manager.isReady else { return "NOT_READY" }
        if manager.isBusy || opRunning { return "BUSY" }
        guard (contactSupport()["contacts"] as? Bool) == true else { return "UNSUPPORTED" }
        return nil
    }

    /// Marks an op as running and returns a one-shot completion guarded by a timeout.
    private func begin<T>(_ done: @escaping (T?, String?) -> Void) -> (T?, String?) -> Void {
        opRunning = true
        var called = false
        let finish: (T?, String?) -> Void = { [weak self] value, error in
            guard !called else { return }
            called = true
            self?.opRunning = false
            done(value, error)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.opTimeout) { finish(nil, "TIMEOUT") }
        return finish
    }

    private static func toMap(_ c: VPDeviceContactsModel) -> [String: Any] {
        ["id": Int(c.contactID), "name": c.nickName ?? "", "phone": c.phoneNumber ?? "", "sos": c.isSOS]
    }
}
