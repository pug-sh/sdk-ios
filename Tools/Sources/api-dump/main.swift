import Foundation

// `api-dump <symbol graph> <output file>` writes the public API that a symbol graph of the module describes: a block
// per type, its conformances and its members. `make api-dump` keeps it in api/Pug.api, which `make api-check` compares.
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
  FileHandle.standardError.write(Data("usage: api-dump <symbol graph> <output file>\n".utf8))
  exit(2)
}

do {
  let graph = try JSONDecoder().decode(SymbolGraph.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
  try Data(render(graph).utf8).write(to: URL(fileURLWithPath: arguments[2]))
} catch {
  FileHandle.standardError.write(Data("api-dump: \(error)\n".utf8))
  exit(1)
}
