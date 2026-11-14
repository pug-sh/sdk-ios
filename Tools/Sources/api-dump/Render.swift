private let typeKinds: Set<String> = ["swift.actor", "swift.class", "swift.enum", "swift.protocol", "swift.struct"]

// Members in the order types conventionally declare them; any other kind comes last.
private let memberKinds = [
  "swift.enum.case", "swift.associatedtype", "swift.typealias", "swift.init", "swift.type.property", "swift.property",
  "swift.type.subscript", "swift.subscript", "swift.type.method", "swift.method", "swift.func.op",
]

// Conformances that every type has or that Sendable implies, which only some compilers report.
private let impliedConformances: Set<String> = ["BitwiseCopyable", "Copyable", "Escapable", "SendableMetatype"]

/// The API as text: the types in the order of their names, each with its conformances and members, then members of
/// types from other modules.
func render(_ graph: SymbolGraph) -> String {
  let symbols = Dictionary(graph.symbols.map { ($0.identifier.precise, $0) }) { first, _ in first }
  var conformances: [String: Set<String>] = [:]
  var superclasses: [String: String] = [:]
  for relationship in graph.relationships {
    let target =
      symbols[relationship.target].map(path) ?? unqualified(relationship.targetFallback ?? relationship.target)
    switch relationship.kind {
    case "conformsTo" where !impliedConformances.contains(target):
      conformances[relationship.source, default: []].insert(target)
    case "inheritsFrom":
      superclasses[relationship.source] = target
    default:
      break
    }
  }

  var members: [String: [Symbol]] = [:]
  for symbol in graph.symbols where !typeKinds.contains(symbol.kind.identifier) {
    members[symbol.pathComponents.dropLast().joined(separator: "."), default: []].append(symbol)
  }
  var blocks: [String] = []
  if let global = members.removeValue(forKey: "") {
    blocks.append(sorted(global).map(declaration).joined(separator: "\n"))
  }
  for type in graph.symbols.filter({ typeKinds.contains($0.kind.identifier) }).sorted(by: { path($0) < path($1) }) {
    let id = type.identifier.precise
    let inherited = [superclasses[id]].compactMap { $0 } + (conformances[id] ?? []).sorted()
    blocks.append(block(header(type, inherited), members.removeValue(forKey: path(type)) ?? []))
  }
  for (extended, extensionMembers) in members.sorted(by: { $0.key < $1.key }) {
    blocks.append(block("extension \(extended)", extensionMembers))
  }
  return blocks.joined(separator: "\n\n") + "\n"
}

private func path(_ symbol: Symbol) -> String {
  symbol.pathComponents.joined(separator: ".")
}

// Swift.Hashable as Hashable, as the declarations write it.
private func unqualified(_ name: String) -> String {
  name.split(separator: ".", maxSplits: 1).last.map(String.init) ?? name
}

private func block(_ header: String, _ members: [Symbol]) -> String {
  ([header + " {"] + sorted(members).map { "  " + declaration($0) } + ["}"]).joined(separator: "\n")
}

private func sorted(_ members: [Symbol]) -> [Symbol] {
  func key(_ symbol: Symbol) -> (Int, String) {
    (memberKinds.firstIndex(of: symbol.kind.identifier) ?? memberKinds.count, fragments(symbol))
  }
  return members.sorted { key($0) < key($1) }
}

private func fragments(_ symbol: Symbol) -> String {
  (symbol.declarationFragments ?? []).map(\.spelling).joined()
}

private func declaration(_ symbol: Symbol) -> String {
  availability(symbol) + fragments(symbol) + whereClause(symbol.swiftGenerics)
}

// The declaration under the type's full name, with the conformances in place of a protocol's inheritance clause.
private func header(_ type: Symbol, _ inherited: [String]) -> String {
  var text = ""
  var isNamed = false
  for fragment in type.declarationFragments ?? [] {
    if !isNamed {
      isNamed = fragment.kind == "identifier"
      text += isNamed ? path(type) : fragment.spelling
    } else if fragment.kind == "text", fragment.spelling.contains(":") {
      break
    } else {
      text += fragment.spelling
    }
  }
  if !inherited.isEmpty {
    text += " : " + inherited.joined(separator: ", ")
  }
  return availability(type) + text + whereClause(type.swiftExtension) + whereClause(type.swiftGenerics)
}

private func whereClause(_ generics: Symbol.Generics?) -> String {
  guard let constraints = generics?.constraints, !constraints.isEmpty else { return "" }
  let requirements = constraints.map { constraint in
    "\(constraint.lhs) \(constraint.kind == "sameType" ? "==" : ":") \(constraint.rhs)"
  }
  return " where " + requirements.joined(separator: ", ")
}

private func availability(_ symbol: Symbol) -> String {
  (symbol.availability ?? []).map { item in
    var arguments = [item.domain ?? "*"]
    if let introduced = item.introduced {
      arguments.append("introduced: \(version(introduced))")
    }
    if let deprecated = item.deprecated {
      arguments.append("deprecated: \(version(deprecated))")
    } else if item.isUnconditionallyDeprecated == true {
      arguments.append("deprecated")
    }
    if let obsoleted = item.obsoleted {
      arguments.append("obsoleted: \(version(obsoleted))")
    }
    if item.isUnconditionallyUnavailable == true {
      arguments.append("unavailable")
    }
    if let renamed = item.renamed {
      arguments.append("renamed: \"\(renamed)\"")
    }
    if let message = item.message {
      arguments.append("message: \"\(message)\"")
    }
    return "@available(\(arguments.joined(separator: ", "))) "
  }
  .joined()
}

private func version(_ version: Availability.Version) -> String {
  ([version.major] + [version.minor, version.patch].compactMap { $0 }).map(String.init).joined(separator: ".")
}
