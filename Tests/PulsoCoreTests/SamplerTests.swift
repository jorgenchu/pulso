import XCTest
@testable import PulsoCore

final class CPUTests: XCTestCase {
    func testLoadIsTheShareOfTicksSinceThePreviousReading() {
        let before = CoreTicks(user: 100, system: 50, idle: 850, nice: 0)
        let after = CoreTicks(user: 130, system: 60, idle: 910, nice: 0)
        let load = after.load(since: before)
        XCTAssertEqual(load.user, 0.3, accuracy: 1e-9)
        XCTAssertEqual(load.system, 0.1, accuracy: 1e-9)
        XCTAssertEqual(load.idle, 0.6, accuracy: 1e-9)
    }

    func testNiceTicksCountAsUserTime() {
        let before = CoreTicks(user: 0, system: 0, idle: 0, nice: 0)
        let after = CoreTicks(user: 10, system: 0, idle: 80, nice: 10)
        XCTAssertEqual(after.load(since: before).user, 0.2, accuracy: 1e-9)
    }

    func testLoadSurvivesCounterWraparound() {
        let before = CoreTicks(user: .max - 9, system: 0, idle: .max - 29, nice: 0)
        let after = CoreTicks(user: 10, system: 0, idle: 50, nice: 0)
        // user advanced 20 ticks and idle 80 across the wrap.
        XCTAssertEqual(after.load(since: before).user, 0.2, accuracy: 1e-9)
    }

    func testNoElapsedTicksReadsAsIdle() {
        let ticks = CoreTicks(user: 5, system: 5, idle: 5, nice: 5)
        let load = ticks.load(since: ticks)
        XCTAssertEqual(load.user, 0)
        XCTAssertEqual(load.idle, 1)
    }

    func testSnapshotAveragesCoresAndSplitsClusters() {
        let topology = CPUTopology(logicalCores: 4, performanceCores: 2, efficiencyCores: 2)
        let zero = CoreTicks(user: 0, system: 0, idle: 0, nice: 0)
        let current = [
            CoreTicks(user: 100, system: 0, idle: 0, nice: 0),   // efficiency, 100%
            CoreTicks(user: 0, system: 50, idle: 50, nice: 0),   // efficiency, 50%
            CoreTicks(user: 0, system: 0, idle: 100, nice: 0),   // performance, 0%
            CoreTicks(user: 20, system: 0, idle: 80, nice: 0),   // performance, 20%
        ]
        let snapshot = CPUSampler.snapshot(from: Array(repeating: zero, count: 4), to: current,
                                           topology: topology, loadAverage: [])
        XCTAssertEqual(snapshot.cores.map(\.kind), [.efficiency, .efficiency, .performance, .performance])
        XCTAssertEqual(snapshot.user, 0.3, accuracy: 1e-9)
        XCTAssertEqual(snapshot.system, 0.125, accuracy: 1e-9)
        XCTAssertEqual(snapshot.usage, 0.425, accuracy: 1e-9)
        XCTAssertEqual(snapshot.efficiencyUsage ?? -1, 0.75, accuracy: 1e-9)
        XCTAssertEqual(snapshot.performanceUsage ?? -1, 0.1, accuracy: 1e-9)
    }

    func testMachineWithoutEfficiencyCoresReportsNoEfficiencyUsage() {
        let topology = CPUTopology(logicalCores: 2, performanceCores: 2, efficiencyCores: 0)
        let ticks = [CoreTicks(user: 1, system: 1, idle: 2, nice: 0), CoreTicks(user: 1, system: 1, idle: 2, nice: 0)]
        let snapshot = CPUSampler.snapshot(from: [], to: ticks, topology: topology, loadAverage: [])
        XCTAssertNil(snapshot.efficiencyUsage)
    }

    func testLiveSampleIsWithinBounds() {
        let sampler = CPUSampler()
        Thread.sleep(forTimeInterval: 0.2)
        let snapshot = sampler.sample()
        XCTAssertEqual(snapshot.cores.count, CPUTopology.current.logicalCores)
        XCTAssertTrue((0...1).contains(snapshot.usage))
        XCTAssertEqual(snapshot.user + snapshot.system + snapshot.idle, 1, accuracy: 1e-6)
    }
}

final class MemoryTests: XCTestCase {
    func testBreakdownMatchesActivityMonitorAccounting() {
        let page: UInt64 = 16_384
        let pages = MemoryPages(internal: 500, purgeable: 100, wired: 200, compressor: 50, external: 150)
        let snapshot = MemorySampler.snapshot(pages: pages, pageSize: page, total: 1000 * page,
                                              swapUsed: 7, swapTotal: 9, pressure: .normal)
        XCTAssertEqual(snapshot.app, 400 * page)
        XCTAssertEqual(snapshot.wired, 200 * page)
        XCTAssertEqual(snapshot.compressed, 50 * page)
        XCTAssertEqual(snapshot.used, 650 * page)
        XCTAssertEqual(snapshot.cached, 250 * page)
        XCTAssertEqual(snapshot.free, 100 * page)
        XCTAssertEqual(snapshot.usedFraction, 0.65, accuracy: 1e-9)
    }

