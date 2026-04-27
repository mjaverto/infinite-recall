import Foundation

/// Builds the system + user messages for the KG extractor.
///
/// The prompt locks the model into a strict JSON envelope:
///   {"nodes":[{"id","label","type","aliases":[]}],
///    "edges":[{"source","target","label"}]}
///
/// No prose, no markdown, no preamble. The 5 valid `type` values are
/// enumerated literally. `id` is a kebab-case slug. Empty input MUST be
/// answered with an empty arrays envelope.
enum KGExtractorPrompt {

  static let systemPrompt: String = """
    You extract a small knowledge graph from a single short memory note.

    Output contract — respond with ONE JSON object and NOTHING else:
    - No prose. No markdown. No code fences. No preamble. No trailing notes.
    - Schema:
      {
        "nodes": [{"id": string, "label": string, "type": string, "aliases": [string]}],
        "edges": [{"source": string, "target": string, "label": string}]
      }
    - "type" is EXACTLY one of: person, place, organization, thing, concept.
    - "id" is a kebab-case slug, lowercase, ASCII, hyphens only — derived from the label.
    - Every "edges[].source" and "edges[].target" MUST match a "nodes[].id" present in this same response.
    - "aliases" is an array (may be empty) of alternate surface forms.
    - If the input has no extractable entities, respond with: {"nodes":[],"edges":[]}

    Examples:

    INPUT: Stand-up with Priya at Acme on Monday — we discussed the Falcon launch and split owners.
    OUTPUT: {"nodes":[{"id":"priya","label":"Priya","type":"person","aliases":[]},{"id":"acme","label":"Acme","type":"organization","aliases":[]},{"id":"falcon-launch","label":"Falcon launch","type":"thing","aliases":["Falcon"]},{"id":"stand-up","label":"Stand-up","type":"concept","aliases":["standup"]}],"edges":[{"source":"priya","target":"acme","label":"works at"},{"source":"stand-up","target":"falcon-launch","label":"discussed"}]}

    INPUT: Refactored the auth module in infinite-recall to drop Firebase. Replaced FirebaseAuthService with LocalAuth.
    OUTPUT: {"nodes":[{"id":"infinite-recall","label":"infinite-recall","type":"thing","aliases":[]},{"id":"auth-module","label":"auth module","type":"concept","aliases":[]},{"id":"firebase","label":"Firebase","type":"organization","aliases":["FirebaseAuthService"]},{"id":"local-auth","label":"LocalAuth","type":"thing","aliases":[]}],"edges":[{"source":"auth-module","target":"infinite-recall","label":"part of"},{"source":"local-auth","target":"firebase","label":"replaced"}]}

    INPUT: Brunch with mom in Brooklyn — she's reading the new Murakami.
    OUTPUT: {"nodes":[{"id":"mom","label":"mom","type":"person","aliases":[]},{"id":"brooklyn","label":"Brooklyn","type":"place","aliases":[]},{"id":"murakami","label":"Murakami","type":"person","aliases":[]}],"edges":[{"source":"mom","target":"brooklyn","label":"met in"},{"source":"mom","target":"murakami","label":"reading"}]}
    """

  /// Build the user message. `sourceApp` is included only when present —
  /// empty/nil source apps are omitted to keep the model focused on the text.
  static func userMessage(content: String, sourceApp: String?) -> String {
    var lines: [String] = []
    if let app = sourceApp, !app.trimmingCharacters(in: .whitespaces).isEmpty {
      lines.append("Source app: \(app)")
    }
    lines.append("Memory:")
    lines.append(content)
    lines.append("")
    lines.append("Respond with the JSON object only.")
    return lines.joined(separator: "\n")
  }
}
