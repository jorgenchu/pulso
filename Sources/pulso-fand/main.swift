import Darwin
import Foundation
import PulsoCore

// pulso-fand: the one root process in Pulso. It sets fan speeds on behalf of the app,
// which cannot write to the SMC itself. The rules it enforces live in FanSupervisor.
//
// usage: pulso-fand --uid <user allowed to connect> [--socket <path>]

var stopRequested: sig_atomic_t = 0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pulso-fand: \(message)\n".utf8))
    exit(1)
}

func value(after flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

guard getuid() == 0 else { fail("must run as root") }
guard let allowedUser = value(after: "--uid").flatMap({ uid_t($0) }) else { fail("missing --uid <user id>") }
let socketPath = value(after: "--socket") ?? FanControlClient.defaultSocketPath
guard let controller = SMCFanController() else { fail("this Mac has no fans to control") }
let sensors = SensorsSampler()
var supervisor = FanSupervisor()

/// Carries out the supervisor's decisions; returns the last failure, if any.
func perform(_ actions: [FanSupervisor.Action]) -> FanControlError? {
    var failure: FanControlError?
    for action in actions {
        do {
            try controller.perform(action)
        } catch {
            failure = (error as? FanControlError) ?? .writeFailed
        }
    }
    return failure
}

func serve(_ client: Int32, at now: TimeInterval) {
    // Only the user the helper was installed for may give orders.
    var user: uid_t = 0, group: gid_t = 0
    guard getpeereid(client, &user, &group) == 0, user == allowedUser || user == 0 else { return }

    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var failure: FanControlError?
    var applied: [FanSupervisor.Action] = []
    if let line = UnixSocket.readLine(from: client),
       let request = try? JSONDecoder().decode(FanRequest.self, from: line) {
        switch supervisor.handle(request, limits: controller.limits, now: now) {
        case let .success(actions):
            applied = actions
            failure = perform(actions)
            // A write that failed leaves the fans in an unknown state: give them all back
            // rather than report a speed that may not be held.
            if failure != nil, !actions.isEmpty {
                _ = supervisor.handle(FanRequest(command: .automatic), limits: controller.limits, now: now)
                _ = perform([.restoreAll])
                applied = [.restoreAll]
            }
        case let .failure(reason): failure = reason
        }
    } else {
        failure = .badRequest
    }
    let fans = supervisor.settled(controller.states(), after: applied)
    if let payload = try? JSONEncoder().encode(FanResponse(error: failure, fans: fans)) {
        _ = UnixSocket.write(payload + [0x0A], to: client)
    }
}

let listener = socket(AF_UNIX, SOCK_STREAM, 0)
guard listener >= 0, var address = UnixSocket.address(for: socketPath) else { fail("cannot create the socket") }
unlink(socketPath)
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
// The socket file is the access control: owned by the one allowed user, closed to everyone else.
guard bound == 0, chown(socketPath, allowedUser, 0) == 0, chmod(socketPath, 0o600) == 0, listen(listener, 4) == 0 else {
    fail("cannot listen on \(socketPath)")
}

// Being stopped (launchd, shutdown, uninstall) must hand the fans back, so catch the
// signals instead of dying with a speed still pinned.
var onSignal = sigaction()
onSignal.__sigaction_u.__sa_handler = { _ in stopRequested = 1 }
sigaction(SIGTERM, &onSignal, nil)
sigaction(SIGINT, &onSignal, nil)
signal(SIGPIPE, SIG_IGN)

while stopRequested == 0 {
    var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    // With every fan on automatic there is nothing to watch: sleep until someone connects.
    let ready = poll(&descriptor, 1, supervisor.needsWatching ? 2000 : -1)
    let now = ProcessInfo.processInfo.systemUptime
    if ready > 0, descriptor.revents & Int16(POLLIN) != 0 {
        let client = accept(listener, nil, nil)
        if client >= 0 {
            serve(client, at: now)
            close(client)
        }
    }
    if supervisor.needsWatching {
        _ = perform(supervisor.tick(now: now, cpuTemperature: sensors.sample().cpuTemperature))
    }
}

_ = perform([.restoreAll])
unlink(socketPath)