    func testCountersThatOvershootTotalNeverUnderflow() {
        let pages = MemoryPages(internal: 900, purgeable: 0, wired: 300, compressor: 0, external: 500)
        let snapshot = MemorySampler.snapshot(pages: pages, pageSize: 1, total: 1000,
                                              swapUsed: 0, swapTotal: 0, pressure: .normal)
        XCTAssertEqual(snapshot.used, 1000)
        XCTAssertEqual(snapshot.cached, 0)
        XCTAssertEqual(snapshot.free, 0)
    }

    func testLiveSampleAddsUp() throws {
        let snapshot = try XCTUnwrap(MemorySampler().sample())
        XCTAssertEqual(snapshot.total, ProcessInfo.processInfo.physicalMemory)
        XCTAssertEqual(snapshot.used + snapshot.cached + snapshot.free, snapshot.total)
        XCTAssertGreaterThan(snapshot.used, 0)
    }
}

final class DiskTests: XCTestCase {
    func testRateIsBytesOverElapsedTime() {
        let activity = DiskSampler.activity(from: DiskCounters(read: 1000, written: 5000),
                                            to: DiskCounters(read: 3000, written: 5500), elapsed: 2)
        XCTAssertEqual(activity.readRate, 1000)
        XCTAssertEqual(activity.writeRate, 250)
        XCTAssertEqual(activity.totalRead, 3000)
    }

    func testEjectedDriveDoesNotProduceANegativeRate() {
        let activity = DiskSampler.activity(from: DiskCounters(read: 9000, written: 9000),
                                            to: DiskCounters(read: 100, written: 9500), elapsed: 1)
        XCTAssertEqual(activity.readRate, 0)
        XCTAssertEqual(activity.writeRate, 500)
    }

    func testFirstSampleHasNoRate() {
        let activity = DiskSampler.activity(from: nil, to: DiskCounters(read: 10, written: 10), elapsed: 0)
        XCTAssertEqual(activity.readRate, 0)
        XCTAssertEqual(activity.writeRate, 0)
    }

    func testDiskImagesAreNotCountedAsPhysicalDrives() {
        XCTAssertFalse(DiskSampler.isPhysical(protocolCharacteristics: ["Physical Interconnect": "Virtual Interface"]))
        XCTAssertTrue(DiskSampler.isPhysical(protocolCharacteristics: ["Physical Interconnect": "Apple Fabric"]))
        XCTAssertTrue(DiskSampler.isPhysical(protocolCharacteristics: ["Physical Interconnect": "USB"]))
        XCTAssertTrue(DiskSampler.isPhysical(protocolCharacteristics: nil), "an undescribed drive still counts")
    }

    func testRootVolumeIsListed() throws {
        let root = try XCTUnwrap(DiskSampler().volumes().first { $0.isRoot })
        XCTAssertGreaterThan(root.total, 0)
        XCTAssertEqual(root.used + root.available, root.total)
    }

    func testPurgeableSpaceIsWhatFinderAddsToTheFreeBlocks() {
        XCTAssertEqual(DiskSampler.purgeableSpace(importantUsage: 9_300, freeBlocks: 9_000), 300)
        XCTAssertEqual(DiskSampler.purgeableSpace(importantUsage: 0, freeBlocks: 9_000), 0, "unsupported file system")
        XCTAssertEqual(DiskSampler.purgeableSpace(importantUsage: 8_000, freeBlocks: 9_000), 0)
    }

    func testAvailableSpaceStaysStableBetweenPurgeableRefreshes() throws {
        let sampler = DiskSampler()
        let first = try XCTUnwrap(sampler.volumes().first { $0.isRoot })
        let second = try XCTUnwrap(sampler.volumes().first { $0.isRoot })
        // The second call reuses the cached purgeable figure, so both must agree to within
        // whatever was written to disk in between.
        let drift = abs(Int64(first.available) - Int64(second.available))
        XCTAssertLessThan(drift, 2_000_000_000)
    }
}

final class NetworkTests: XCTestCase {
    func testDeltaIsTheDifferenceBetweenReadings() {
        let delta = InterfaceCounters(received: 1500, sent: 700).delta(since: InterfaceCounters(received: 1000, sent: 100))
        XCTAssertEqual(delta.received, 500)
        XCTAssertEqual(delta.sent, 600)
    }

    func testResetInterfaceCountsAsZero() {
        let delta = InterfaceCounters(received: 10, sent: 900).delta(since: InterfaceCounters(received: 1000, sent: 100))
        XCTAssertEqual(delta.received, 0)
        XCTAssertEqual(delta.sent, 800)
    }

    func testOnlyHardwarePortsCountTowardTheTotal() {
        var metadata = InterfaceMetadata()
        metadata.displayNames = ["en0": "Wi-Fi"]
        XCTAssertTrue(NetworkSampler.countsTowardTotal("en0", metadata: metadata))
        XCTAssertFalse(NetworkSampler.countsTowardTotal("utun3", metadata: metadata))
        XCTAssertFalse(NetworkSampler.countsTowardTotal("lo0", metadata: metadata))
    }

    func testFallsBackToEthernetNamesWithoutSystemConfiguration() {
        XCTAssertTrue(NetworkSampler.countsTowardTotal("en1", metadata: InterfaceMetadata()))
        XCTAssertFalse(NetworkSampler.countsTowardTotal("utun0", metadata: InterfaceMetadata()))
    }

    func testLoopbackIsAlwaysPresentInTheRawCounters() {
        XCTAssertNotNil(NetworkSampler.readCounters()["lo0"])
    }

