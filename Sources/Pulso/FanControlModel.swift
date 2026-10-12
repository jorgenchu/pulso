import Combine
import Foundation
import PulsoCore

/// Manual fan speeds, asked of the privileged helper. Without the helper installed the
/// fans can only be read.
@MainActor
final class FanControlModel: ObservableObject {
    /// The fans as the helper last reported them.
    @Published private(set) var fans: [FanState] = []
    @Published private(set) var isAvailable: Bool
    /// Why the last request was refused, if it was.
    @Published private(set) var error: FanControlError?

    private let client = FanControlClient()
    /// Requests block on a socket, so they queue up off the main thread.
    private let queue = DispatchQueue(label: "pulso.fans", qos: .userInitiated)
    private var contact: Timer?

    init() {
        isAvailable = client.isHelperAvailable
    }

    var isManual: Bool {
        fans.contains { $0.mode == .manual }
    }

    /// Asks the helper how the fans are.
    func refresh() {
        isAvailable = client.isHelperAvailable
        guard isAvailable else { return }
        send(FanRequest(command: .status))
    }

    /// Manual starts every fan at the speed it has now, so nothing changes until a slider moves.
    func setManual(_ manual: Bool) {
        guard isAvailable else { return }
        if manual {
            for fan in fans {
                send(FanRequest(command: .set, fan: fan.index, rpm: fan.limits.clamp(fan.rpm)))
            }
        } else {
            send(FanRequest(command: .automatic))
        }
    }

    func setTarget(_ rpm: Double, fan: Int) {
        send(FanRequest(command: .set, fan: fan, rpm: rpm))
    }

    /// Hands the fans back to the system and waits for the helper to say so. For quitting.
    func releaseAndWait() {
        guard isManual else { return }
        let client = self.client
        queue.sync { _ = try? client.send(FanRequest(command: .automatic)) }
    }

    private func send(_ request: FanRequest) {
        let client = self.client
        queue.async {
            let result = Result { try client.send(request) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.receive(result) }
            }
        }
    }

    private func receive(_ result: Result<FanResponse, Error>) {
        switch result {
        case let .success(response):
            error = response.error
            fans = response.fans
        case let .failure(failure):
            error = failure as? FanControlError ?? .helperUnavailable
            isAvailable = client.isHelperAvailable
        }
        keepInContact(isManual)
    }

    /// The helper hands the fans back if it stops hearing from the app, so while any
    /// fan is manual it is asked for its status well within that time.
    private func keepInContact(_ needed: Bool) {
        if needed, contact == nil {
            contact = Timer.scheduledTimer(withTimeInterval: FanSupervisor.contactTimeout / 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(FanRequest(command: .status)) }
            }
        } else if !needed {
            contact?.invalidate()
            contact = nil
        }
    }
}
