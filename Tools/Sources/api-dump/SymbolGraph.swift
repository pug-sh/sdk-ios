/// The parts of a symbol graph, as `swift symbolgraph-extract` writes it, that make up the public API.
struct SymbolGraph: Decodable {
  let symbols: [Symbol]
  let relationships: [Relationship]
}

struct Symbol: Decodable {
  struct Kind: Decodable {
    let identifier: String
  }

  struct Identifier: Decodable {
    let precise: String
  }

  struct Fragment: Decodable {
    let kind: String
    let spelling: String
  }

  struct Generics: Decodable {
    let constraints: [Constraint]?
  }

  let kind: Kind
  let identifier: Identifier
  let pathComponents: [String]
  let declarationFragments: [Fragment]?
  let swiftGenerics: Generics?
  let swiftExtension: Generics?
  let availability: [Availability]?
}

struct Constraint: Decodable {
  let kind: String
  let lhs: String
  let rhs: String
}

struct Availability: Decodable {
  struct Version: Decodable {
    let major: Int
    let minor: Int?
    let patch: Int?
  }

  let domain: String?
  let introduced: Version?
  let deprecated: Version?
  let obsoleted: Version?
  let renamed: String?
  let message: String?
  let isUnconditionallyDeprecated: Bool?
  let isUnconditionallyUnavailable: Bool?
}

struct Relationship: Decodable {
  let kind: String
  let source: String
  let target: String
  let targetFallback: String?
}
