import MCP

/// Tool definitions as the model sees them. Descriptions say when to use a tool and what comes back.
enum ToolCatalog {
    static let maxSearch = 25
    static let abstractChars = 600
    static let defaultFulltextChars = 20_000
    static let maxFulltextChars = 60_000
    static let openalexAbstractChars = 500
    /// Rows read for `search_openalex` with `since` (the client has no date filter; results are filtered here).
    static let openalexSincePool = 100

    private static func schema(_ properties: [String: Value], required: [String]) -> Value {
        .object(["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
                 "additionalProperties": false])
    }

    private static let maxProperty: Value = .object([
        "type": "integer", "minimum": 1, "maximum": .int(maxSearch), "description": "Number of results, default 10, at most 25.",
    ])
    private static let sinceProperty: Value = .object([
        "type": "string", "description": "Only works first submitted on or after this date, YYYY-MM-DD.",
    ])
    private static let idProperty: Value = .object([
        "type": "string",
        "description": "arXiv id such as 2610.12345 (a version suffix, arXiv: prefix or abs URL is accepted) or OpenAlex id such as W4381712656 (journal papers in the digest).",
    ])

    static let tools: [Tool] = [
        Tool(
            name: "search_arxiv",
            description: """
                Search arXiv by topic, method name, title words or author and get the best-matching papers, most relevant \
                first. Use it for papers that are not in the current digest. Every word of the query must match somewhere \
                in the paper's metadata, so prefer two to five distinctive words over a sentence. Returns a JSON array of \
                {id, title, authors (first five), published (YYYY-MM-DD), abstract (cut at 600 characters)}. arXiv allows \
                one request every three seconds, so plan searches rather than issuing many small ones.
                """,
            inputSchema: schema([
                "query": .object(["type": "string", "description": "Words to search for, e.g. \"GRPO reward hacking\"."]),
                "categories": .object(["type": "array", "items": .object(["type": "string"]),
                                       "description": "Restrict to these arXiv categories, e.g. [\"cs.LG\", \"cs.CL\"]."]),
                "since": sinceProperty,
                "max": maxProperty,
            ], required: ["query"]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)),
        Tool(
            name: "get_paper",
            description: """
                Get one paper's metadata and full abstract by arXiv id or OpenAlex id (W..., the journal papers in the \
                digest): title, all authors, categories, dates, links, venue and DOI for journal papers, whether its full \
                text is stored, and the reader's triage result for it (score 0-10 for relevance to the reader's \
                interests, a one-line reason, tags) when the paper went through the digest pipeline. Looks in the local \
                library first and asks arXiv only for arXiv papers the app has never seen; a W... id the app has not \
                stored is an error (use `get_citations` or `search_openalex` for those).
                """,
            inputSchema: schema(["id": idProperty], required: ["id"]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)),
        Tool(
            name: "get_fulltext",
            description: """
                Read a slice of a paper's full text (converted from the arXiv HTML or PDF; formulas may be flattened). \
                Use it when the abstract and the digest do not answer the question: exact numbers, experimental setup, \
                baselines, ablations, derivations. Returns {id, total_chars, offset, text, next_offset}; read from \
                `offset` 0 first (the introduction usually tells you where things are) and continue with `next_offset` \
                instead of asking for the whole paper. Fetches and stores the text if the app does not have it yet, which \
                can take several seconds. Journal papers from OpenAlex (W... ids) have no full text: for them you get \
                {id, fulltext_available: false, note, abstract} instead.
                """,
            inputSchema: schema([
                "id": idProperty,
                "max_chars": .object(["type": "integer", "minimum": 500, "maximum": .int(maxFulltextChars),
                                      "description": "Characters to return, default 20000, at most 60000."]),
                "offset": .object(["type": "integer", "minimum": 0, "description": "Character offset to start from, default 0."]),
            ], required: ["id"]),
            annotations: .init(readOnlyHint: false, idempotentHint: true, openWorldHint: true)),
        Tool(
            name: "search_openalex",
            description: """
                Search OpenAlex (a catalogue of scholarly works) for published papers: journal and conference articles, \
                including the published versions of arXiv preprints, most relevant first. Use it to find where a preprint \
                appeared, work outside arXiv, or how widely something is cited. Returns a JSON array of {id (OpenAlex id \
                W...), arxiv_id (when the work has an arXiv version), title, venue, year, cited_by_count, doi, pdf_url \
                (open-access copy, when known), abstract (cut at 500 characters)}; fields that are unknown are omitted. \
                Pass an id to `get_citations` to see what a work cites or who cites it.
                """,
            inputSchema: schema([
                "query": .object(["type": "string", "description": "Words to search for."]),
                "since": sinceProperty,
                "max": maxProperty,
            ], required: ["query"]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)),
        Tool(
            name: "get_citations",
            description: """
                List the works a paper cites (`references`) or the works that cite it (`cited_by`), from OpenAlex. \
                Accepts an arXiv id (resolved to the OpenAlex work, which is the published version when there is one) \
                or an OpenAlex id W... from `search_openalex`. Returns {paper: the resolved work, direction, works: [{id, \
                arxiv_id, title, venue, year, cited_by_count, doi, pdf_url}]}, unknown fields omitted. Citation data for \
                papers from the last few weeks is often empty; a paper OpenAlex does not know answers with "not found \
                in OpenAlex".
                """,
            inputSchema: schema([
                "id": idProperty,
                "direction": .object(["type": "string", "enum": ["references", "cited_by"]]),
                "max": maxProperty,
            ], required: ["id", "direction"]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)),
        Tool(
            name: "search_digests",
            description: """
                Full-text search over the reader's past digests (titles, summaries, cluster narratives, paper write-ups) \
                and earlier chat messages. Use it for "have we seen this before", "what did the digest say about X last \
                week" or to find on which day a paper or topic came up. Every word must match (prefix match). Returns a \
                JSON array of {kind: "digest" | "chat", date, title or role, snippet, edition (digest hits only)}; open \
                a hit with `get_digest` using its date and edition.
                """,
            inputSchema: schema([
                "query": .object(["type": "string", "description": "Words to search for."]),
                "max": maxProperty,
            ], required: ["query"]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(
            name: "get_digest",
            description: """
                Get the stored digest of one day as JSON: title, summary, clusters with narratives, papers in rank order \
                with essence, detail, why_it_matters, caveats, triage score and links, the HuggingFace section and trend \
                notes. Use it for a day that is not the digest already in your context. A day can have several \
                editions (later runs that day covering papers not shown yet); without `edition` you get the latest. \
                The result includes `edition` and `editions_available` so you can open the others.
                """,
            inputSchema: schema([
                "date": .object(["type": "string", "description": "YYYY-MM-DD, or \"today\"."]),
                "edition": .object(["type": "integer", "minimum": 1, "description": "Edition number; omit for the latest."]),
            ], required: ["date"]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)),
    ]
}
