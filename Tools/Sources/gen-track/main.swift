import Foundation

// `gen-track <descriptor set> <output directory>` writes the SDK's typed track API from a protoc
// descriptor set of the event protos that includes source info. `make typed-track` runs it.
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: gen-track <descriptor set> <output directory>\n".utf8))
    exit(2)
}

do {
    let events = try readEvents(from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, source) in render(events) {
        let file = directory.appendingPathComponent(name)
        try Data(source.utf8).write(to: file)
        print("Wrote \(file.path)")
    }
    print("\(events.count) well-known events")
} catch {
    FileHandle.standardError.write(Data("gen-track: \(error)\n".utf8))
    exit(1)
}
