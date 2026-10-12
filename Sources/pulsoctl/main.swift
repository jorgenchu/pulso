import Foundation
import PulsoCore

let usage = """
    pulsoctl — inspecciona el motor de métricas de Pulso

    Uso:
      pulsoctl snapshot [--processes]   Vuelca una muestra completa en JSON
      pulsoctl watch [segundos] [-n N]  Una línea por muestra (por defecto cada 2 s)
      pulsoctl sensors                  Temperaturas, ventiladores, potencia y claves SMC en bruto
      pulsoctl smc CLAVE...             Lee claves SMC concretas (tipo, bytes y valor)
      pulsoctl traffic [segundos]       Procesos que más red usan, bajada y subida
      pulsoctl fan [status|auto|set N RPM]  Estado y control de los ventiladores
      pulsoctl info                     Datos fijos del equipo
      pulsoctl bench [muestras]         Mide el coste de cada muestra
    """

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    guard let data = try? encoder.encode(value) else {
        FileHandle.standardError.write(Data("no se pudo codificar la muestra\n".utf8))
        exit(1)
    }
    print(String(decoding: data, as: UTF8.self))
}

func snapshot(includingProcesses: Bool) {
    let monitor = SystemMonitor()
    // Rates are measured between two readings, so leave a window before sampling.
    Thread.sleep(forTimeInterval: 1)
    printJSON(monitor.sampleNow(includingProcesses: includingProcesses))
}

func watch(interval: TimeInterval, count: Int?) {
    let monitor = SystemMonitor()
    var remaining = count
    while remaining.map({ $0 > 0 }) ?? true {
        Thread.sleep(forTimeInterval: interval)
        let sample = monitor.sampleNow()
        var fields = ["CPU " + Format.percent(sample.cpu.usage)]
        if let performance = sample.cpu.performanceUsage, let efficiency = sample.cpu.efficiencyUsage {
            fields.append("P " + Format.percent(performance) + " E " + Format.percent(efficiency))
        }
        if let gpu = sample.gpus.first?.utilization { fields.append("GPU " + Format.percent(gpu)) }
        if let memory = sample.memory { fields.append("MEM " + Format.percent(memory.usedFraction)) }
        fields.append("↓ " + Format.rate(sample.network.downloadRate) + " ↑ " + Format.rate(sample.network.uploadRate))
        fields.append("R " + Format.rate(sample.disk.activity.readRate) + " W " + Format.rate(sample.disk.activity.writeRate))
        if let temperature = sample.sensors.cpuTemperature { fields.append(Format.temperature(temperature) + "C") }
        if let fan = sample.sensors.fans.first { fields.append(Format.number(fan.rpm, digits: 0) + " rpm") }
        if let watts = sample.sensors.power.system { fields.append(Format.number(watts, digits: 1) + " W") }
        print(fields.joined(separator: " | "))
        fflush(stdout)
        remaining = remaining.map { $0 - 1 }
    }
}

func sensors() {
    let sample = SensorsSampler().sample()
    print("TEMPERATURAS (\(sample.temperatures.count) sensores)")
    print("  CPU media: " + (sample.cpuTemperature.map { Format.number($0, digits: 1) + " °C" } ?? "—")
        + "   GPU media: " + (sample.gpuTemperature.map { Format.number($0, digits: 1) + " °C" } ?? "—"))
    for group in SensorGroup.allCases {
        let readings = sample.temperatures(in: group)
        guard !readings.isEmpty else { continue }
        print("  [\(group.rawValue)]")
        for reading in readings {
            print("    " + reading.name.padding(toLength: 34, withPad: " ", startingAt: 0)
                + Format.number(reading.celsius, digits: 1) + " °C")
        }
    }
    print("\nVENTILADORES")
    if sample.fans.isEmpty { print("  (ninguno)") }
    for fan in sample.fans {
        print("  #\(fan.index): \(Format.number(fan.rpm, digits: 0)) rpm"
            + "  [\(Format.number(fan.minimumRPM, digits: 0)) – \(Format.number(fan.maximumRPM, digits: 0))]")
    }
    print("\nPOTENCIA")
    print("  Sistema:   " + (sample.power.system.map { Format.number($0, digits: 2) + " W" } ?? "—"))
    print("  Adaptador: " + (sample.power.adapter.map { Format.number($0, digits: 2) + " W" } ?? "—"))

    guard let smc = SMCConnection() else {
        print("\nSMC no disponible")
        return
    }
    let keys = smc.allKeys()
    print("\nSMC: \(keys.count) claves. Numéricas de temperatura (T), ventilador (F) y potencia (P):")
    for key in keys where ["T", "F", "P"].contains(String(key.prefix(1))) {
        guard let value = smc.read(key), let number = value.doubleValue, number.isFinite, number != 0 else { continue }
        print("  \(key)  \(value.type)  " + Format.number(number, digits: 2))
    }
}

func traffic(seconds: TimeInterval) {
    let monitor = NetworkProcessMonitor()
    monitor.limit = 8
    monitor.start(interval: 2)
    defer { monitor.stop() }
    let deadline = Date().addingTimeInterval(seconds)
    var printed: NetworkProcessSnapshot?
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.5)
        guard let snapshot = monitor.snapshot(), snapshot != printed else { continue }
        printed = snapshot
        print("--- bajada / subida ---")
        for process in snapshot.top {
            let name = process.processCount > 1 ? "\(process.name) ×\(process.processCount)" : process.name
            print("  " + name.padding(toLength: 38, withPad: " ", startingAt: 0)
                + Format.rate(process.downloadRate).padding(toLength: 13, withPad: " ", startingAt: 0)
                + Format.rate(process.uploadRate))
        }
        if snapshot.otherCount > 0 {
            print("  " + "Otros \(snapshot.otherCount)".padding(toLength: 38, withPad: " ", startingAt: 0)
                + Format.rate(snapshot.otherDownloadRate).padding(toLength: 13, withPad: " ", startingAt: 0)
                + Format.rate(snapshot.otherUploadRate))
        }
        fflush(stdout)
    }
    if printed == nil { print("nettop no ha devuelto ninguna muestra") }
}