    func testInterfaceNamesAreWellFormed() {
        let names = NetworkSampler.readCounters().keys
        XCTAssertFalse(names.isEmpty)
        for name in names {
            XCTAssertNotNil(name.range(of: #"^[a-z]+[0-9]+$"#, options: .regularExpression), "odd interface name '\(name)'")
        }
    }

    func testChangeObserverReportsTheInitialStateOnce() {
        let observer = NetworkChangeObserver()
        XCTAssertTrue(observer.consumeChange(), "the first read must always happen")
        XCTAssertFalse(observer.consumeChange(), "no change since, so nothing to re-read")
    }

    func testLiveSampleFindsThePrimaryInterface() throws {
        let snapshot = NetworkSampler().sample()
        try XCTSkipIf(snapshot.primaryInterface == nil, "machine is offline")
        let primary = try XCTUnwrap(snapshot.primary)
        XCTAssertFalse(primary.addresses.isEmpty)
        XCTAssertNotEqual(primary.displayName, "")
    }
}

final class NetworkProcessTests: XCTestCase {
    func testParsesANettopRow() {
        XCTAssertEqual(NetworkProcessMonitor.parse(line: "cloudd.1004,100693,30903,"),
                       TrafficSample(name: "cloudd", pid: 1004, received: 100_693, sent: 30_903))
    }

    func testNamesWithDotsAndCommasKeepTheirPid() {
        XCTAssertEqual(NetworkProcessMonitor.parse(line: "com.apple.WebKi.92996,25825,1438,")?.name, "com.apple.WebKi")
        XCTAssertEqual(NetworkProcessMonitor.parse(line: "com.apple.WebKi.92996,25825,1438,")?.pid, 92_996)
        XCTAssertEqual(NetworkProcessMonitor.parse(line: "Odd, Inc.77,5,6,"),
                       TrafficSample(name: "Odd, Inc", pid: 77, received: 5, sent: 6))
    }

    func testHeaderAndGarbageAreNotRows() {
        XCTAssertTrue(NetworkProcessMonitor.isHeader(",bytes_in,bytes_out,"))
        XCTAssertFalse(NetworkProcessMonitor.isHeader("cloudd.1004,1,2,"))
        XCTAssertNil(NetworkProcessMonitor.parse(line: ",bytes_in,bytes_out,"))
        XCTAssertNil(NetworkProcessMonitor.parse(line: "nopid,1,2,"))
        XCTAssertNil(NetworkProcessMonitor.parse(line: ""))
    }

    private let samples = [
        TrafficSample(name: "Browser Helper", pid: 1, received: 3000, sent: 300),
        TrafficSample(name: "Browser Helper", pid: 2, received: 1000, sent: 100),
        TrafficSample(name: "cloudd", pid: 3, received: 600, sent: 1800),
        TrafficSample(name: "idle", pid: 4, received: 0, sent: 0),
        TrafficSample(name: "mDNSResponder", pid: 5, received: 20, sent: 10),
        TrafficSample(name: "ntpd", pid: 6, received: 6, sent: 4),
    ]

    func testRatesAreBytesOverElapsedTimeAndSameNamesMerge() {
        let snapshot = NetworkProcessMonitor.snapshot(from: samples, elapsed: 2, limit: 5) { $0.name }
        XCTAssertEqual(snapshot.top.map(\.name), ["Browser Helper", "cloudd", "mDNSResponder", "ntpd"])
        XCTAssertEqual(snapshot.top[0].processCount, 2)
        XCTAssertEqual(snapshot.top[0].downloadRate, 2000)
        XCTAssertEqual(snapshot.top[0].uploadRate, 200)
        XCTAssertEqual(snapshot.top[1].uploadRate, 900)
    }

    func testProcessesWithoutTrafficAreLeftOut() {
        let snapshot = NetworkProcessMonitor.snapshot(from: samples, elapsed: 2, limit: 5) { $0.name }
        XCTAssertFalse(snapshot.top.contains { $0.name == "idle" })
        XCTAssertEqual(snapshot.otherCount, 0)
    }

    func testWhatDoesNotFitTheListIsSummed() {
        let snapshot = NetworkProcessMonitor.snapshot(from: samples, elapsed: 2, limit: 2) { $0.name }
        XCTAssertEqual(snapshot.top.map(\.name), ["Browser Helper", "cloudd"])
        XCTAssertEqual(snapshot.otherCount, 2)
        XCTAssertEqual(snapshot.otherDownloadRate, 13)
        XCTAssertEqual(snapshot.otherUploadRate, 7)
    }

    func testTopAndRestAccountForEveryByte() {
        let snapshot = NetworkProcessMonitor.snapshot(from: samples, elapsed: 1, limit: 3) { $0.name }
        let download = snapshot.top.reduce(0) { $0 + $1.downloadRate } + snapshot.otherDownloadRate
        XCTAssertEqual(download, Double(samples.reduce(0) { $0 + $1.received }))
    }

    func testMonitorIsIdleUntilStartedAndAfterStopping() {
        let monitor = NetworkProcessMonitor()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertNil(monitor.snapshot())
        monitor.start(interval: 1)
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertNil(monitor.snapshot())
    }
}

final class FanControlTests: XCTestCase {
    private let limits = [FanLimits(minimum: 1499, maximum: 4296), FanLimits(minimum: 1499, maximum: 4744)]

    func testSpeedsAreClampedToTheFansOwnRange() {
        XCTAssertEqual(limits[0].clamp(2600), 2600)
        XCTAssertEqual(limits[0].clamp(0), 1499)
        XCTAssertEqual(limits[0].clamp(99_999), 4296)
        XCTAssertEqual(FanLimits(minimum: 1200, maximum: 0).clamp(500), 1200, "a missing maximum must not allow less than the minimum")
    }

    func testSpeedIsEncodedAsALittleEndianFloat() {
        XCTAssertEqual(SMCFanController.encode(rpm: 2600), [0x00, 0x80, 0x22, 0x45])
        XCTAssertEqual(SMCValue(key: "F0Tg", type: "flt ", bytes: SMCFanController.encode(rpm: 1499)).doubleValue, 1499)
    }

    func testSettingAFanClampsAndTakesItOffAutomatic() {
        var supervisor = FanSupervisor()
        let result = supervisor.handle(FanRequest(command: .set, fan: 1, rpm: 9000), limits: limits, now: 0)
        XCTAssertEqual(try result.get(), [.set(fan: 1, rpm: 4744)])
        XCTAssertEqual(supervisor.manualFans, [1])
        XCTAssertTrue(supervisor.needsWatching)
    }

    func testBadRequestsAreRefusedWithoutTouchingAnything() {
        var supervisor = FanSupervisor()
        XCTAssertThrowsError(try supervisor.handle(FanRequest(command: .set, fan: 7, rpm: 2000), limits: limits, now: 0).get())
        XCTAssertThrowsError(try supervisor.handle(FanRequest(command: .set, fan: 0), limits: limits, now: 0).get())
        XCTAssertThrowsError(try supervisor.handle(FanRequest(command: .set, fan: 0, rpm: .nan), limits: limits, now: 0).get())
        XCTAssertThrowsError(try supervisor.handle(FanRequest(command: .automatic, fan: -1), limits: limits, now: 0).get())
        XCTAssertFalse(supervisor.needsWatching)
    }

    func testAutomaticReturnsOneFanOrAllOfThem() throws {
        var supervisor = FanSupervisor()
        _ = supervisor.handle(FanRequest(command: .set, fan: 0, rpm: 2000), limits: limits, now: 0)
        _ = supervisor.handle(FanRequest(command: .set, fan: 1, rpm: 2000), limits: limits, now: 0)
        XCTAssertEqual(try supervisor.handle(FanRequest(command: .automatic, fan: 0), limits: limits, now: 1).get(), [.automatic(fan: 0)])
        XCTAssertEqual(supervisor.manualFans, [1])
        XCTAssertEqual(try supervisor.handle(FanRequest(command: .automatic), limits: limits, now: 2).get(), [.restoreAll])
        XCTAssertFalse(supervisor.needsWatching)
    }

    func testFansGoBackToAutomaticWhenTheAppGoesQuiet() {
        var supervisor = FanSupervisor()
        _ = supervisor.handle(FanRequest(command: .set, fan: 0, rpm: 2000), limits: limits, now: 100)
        XCTAssertEqual(supervisor.tick(now: 100 + FanSupervisor.contactTimeout, cpuTemperature: 50), [])
        XCTAssertEqual(supervisor.tick(now: 101 + FanSupervisor.contactTimeout, cpuTemperature: 50), [.restoreAll])
        XCTAssertTrue(supervisor.manualFans.isEmpty)
    }

    func testAPingKeepsManualControlAlive() {
        var supervisor = FanSupervisor()
        _ = supervisor.handle(FanRequest(command: .set, fan: 0, rpm: 2000), limits: limits, now: 0)
        _ = supervisor.handle(FanRequest(command: .ping), limits: limits, now: 25)
        XCTAssertEqual(supervisor.tick(now: 50, cpuTemperature: 50), [])
        XCTAssertEqual(supervisor.manualFans, [0])
    }

    func testAHotCPUEndsManualControlAndRefusesItUntilItCools() {
        var supervisor = FanSupervisor()
        _ = supervisor.handle(FanRequest(command: .set, fan: 0, rpm: 1499), limits: limits, now: 0)
        XCTAssertEqual(supervisor.tick(now: 1, cpuTemperature: FanSupervisor.cutOffTemperature), [.restoreAll])
        XCTAssertTrue(supervisor.isLockedOut)
        XCTAssertThrowsError(try supervisor.handle(FanRequest(command: .set, fan: 0, rpm: 1499), limits: limits, now: 2).get()) {
            XCTAssertEqual($0 as? FanControlError, .tooHot)
        }
        // Still warm: between the two thresholds the lock stays.
        XCTAssertEqual(supervisor.tick(now: 3, cpuTemperature: 90), [])
        XCTAssertTrue(supervisor.isLockedOut)
        XCTAssertEqual(supervisor.tick(now: 4, cpuTemperature: FanSupervisor.resumeTemperature - 1), [])
        XCTAssertFalse(supervisor.isLockedOut)
        XCTAssertNoThrow(try supervisor.handle(FanRequest(command: .set, fan: 0, rpm: 1499), limits: limits, now: 5).get())
    }

    func testAskingForAutomaticStillWorksWhileLockedOut() {
        var supervisor = FanSupervisor()
        _ = supervisor.tick(now: 0, cpuTemperature: 99)
        XCTAssertNoThrow(try supervisor.handle(FanRequest(command: .automatic), limits: limits, now: 1).get())
    }

    func testAReadingTakenBeforeTheSMCCatchesUpShowsWhatWasAsked() throws {
        var supervisor = FanSupervisor()
        // What the SMC still reports right after accepting a write: nothing has changed yet.
        let stale = limits.enumerated().map { FanState(index: $0, mode: .automatic, rpm: 0, targetRPM: 0, limits: $1) }

        let set = try supervisor.handle(FanRequest(command: .set, fan: 0, rpm: 2600), limits: limits, now: 0).get()
        var fans = supervisor.settled(stale, after: set)
        XCTAssertEqual(fans[0].mode, .manual)
        XCTAssertEqual(fans[0].targetRPM, 2600)
        XCTAssertEqual(fans[0].rpm, 0, "the measured speed is never made up")
        XCTAssertEqual(fans[1], stale[1], "a fan nobody touched reads as the SMC reports it")

        // A later request about another fan must not lose the first one.
        _ = try supervisor.handle(FanRequest(command: .set, fan: 1, rpm: 2200), limits: limits, now: 1).get()
        XCTAssertEqual(supervisor.settled(stale).map(\.mode), [.manual, .manual])

        let manual = [FanState(index: 0, mode: .manual, rpm: 2595, targetRPM: 2600, limits: limits[0]),
                      FanState(index: 1, mode: .manual, rpm: 2190, targetRPM: 2200, limits: limits[1])]
        let release = try supervisor.handle(FanRequest(command: .automatic), limits: limits, now: 2).get()
        fans = supervisor.settled(manual, after: release)
        XCTAssertEqual(fans.map(\.mode), [.automatic, .automatic])
    }

    func testAFanHeldByAnotherToolIsReportedAsItIs() {
        let supervisor = FanSupervisor()
        let held = [FanState(index: 0, mode: .manual, rpm: 3000, targetRPM: 3000, limits: limits[0])]
        XCTAssertEqual(supervisor.settled(held), held)
    }

    func testRequestsAndResponsesSurviveTheWire() throws {
        let request = FanRequest(command: .set, fan: 1, rpm: 2600)
        XCTAssertEqual(try JSONDecoder().decode(FanRequest.self, from: JSONEncoder().encode(request)), request)
        let response = FanResponse(error: .tooHot, fans: [FanState(index: 0, mode: .manual, rpm: 2584, targetRPM: 2600, limits: limits[0])])
        XCTAssertEqual(try JSONDecoder().decode(FanResponse.self, from: JSONEncoder().encode(response)), response)
    }

    func testClientReportsAMissingHelper() {
        let client = FanControlClient(socketPath: "/tmp/pulso-no-such-helper.sock")
        XCTAssertFalse(client.isHelperAvailable)
        XCTAssertThrowsError(try client.send(FanRequest(command: .status))) {
            XCTAssertEqual($0 as? FanControlError, .helperUnavailable)
        }
    }

    func testWritingToTheSMCIsRefusedWithoutRoot() throws {
        try XCTSkipIf(getuid() == 0, "running as root")
        let controller = try XCTUnwrap(SMCFanController(), "no fans on this machine")
        let before = controller.states()
        // Asking for automatic is harmless even if it were allowed.
        XCTAssertThrowsError(try controller.perform(.automatic(fan: 0))) {
            XCTAssertEqual($0 as? FanControlError, .notPrivileged)
        }
        XCTAssertEqual(controller.states().map(\.mode), before.map(\.mode))
    }

    func testLiveFansReportASpeedWithinTheirRange() throws {
        let controller = try XCTUnwrap(SMCFanController(), "no fans on this machine")
        for fan in controller.states() {
            XCTAssertGreaterThan(fan.limits.maximum, fan.limits.minimum)
            XCTAssertLessThanOrEqual(fan.rpm, fan.limits.maximum * 1.1)
        }
    }
}

final class BatteryTests: XCTestCase {
    private let discharging: [String: Any] = [
        "BatteryInstalled": true, "CurrentCapacity": 80, "MaxCapacity": 100,
        "IsCharging": false, "ExternalConnected": false, "FullyCharged": false,
        "TimeRemaining": 245, "CycleCount": 312,
        "DesignCapacity": 6000, "AppleRawMaxCapacity": 5400,
        "Temperature": 3055, "Voltage": 12_000,
        // -1.5 A as the registry stores it.
        "Amperage": NSNumber(value: UInt64(bitPattern: -1500)),
    ]

    func testDischargingBattery() throws {
        let snapshot = try XCTUnwrap(BatterySampler.snapshot(properties: discharging))
        XCTAssertEqual(snapshot.charge, 0.8, accuracy: 1e-9)
        XCTAssertEqual(snapshot.minutesRemaining, 245)
        XCTAssertEqual(snapshot.cycleCount, 312)
        XCTAssertEqual(snapshot.health ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(snapshot.temperature ?? 0, 30.55, accuracy: 1e-9)
        XCTAssertEqual(snapshot.amperage ?? 0, -1.5, accuracy: 1e-9)
        XCTAssertEqual(snapshot.power ?? 0, -18, accuracy: 1e-9)
    }

    func testEstimateStillCalculatingIsReportedAsUnknown() throws {
        var properties = discharging
        properties["TimeRemaining"] = 65_535
        XCTAssertNil(try XCTUnwrap(BatterySampler.snapshot(properties: properties)).minutesRemaining)
    }

    func testPluggedInAndNotChargingHasNoTimeRemaining() throws {
        var properties = discharging
        properties["ExternalConnected"] = true
        let snapshot = try XCTUnwrap(BatterySampler.snapshot(properties: properties))
        XCTAssertNil(snapshot.minutesRemaining)
        XCTAssertTrue(snapshot.isPluggedIn)
    }

    func testAdapterDetailsAreRead() throws {
        var properties = discharging
        properties["AdapterDetails"] = ["Watts": 96, "Name": "96W USB-C Power Adapter"]
        let snapshot = try XCTUnwrap(BatterySampler.snapshot(properties: properties))
        XCTAssertEqual(snapshot.adapterWatts, 96)
        XCTAssertEqual(snapshot.adapterName, "96W USB-C Power Adapter")
    }

    func testCapacitiesAreFoundInsideBatteryData() throws {
        var properties = discharging
        properties["DesignCapacity"] = nil
        properties["AppleRawMaxCapacity"] = nil
        properties["BatteryData"] = ["DesignCapacity": 8694, "AppleRawMaxCapacity": 6818]
        let snapshot = try XCTUnwrap(BatterySampler.snapshot(properties: properties))
        XCTAssertEqual(snapshot.designCapacity, 8694)
        XCTAssertEqual(snapshot.health ?? 0, 6818.0 / 8694.0, accuracy: 1e-9)
    }

    func testMissingTemperatureIsFilledFromTheBatterySensors() throws {
        var properties = discharging
        properties["Temperature"] = nil
        let battery = try XCTUnwrap(BatterySampler.snapshot(properties: properties))
        XCTAssertNil(battery.temperature)
        let sensors = SensorsSampler.snapshot(temperatures: [
            TemperatureReading(name: "Battery 1", celsius: 30, group: .battery),
            TemperatureReading(name: "Battery 2", celsius: 32, group: .battery),
            TemperatureReading(name: "CPU P1", celsius: 80, group: .cpuPerformance),
        ], fans: [], power: PowerReading())
        XCTAssertEqual(SystemMonitor.fillingTemperature(of: battery, from: sensors)?.temperature, 31)
    }

    func testReportedTemperatureIsNotOverwritten() throws {
        let battery = try XCTUnwrap(BatterySampler.snapshot(properties: discharging))
        let sensors = SensorsSampler.snapshot(temperatures: [
            TemperatureReading(name: "Battery 1", celsius: 99, group: .battery),
        ], fans: [], power: PowerReading())
        XCTAssertEqual(SystemMonitor.fillingTemperature(of: battery, from: sensors)?.temperature ?? 0, 30.55, accuracy: 1e-9)
    }

    func testMacWithoutBatteryHasNoSnapshot() {
        XCTAssertNil(BatterySampler.snapshot(properties: ["BatteryInstalled": false]))
        XCTAssertNil(BatterySampler.snapshot(properties: [:]))
    }
}

final class SensorTests: XCTestCase {
    func testSMCValueDecoding() {
        func value(_ type: String, _ bytes: [UInt8]) -> Double? {
            SMCValue(key: "TEST", type: type, bytes: bytes).doubleValue
        }
        // 42.5 as a little-endian IEEE float.
        XCTAssertEqual(value("flt ", [0x00, 0x00, 0x2A, 0x42]), 42.5)
        XCTAssertEqual(value("ui8 ", [2]), 2)
        XCTAssertEqual(value("ui16", [0x01, 0x02]), 258)
        XCTAssertEqual(value("ui32", [0x00, 0x00, 0x07, 0xD0]), 2000)
        XCTAssertEqual(value("si8 ", [0xFF]), -1)
        XCTAssertEqual(value("si16", [0xFF, 0xFE]), -2)
        XCTAssertEqual(value("sp78", [0x2A, 0x80]), 42.5)
        XCTAssertEqual(value("sp78", [0xFF, 0x00]), -1)
        XCTAssertEqual(value("fpe2", [0x12, 0xC0]), 1200)
        XCTAssertNil(value("ch8*", [0x41, 0x42]))
        XCTAssertNil(value("flt ", [0x00, 0x00]), "a truncated value must not decode")
    }

    func testFourCCRoundTrip() {
        XCTAssertEqual(FourCC.encode("#KEY"), 0x234B_4559)
        XCTAssertEqual(FourCC.decode(0x464E_756D), "FNum")
        XCTAssertNil(FourCC.encode("TOOLONG"))
    }

    func testHIDSensorNamesMapToGroups() {
        XCTAssertEqual(SensorsSampler.hidGroup(forSensorNamed: "pACC MTR Temp Sensor3"), .cpuPerformance)
        XCTAssertEqual(SensorsSampler.hidGroup(forSensorNamed: "eACC MTR Temp Sensor0"), .cpuEfficiency)
        XCTAssertEqual(SensorsSampler.hidGroup(forSensorNamed: "GPU MTR Temp Sensor1"), .gpu)
        XCTAssertEqual(SensorsSampler.hidGroup(forSensorNamed: "SOC MTR Temp Sensor0"), .soc)
        XCTAssertEqual(SensorsSampler.hidGroup(forSensorNamed: "NAND CH0 temp"), .storage)
        XCTAssertEqual(SensorsSampler.hidGroup(forSensorNamed: "gas gauge battery"), .battery)
        XCTAssertEqual(SensorsSampler.hidGroup(forSensorNamed: "PMU tdev2"), .other)
    }

    func testPowerManagementDieSensorsAreNotCPUSensors() {
        XCTAssertFalse(SensorsSampler.hidGroup(forSensorNamed: "PMU tdie4").isCPU)
    }

    func testInvalidAndCalibrationReadingsAreDropped() {
        let readings = SensorsSampler.hidTemperatures(from: [
            ("PMU tdie1", 55), ("PMU tcal", 51.85), ("PMU tdie2", 0), ("PMU tdie3", -20), ("PMU tdie4", 400),
        ])
        XCTAssertEqual(readings.map(\.name), ["PMU tdie1"])
    }

    func testDuplicateSensorNamesStayDistinct() {
        let readings = SensorsSampler.hidTemperatures(from: [("gas gauge battery", 30), ("gas gauge battery", 31)])
        XCTAssertEqual(Set(readings.map(\.id)).count, 2)
    }

    func testHIDIsNotReadWhenTheSMCCoversTheCPU() {
        let smc = [TemperatureReading(name: "CPU P1", celsius: 70, group: .cpuPerformance)]
        var hidWasRead = false
        let merged = SensorsSampler.merge(smc: smc) {
            hidWasRead = true
            return []
        }
        XCTAssertEqual(merged, smc)
        XCTAssertFalse(hidWasRead)
    }

    func testHIDOnlyFillsGroupsTheSMCLeftEmpty() {
        let smc = [TemperatureReading(name: "SSD", celsius: 32, group: .storage)]
        let merged = SensorsSampler.merge(smc: smc) {
            [TemperatureReading(name: "NAND CH0 temp", celsius: 33, group: .storage),
             TemperatureReading(name: "pACC MTR Temp Sensor0", celsius: 60, group: .cpuPerformance)]
        }
        XCTAssertEqual(merged.map(\.name), ["SSD", "pACC MTR Temp Sensor0"])
    }

    func testChipGenerationIsParsedFromTheBrandString() {
        XCTAssertEqual(SMCSensorCatalog.generation(ofChip: "Apple M1 Pro"), 1)
        XCTAssertEqual(SMCSensorCatalog.generation(ofChip: "Apple M4 Max"), 4)
        XCTAssertEqual(SMCSensorCatalog.generation(ofChip: "Apple M12"), 12)
        XCTAssertNil(SMCSensorCatalog.generation(ofChip: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz"))
    }

    func testCatalogNamesCoresPerCluster() {
        let sensors = SMCSensorCatalog.coreSensors(forChip: "Apple M1 Pro")
        XCTAssertEqual(sensors.first { $0.key == "Tp01" }, SMCSensor(key: "Tp01", name: "CPU P1", group: .cpuPerformance))
        XCTAssertEqual(sensors.first { $0.key == "Tp0T" }, SMCSensor(key: "Tp0T", name: "CPU E2", group: .cpuEfficiency))
        XCTAssertEqual(sensors.first { $0.key == "Tg0D" }, SMCSensor(key: "Tg0D", name: "GPU 2", group: .gpu))
        XCTAssertEqual(Set(sensors.map(\.key)).count, sensors.count, "a key must not be listed twice")
    }

    func testUnknownChipFallsBackToKeyPrefixes() {
        XCTAssertTrue(SMCSensorCatalog.coreSensors(forChip: "Apple M99").isEmpty)
        let guessed = SMCSensorCatalog.guessCoreSensors(among: ["Tp01", "Tg05", "TB0T", "F0Ac", "Te05"])
        XCTAssertEqual(guessed.map(\.key), ["Tp01", "Tg05", "Te05"])
        XCTAssertEqual(guessed.map(\.group), [.cpu, .gpu, .cpu])
    }

    func testLiveCPUTemperatureComesFromCoreSensors() throws {
        let snapshot = SensorsSampler().sample()
        try XCTSkipIf(snapshot.temperatures.isEmpty, "no sensors exposed (virtual machine?)")
        let cpu = try XCTUnwrap(snapshot.cpuTemperature)
        XCTAssertTrue((10...125).contains(cpu), "implausible CPU temperature \(cpu)")
        XCTAssertTrue(snapshot.temperatures.contains { $0.group.isCPU })
    }

    func testAggregatesPreferCoreSensorsOverDieSensors() {
        let temperatures = [
            TemperatureReading(name: "p", celsius: 60, group: .cpuPerformance),
            TemperatureReading(name: "e", celsius: 40, group: .cpuEfficiency),
            TemperatureReading(name: "d", celsius: 90, group: .cpu),
            TemperatureReading(name: "g", celsius: 45, group: .gpu),
        ]
        let snapshot = SensorsSampler.snapshot(temperatures: temperatures, fans: [], power: PowerReading())
        XCTAssertEqual(snapshot.cpuTemperature, 50)
        XCTAssertEqual(snapshot.gpuTemperature, 45)
        XCTAssertEqual(snapshot.hottest, 90)
    }

    func testCPUTemperatureFallsBackToDieSensors() {
        let temperatures = [TemperatureReading(name: "d", celsius: 70, group: .cpu)]
        XCTAssertEqual(SensorsSampler.snapshot(temperatures: temperatures, fans: [], power: PowerReading()).cpuTemperature, 70)
    }

    func testFanFractionIsClampedToItsRange() {
        XCTAssertEqual(FanReading(index: 0, rpm: 3000, minimumRPM: 1000, maximumRPM: 5000).fraction, 0.5)
        XCTAssertEqual(FanReading(index: 0, rpm: 0, minimumRPM: 1000, maximumRPM: 5000).fraction, 0)
        XCTAssertEqual(FanReading(index: 0, rpm: 9000, minimumRPM: 1000, maximumRPM: 5000).fraction, 1)
        XCTAssertEqual(FanReading(index: 0, rpm: 1000, minimumRPM: 0, maximumRPM: 0).fraction, 0)
    }
}

final class ProcessTests: XCTestCase {
    func testParsesPsOutput() {
        let output = """
                1   0.0  21040 launchd
              412  12.5 512000 Google Chrome Helper (Renderer)
            garbage line
              900   3,5   2048 Finder

            """
        let processes = ProcessSampler.parse(output)
        XCTAssertEqual(processes.map(\.pid), [1, 412, 900])
        XCTAssertEqual(processes[1].name, "Google Chrome Helper (Renderer)")
        XCTAssertEqual(processes[1].cpu, 12.5)
        XCTAssertEqual(processes[1].memory, 512_000 * 1024)
        XCTAssertEqual(processes[2].cpu, 3.5, "a comma decimal separator must still parse")
    }

    func testTopListsAreSortedAndLimited() {
        let processes = (1...10).map { ProcessUsage(pid: Int32($0), name: "p\($0)", cpu: Double($0), memory: UInt64(100 - $0)) }
        let snapshot = ProcessSampler.snapshot(processes, limit: 3)
        XCTAssertEqual(snapshot.count, 10)
        XCTAssertEqual(snapshot.topByCPU.map(\.pid), [10, 9, 8])
        XCTAssertEqual(snapshot.topByMemory.map(\.pid), [1, 2, 3])
    }

    func testLiveSampleSeesOtherUsersProcesses() throws {
        let snapshot = try XCTUnwrap(ProcessSampler(limit: 5).sample())
        XCTAssertGreaterThan(snapshot.count, 50)
        XCTAssertEqual(snapshot.topByCPU.count, 5)
    }

    func testOwnFootprintIsReadable() {
        XCTAssertGreaterThan(ProcessSampler.footprint(of: getpid()) ?? 0, 0)
    }
}

final class SupportTests: XCTestCase {
    func testRingBufferKeepsTheNewestElementsInOrder() {
        var buffer = RingBuffer<Int>(capacity: 3)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(buffer.last)
        (1...2).forEach { buffer.append($0) }
        XCTAssertEqual(buffer.elements, [1, 2])
        (3...5).forEach { buffer.append($0) }
        XCTAssertEqual(buffer.elements, [3, 4, 5])
        XCTAssertEqual(buffer.last, 5)
        XCTAssertEqual(buffer.count, 3)
    }

    func testThrottledReusesItsValueUntilItExpires() {
        var throttled = Throttled<Int>(lifetime: 10)
        var calls = 0
        func next() -> Int { calls += 1; return calls }
        XCTAssertEqual(throttled.value(at: 0, next), 1)
        XCTAssertEqual(throttled.value(at: 9, next), 1)
        XCTAssertEqual(throttled.value(at: 10, next), 2)
        throttled.invalidate()
        XCTAssertEqual(throttled.value(at: 11, next), 3)
    }

    func testByteFormatting() {
        XCTAssertEqual(Format.bytes(0), "0 B")
        XCTAssertEqual(Format.bytes(999), "999 B")
        XCTAssertEqual(digitsOnly(Format.bytes(1500)), "150 KB")
        XCTAssertEqual(digitsOnly(Format.bytes(17_179_869_184, binary: true)), "160 GB")
        XCTAssertEqual(Format.bytes(250_000_000_000), "250 GB")
    }

    func testRateNeverDropsBelowKilobytes() {
        XCTAssertEqual(Format.rate(0), "0 KB/s")
        XCTAssertEqual(Format.rate(500), "0 KB/s")   // 0.5 KB rounds to even
        XCTAssertEqual(Format.rate(12_000), "12 KB/s")
        XCTAssertEqual(digitsOnly(Format.rate(1_250_000)), "125 MB/s")
        XCTAssertEqual(Format.rate(-5), "0 KB/s")
    }

    func testDurations() {
        XCTAssertEqual(Format.hoursMinutes(187), "3:07")
        XCTAssertEqual(Format.hoursMinutes(5), "0:05")
        XCTAssertEqual(Format.uptime(4 * 86_400 + 3 * 3600 + 59), "4 d 3 h")
        XCTAssertEqual(Format.uptime(3 * 3600 + 12 * 60), "3 h 12 min")
        XCTAssertEqual(Format.uptime(59), "0 min")
    }

    func testPercentAndTemperature() {
        XCTAssertEqual(Format.percent(0.426), "43%")
        XCTAssertEqual(Format.percent(-1), "0%")
        XCTAssertEqual(Format.temperature(58.4), "58°")
        XCTAssertEqual(Format.temperature(100, fahrenheit: true), "212°")
    }

    /// Drops the locale-dependent decimal separator so the assertion holds in any locale.
    private func digitsOnly(_ text: String) -> String {
        text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "")
    }
}