func fan(_ arguments: [String]) {
    func show(_ fans: [FanState]) {
        for fan in fans {
            print("  #\(fan.index)  \(fan.mode == .manual ? "manual    " : "automático")  "
                + "\(Format.number(fan.rpm, digits: 0)) rpm  objetivo \(Format.number(fan.targetRPM, digits: 0))"
                + "  [\(Format.number(fan.limits.minimum, digits: 0)) – \(Format.number(fan.limits.maximum, digits: 0))]")
        }
    }
    let client = FanControlClient()
    let request: FanRequest
    switch arguments.first {
    case nil, "status":
        // Reading needs no privileges, so the status works with or without the helper.
        guard let controller = SMCFanController() else {
            print("Este equipo no tiene ventiladores controlables")
            return
        }
        show(controller.states())
        print(client.isHelperAvailable ? "Servicio de ventiladores: instalado"
            : "Servicio de ventiladores: no instalado (sudo scripts/install-fan-helper.sh)")
        return
    case "auto":
        request = FanRequest(command: .automatic)
    case "set":
        guard arguments.count == 3, let index = Int(arguments[1]), let rpm = Double(arguments[2]) else {
            print("Uso: pulsoctl fan set <ventilador> <rpm>")
            return
        }
        request = FanRequest(command: .set, fan: index, rpm: rpm)
    default:
        print("Uso: pulsoctl fan [status | auto | set <ventilador> <rpm>]")
        return
    }
    do {
        let response = try client.send(request)
        show(response.fans)
        if let error = response.error { print("El servicio lo ha rechazado: \(error.rawValue)") }
    } catch {
        print("No se pudo hablar con el servicio de ventiladores: \(error)")
    }
}

func smc(keys: [String]) {
    guard let smc = SMCConnection() else {
        print("SMC no disponible")
        return
    }
    for key in keys {
        guard let value = smc.read(key) else {
            print("\(key)  (no existe)")
            continue
        }
        let hex = value.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("\(key)  [\(value.type)] \(value.bytes.count) B  \(hex)  →  "
            + (value.doubleValue.map { Format.number($0, digits: 3) } ?? "sin valor numérico"))
    }
}

func bench(samples: Int) {
    func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }
    func measure(_ label: String, includingProcesses: Bool) {
        let monitor = SystemMonitor()
        _ = monitor.sampleNow(includingProcesses: includingProcesses)
        let cpuStart = cpuSeconds(), wallStart = Date()
        for _ in 0..<samples { _ = monitor.sampleNow(includingProcesses: includingProcesses) }
        let cpu = (cpuSeconds() - cpuStart) / Double(samples)
        let wall = Date().timeIntervalSince(wallStart) / Double(samples)
        print(label)
        print("  \(Format.number(wall * 1000, digits: 2)) ms de reloj, \(Format.number(cpu * 1000, digits: 2)) ms de CPU por muestra")
        print("  ≈ \(Format.number(cpu / 2 * 100, digits: 2))% de un núcleo muestreando cada 2 s")
    }
    func breakdown(_ label: String, _ body: () -> Void) {
        body()
        let start = cpuSeconds()
        for _ in 0..<samples { body() }
        let milliseconds = (cpuSeconds() - start) / Double(samples) * 1000
        print("  " + label.padding(toLength: 26, withPad: " ", startingAt: 0) + Format.number(milliseconds, digits: 3) + " ms")
    }

    // sampleNow() bypasses the slow-metric caches, so this is the worst case per tick.
    print("\(samples) muestras, sin cachés (peor caso)\n")
    measure("Métricas base", includingProcesses: false)
    // The `ps` child's own CPU time is not included in this process's rusage.
    measure("Con lista de procesos (solo con un panel abierto)", includingProcesses: true)

    print("\nCPU por lector")
    let cpu = CPUSampler(), memory = MemorySampler(), gpu = GPUSampler(), disk = DiskSampler()
    let network = NetworkSampler(), sensors = SensorsSampler(), battery = BatterySampler()
    breakdown("CPU") { _ = cpu.sample() }
    breakdown("Memoria") { _ = memory.sample() }
    breakdown("GPU") { _ = gpu.sample() }
    breakdown("Disco · actividad") { _ = disk.sampleActivity() }
    breakdown("Disco · volúmenes") { _ = disk.volumes() }
    breakdown("Red") { _ = network.sample() }
    breakdown("Sensores") { _ = sensors.sample() }
    breakdown("Batería") { _ = battery.sample() }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first ?? "snapshot" {
case "snapshot":
    snapshot(includingProcesses: arguments.contains("--processes"))
case "watch":
    let countIndex = arguments.firstIndex(of: "-n")
    let count = countIndex.flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil }
    let interval = arguments.dropFirst().first.flatMap(TimeInterval.init) ?? 2
    watch(interval: max(0.2, interval), count: count)
case "sensors":
    sensors()
case "smc":
    smc(keys: Array(arguments.dropFirst()))
case "traffic":
    traffic(seconds: arguments.dropFirst().first.flatMap(TimeInterval.init) ?? 9)
case "fan":
    fan(Array(arguments.dropFirst()))
case "info":
    printJSON(SystemInfo.current)
case "bench":
    bench(samples: arguments.dropFirst().first.flatMap(Int.init) ?? 50)
default:
    print(usage)
}
