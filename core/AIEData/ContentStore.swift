import Foundation
import GRDB
import NaturalLanguage

public struct IndexedFileMetadata: Sendable {
    public let fileID: String
    public let versionID: String
    public let contentHash: String
    public let path: String
    public let relativePath: String
    public let rootPath: String
    public let kind: String
    public let ext: String
    public let size: Int64
    public let modifiedAt: Double
}

/// Drops the decoded vector matrix after any committed write. The hit path then skips the
/// chunk/file/feature join that was measured at about 330 ms per query.
private final class VectorWorkspaceInvalidator: TransactionObserver {
    weak var store: ContentStore?

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }

    func databaseDidChange(with event: DatabaseEvent) {}

    func databaseDidCommit(_ db: Database) {
        store?.clearVectorWorkspace()
    }

    func databaseDidRollback(_ db: Database) {}
}

/// One local database, with atomic snapshots and version-scoped derived records.
public final class ContentStore: @unchecked Sendable {
    public static let defaultIndexSoftLimitBytes: Int64 = 1_717_986_918

    public let isReadOnly: Bool
    private let filePath: String
    private let vectorIndex: any VectorIndex
    private let workspaceLock = NSLock()
    private let workspaceInvalidator = VectorWorkspaceInvalidator()
    private var workspaceGeneration: UInt64 = 0
    private var vectorWorkspaces: [VectorWorkspaceKey: VectorWorkspace] = [:]
    let database: DatabasePool

    public init(path: String, vectorIndex: any VectorIndex = ExactVectorIndex(), readOnly: Bool = false) throws {
        isReadOnly = readOnly
        filePath = path
        self.vectorIndex = vectorIndex
        let url = URL(fileURLWithPath: path)
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        var configuration = Configuration()
        configuration.readonly = readOnly
        configuration.busyMode = .timeout(10)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            if readOnly { try db.execute(sql: "PRAGMA query_only = ON") }
        }
        database = try DatabasePool(path: path, configuration: configuration)
        if readOnly { return }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_layered_content") { db in
            try db.execute(sql: """
            CREATE TABLE roots(id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, active INTEGER NOT NULL DEFAULT 1);
            CREATE TABLE files(
                id TEXT PRIMARY KEY, root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
                path TEXT NOT NULL, relative_path TEXT NOT NULL, kind TEXT NOT NULL, ext TEXT NOT NULL,
                current_version_id TEXT REFERENCES file_versions(id) DEFERRABLE INITIALLY DEFERRED,
                present INTEGER NOT NULL DEFAULT 1, size INTEGER NOT NULL, modified_at DOUBLE NOT NULL);
            CREATE INDEX files_root_path ON files(root_id, path);
            CREATE TABLE file_versions(
                id TEXT PRIMARY KEY, file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                content_hash TEXT NOT NULL, size INTEGER NOT NULL, created_at DOUBLE NOT NULL,
                coverage TEXT NOT NULL, import_signature TEXT NOT NULL,
                UNIQUE(file_id, content_hash));
            CREATE TABLE chunks(
                id TEXT PRIMARY KEY, version_id TEXT NOT NULL REFERENCES file_versions(id) ON DELETE CASCADE,
                parent_id TEXT REFERENCES chunks(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
                block_key TEXT NOT NULL, kind TEXT NOT NULL, page INTEGER, start_seconds DOUBLE, end_seconds DOUBLE,
                location_json TEXT, text TEXT NOT NULL, content_hash TEXT NOT NULL, parser_version TEXT NOT NULL,
                UNIQUE(version_id, block_key));
            CREATE INDEX chunks_version ON chunks(version_id);
            CREATE TABLE semantic_records(
                chunk_id TEXT PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
                summary TEXT NOT NULL, keywords_json TEXT NOT NULL, method TEXT NOT NULL,
                model_id TEXT NOT NULL, model_version TEXT NOT NULL, updated_at DOUBLE NOT NULL);
            CREATE TABLE embedding_spaces(id TEXT PRIMARY KEY, model_id TEXT NOT NULL, model_version TEXT NOT NULL, dimensions INTEGER NOT NULL CHECK(dimensions > 0));
            CREATE TABLE embeddings(
                chunk_id TEXT NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
                space_id TEXT NOT NULL REFERENCES embedding_spaces(id), content_hash TEXT NOT NULL, vector BLOB NOT NULL,
                PRIMARY KEY(chunk_id, space_id));
            CREATE TABLE scan_jobs(
                version_id TEXT NOT NULL REFERENCES file_versions(id) ON DELETE CASCADE,
                stage TEXT NOT NULL, status TEXT NOT NULL, error TEXT, attempted_at TEXT, attempts INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(version_id, stage));
            CREATE TABLE artifact_links(
                source_version_id TEXT NOT NULL REFERENCES file_versions(id) ON DELETE CASCADE,
                artifact_file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                relation TEXT NOT NULL, created_at DOUBLE NOT NULL,
                PRIMARY KEY(source_version_id, artifact_file_id, relation));
            CREATE VIRTUAL TABLE chunk_fts USING fts5(chunk_id UNINDEXED, terms, tokenize='unicode61');
            CREATE TRIGGER chunks_delete_fts AFTER DELETE ON chunks BEGIN DELETE FROM chunk_fts WHERE chunk_id=old.id; END;
            """)
        }
        migrator.registerMigration("v2_database_source") { db in
            try db.execute(sql: """
            CREATE TABLE analysis_records(id TEXT PRIMARY KEY, root_path TEXT NOT NULL, relative_path TEXT NOT NULL,
                file_id TEXT, revision INTEGER NOT NULL DEFAULT 0, UNIQUE(root_path,relative_path));
            CREATE INDEX analysis_file ON analysis_records(file_id);
            CREATE TABLE analysis_fields(record_id TEXT NOT NULL REFERENCES analysis_records(id) ON DELETE CASCADE,
                node_id INTEGER NOT NULL, parent_id INTEGER, name TEXT, ordinal INTEGER NOT NULL,
                value_type TEXT NOT NULL, text_value TEXT, PRIMARY KEY(record_id,node_id));
            CREATE TABLE migration_imports(source TEXT PRIMARY KEY, imported_at DOUBLE NOT NULL, field_count INTEGER NOT NULL);
            CREATE TABLE work_leases(record_id TEXT NOT NULL, scope TEXT NOT NULL, owner TEXT NOT NULL,
                expires_at DOUBLE NOT NULL, PRIMARY KEY(record_id,scope));
            CREATE TABLE file_preferences(path TEXT NOT NULL, name TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY(path,name));
            CREATE TABLE trash_records(id TEXT PRIMARY KEY, original_path TEXT NOT NULL, root_path TEXT NOT NULL,
                relative_path TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL, ext TEXT NOT NULL,
                trashed_at DOUBLE NOT NULL, stored_path TEXT NOT NULL, analysis_id TEXT, state TEXT NOT NULL,
                restore_path TEXT, content_hash TEXT);
            """)
        }
        migrator.registerMigration("v3_photo_queue") { db in
            try db.execute(sql: """
            CREATE TABLE photo_assets(
                asset_id TEXT PRIMARY KEY, root_path TEXT NOT NULL, path TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL, kind TEXT NOT NULL, revision TEXT NOT NULL,
                captured_at DOUBLE NOT NULL, modified_at DOUBLE NOT NULL, duration DOUBLE NOT NULL,
                present INTEGER NOT NULL DEFAULT 1, local_status TEXT NOT NULL DEFAULT 'pending',
                deep_status TEXT NOT NULL DEFAULT 'pending', error TEXT, retry_at DOUBLE NOT NULL DEFAULT 0);
            """)
        }
        migrator.registerMigration("v4_numeric_fragments") { db in
            // Rebuild derived search data from stored chunks only; no file scan or model calls.
            try db.execute(sql: "DROP TABLE chunk_fts")
            try db.execute(sql: "CREATE VIRTUAL TABLE chunk_fts USING fts5(chunk_id UNINDEXED, terms, identifiers UNINDEXED, tokenize='unicode61')")
            let rows = try Row.fetchCursor(db, sql: """
                SELECT c.id,c.text,f.relative_path,coalesce(s.summary,'') AS summary,
                       coalesce(s.keywords_json,'[]') AS keywords_json
                FROM chunks c JOIN file_versions v ON v.id=c.version_id
                JOIN files f ON f.id=v.file_id LEFT JOIN semantic_records s ON s.chunk_id=c.id
                """)
            while let row = try rows.next() {
                let keywords = (try? JSONDecoder().decode([String].self, from: Data((row["keywords_json"] as String).utf8))) ?? []
                let text = [row["relative_path"] as String, row["text"] as String, row["summary"] as String, keywords.joined(separator: " ")].joined(separator: "\n")
                try db.execute(sql: "INSERT INTO chunk_fts(chunk_id,terms,identifiers) VALUES(?,?,?)",
                    arguments: [row["id"] as String, SearchEncoding.encode(text), NumericSearch.runs(text).joined(separator: " ")])
            }
        }
        migrator.registerMigration("v5_content_unit_projection") { db in
            try db.execute(sql: """
            CREATE TABLE sources(
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, locator TEXT NOT NULL UNIQUE, display_name TEXT NOT NULL,
                authorization_state TEXT NOT NULL, scan_policy TEXT NOT NULL, created_at DOUBLE NOT NULL, updated_at DOUBLE NOT NULL);
            CREATE TABLE items(
                id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                stable_key TEXT NOT NULL, kind TEXT NOT NULL,
                current_version_id TEXT REFERENCES file_versions(id) DEFERRABLE INITIALLY DEFERRED,
                lifecycle_state TEXT NOT NULL, created_at DOUBLE NOT NULL, updated_at DOUBLE NOT NULL,
                UNIQUE(source_id,stable_key));
            CREATE TABLE item_locators(
                id TEXT PRIMARY KEY, item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE, locator TEXT NOT NULL,
                volume_identifier TEXT, file_resource_identifier TEXT,
                first_seen_at DOUBLE NOT NULL, last_seen_at DOUBLE NOT NULL, state TEXT NOT NULL,
                UNIQUE(item_id,locator));
            CREATE TABLE content_units(
                id TEXT PRIMARY KEY, item_version_id TEXT NOT NULL REFERENCES file_versions(id) ON DELETE CASCADE,
                parent_unit_id TEXT REFERENCES content_units(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
                unit_type TEXT NOT NULL, role TEXT NOT NULL, ordinal INTEGER NOT NULL,
                title TEXT, anchor_json TEXT, content_hash TEXT NOT NULL, created_at DOUBLE NOT NULL);
            CREATE INDEX content_units_version ON content_units(item_version_id,ordinal);
            CREATE TABLE unit_contents(
                id TEXT PRIMARY KEY, unit_id TEXT NOT NULL REFERENCES content_units(id) ON DELETE CASCADE,
                content_type TEXT NOT NULL, text TEXT NOT NULL, language TEXT, confidence DOUBLE,
                producer_run_id TEXT, is_primary INTEGER NOT NULL, created_at DOUBLE NOT NULL);
            CREATE INDEX unit_contents_unit ON unit_contents(unit_id);
            CREATE TABLE observations(
                id TEXT PRIMARY KEY, subject_type TEXT NOT NULL, subject_id TEXT NOT NULL, observation_type TEXT NOT NULL,
                value_text TEXT, value_number DOUBLE, value_json TEXT, confidence DOUBLE,
                producer_run_id TEXT, state TEXT NOT NULL, created_at DOUBLE NOT NULL);
            CREATE INDEX observations_subject ON observations(subject_type,subject_id,observation_type,state);
            CREATE TABLE features(
                id TEXT PRIMARY KEY, subject_type TEXT NOT NULL, subject_id TEXT NOT NULL, feature_type TEXT NOT NULL,
                model_key TEXT NOT NULL, model_revision TEXT NOT NULL, dimensions INTEGER,
                metric TEXT, vector_blob BLOB, content_hash TEXT NOT NULL, producer_run_id TEXT, created_at DOUBLE NOT NULL,
                UNIQUE(subject_type,subject_id,feature_type,model_key,model_revision));
            CREATE TABLE relations(
                id TEXT PRIMARY KEY, from_subject_type TEXT NOT NULL, from_subject_id TEXT NOT NULL, relation_type TEXT NOT NULL,
                to_subject_type TEXT NOT NULL, to_subject_id TEXT NOT NULL, confidence DOUBLE,
                evidence_unit_id TEXT, producer_run_id TEXT, state TEXT NOT NULL, created_at DOUBLE NOT NULL,
                UNIQUE(from_subject_type,from_subject_id,relation_type,to_subject_type,to_subject_id));
            CREATE TABLE jobs(
                id TEXT PRIMARY KEY, subject_type TEXT NOT NULL, subject_id TEXT NOT NULL, job_type TEXT NOT NULL,
                priority INTEGER NOT NULL, state TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0,
                not_before DOUBLE NOT NULL DEFAULT 0, lease_owner TEXT, lease_expires_at DOUBLE,
                input_hash TEXT NOT NULL, error_code TEXT, created_at DOUBLE NOT NULL, updated_at DOUBLE NOT NULL,
                UNIQUE(subject_type,subject_id,job_type,input_hash));
            CREATE TABLE model_runs(
                id TEXT PRIMARY KEY, job_id TEXT REFERENCES jobs(id) ON DELETE SET NULL,
                processor_key TEXT NOT NULL, processor_version TEXT NOT NULL,
                model_key TEXT, model_revision TEXT, prompt_version TEXT,
                input_fingerprint TEXT NOT NULL, parameters_json TEXT,
                started_at DOUBLE NOT NULL, finished_at DOUBLE, duration_ms INTEGER, outcome TEXT NOT NULL, error_code TEXT);
            CREATE TABLE search_documents(
                id TEXT PRIMARY KEY, item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                item_version_id TEXT NOT NULL REFERENCES file_versions(id) ON DELETE CASCADE,
                unit_id TEXT NOT NULL REFERENCES content_units(id) ON DELETE CASCADE,
                filename TEXT NOT NULL, path_text TEXT NOT NULL, title TEXT NOT NULL,
                body_text TEXT NOT NULL, ocr_text TEXT NOT NULL, chart_text TEXT NOT NULL,
                transcript_text TEXT NOT NULL DEFAULT '', summary_text TEXT NOT NULL,
                keywords TEXT NOT NULL, entity_names TEXT NOT NULL,
                item_type TEXT NOT NULL, modified_at DOUBLE NOT NULL, importance DOUBLE NOT NULL,
                identifiers TEXT NOT NULL, updated_at DOUBLE NOT NULL,
                UNIQUE(unit_id));
            CREATE VIRTUAL TABLE search_documents_fts USING fts5(
                search_document_id UNINDEXED, filename, path_text, title, body_text, ocr_text,
                chart_text, transcript_text, summary_text, keywords, entity_names,
                identifiers UNINDEXED, tokenize='unicode61');
            CREATE TRIGGER search_documents_delete_fts AFTER DELETE ON search_documents BEGIN
                DELETE FROM search_documents_fts WHERE search_document_id=old.id;
            END;
            """)
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.*,f.id AS file_id,f.root_id,f.path,f.relative_path,f.kind AS file_kind,f.ext,f.modified_at,
                       v.content_hash AS version_hash,coalesce(s.summary,'') AS summary,
                       coalesce(s.keywords_json,'[]') AS keywords_json,r.path AS root_path
                FROM chunks c JOIN file_versions v ON v.id=c.version_id
                JOIN files f ON f.id=v.file_id JOIN roots r ON r.id=f.root_id
                LEFT JOIN semantic_records s ON s.chunk_id=c.id
                """)
            for row in rows { try Self.upsertProjection(row: row, db: db) }
        }
        migrator.registerMigration("v6_operational_understanding") { db in
            if try !db.columns(in: "search_documents").contains(where: { $0.name == "transcript_text" }) {
                try db.execute(sql: "ALTER TABLE search_documents ADD COLUMN transcript_text TEXT NOT NULL DEFAULT ''")
            }
            try db.execute(sql: """
            CREATE INDEX jobs_state_priority ON jobs(state,not_before,priority DESC);
            CREATE INDEX model_runs_fingerprint ON model_runs(input_fingerprint,processor_key,outcome);
            CREATE VIEW item_versions AS
                SELECT v.id,i.id AS item_id,v.content_hash,v.size,v.created_at,v.coverage,v.import_signature
                FROM file_versions v JOIN items i ON i.id=v.file_id;
            DROP TRIGGER IF EXISTS search_documents_delete_fts;
            DROP TABLE search_documents_fts;
            CREATE VIRTUAL TABLE search_documents_fts USING fts5(
                search_document_id UNINDEXED, filename, path_text, title, body_text, ocr_text,
                chart_text, transcript_text, summary_text, keywords, entity_names,
                identifiers UNINDEXED, tokenize='unicode61');
            CREATE TRIGGER search_documents_delete_fts AFTER DELETE ON search_documents BEGIN
                DELETE FROM search_documents_fts WHERE search_document_id=old.id;
            END;
            DROP TRIGGER IF EXISTS chunks_delete_fts;
            CREATE TRIGGER chunks_delete_fts AFTER DELETE ON chunks BEGIN
                DELETE FROM chunk_fts WHERE chunk_id=old.id;
            END;
            UPDATE search_documents
            SET transcript_text=coalesce((
                SELECT uc.text FROM unit_contents uc
                WHERE uc.unit_id=search_documents.unit_id AND uc.content_type='transcript'
                ORDER BY uc.is_primary DESC,uc.created_at DESC LIMIT 1
            ),'');
            DELETE FROM unit_contents
            WHERE unit_id IN (SELECT id FROM content_units WHERE unit_type='semantic_analysis');
            UPDATE search_documents SET body_text=''
            WHERE unit_id IN (SELECT id FROM content_units WHERE unit_type='semantic_analysis');
            """)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM search_documents")
            for row in rows {
                try db.execute(sql: """
                    INSERT INTO search_documents_fts(
                        search_document_id,filename,path_text,title,body_text,ocr_text,chart_text,
                        transcript_text,summary_text,keywords,entity_names,identifiers)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [
                        row["id"] as String,
                        SearchEncoding.encode(row["filename"] as String),
                        SearchEncoding.encode(row["path_text"] as String),
                        SearchEncoding.encode(row["title"] as String),
                        SearchEncoding.encode(row["body_text"] as String),
                        SearchEncoding.encode(row["ocr_text"] as String),
                        SearchEncoding.encode(row["chart_text"] as String),
                        SearchEncoding.encode(row["transcript_text"] as String),
                        SearchEncoding.encode(row["summary_text"] as String),
                        SearchEncoding.encode(row["keywords"] as String),
                        SearchEncoding.encode(row["entity_names"] as String),
                        row["identifiers"] as String,
                    ])
            }
        }
        migrator.registerMigration("v7_projection_integrity") { db in
            try db.execute(sql: """
            DELETE FROM observations
            WHERE subject_type='content_unit' AND subject_id NOT IN (SELECT id FROM chunks);
            DELETE FROM features
            WHERE subject_type='content_unit' AND subject_id NOT IN (SELECT id FROM chunks);
            DELETE FROM relations
            WHERE (from_subject_type='content_unit' AND from_subject_id NOT IN (SELECT id FROM chunks))
               OR (to_subject_type='content_unit' AND to_subject_id NOT IN (SELECT id FROM chunks));
            DELETE FROM content_units WHERE id NOT IN (SELECT id FROM chunks);
            CREATE TRIGGER chunks_delete_projection AFTER DELETE ON chunks BEGIN
                DELETE FROM observations WHERE subject_type='content_unit' AND subject_id=old.id;
                DELETE FROM features WHERE subject_type='content_unit' AND subject_id=old.id;
                DELETE FROM relations
                    WHERE (from_subject_type='content_unit' AND from_subject_id=old.id)
                       OR (to_subject_type='content_unit' AND to_subject_id=old.id);
                DELETE FROM content_units WHERE id=old.id;
            END;
            """)
            let missingProjection = try Row.fetchAll(db, sql: """
                SELECT c.*,f.id AS file_id,f.root_id,f.path,f.relative_path,f.kind AS file_kind,f.ext,f.modified_at,
                       v.content_hash AS version_hash,coalesce(s.summary,'') AS summary,
                       coalesce(s.keywords_json,'[]') AS keywords_json,r.path AS root_path
                FROM chunks c JOIN file_versions v ON v.id=c.version_id
                JOIN files f ON f.id=v.file_id JOIN roots r ON r.id=f.root_id
                LEFT JOIN semantic_records s ON s.chunk_id=c.id
                WHERE NOT EXISTS (SELECT 1 FROM content_units cu WHERE cu.id=c.id)
                """)
            for row in missingProjection { try Self.upsertProjection(row: row, db: db) }

            let missingFTS = try Row.fetchAll(db, sql: """
                SELECT c.id,c.text,f.relative_path,coalesce(s.summary,'') AS summary,
                       coalesce(s.keywords_json,'[]') AS keywords_json
                FROM chunks c JOIN file_versions v ON v.id=c.version_id
                JOIN files f ON f.id=v.file_id LEFT JOIN semantic_records s ON s.chunk_id=c.id
                WHERE NOT EXISTS (SELECT 1 FROM chunk_fts x WHERE x.chunk_id=c.id)
                """)
            for row in missingFTS {
                let keywordJSON: String = row["keywords_json"]
                let keywords = (try? JSONDecoder().decode([String].self, from: Data(keywordJSON.utf8))) ?? []
                let text = [
                    row["relative_path"] as String, row["text"] as String,
                    row["summary"] as String, keywords.joined(separator: " "),
                ].joined(separator: "\n")
                try db.execute(
                    sql: "INSERT INTO chunk_fts(chunk_id,terms,identifiers) VALUES(?,?,?)",
                    arguments: [
                        row["id"] as String, SearchEncoding.encode(text),
                        NumericSearch.runs(text).joined(separator: " "),
                    ]
                )
            }
        }
        migrator.registerMigration("v8_float16_feature_vectors") { db in
            try db.execute(sql: """
                ALTER TABLE features ADD COLUMN vector_format TEXT NOT NULL DEFAULT 'none';
                ALTER TABLE features ADD COLUMN model_identifier TEXT;
                CREATE INDEX features_vector_lookup
                ON features(feature_type,model_key,subject_type,subject_id,content_hash);
                """)

            // Copy every legacy row first. Existing mirrored features are overwritten from the
            // authoritative compatibility row so dimensions, model revision and hashes agree.
            var offset = 0
            while true {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT e.chunk_id,e.space_id,e.content_hash,e.vector,
                           s.model_id,s.model_version,s.dimensions
                    FROM embeddings e JOIN embedding_spaces s ON s.id=e.space_id
                    ORDER BY e.chunk_id,e.space_id LIMIT 256 OFFSET ?
                    """, arguments: [offset])
                guard !rows.isEmpty else { break }
                for row in rows {
                    let dimensions: Int = row["dimensions"]
                    let legacy: Data = row["vector"]
                    let vector = try VectorCodec.decode(legacy, expectedDimensions: dimensions)
                    let blob = try VectorCodec.encode(vector)
                    let chunkID: String = row["chunk_id"]
                    let spaceID: String = row["space_id"]
                    let modelVersion: String = row["model_version"]
                    let featureID = ContentIdentity.digest(
                        [chunkID, "text_embedding", spaceID, modelVersion].joined(separator: ":")
                    )
                    try db.execute(sql: """
                        INSERT INTO features(
                            id,subject_type,subject_id,feature_type,model_key,model_revision,
                            dimensions,metric,vector_blob,content_hash,producer_run_id,created_at,
                            vector_format,model_identifier)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(subject_type,subject_id,feature_type,model_key,model_revision)
                        DO UPDATE SET dimensions=excluded.dimensions,metric=excluded.metric,
                            vector_blob=excluded.vector_blob,content_hash=excluded.content_hash,
                            created_at=excluded.created_at,vector_format=excluded.vector_format,
                            model_identifier=excluded.model_identifier
                        """, arguments: [
                            featureID, "content_unit", chunkID, "text_embedding", spaceID, modelVersion,
                            dimensions, "cosine", blob, row["content_hash"] as String, nil,
                            Date().timeIntervalSince1970, VectorCodec.format, row["model_id"] as String,
                        ])
                }
                offset += rows.count
            }

            // Convert any feature-only vectors that were not represented by the compatibility table.
            while true {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id,dimensions,vector_blob FROM features
                    WHERE feature_type='text_embedding' AND vector_blob IS NOT NULL
                      AND vector_format<>? LIMIT 256
                    """, arguments: [VectorCodec.format])
                guard !rows.isEmpty else { break }
                for row in rows {
                    guard let dimensions: Int = row["dimensions"] else {
                        throw DataLayerError.invalidEmbedding
                    }
                    let oldBlob: Data = row["vector_blob"]
                    let blob = try VectorCodec.encode(
                        VectorCodec.decode(oldBlob, expectedDimensions: dimensions)
                    )
                    try db.execute(
                        sql: "UPDATE features SET vector_blob=?,vector_format=? WHERE id=?",
                        arguments: [blob, VectorCodec.format, row["id"] as String]
                    )
                }
            }

            let missing = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM embeddings e JOIN embedding_spaces s ON s.id=e.space_id
                WHERE NOT EXISTS (
                    SELECT 1 FROM features x
                    WHERE x.subject_type='content_unit' AND x.subject_id=e.chunk_id
                      AND x.feature_type='text_embedding' AND x.model_key=e.space_id
                      AND x.model_revision=s.model_version AND x.model_identifier=s.model_id
                      AND x.dimensions=s.dimensions AND x.content_hash=e.content_hash
                      AND x.vector_format=?
                )
                """, arguments: [VectorCodec.format]) ?? 0
            guard missing == 0 else { throw DataLayerError.invalidEmbedding }

            // This migration is transactional: compatibility tables disappear only after all
            // vectors and their model metadata have been checked.
            try db.execute(sql: """
                DROP TABLE embeddings;
                DROP TABLE embedding_spaces;
                """)
        }
        migrator.registerMigration("v9_retire_legacy_chunk_fts") { db in
            let missingDocuments = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM chunks c
                WHERE NOT EXISTS (SELECT 1 FROM search_documents sd WHERE sd.unit_id=c.id)
                """) ?? 0
            guard missingDocuments == 0 else {
                throw DataLayerError.invalidDocument(
                    "Search projection is incomplete; legacy FTS was retained"
                )
            }

            let missingFTS = try Row.fetchAll(db, sql: """
                SELECT sd.* FROM search_documents sd
                WHERE NOT EXISTS (
                    SELECT 1 FROM search_documents_fts f
                    WHERE f.search_document_id=sd.id
                )
                """)
            for row in missingFTS {
                try db.execute(sql: """
                    INSERT INTO search_documents_fts(
                        search_document_id,filename,path_text,title,body_text,ocr_text,chart_text,
                        transcript_text,summary_text,keywords,entity_names,identifiers)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [
                        row["id"] as String,
                        SearchEncoding.encode(row["filename"] as String),
                        SearchEncoding.encode(row["path_text"] as String),
                        SearchEncoding.encode(row["title"] as String),
                        SearchEncoding.encode(row["body_text"] as String),
                        SearchEncoding.encode(row["ocr_text"] as String),
                        SearchEncoding.encode(row["chart_text"] as String),
                        SearchEncoding.encode(row["transcript_text"] as String),
                        SearchEncoding.encode(row["summary_text"] as String),
                        SearchEncoding.encode(row["keywords"] as String),
                        SearchEncoding.encode(row["entity_names"] as String),
                        row["identifiers"] as String,
                    ])
            }

            try db.execute(sql: """
                DROP TRIGGER IF EXISTS chunks_delete_fts;
                DROP TABLE IF EXISTS chunk_fts;
                """)
        }
        migrator.registerMigration("v10_durable_job_scheduler") { db in
            try db.execute(sql: """
                ALTER TABLE jobs ADD COLUMN checkpoint_json TEXT;
                ALTER TABLE jobs ADD COLUMN max_attempts INTEGER NOT NULL DEFAULT 5;
                CREATE INDEX jobs_claim
                ON jobs(job_type,state,not_before,priority DESC,created_at);
                UPDATE jobs SET lease_owner=NULL,lease_expires_at=NULL WHERE state<>'running';
                """)
        }
        migrator.registerMigration("v11_search_fts_rowid") { db in
            guard try db.tableExists("search_documents") else { return }
            try db.execute(sql: """
                ALTER TABLE search_documents ADD COLUMN fts_rowid INTEGER;
                UPDATE search_documents SET fts_rowid=rowid;
                CREATE UNIQUE INDEX search_documents_fts_rowid ON search_documents(fts_rowid);
                DROP TRIGGER IF EXISTS search_documents_delete_fts;
                DROP TABLE search_documents_fts;
                CREATE VIRTUAL TABLE search_documents_fts USING fts5(
                    search_document_id UNINDEXED, filename, path_text, title, body_text, ocr_text,
                    chart_text, transcript_text, summary_text, keywords, entity_names,
                    identifiers UNINDEXED, tokenize='unicode61');
                CREATE TRIGGER search_documents_delete_fts AFTER DELETE ON search_documents BEGIN
                    DELETE FROM search_documents_fts WHERE rowid=old.fts_rowid;
                END;
                """)
            let rows = try Row.fetchCursor(db, sql: "SELECT * FROM search_documents ORDER BY fts_rowid")
            while let row = try rows.next() {
                try db.execute(sql: """
                    INSERT INTO search_documents_fts(
                        rowid,search_document_id,filename,path_text,title,body_text,ocr_text,chart_text,
                        transcript_text,summary_text,keywords,entity_names,identifiers)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [
                        row["fts_rowid"] as Int64,
                        row["id"] as String,
                        SearchEncoding.encode(row["filename"] as String),
                        SearchEncoding.encode(row["path_text"] as String),
                        SearchEncoding.encode(row["title"] as String),
                        SearchEncoding.encode(row["body_text"] as String),
                        SearchEncoding.encode(row["ocr_text"] as String),
                        SearchEncoding.encode(row["chart_text"] as String),
                        SearchEncoding.encode(row["transcript_text"] as String),
                        SearchEncoding.encode(row["summary_text"] as String),
                        SearchEncoding.encode(row["keywords"] as String),
                        SearchEncoding.encode(row["entity_names"] as String),
                        row["identifiers"] as String,
                    ])
            }
        }
        migrator.registerMigration("v12_cascade_lookup_indexes", foreignKeyChecks: .immediate) { db in
            // Chunk replacement deletes stale rows. Without indexes on the recursive foreign
            // keys, SQLite scans the entire chunk/content-unit tables once per deleted block.
            if try db.tableExists("chunks") {
                try db.execute(sql: "CREATE INDEX chunks_parent ON chunks(parent_id)")
            }
            if try db.tableExists("content_units") {
                try db.execute(sql: "CREATE INDEX content_units_parent ON content_units(parent_unit_id)")
            }
            if try db.tableExists("relations") {
                try db.execute(sql: "CREATE INDEX relations_to_subject ON relations(to_subject_type,to_subject_id)")
            }
        }
        migrator.registerMigration("v13_current_version_lookup", foreignKeyChecks: .immediate) { db in
            guard try db.tableExists("files") else { return }
            // Semantic usage and retrieval join each chunk to its current file version.
            // Without this lookup, SQLite can scan every file once per embedding.
            try db.execute(sql: "CREATE INDEX files_current_version ON files(current_version_id)")
        }
        migrator.registerMigration("v14_semantic_method_lookup", foreignKeyChecks: .immediate) { db in
            guard try db.tableExists("semantic_records") else { return }
            try db.execute(sql: "CREATE INDEX semantic_records_method ON semantic_records(method,chunk_id)")
        }
        migrator.registerMigration("v15_visual_embedding_retry", foreignKeyChecks: .immediate) { db in
            guard try db.tableExists("chunks") else { return }
            try db.execute(sql: """
                CREATE INDEX chunks_version_page_kind ON chunks(version_id,page,kind);
                CREATE TABLE visual_embedding_attempts(
                    chunk_id TEXT NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
                    model_key TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                    retry_after DOUBLE NOT NULL DEFAULT 0, last_error TEXT,
                    PRIMARY KEY(chunk_id,model_key));
                """)
        }
        migrator.registerMigration("v16_feature_subject_lookup", foreignKeyChecks: .immediate) { db in
            guard try db.tableExists("features") else { return }
            try db.execute(sql: "CREATE INDEX features_subject_lookup ON features(subject_type,subject_id,feature_type)")
        }
        let requiresBackup = try database.read { db in
            try db.tableExists("grdb_migrations") && !String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations").contains("v2_database_source")
        }
        if requiresBackup {
            let backupPath = path + ".before-v2.sqlite"
            if !FileManager.default.fileExists(atPath: backupPath) {
                guard FileManager.default.createFile(atPath: backupPath, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                do { try database.backup(to: DatabaseQueue(path: backupPath)) }
                catch { try? FileManager.default.removeItem(atPath: backupPath); throw error }
            }
        }
        let requiresVectorBackup = try database.read { db in
            guard try db.tableExists("grdb_migrations"), try db.tableExists("embeddings") else {
                return false
            }
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            return applied.contains("v7_projection_integrity") && !applied.contains("v8_float16_feature_vectors")
        }
        if requiresVectorBackup {
            let backupPath = path + ".before-vector-f16.sqlite"
            if !FileManager.default.fileExists(atPath: backupPath) {
                guard FileManager.default.createFile(
                    atPath: backupPath, contents: nil, attributes: [.posixPermissions: 0o600]
                ) else { throw CocoaError(.fileWriteUnknown) }
                do { try database.backup(to: DatabaseQueue(path: backupPath)) }
                catch { try? FileManager.default.removeItem(atPath: backupPath); throw error }
            }
        }
        try migrator.migrate(database)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        workspaceInvalidator.store = self
        database.add(transactionObserver: workspaceInvalidator)
    }

    fileprivate func clearVectorWorkspace() {
        workspaceLock.lock()
        workspaceGeneration &+= 1
        vectorWorkspaces.removeAll()
        workspaceLock.unlock()
    }

    /// Commit a complete enumeration of explicitly selected roots. Batched writes are resumable;
    /// removed files lose visibility only when the complete replacement snapshot is ready.
    public func synchronize(
        documents: [SourceDocument], rootPaths: [String], preservingRoots: [String] = [],
        progress: ((Int, Int) -> Void)? = nil,
        shouldContinue: (() -> Bool)? = nil
    ) throws {
        try validate(documents: documents, rootPaths: rootPaths)
        guard shouldContinue?() != false else { throw CancellationError() }
        try ensureRoots(rootPaths)
        progress?(0, documents.count)
        var start = 0
        while start < documents.count {
            guard shouldContinue?() != false else { throw CancellationError() }
            var end = start
            var blockCount = 0
            // Bound both dimensions. A fixed 128-file transaction can contain more than
            // 100,000 PDF blocks and is effectively unrecoverable after an interruption.
            while end < documents.count && end - start < 32 {
                let nextBlocks = documents[end].blocks.count
                if end > start && blockCount + nextBlocks > 512 { break }
                blockCount += nextBlocks
                end += 1
            }
            try stage(documents: Array(documents[start..<end]), rootPaths: rootPaths)
            start = end
            progress?(start, documents.count)
        }
        guard shouldContinue?() != false else { throw CancellationError() }
        try publishSnapshot(
            documentIDs: documents.map(\.id), rootPaths: rootPaths,
            preservingRoots: preservingRoots
        )
    }

    /// Persist prepared documents without retiring the last complete snapshot. Callers may stage
    /// small batches as extraction finishes and publish visibility only after a complete walk.
    public func stage(documents: [SourceDocument], rootPaths: [String]) throws {
        try validate(documents: documents, rootPaths: rootPaths)
        try ensureRoots(rootPaths)
        try database.write { db in
            for document in documents { try self.upsert(document, db: db) }
        }
    }

    public func publishSnapshot(
        documentIDs: [String], rootPaths: [String], preservingRoots: [String] = []
    ) throws {
        guard Set(documentIDs).count == documentIDs.count else {
            throw DataLayerError.invalidDocument("Duplicate snapshot identity")
        }
        let allowed = Set(rootPaths)
        try database.write { db in
            // Publish the new enumeration as one small atomic visibility change. The temporary
            // table avoids SQLite variable limits for large libraries.
            try db.execute(sql: "DROP TABLE IF EXISTS temp.aie_current_snapshot")
            try db.execute(sql: "CREATE TEMP TABLE aie_current_snapshot(id TEXT PRIMARY KEY)")
            for id in documentIDs {
                try db.execute(
                    sql: "INSERT INTO aie_current_snapshot(id) VALUES(?)",
                    arguments: [id]
                )
            }
            for rootID in preservingRoots.filter({ allowed.contains($0) }).map(ContentIdentity.root) {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO aie_current_snapshot(id)
                    SELECT id FROM files WHERE root_id=? AND present=1
                    """,
                    arguments: [rootID]
                )
            }
            if rootPaths.isEmpty {
                try db.execute(sql: "UPDATE roots SET active=0")
                try db.execute(
                    sql: "UPDATE sources SET authorization_state='revoked',updated_at=?",
                    arguments: [Date().timeIntervalSince1970]
                )
            } else {
                let marks = rootPaths.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "UPDATE roots SET active=CASE WHEN path IN (" + marks + ") THEN 1 ELSE 0 END",
                    arguments: StatementArguments(rootPaths)
                )
                try db.execute(
                    sql: """
                    UPDATE sources
                    SET authorization_state=CASE WHEN locator IN (\(marks)) THEN 'authorized' ELSE 'revoked' END,
                        updated_at=?
                    """,
                    arguments: StatementArguments(rootPaths) + [Date().timeIntervalSince1970]
                )
            }
            try db.execute(sql: """
                UPDATE files
                SET present=CASE WHEN id IN (SELECT id FROM aie_current_snapshot) THEN 1 ELSE 0 END
                """)
            try db.execute(sql: """
                UPDATE items
                SET lifecycle_state=CASE
                    WHEN id IN (SELECT id FROM aie_current_snapshot) THEN 'present' ELSE 'missing' END,
                    updated_at=?
                """, arguments: [Date().timeIntervalSince1970])
            try db.execute(sql: """
                UPDATE item_locators
                SET state=CASE
                    WHEN item_id IN (SELECT id FROM aie_current_snapshot)
                     AND locator=(SELECT path FROM files WHERE files.id=item_locators.item_id)
                    THEN 'current' ELSE 'historical' END
                """)
            try Self.refreshExactDuplicateRelations(db: db)
            try Self.retireInactiveSearchChunks(db: db)
            try db.execute(sql: "DROP TABLE aie_current_snapshot")
        }
    }

    private func validate(documents: [SourceDocument], rootPaths: [String]) throws {
        let allowed = Set(rootPaths)
        var ids = Set<String>()
        for document in documents {
            guard allowed.contains(document.rootPath), ids.insert(document.id).inserted,
                  !document.contentHash.isEmpty, !document.relativePath.hasPrefix("/"),
                  !document.relativePath.split(separator: "/").contains(".."),
                  document.path.hasPrefix(document.rootPath + "/") else { throw DataLayerError.invalidDocument(document.path) }
            let keys = Set(document.blocks.map(\.key))
            guard keys.count == document.blocks.count, keys.contains("document"),
                  document.blocks.allSatisfy({ $0.parentKey == nil || (keys.contains($0.parentKey!) && $0.parentKey != $0.key) }) else {
                throw DataLayerError.invalidDocument("Invalid block hierarchy")
            }
            let parents = Dictionary(uniqueKeysWithValues: document.blocks.map { ($0.key, $0.parentKey) })
            for block in document.blocks {
                var visited = Set<String>(); var cursor: String? = block.key
                while let key = cursor {
                    guard visited.insert(key).inserted else { throw DataLayerError.invalidDocument("Cyclic block hierarchy") }
                    cursor = parents[key] ?? nil
                }
            }
        }
    }

    private func ensureRoots(_ rootPaths: [String]) throws {
        // Make new roots available to batched upserts, but keep the last complete visibility
        // snapshot intact until every document has committed. A crash can therefore leave extra
        // old results temporarily visible, never an empty or half-cleared library.
        try database.write { db in
            for path in rootPaths {
                try db.execute(sql: "INSERT INTO roots(id,path,active) VALUES(?,?,1) ON CONFLICT(id) DO UPDATE SET path=excluded.path",
                               arguments: [ContentIdentity.root(path), path])
            }
        }
    }

    private static func refreshExactDuplicateRelations(db: Database) throws {
        try db.execute(sql: "DELETE FROM relations WHERE relation_type='duplicate.exact'")
        let rows = try Row.fetchAll(db, sql: """
            SELECT v.content_hash,group_concat(f.id) AS item_ids
            FROM files f JOIN roots r ON r.id=f.root_id
            JOIN file_versions v ON v.id=f.current_version_id
            WHERE f.present=1 AND r.active=1
            GROUP BY v.content_hash HAVING count(DISTINCT f.id)>1
            """)
        let now = Date().timeIntervalSince1970
        for row in rows {
            let ids = (row["item_ids"] as String).split(separator: ",").map(String.init).sorted()
            guard ids.count > 1 else { continue }
            for leftIndex in 0..<(ids.count - 1) {
                for rightIndex in (leftIndex + 1)..<ids.count {
                    let left = ids[leftIndex], right = ids[rightIndex]
                    let relationID = ContentIdentity.digest("duplicate.exact:" + left + ":" + right)
                    try db.execute(sql: """
                        INSERT INTO relations(
                            id,from_subject_type,from_subject_id,relation_type,to_subject_type,to_subject_id,
                            confidence,evidence_unit_id,producer_run_id,state,created_at)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?)
                        """, arguments: [
                            relationID, "item", left, "duplicate.exact", "item", right,
                            1.0, nil, nil, "current", now,
                        ])
                }
            }
        }
    }

    /// Revoke roots without waiting for a new file enumeration. A later synchronize activates new roots.
    public func restrictRoots(to rootPaths: [String]) throws {
        try database.write { db in
            let placeholders = rootPaths.map { _ in "?" }.joined(separator: ",")
            let sourceArguments: StatementArguments = [Date().timeIntervalSince1970]
            try db.execute(sql: "UPDATE roots SET active=0 WHERE path NOT IN (" + placeholders + ")",
                           arguments: StatementArguments(rootPaths))
            try db.execute(sql: """
                UPDATE sources SET authorization_state='revoked',updated_at=?
                WHERE locator NOT IN (\(placeholders))
                """, arguments: sourceArguments + StatementArguments(rootPaths))
            try db.execute(sql: """
                UPDATE items SET lifecycle_state='missing',updated_at=?
                WHERE source_id IN (SELECT id FROM sources WHERE authorization_state='revoked')
                """, arguments: [Date().timeIntervalSince1970])
            try db.execute(sql: """
                UPDATE item_locators SET state='historical'
                WHERE source_id IN (SELECT id FROM sources WHERE authorization_state='revoked')
                """)
            try Self.retireInactiveSearchChunks(db: db)
        }
    }

    /// Derived search data is current-only. Version, analysis, trash and artifact records remain.
    /// Existing delete triggers remove the matching FTS, content units and vectors atomically.
    private static func retireInactiveSearchChunks(db: Database) throws {
        try db.execute(sql: """
            DELETE FROM chunks WHERE version_id NOT IN (
                SELECT f.current_version_id FROM files f JOIN roots r ON r.id=f.root_id
                WHERE f.present=1 AND r.active=1 AND f.current_version_id IS NOT NULL
            )
            """)
    }

    func upsert(_ doc: SourceDocument, db: Database) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let signature = ContentIdentity.digest(Data("embedding-source-v2:".utf8) + (try encoder.encode(doc)))
        let versionID = doc.versionID
        let previous = try String.fetchOne(db, sql: "SELECT import_signature FROM file_versions WHERE id=?", arguments: [versionID])
        try db.execute(sql: """
            INSERT INTO files(id,root_id,path,relative_path,kind,ext,size,modified_at,present) VALUES(?,?,?,?,?,?,?,?,1)
            ON CONFLICT(id) DO UPDATE SET root_id=excluded.root_id,path=excluded.path,relative_path=excluded.relative_path,
            kind=excluded.kind,ext=excluded.ext,size=excluded.size,modified_at=excluded.modified_at,present=1
            """, arguments: [doc.id, ContentIdentity.root(doc.rootPath), doc.path, doc.relativePath, doc.kind, doc.ext, doc.size, doc.modifiedAt])
        try db.execute(sql: """
            INSERT INTO file_versions(id,file_id,content_hash,size,created_at,coverage,import_signature) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET coverage=excluded.coverage,import_signature=excluded.import_signature
            """, arguments: [versionID, doc.id, doc.contentHash, doc.size, Date().timeIntervalSince1970, doc.coverage, signature])
        try db.execute(sql: "UPDATE files SET current_version_id=? WHERE id=?", arguments: [versionID, doc.id])
        // Re-adding a revoked/deleted file must restore its retired search projection.
        let hasChunks = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chunks WHERE version_id=?)",
                                          arguments: [versionID]) ?? false
        guard signature != previous || !hasChunks else { return }
        let blockIDs = Set(doc.blocks.map { ContentIdentity.chunk(versionID: versionID, key: $0.key) })
        for id in try String.fetchAll(db, sql: "SELECT id FROM chunks WHERE version_id=?", arguments: [versionID]) where !blockIDs.contains(id) {
            try db.execute(sql: "DELETE FROM chunks WHERE id=?", arguments: [id])
        }
        for block in doc.blocks {
            let id = ContentIdentity.chunk(versionID: versionID, key: block.key)
            let parent = block.parentKey.map { ContentIdentity.chunk(versionID: versionID, key: $0) }
            let isRoot = block.key == "document"
            let summary = isRoot ? doc.fileSummary : block.summary
            let keywords = isRoot ? doc.fileKeywords : block.tags
            let contentHash = ContentIdentity.digest([block.text, summary, keywords.joined(separator: "\n")].joined(separator: "\n"))
            try db.execute(sql: """
                DELETE FROM features INDEXED BY features_subject_lookup
                WHERE subject_type='content_unit' AND subject_id=? AND feature_type='text_embedding' AND content_hash<>?
                """, arguments: [id, contentHash])
            try db.execute(sql: """
                INSERT INTO chunks(id,version_id,parent_id,block_key,kind,page,start_seconds,end_seconds,location_json,text,content_hash,parser_version)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET parent_id=excluded.parent_id,kind=excluded.kind,
                page=excluded.page,start_seconds=excluded.start_seconds,end_seconds=excluded.end_seconds,
                location_json=excluded.location_json,text=excluded.text,content_hash=excluded.content_hash,parser_version=excluded.parser_version
                """, arguments: [id, versionID, parent, block.key, block.kind, block.page, block.startSeconds, block.endSeconds,
                                  block.locationJSON, block.text, contentHash, block.parserVersion])
            let keywordsJSON = String(data: try encoder.encode(keywords), encoding: .utf8)!
            try db.execute(sql: """
                INSERT INTO semantic_records(chunk_id,summary,keywords_json,method,model_id,model_version,updated_at) VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(chunk_id) DO UPDATE SET summary=excluded.summary,keywords_json=excluded.keywords_json,
                method=excluded.method,model_id=excluded.model_id,model_version=excluded.model_version,updated_at=excluded.updated_at
                """, arguments: [id, summary, keywordsJSON, isRoot ? "file_summary" : block.summaryMethod,
                                  isRoot ? doc.summaryModel : "local", isRoot ? doc.summaryVersion : block.parserVersion, Date().timeIntervalSince1970])
            try Self.upsertProjection(document: doc, block: block, chunkID: id, parentChunkID: parent,
                                      contentHash: contentHash, summary: summary, keywords: keywords, db: db)
        }
        for stage in doc.stages {
            try db.execute(sql: """
                INSERT INTO scan_jobs(version_id,stage,status,error,attempted_at,attempts) VALUES(?,?,?,?,?,?)
                ON CONFLICT(version_id,stage) DO UPDATE SET status=excluded.status,error=excluded.error,
                attempts=scan_jobs.attempts + CASE WHEN excluded.attempted_at IS NOT NULL AND excluded.attempted_at IS NOT scan_jobs.attempted_at THEN 1 ELSE 0 END,
                attempted_at=excluded.attempted_at
                """, arguments: [versionID, stage.stage, stage.status, stage.error, stage.attemptedAt, stage.attemptedAt == nil ? 0 : 1])
        }
        try Self.upsertOperationalRecords(document: doc, db: db)
    }

    private static func upsertOperationalRecords(document doc: SourceDocument, db: Database) throws {
        let now = Date().timeIntervalSince1970
        let versionID = doc.versionID
        var jobIDs: [String: String] = [:]
        for stage in doc.stages {
            let jobID = ContentIdentity.digest(versionID + ":" + stage.stage + ":" + doc.contentHash)
            jobIDs[stage.stage] = jobID
            let state: String
            switch stage.status {
            case "ready", "usable", "available": state = "succeeded"
            case "failed", "needs_review", "limited", "empty": state = "failed"
            case "unsupported": state = "cancelled"
            default: state = "pending"
            }
            try db.execute(sql: """
                INSERT INTO jobs(
                    id,subject_type,subject_id,job_type,priority,state,attempt_count,not_before,
                    lease_owner,lease_expires_at,input_hash,error_code,created_at,updated_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(subject_type,subject_id,job_type,input_hash) DO UPDATE SET
                    priority=excluded.priority,
                    state=CASE
                        WHEN excluded.state IN ('succeeded','cancelled') THEN excluded.state
                        WHEN jobs.state='running' AND jobs.lease_expires_at>? THEN jobs.state
                        WHEN jobs.state='pending' AND jobs.not_before>? THEN jobs.state
                        ELSE excluded.state
                    END,
                    attempt_count=max(jobs.attempt_count,excluded.attempt_count),
                    error_code=excluded.error_code,updated_at=excluded.updated_at
                """, arguments: [
                    jobID, "item_version", versionID, stage.stage, jobPriority(stage.stage), state,
                    stage.attemptedAt == nil ? 0 : 1, 0, nil, nil, doc.contentHash,
                    stage.error, now, now, now, now,
                ])
        }

        var runIDs: [String: String] = [:]
        for run in doc.processorRuns {
            let runID = ContentIdentity.digest([
                versionID, run.jobType, run.processorKey, run.processorVersion,
                run.inputFingerprint, String(run.startedAt),
            ].joined(separator: ":"))
            runIDs[run.jobType] = runID
            try db.execute(sql: """
                INSERT INTO model_runs(
                    id,job_id,processor_key,processor_version,model_key,model_revision,prompt_version,
                    input_fingerprint,parameters_json,started_at,finished_at,duration_ms,outcome,error_code)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET finished_at=excluded.finished_at,duration_ms=excluded.duration_ms,
                    outcome=excluded.outcome,error_code=excluded.error_code
                """, arguments: [
                    runID, jobIDs[run.jobType], run.processorKey, run.processorVersion,
                    run.modelKey, run.modelRevision, run.promptVersion, run.inputFingerprint,
                    run.parametersJSON, run.startedAt, run.finishedAt, run.durationMS,
                    run.outcome, run.errorCode,
                ])
        }

        let chunkIDs = doc.blocks.map { ContentIdentity.chunk(versionID: versionID, key: $0.key) }
        if !chunkIDs.isEmpty {
            let marks = chunkIDs.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM observations WHERE (subject_type='item_version' AND subject_id=?) OR (subject_type='content_unit' AND subject_id IN (" + marks + "))",
                arguments: StatementArguments([versionID] + chunkIDs)
            )
        }
        let blockIDs = Dictionary(uniqueKeysWithValues: doc.blocks.map {
            ($0.key, ContentIdentity.chunk(versionID: versionID, key: $0.key))
        })
        for observation in doc.observations {
            guard observation.valueText != nil || observation.valueNumber != nil || observation.valueJSON != nil else { continue }
            let subjectType = observation.subjectBlockKey == nil ? "item_version" : "content_unit"
            let subjectID = observation.subjectBlockKey.flatMap { blockIDs[$0] } ?? versionID
            let identityValue = observation.valueText
                ?? observation.valueNumber.map { String($0) }
                ?? observation.valueJSON
                ?? ""
            let observationID = ContentIdentity.digest(
                [subjectType, subjectID, observation.type, identityValue].joined(separator: ":")
            )
            try db.execute(sql: """
                INSERT INTO observations(
                    id,subject_type,subject_id,observation_type,value_text,value_number,value_json,
                    confidence,producer_run_id,state,created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET value_text=excluded.value_text,value_number=excluded.value_number,
                    value_json=excluded.value_json,confidence=excluded.confidence,
                    producer_run_id=excluded.producer_run_id,state=excluded.state
                """, arguments: [
                    observationID, subjectType, subjectID, observation.type,
                    observation.valueText, observation.valueNumber, observation.valueJSON,
                    observation.confidence, observation.producerJobType.flatMap { runIDs[$0] },
                    observation.state, now,
                ])
        }

        let hashFeatureID = ContentIdentity.digest(versionID + ":feature:content.sha256")
        try db.execute(sql: """
            INSERT INTO features(
                id,subject_type,subject_id,feature_type,model_key,model_revision,dimensions,metric,
                vector_blob,content_hash,producer_run_id,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(subject_type,subject_id,feature_type,model_key,model_revision)
            DO UPDATE SET content_hash=excluded.content_hash,created_at=excluded.created_at
            """, arguments: [
                hashFeatureID, "item_version", versionID, "content.sha256", "CryptoKit.SHA256", "1",
                nil, "exact", nil, doc.contentHash, nil, now,
            ])
    }

    private static func jobPriority(_ stage: String) -> Int {
        switch stage {
        case "index": return 100
        case "local", "transcript": return 80
        case "deep": return 50
        case "quick": return 40
        default: return 10
        }
    }

    private static func upsertProjection(row: Row, db: Database) throws {
        let keywords: [String] = (try? JSONDecoder().decode([String].self, from: Data((row["keywords_json"] as String).utf8))) ?? []
        let versionID: String = row["version_id"]
        let chunkID: String = row["id"]
        let parentID: String? = row["parent_id"]
        let blockKey: String = row["block_key"]
        let block = ContentBlock(
            key: blockKey,
            parentKey: nil,
            kind: row["kind"],
            page: row["page"],
            startSeconds: row["start_seconds"],
            endSeconds: row["end_seconds"],
            locationJSON: row["location_json"],
            text: row["text"],
            tags: keywords,
            summary: row["summary"],
            parserVersion: row["parser_version"])
        let rootPath: String = row["root_path"]
        let path: String = row["path"]
        let relative: String = row["relative_path"]
        let doc = SourceDocument(
            id: row["file_id"], rootPath: rootPath, path: path, relativePath: relative,
            kind: row["file_kind"], ext: row["ext"], contentHash: row["version_hash"],
            size: 0, modifiedAt: row["modified_at"], blocks: [block])
        try upsertProjection(document: doc, block: block, chunkID: chunkID, parentChunkID: parentID,
                             contentHash: row["content_hash"], summary: row["summary"],
                             keywords: keywords, versionID: versionID, db: db)
    }

    private static func upsertProjection(document doc: SourceDocument, block: ContentBlock, chunkID: String,
                                         parentChunkID: String?, contentHash: String, summary: String,
                                         keywords: [String], versionID: String? = nil, db: Database) throws {
        let now = Date().timeIntervalSince1970
        let sourceID = ContentIdentity.root(doc.rootPath)
        let sourceName = URL(fileURLWithPath: doc.rootPath).lastPathComponent
        try db.execute(sql: """
            INSERT INTO sources(id,kind,locator,display_name,authorization_state,scan_policy,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET locator=excluded.locator,display_name=excluded.display_name,
            authorization_state=excluded.authorization_state,updated_at=excluded.updated_at
            """, arguments: [sourceID, "folder", doc.rootPath, sourceName.isEmpty ? doc.rootPath : sourceName, "authorized", "local_first", now, now])
        try db.execute(sql: """
            INSERT INTO items(id,source_id,stable_key,kind,current_version_id,lifecycle_state,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET source_id=excluded.source_id,stable_key=excluded.stable_key,
            kind=excluded.kind,current_version_id=excluded.current_version_id,lifecycle_state='present',updated_at=excluded.updated_at
            """, arguments: [doc.id, sourceID, doc.id, doc.kind, versionID ?? doc.versionID, "present", now, now])
        let locatorID = ContentIdentity.digest(doc.id + ":" + doc.path)
        try db.execute(sql: """
            INSERT INTO item_locators(id,item_id,source_id,locator,volume_identifier,file_resource_identifier,first_seen_at,last_seen_at,state)
            VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(item_id,locator) DO UPDATE SET last_seen_at=excluded.last_seen_at,state=excluded.state
            """, arguments: [locatorID, doc.id, sourceID, doc.path, nil, nil, now, now, "current"])
        let anchor = anchorJSON(block)
        let ordinal = projectionOrdinal(block)
        let role = block.key == "document" ? "document" : "evidence"
        let title = projectionTitle(document: doc, block: block)
        try db.execute(sql: """
            INSERT INTO content_units(id,item_version_id,parent_unit_id,unit_type,role,ordinal,title,anchor_json,content_hash,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET parent_unit_id=excluded.parent_unit_id,unit_type=excluded.unit_type,
            role=excluded.role,ordinal=excluded.ordinal,title=excluded.title,anchor_json=excluded.anchor_json,
            content_hash=excluded.content_hash
            """, arguments: [chunkID, versionID ?? doc.versionID, parentChunkID, block.kind, role, ordinal, title, anchor, contentHash, now])
        let contentType = unitContentType(block)
        if ["model_observation", "system_observation"].contains(contentType) {
            try db.execute(sql: "DELETE FROM unit_contents WHERE unit_id=?", arguments: [chunkID])
        } else {
            let unitContentID = ContentIdentity.digest(chunkID + ":" + contentType + ":primary")
            try db.execute(sql: """
                INSERT INTO unit_contents(id,unit_id,content_type,text,language,confidence,producer_run_id,is_primary,created_at)
                VALUES(?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET content_type=excluded.content_type,text=excluded.text,
                language=excluded.language,confidence=excluded.confidence,is_primary=excluded.is_primary
                """, arguments: [unitContentID, chunkID, contentType, block.text, nil, nil, nil, 1, now])
        }
        try upsertSearchDocument(document: doc, block: block, chunkID: chunkID, versionID: versionID ?? doc.versionID,
                                 title: title, contentType: contentType, summary: summary, keywords: keywords,
                                 db: db, now: now)
    }

    private static func upsertSearchDocument(document doc: SourceDocument, block: ContentBlock, chunkID: String,
                                             versionID: String, title: String, contentType: String,
                                             summary: String, keywords: [String], db: Database, now: Double) throws {
        let filename = URL(fileURLWithPath: doc.path).lastPathComponent
        let body = contentType == "native_text" ? block.text : ""
        let ocr = contentType == "ocr_text" ? block.text : ""
        let chart = contentType == "chart_text" ? block.text : ""
        let transcript = contentType == "transcript" ? block.text : ""
        let relatedObservations = doc.observations.filter {
            $0.state == "current"
                && ($0.subjectBlockKey == block.key || ($0.subjectBlockKey == nil && block.key == "document"))
        }
        let entityText = relatedObservations.filter { $0.type == "entity" }.compactMap(\.valueText).joined(separator: " ")
        let observedKeywords = relatedObservations.filter {
            ["keyword", "topic", "visual.object", "visual.action", "visual.scene", "content.type"].contains($0.type)
        }.compactMap(\.valueText)
        let keywordText = (keywords + observedKeywords).joined(separator: " ")
        let rawFields = [filename, doc.relativePath, title, body, ocr, chart, transcript, summary, keywordText, entityText]
        let identifiers = NumericSearch.runs(rawFields.joined(separator: "\n")).joined(separator: " ")
        try db.execute(sql: """
            INSERT INTO search_documents(
                id,item_id,item_version_id,unit_id,filename,path_text,title,body_text,ocr_text,chart_text,
                transcript_text,summary_text,keywords,entity_names,item_type,modified_at,importance,identifiers,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(unit_id) DO UPDATE SET filename=excluded.filename,path_text=excluded.path_text,
            title=excluded.title,body_text=excluded.body_text,ocr_text=excluded.ocr_text,chart_text=excluded.chart_text,
            transcript_text=excluded.transcript_text,summary_text=excluded.summary_text,
            keywords=excluded.keywords,entity_names=excluded.entity_names,
            item_type=excluded.item_type,modified_at=excluded.modified_at,importance=excluded.importance,
            identifiers=excluded.identifiers,updated_at=excluded.updated_at
            """, arguments: [chunkID, doc.id, versionID, chunkID, filename, doc.relativePath, title, body, ocr, chart,
                              transcript, summary, keywordText, entityText, doc.kind, doc.modifiedAt, block.key == "document" ? 0.5 : 1.0,
                              identifiers, now])
        try db.execute(sql: """
            UPDATE search_documents
            SET fts_rowid=(SELECT coalesce(max(fts_rowid),0)+1 FROM search_documents)
            WHERE unit_id=? AND fts_rowid IS NULL
            """, arguments: [chunkID])
        guard let ftsRowID = try Int64.fetchOne(
            db, sql: "SELECT fts_rowid FROM search_documents WHERE unit_id=?",
            arguments: [chunkID]
        ) else { throw DataLayerError.invalidDocument("Missing FTS row identity") }
        try db.execute(sql: "DELETE FROM search_documents_fts WHERE rowid=?", arguments: [ftsRowID])
        try db.execute(sql: """
            INSERT INTO search_documents_fts(rowid,search_document_id,filename,path_text,title,body_text,ocr_text,chart_text,transcript_text,summary_text,keywords,entity_names,identifiers)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, arguments: [ftsRowID, chunkID, SearchEncoding.encode(filename), SearchEncoding.encode(doc.relativePath),
                              SearchEncoding.encode(title), SearchEncoding.encode(body), SearchEncoding.encode(ocr),
                              SearchEncoding.encode(chart), SearchEncoding.encode(transcript), SearchEncoding.encode(summary),
                              SearchEncoding.encode(keywordText), SearchEncoding.encode(entityText), identifiers])
    }

    private static func unitContentType(_ block: ContentBlock) -> String {
        let kind = block.kind.lowercased()
        if kind == "semantic_analysis" { return "model_observation" }
        if kind == "system_visual_labels" { return "system_observation" }
        if kind.contains("ocr") || kind.contains("image") || kind.contains("frame") { return "ocr_text" }
        if kind.contains("sheet") || kind.contains("table") || kind.contains("chart") { return "chart_text" }
        if kind.contains("transcript") || kind.contains("audio") { return "transcript" }
        return "native_text"
    }

    private static func projectionOrdinal(_ block: ContentBlock) -> Int {
        if let page = block.page { return page }
        if let seconds = block.startSeconds { return Int(seconds * 1000) }
        return block.key == "document" ? 0 : abs(block.key.hashValue % 1_000_000)
    }

    private static func projectionTitle(document doc: SourceDocument, block: ContentBlock) -> String {
        if block.key == "document" { return URL(fileURLWithPath: doc.path).lastPathComponent }
        if let page = block.page { return "第 \(page) 页" }
        if let start = block.startSeconds, let end = block.endSeconds { return "\(Int(start))–\(Int(end)) 秒" }
        return block.kind
    }

    private static func anchorJSON(_ block: ContentBlock) -> String? {
        if let location = block.locationJSON, !location.isEmpty { return location }
        var object: [String: Any] = [:]
        if let page = block.page {
            object[block.kind == "slide" ? "slide" : "page"] = page
        }
        if let start = block.startSeconds { object["start_ms"] = Int(start * 1000) }
        if let end = block.endSeconds { object["end_ms"] = Int(end * 1000) }
        guard !object.isEmpty, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static let selectChunk = """
        SELECT c.*,f.id AS file_id,f.path,f.relative_path,s.summary,s.keywords_json FROM chunks c
        JOIN files f ON f.current_version_id=c.version_id JOIN roots r ON r.id=f.root_id
        JOIN semantic_records s ON s.chunk_id=c.id
        """
    private func authorization(_ roots: [String]) -> (String, StatementArguments) {
        let ids = roots.map(ContentIdentity.root)
        return ("f.present=1 AND r.active=1 AND f.root_id IN (" + ids.map { _ in "?" }.joined(separator: ",") + ")", StatementArguments(ids))
    }

    public func cachedSourceBlocks(versionID: String, parserVersion: String) throws -> [ContentBlock]? {
        try database.read { db in
            guard try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM file_versions WHERE id=?)",
                arguments: [versionID]
            ) == true else { return nil }
            let decoder = JSONDecoder()
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.block_key,c.kind,c.page,c.start_seconds,c.end_seconds,c.location_json,c.text,
                       c.parser_version,p.block_key AS parent_key,
                       coalesce(s.summary,'') AS summary,coalesce(s.keywords_json,'[]') AS keywords_json,
                       coalesce(s.method,'extractive') AS summary_method
                FROM chunks c
                LEFT JOIN chunks p ON p.id=c.parent_id
                LEFT JOIN semantic_records s ON s.chunk_id=c.id
                WHERE c.version_id=? AND c.block_key<>'document'
                  AND (c.parser_version=? OR (p.parser_version=? AND c.parser_version='structure-1'))
                ORDER BY c.rowid
                """, arguments: [versionID, parserVersion, parserVersion])
            guard !rows.isEmpty else { return nil }
            return rows.map { row in
                    let keywordsJSON: String = row["keywords_json"]
                    return ContentBlock(
                        key: row["block_key"], parentKey: row["parent_key"], kind: row["kind"],
                        page: row["page"], startSeconds: row["start_seconds"], endSeconds: row["end_seconds"],
                        locationJSON: row["location_json"], text: row["text"],
                        tags: (try? decoder.decode([String].self, from: Data(keywordsJSON.utf8))) ?? [],
                        summary: row["summary"], summaryMethod: row["summary_method"],
                        parserVersion: row["parser_version"]
                    )
                }
        }
    }

    public func chunks(rootPaths: [String]) throws -> [ChunkResult] {
        guard !rootPaths.isEmpty else { return [] }
        let (whereSQL, args) = authorization(rootPaths)
        return try database.read { db in
            try Row.fetchAll(db, sql: Self.selectChunk + " WHERE " + whereSQL + " ORDER BY f.path,c.page,c.block_key", arguments: args).map { self.result($0) }
        }
    }

    /// Metadata only: no filesystem enumeration, parsing or projection updates.
    public func indexedFileMetadata(rootPaths: [String]) throws -> [IndexedFileMetadata] {
        guard !rootPaths.isEmpty else { return [] }
        let (whereSQL, args) = authorization(rootPaths)
        return try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id,f.path,f.relative_path,r.path AS root_path,f.kind,f.ext,f.size,f.modified_at,
                       v.id AS version_id,v.content_hash
                FROM files f JOIN roots r ON r.id=f.root_id
                JOIN file_versions v ON v.id=f.current_version_id
                WHERE \(whereSQL) ORDER BY f.path
                """, arguments: args).map { row in
                    IndexedFileMetadata(fileID: row["id"], versionID: row["version_id"],
                        contentHash: row["content_hash"], path: row["path"], relativePath: row["relative_path"],
                        rootPath: row["root_path"], kind: row["kind"], ext: row["ext"],
                        size: row["size"], modifiedAt: row["modified_at"])
                }
        }
    }

    /// Check the pool's primary connection, not only an implicitly read-only reader.
    /// The no-row probe must be rejected by SQLite before evaluation is allowed to proceed.
    public func verifyReadOnlyAccess() throws {
        guard isReadOnly else { throw DataLayerError.invalidDocument("Evaluation database is not read-only") }
        try database.writeWithoutTransaction { db in
            guard db.configuration.readonly,
                  try Int.fetchOne(db, sql: "PRAGMA query_only") == 1 else {
                throw DataLayerError.invalidDocument("SQLite read-only protection is unavailable")
            }
            do {
                try db.execute(sql: "UPDATE files SET present=present WHERE 0")
            } catch let error as DatabaseError where error.resultCode == .SQLITE_READONLY {
                return
            }
            throw DataLayerError.invalidDocument("SQLite unexpectedly accepted the write probe")
        }
    }

    /// Current entity observations grouped by their source file. Used by local,
    /// source-backed completion without reconstructing the original scan payload.
    public func entityNames(rootPaths: [String], limitPerFile: Int = 24) throws -> [String: [String]] {
        guard !rootPaths.isEmpty, limitPerFile > 0 else { return [:] }
        let whereSQL = "f.present=1 AND r.active=1 AND r.path IN (" + rootPaths.map { _ in "?" }.joined(separator: ",") + ")"
        let args = StatementArguments(rootPaths)
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.path,o.value_text
                FROM observations o
                JOIN file_versions v ON v.id=o.subject_id
                JOIN files f ON f.current_version_id=v.id
                JOIN roots r ON r.id=f.root_id
                WHERE \(whereSQL) AND o.observation_type='entity'
                  AND o.state='current' AND o.value_text IS NOT NULL
                ORDER BY f.path,o.created_at DESC
                """, arguments: args)
            var result: [String: [String]] = [:]
            for row in rows {
                let path: String = row["path"]
                let value: String = row["value_text"]
                guard result[path, default: []].count < limitPerFile,
                      !result[path, default: []].contains(value) else { continue }
                result[path, default: []].append(value)
            }
            return result
        }
    }

    /// Each allTerms group is a set of synonyms. Every group must match; anyTerms is an optional OR group.
    public func search(allTerms: [[String]], anyTerms: [String] = [], rootPaths: [String], limit: Int = 120) throws -> [ChunkResult] {
        try searchProjected(allTerms: allTerms, anyTerms: anyTerms, rootPaths: rootPaths, limit: limit)
    }

    private func searchProjected(allTerms: [[String]], anyTerms: [String], rootPaths: [String], limit: Int) throws -> [ChunkResult] {
        guard !rootPaths.isEmpty else { return [] }
        let sourceColumns = "{filename body_text ocr_text transcript_text chart_text}:"
        let groups = allTerms + (anyTerms.isEmpty ? [] : [anyTerms])
        let clauses = groups.compactMap { group -> String? in
            let terms = group.compactMap(SearchEncoding.expression).map { sourceColumns + $0 }
            return terms.isEmpty ? nil : "(" + terms.joined(separator: " OR ") + ")"
        }
        guard !clauses.isEmpty else { return [] }
        let (whereSQL, args) = authorization(rootPaths)
        return try database.read { db in
            var numericChecks: [String] = []
            var checksArguments = StatementArguments()
            for group in groups where group.contains(where: { NumericSearch.term($0) != nil }) {
                var alternatives: [String] = []
                for term in group {
                    if let number = NumericSearch.term(term) {
                        alternatives.append("instr(CASE WHEN c.kind='document' THEN sd.filename ELSE search_documents_fts.identifiers END,?)>0")
                        checksArguments += [number]
                    } else if let expression = SearchEncoding.expression(term) {
                        alternatives.append("sd.id IN (SELECT search_document_id FROM search_documents_fts WHERE search_documents_fts MATCH ?)")
                        checksArguments += [sourceColumns + expression]
                    }
                }
                numericChecks.append("(" + alternatives.joined(separator: " OR ") + ")")
            }
            let verification = numericChecks.isEmpty ? "" : " AND " + numericChecks.joined(separator: " AND ")
            let sql = """
                SELECT c.*,f.id AS file_id,f.path,f.relative_path,'' AS summary,'[]' AS keywords_json
                FROM search_documents_fts
                JOIN search_documents sd ON sd.id=search_documents_fts.search_document_id
                JOIN content_units cu ON cu.id=sd.unit_id
                JOIN chunks c ON c.id=cu.id
                JOIN files f ON f.current_version_id=c.version_id
                JOIN roots r ON r.id=f.root_id
                WHERE \(whereSQL) AND c.kind IN ('document','paragraph','page','page_text','slide','slide_text',
                    'sheet_rows','table_text','xml_text','archive_text','message_body','transcript','transcript_excerpt',
                    'image_ocr','frame_ocr')
                    AND search_documents_fts MATCH ?\(verification)
                ORDER BY bm25(search_documents_fts,0.0,10.0,1.2,6.0,1.5,1.1,1.2,1.5,0.6,0.7,0.7,0.0),
                         f.path,c.page LIMIT ?
                """
            let searchArguments = StatementArguments([clauses.joined(separator: " AND ")]) + checksArguments + [min(max(limit, 1), 1000)]
            return try Row.fetchAll(db, sql: sql, arguments: args + searchArguments)
                .enumerated().map { self.result($0.element, score: Double(1000 - $0.offset)) }
        }
    }

    public func chunk(id: String, rootPaths: [String]) throws -> ChunkResult? {
        guard !rootPaths.isEmpty else { return nil }
        let (whereSQL, args) = authorization(rootPaths)
        return try database.read { db in
            try Row.fetchOne(db, sql: Self.selectChunk + " WHERE " + whereSQL + " AND c.id=?", arguments: args + [id]).map { self.result($0) }
        }
    }

    /// File-level DeepScan summaries only; both the stored source hash and its projection must match.
    public func deepScanEmbeddingInputs(
        spaceID: String, legacySpaceID: String, modelID: String, modelVersion: String,
        dimensions: Int, rootPaths: [String]
    ) throws -> [(chunk: ChunkResult, vector: [Float]?, indexed: Bool)] {
        guard !rootPaths.isEmpty else { return [] }
        let (clause, args) = authorization(rootPaths)
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.*,f.id AS file_id,f.path,f.relative_path,s.summary,s.keywords_json,
                       x.vector_blob AS indexed_vector,old.vector_blob AS reusable_vector
                FROM chunks c JOIN files f ON f.current_version_id=c.version_id
                JOIN roots r ON r.id=f.root_id JOIN file_versions v ON v.id=c.version_id
                JOIN semantic_records s ON s.chunk_id=c.id
                JOIN analysis_records a ON f.path=a.root_path||'/'||a.relative_path
                JOIN analysis_fields d ON d.record_id=a.id AND d.parent_id=0 AND d.name='deepScan'
                JOIN analysis_fields p ON p.record_id=a.id AND p.parent_id=d.node_id AND p.name='parse'
                JOIN analysis_fields h ON h.record_id=a.id AND h.parent_id=p.node_id AND h.name='sourceHash'
                JOIN analysis_fields b ON b.record_id=a.id AND b.parent_id=d.node_id AND b.name='blurb_zh'
                JOIN analysis_fields m ON m.record_id=a.id AND m.parent_id=p.node_id AND m.name='model'
                JOIN analysis_fields pv ON pv.record_id=a.id AND pv.parent_id=p.node_id AND pv.name='parserVersion'
                LEFT JOIN features x ON x.subject_type='content_unit' AND x.subject_id=c.id
                    AND x.feature_type='text_embedding' AND x.model_key=? AND x.model_revision=?
                    AND x.model_identifier=? AND x.dimensions=? AND x.vector_format=?
                    AND x.metric='cosine' AND x.content_hash=c.content_hash
                LEFT JOIN features old ON old.subject_type='content_unit' AND old.subject_id=c.id
                    AND old.feature_type='text_embedding' AND old.model_key=? AND old.model_revision=?
                    AND old.model_identifier=? AND old.dimensions=? AND old.vector_format=?
                    AND old.metric='cosine' AND old.content_hash=c.content_hash
                WHERE \(clause) AND c.kind='document' AND s.method='file_summary'
                    AND h.text_value=v.content_hash AND b.text_value=s.summary AND trim(s.summary)<>''
                    AND lower(m.text_value) LIKE '%8b%' AND s.model_id=m.text_value
                    AND s.model_version=pv.text_value
                ORDER BY f.path
                """, arguments: [spaceID, modelVersion, modelID, dimensions, VectorCodec.format,
                                   legacySpaceID, modelVersion, modelID, dimensions, VectorCodec.format] + args)
            return rows.map { row in
                func vector(_ column: String) -> [Float]? {
                    guard let blob = row[column] as Data? else { return nil }
                    return try? VectorCodec.decode(blob, expectedDimensions: dimensions)
                }
                let indexed = vector("indexed_vector")
                return (self.result(row), indexed ?? vector("reusable_vector"), indexed != nil)
            }
        }
    }

    /// Model adapters supply real vectors. No zero vectors or invented embeddings are generated here.
    public func putEmbedding(chunkID: String, spaceID: String, modelID: String, modelVersion: String,
                             vector: [Float], rootPaths: [String], expectedContentHash: String? = nil,
                             featureType: String = "text_embedding") throws {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }),
              !spaceID.isEmpty, !modelID.isEmpty else { throw DataLayerError.invalidEmbedding }
        let data = try VectorCodec.encode(vector)
        guard try chunk(id: chunkID, rootPaths: rootPaths) != nil else { throw DataLayerError.missingChunk }
        try database.write { db in
            let (clause, auth) = self.authorization(rootPaths)
            guard try Row.fetchOne(db, sql: Self.selectChunk + " WHERE " + clause + " AND c.id=?", arguments: auth + [chunkID]) != nil else { throw DataLayerError.staleVersion }
            if let row = try Row.fetchOne(db, sql: """
                SELECT model_identifier,model_revision,dimensions FROM features
                WHERE feature_type=? AND model_key=? LIMIT 1
                """, arguments: [featureType, spaceID]) {
                guard row["model_identifier"] as String? == modelID,
                      row["model_revision"] as String == modelVersion,
                      row["dimensions"] as Int == vector.count else {
                    throw DataLayerError.invalidEmbedding
                }
            }
            let hash = try String.fetchOne(db, sql: "SELECT content_hash FROM chunks WHERE id=?", arguments: [chunkID])!
            if let expectedContentHash, hash != expectedContentHash { throw DataLayerError.staleVersion }
            let featureID = ContentIdentity.digest(
                [chunkID, featureType, spaceID, modelVersion].joined(separator: ":")
            )
            try db.execute(sql: """
                INSERT INTO features(
                    id,subject_type,subject_id,feature_type,model_key,model_revision,dimensions,
                    metric,vector_blob,content_hash,producer_run_id,created_at,vector_format,
                    model_identifier)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(subject_type,subject_id,feature_type,model_key,model_revision)
                DO UPDATE SET dimensions=excluded.dimensions,metric=excluded.metric,
                    vector_blob=excluded.vector_blob,content_hash=excluded.content_hash,
                    created_at=excluded.created_at,vector_format=excluded.vector_format,
                    model_identifier=excluded.model_identifier
                """, arguments: [
                    featureID, "content_unit", chunkID, featureType, spaceID, modelVersion,
                    vector.count, "cosine", data, hash, nil, Date().timeIntervalSince1970,
                    VectorCodec.format, modelID,
                ])
        }
    }

    /// Exact cosine retrieval for local collections; the model/version namespace must match at both ends.
    public func searchVector(_ vector: [Float], spaceID: String, rootPaths: [String], limit: Int = 20) throws -> [ChunkResult] {
        try searchVectorProfiled(
            vector, spaceID: spaceID, rootPaths: rootPaths, limit: limit
        ).matches
    }

    public func searchVectorProfiled(
        _ vector: [Float], spaceID: String, rootPaths: [String], limit: Int = 20,
        featureType: String = "text_embedding", v1RawTextOnly: Bool = false
    ) throws -> VectorSearchOutput {
        func emptyOutput() -> VectorSearchOutput {
            VectorSearchOutput(
                matches: [],
                diagnostics: VectorSearchDiagnostics(
                    scannedVectors: 0, connectionWaitMilliseconds: 0,
                    metadataReadMilliseconds: 0, candidateReadMilliseconds: 0,
                    cosineMilliseconds: 0, detailReadMilliseconds: 0,
                    totalMilliseconds: 0, highestScore: nil, lowestTopScore: nil
                )
            )
        }
        guard !rootPaths.isEmpty else { return emptyOutput() }
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { throw DataLayerError.invalidEmbedding }
        guard vector.contains(where: { $0 != 0 }) else { throw DataLayerError.invalidEmbedding }
        guard limit > 0 else { return emptyOutput() }
        let (authorizedSQL, args) = authorization(rootPaths)
        let whereSQL = authorizedSQL + (v1RawTextOnly ? " AND " + Self.v1RawTextScope : "")
        let totalStarted = ProcessInfo.processInfo.systemUptime
        return try database.read { db in
            let connectionWait = (ProcessInfo.processInfo.systemUptime - totalStarted) * 1_000
            let metadataStarted = ProcessInfo.processInfo.systemUptime
            guard let dimensions = try Int.fetchOne(db, sql: """
                SELECT dimensions FROM features
                WHERE feature_type=? AND model_key=? AND vector_format=?
                LIMIT 1
                """, arguments: [featureType, spaceID, VectorCodec.format]) else {
                let total = (ProcessInfo.processInfo.systemUptime - totalStarted) * 1_000
                return VectorSearchOutput(
                    matches: [],
                    diagnostics: VectorSearchDiagnostics(
                        scannedVectors: 0, connectionWaitMilliseconds: connectionWait,
                        metadataReadMilliseconds:
                            (ProcessInfo.processInfo.systemUptime - metadataStarted) * 1_000,
                        candidateReadMilliseconds: 0, cosineMilliseconds: 0,
                        detailReadMilliseconds: 0, totalMilliseconds: total,
                        highestScore: nil, lowestTopScore: nil
                    )
                )
            }
            guard dimensions == vector.count else { throw DataLayerError.invalidEmbedding }
            let metadataRead = (ProcessInfo.processInfo.systemUptime - metadataStarted) * 1_000
            let workspaceStarted = ProcessInfo.processInfo.systemUptime
            if let workspace = try vectorWorkspace(
                db: db, spaceID: spaceID, featureType: featureType, dimensions: dimensions, rootPaths: rootPaths,
                whereSQL: whereSQL, arguments: args
            ) {
                let candidateRead = (ProcessInfo.processInfo.systemUptime - workspaceStarted) * 1_000
                let cosineStarted = ProcessInfo.processInfo.systemUptime
                let matches = workspace.ids.isEmpty ? [] : try ExactVectorIndex.topMatches(
                    query: vector, ids: workspace.ids, matrix: workspace.matrix,
                    dimensions: dimensions, limit: limit
                )
                let cosine = (ProcessInfo.processInfo.systemUptime - cosineStarted) * 1_000
                guard !matches.isEmpty else {
                    let total = (ProcessInfo.processInfo.systemUptime - totalStarted) * 1_000
                    return VectorSearchOutput(
                        matches: [],
                        diagnostics: VectorSearchDiagnostics(
                            scannedVectors: workspace.ids.count,
                            connectionWaitMilliseconds: connectionWait,
                            metadataReadMilliseconds: metadataRead,
                            candidateReadMilliseconds: candidateRead,
                            cosineMilliseconds: cosine, detailReadMilliseconds: 0,
                            totalMilliseconds: total, highestScore: nil, lowestTopScore: nil
                        )
                    )
                }
                let detailStarted = ProcessInfo.processInfo.systemUptime
                let placeholders = matches.map { _ in "?" }.joined(separator: ",")
                let detailRows = try Row.fetchAll(
                    db, sql: Self.selectChunk + " WHERE " + whereSQL
                        + " AND c.id IN (" + placeholders + ")",
                    arguments: args + StatementArguments(matches.map(\.id))
                )
                let details = Dictionary(uniqueKeysWithValues: detailRows.map {
                    ($0["id"] as String, $0)
                })
                let result = matches.compactMap { match in
                    details[match.id].map { self.result($0, score: match.score) }
                }
                let detailRead = (ProcessInfo.processInfo.systemUptime - detailStarted) * 1_000
                let total = (ProcessInfo.processInfo.systemUptime - totalStarted) * 1_000
                return VectorSearchOutput(
                    matches: result,
                    diagnostics: VectorSearchDiagnostics(
                        scannedVectors: workspace.ids.count,
                        connectionWaitMilliseconds: connectionWait,
                        metadataReadMilliseconds: metadataRead,
                        candidateReadMilliseconds: candidateRead,
                        cosineMilliseconds: cosine, detailReadMilliseconds: detailRead,
                        totalMilliseconds: total, highestScore: matches.first?.score,
                        lowestTopScore: matches.last?.score
                    )
                )
            }
            // Keep root/current-version filtering ahead of vector blobs. Letting SQLite start
            // with features reads every library's vectors even when only one root is searched.
            let sql = """
                SELECT c.id,x.vector_blob
                FROM files f JOIN roots r ON r.id=f.root_id
                CROSS JOIN chunks c ON c.version_id=f.current_version_id
                CROSS JOIN features x ON x.subject_type='content_unit' AND x.subject_id=c.id
                    AND x.content_hash=c.content_hash AND x.feature_type=?
                WHERE \(whereSQL) AND x.model_key=? AND x.vector_format=?
                """
            let rows = try Row.fetchCursor(
                db, sql: sql, arguments: [featureType] + args + [spaceID, VectorCodec.format]
            )
            var candidateRead = 0.0
            var scannedVectors = 0
            let cosineStarted = ProcessInfo.processInfo.systemUptime
            let matches = try vectorIndex.search(
                query: vector, dimensions: dimensions, limit: limit
            ) {
                let readStarted = ProcessInfo.processInfo.systemUptime
                let row = try rows.next()
                candidateRead += (ProcessInfo.processInfo.systemUptime - readStarted) * 1_000
                guard let row else { return nil }
                scannedVectors += 1
                return VectorIndexCandidate(id: row["id"], vector: row["vector_blob"])
            }
            let cosineElapsed = (ProcessInfo.processInfo.systemUptime - cosineStarted) * 1_000
            let cosine = max(0, cosineElapsed - candidateRead)
            guard !matches.isEmpty else {
                let total = (ProcessInfo.processInfo.systemUptime - totalStarted) * 1_000
                return VectorSearchOutput(
                    matches: [],
                    diagnostics: VectorSearchDiagnostics(
                        scannedVectors: scannedVectors,
                        connectionWaitMilliseconds: connectionWait,
                        metadataReadMilliseconds: metadataRead,
                        candidateReadMilliseconds: candidateRead,
                        cosineMilliseconds: cosine, detailReadMilliseconds: 0,
                        totalMilliseconds: total, highestScore: nil, lowestTopScore: nil
                    )
                )
            }
            let detailStarted = ProcessInfo.processInfo.systemUptime
            let placeholders = matches.map { _ in "?" }.joined(separator: ",")
            let detailRows = try Row.fetchAll(
                db, sql: Self.selectChunk + " WHERE " + whereSQL
                    + " AND c.id IN (" + placeholders + ")",
                arguments: args + StatementArguments(matches.map(\.id))
            )
            let details = Dictionary(uniqueKeysWithValues: detailRows.map {
                ($0["id"] as String, $0)
            })
            let result = matches.compactMap { match in
                details[match.id].map { self.result($0, score: match.score) }
            }
            let detailRead = (ProcessInfo.processInfo.systemUptime - detailStarted) * 1_000
            let total = (ProcessInfo.processInfo.systemUptime - totalStarted) * 1_000
            return VectorSearchOutput(
                matches: result,
                diagnostics: VectorSearchDiagnostics(
                    scannedVectors: scannedVectors,
                    connectionWaitMilliseconds: connectionWait,
                    metadataReadMilliseconds: metadataRead,
                    candidateReadMilliseconds: candidateRead,
                    cosineMilliseconds: cosine, detailReadMilliseconds: detailRead,
                    totalMilliseconds: total, highestScore: matches.first?.score,
                    lowestTopScore: matches.last?.score
                )
            )
        }
    }

    /// Current libraries are a few thousand vectors. Keeping that working set decoded avoids the
    /// measured 350 ms SQLite row scan and 190 ms scalar cosine. A committed write drops the
    /// matrix; larger sets stay on the stream.
    private struct VectorWorkspaceKey: Hashable {
        let spaceID: String
        let featureType: String
        let rootsKey: String
        let dimensions: Int
    }

    private struct VectorWorkspace {
        let ids: [String]
        let matrix: [Float]
    }

    private func vectorWorkspace(
        db: Database, spaceID: String, featureType: String, dimensions: Int, rootPaths: [String],
        whereSQL: String, arguments: StatementArguments
    ) throws -> VectorWorkspace? {
        guard vectorIndex is ExactVectorIndex else { return nil }
        let key = VectorWorkspaceKey(spaceID: spaceID, featureType: featureType,
                                     rootsKey: rootPaths.sorted().joined(separator: "\n") + "\n" + whereSQL, dimensions: dimensions)
        workspaceLock.lock()
        let generation = workspaceGeneration
        let cached = vectorWorkspaces[key]
        workspaceLock.unlock()
        if let cached { return cached }
        let count = Int(try Int64.fetchOne(db, sql: """
            SELECT count(*)
            FROM files f JOIN roots r ON r.id=f.root_id
            CROSS JOIN chunks c ON c.version_id=f.current_version_id
            CROSS JOIN features x ON x.subject_type='content_unit' AND x.subject_id=c.id
                AND x.content_hash=c.content_hash AND x.feature_type=?
            WHERE \(whereSQL) AND x.model_key=? AND x.vector_format=?
            """, arguments: [featureType] + arguments + [spaceID, VectorCodec.format]) ?? 0)
        let matrixBytes = Int64(count) * Int64(dimensions) * Int64(MemoryLayout<Float>.size)
        guard matrixBytes <= 32 * 1_024 * 1_024 else { return nil }

        var ids: [String] = []
        var matrix: [Float] = []
        ids.reserveCapacity(count)
        matrix.reserveCapacity(count * dimensions)
        if count > 0 {
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id,x.vector_blob
                FROM files f JOIN roots r ON r.id=f.root_id
                CROSS JOIN chunks c ON c.version_id=f.current_version_id
                CROSS JOIN features x ON x.subject_type='content_unit' AND x.subject_id=c.id
                    AND x.content_hash=c.content_hash AND x.feature_type=?
                WHERE \(whereSQL) AND x.model_key=? AND x.vector_format=?
                """, arguments: [featureType] + arguments + [spaceID, VectorCodec.format])
            for row in rows {
                let blob: Data = row["vector_blob"]
                ids.append(row["id"])
                try VectorCodec.appendPayload(blob, expectedDimensions: dimensions, to: &matrix)
            }
        }
        let built = VectorWorkspace(ids: ids, matrix: matrix)
        workspaceLock.lock()
        if workspaceGeneration == generation {
            if vectorWorkspaces.count >= 3 { vectorWorkspaces.removeAll() }
            vectorWorkspaces[key] = built
        }
        workspaceLock.unlock()
        return built
    }

    public func missingEmbeddings(
        spaceID: String, rootPaths: [String], limit: Int = 8,
        semanticMethods: [String]? = nil, rawTextOnly: Bool = false,
        includeAllTextKinds: Bool = false
    ) throws -> [ChunkResult] {
        guard !rootPaths.isEmpty else { return [] }
        let (clause, args) = authorization(rootPaths)
        let selectedMethods = semanticMethods?.filter { !$0.isEmpty }
        let recordJoin = rawTextOnly ? "LEFT JOIN" : "JOIN"
        let methodClause: String
        var methodArguments = StatementArguments()
        if rawTextOnly {
            methodClause = includeAllTextKinds
                ? " AND " + Self.v1RawTextScope
                : " AND lower(f.ext) IN ('txt','md','pdf')"
                    + " AND c.kind IN ('paragraph','page','page_text') AND length(trim(c.text))>=12"
        } else if let selectedMethods {
            guard !selectedMethods.isEmpty else { return [] }
            methodClause = " AND s.method IN (" + selectedMethods.map { _ in "?" }.joined(separator: ",") + ")"
                + " AND (s.method<>'file_summary' OR trim(s.summary)<>'' OR s.keywords_json<>'[]')"
            methodArguments += StatementArguments(selectedMethods)
        } else {
            methodClause = ""
        }
        return try database.read { db in
            let batchLimit = max(1, min(limit, 100))
            let candidateLimit = max(256, min(batchLimit * 32, 2_000))
            let rows = try Row.fetchAll(db, sql: """
                 SELECT c.*,f.id AS file_id,f.path,f.relative_path,
                        coalesce(s.summary,'') AS summary,coalesce(s.keywords_json,'[]') AS keywords_json,
                 \(Self.semanticContentClassSQL) AS budget_class,
                 row_number() OVER (
                    PARTITION BY f.id
                    ORDER BY CASE WHEN c.block_key='document' THEN 0 ELSE 1 END,
                             coalesce(c.page,2147483647),coalesce(c.start_seconds,1.0e30),c.block_key
                 ) AS file_rank
                 FROM chunks c
                 JOIN files f ON f.current_version_id=c.version_id
                 JOIN roots r ON r.id=f.root_id
                 \(recordJoin) semantic_records s ON s.chunk_id=c.id
                 LEFT JOIN features x ON x.subject_type='content_unit' AND x.subject_id=c.id
                    AND x.content_hash=c.content_hash AND x.feature_type='text_embedding'
                    AND x.model_key=? AND x.vector_format=?
                 WHERE \(clause)\(methodClause) AND x.id IS NULL
                 ORDER BY file_rank,f.modified_at DESC,f.path,c.block_key LIMIT ?
                """, arguments: [spaceID, VectorCodec.format] + args + methodArguments + [candidateLimit])
            var groups = Dictionary(grouping: rows) { row in
                SemanticContentClass(rawValue: row["budget_class"] as String) ?? .other
            }.mapValues { $0.map { self.result($0) } }
            let usage = try Self.semanticUsage(
                db: db, spaceID: spaceID,
                softLimitBytes: Self.defaultIndexSoftLimitBytes,
                currentOnly: true
            )
            var virtualBytes = Dictionary(uniqueKeysWithValues: usage.map { ($0.contentClass, $0.bytes) })
            var selected: [ChunkResult] = []
            let estimatedVectorBytes: Int64 = 2_064 // 1024 Float16 values plus the versioned header.
            while selected.count < batchLimit {
                let available = SemanticContentClass.allCases.filter { groups[$0]?.isEmpty == false }
                guard let nextClass = available.min(by: {
                    let lhs = Double(virtualBytes[$0, default: 0]) / $0.budgetShare
                    let rhs = Double(virtualBytes[$1, default: 0]) / $1.budgetShare
                    return lhs == rhs
                        ? SemanticContentClass.allCases.firstIndex(of: $0)! < SemanticContentClass.allCases.firstIndex(of: $1)!
                        : lhs < rhs
                }) else { break }
                selected.append(groups[nextClass]!.removeFirst())
                virtualBytes[nextClass, default: 0] += estimatedVectorBytes
            }
            return selected
        }
    }
    public func embeddingCoverage(
        spaceID: String, rootPaths: [String], semanticMethods: [String]? = nil,
        rawTextOnly: Bool = false, includeAllTextKinds: Bool = false
    ) throws -> (ready: Int, total: Int) {
        guard !rootPaths.isEmpty else { return (0, 0) }
        let (clause, args) = authorization(rootPaths)
        let selectedMethods = semanticMethods?.filter { !$0.isEmpty }
        let recordJoin = rawTextOnly ? "" : "JOIN semantic_records s ON s.chunk_id=c.id"
        let methodClause: String
        var methodArguments = StatementArguments()
        if rawTextOnly {
            methodClause = includeAllTextKinds
                ? " AND " + Self.v1RawTextScope
                : " AND lower(f.ext) IN ('txt','md','pdf')"
                    + " AND c.kind IN ('paragraph','page','page_text') AND length(trim(c.text))>=12"
        } else if let selectedMethods {
            guard !selectedMethods.isEmpty else { return (0, 0) }
            methodClause = " AND s.method IN (" + selectedMethods.map { _ in "?" }.joined(separator: ",") + ")"
                + " AND (s.method<>'file_summary' OR trim(s.summary)<>'' OR s.keywords_json<>'[]')"
            methodArguments += StatementArguments(selectedMethods)
        } else {
            methodClause = ""
        }
        return try database.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT count(x.id) AS ready,count(c.id) AS total
                FROM chunks c JOIN files f ON f.current_version_id=c.version_id
                JOIN roots r ON r.id=f.root_id
                \(recordJoin)
                LEFT JOIN features x ON x.subject_type='content_unit' AND x.subject_id=c.id
                    AND x.content_hash=c.content_hash AND x.feature_type='text_embedding'
                    AND x.model_key=? AND x.vector_format=?
                WHERE \(clause)\(methodClause)
                """, arguments: [spaceID, VectorCodec.format] + args + methodArguments)!
            return (row["ready"], row["total"])
        }
    }

    private static let v1RawTextScope = "c.kind IN ('paragraph','page','page_text','slide','slide_text',"
        + "'sheet_rows','table_text','xml_text','archive_text','message_body','transcript','transcript_excerpt') AND length(trim(c.text))>=12"

    private static let visualScope = """
        (c.kind IN ('visual_image','visual_frame') OR
         (c.kind='visual_page' AND (
            c.page<=3 OR
            NOT EXISTS(SELECT 1 FROM chunks p WHERE p.version_id=c.version_id AND p.page=c.page
                       AND p.kind IN ('page','page_text') AND length(trim(p.text))>0) OR
            (SELECT coalesce(sum(length(p.text)),0) FROM chunks p WHERE p.version_id=c.version_id
             AND p.page=c.page AND p.kind IN ('page','page_text'))<500 OR
            EXISTS(SELECT 1 FROM chunks p WHERE p.version_id=c.version_id AND p.page=c.page
                   AND p.kind IN ('page','page_text')
                   AND (p.text LIKE '%Figure%' OR p.text LIKE '%Fig.%' OR p.text LIKE '%图%'))
         )))
        """

    public func visualEmbeddingCoverage(spaceID: String, rootPaths: [String]) throws -> (ready: Int, total: Int) {
        guard !rootPaths.isEmpty else { return (0, 0) }
        let (clause, args) = authorization(rootPaths)
        return try database.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT count(x.id) AS ready,count(c.id) AS total
                FROM chunks c JOIN files f ON f.current_version_id=c.version_id
                JOIN roots r ON r.id=f.root_id
                LEFT JOIN features x ON x.subject_type='content_unit' AND x.subject_id=c.id
                    AND x.content_hash=c.content_hash AND x.feature_type='visual_embedding'
                    AND x.model_key=? AND x.vector_format=?
                WHERE \(clause) AND (\(Self.visualScope) OR x.id IS NOT NULL)
                """, arguments: [spaceID, VectorCodec.format] + args)!
            return (row["ready"], row["total"])
        }
    }

    public func missingVisualEmbeddings(spaceID: String, rootPaths: [String], limit: Int = 1) throws -> [ChunkResult] {
        guard !rootPaths.isEmpty, limit > 0 else { return [] }
        let (clause, args) = authorization(rootPaths)
        return try database.read { db in
            try Row.fetchAll(db, sql: Self.selectChunk + """

                LEFT JOIN features x ON x.subject_type='content_unit' AND x.subject_id=c.id
                    AND x.content_hash=c.content_hash AND x.feature_type='visual_embedding'
                    AND x.model_key=? AND x.vector_format=?
                LEFT JOIN visual_embedding_attempts a ON a.chunk_id=c.id AND a.model_key=?
                WHERE \(clause) AND \(Self.visualScope) AND x.id IS NULL
                    AND coalesce(a.retry_after,0)<=?
                ORDER BY CASE c.kind WHEN 'visual_image' THEN 0 WHEN 'visual_frame' THEN 1 ELSE 2 END,
                         coalesce(a.attempts,0),f.path,c.page
                LIMIT ?
                """, arguments: [spaceID, VectorCodec.format, spaceID] + args
                    + [Date().timeIntervalSince1970, limit]).map { self.result($0) }
        }
    }

    public func recordVisualEmbeddingFailure(chunkID: String, spaceID: String, rootPaths: [String], error: String) throws {
        guard try chunk(id: chunkID, rootPaths: rootPaths) != nil else { throw DataLayerError.missingChunk }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO visual_embedding_attempts(chunk_id,model_key,attempts,retry_after,last_error)
                VALUES(?,?,1,?,?)
                ON CONFLICT(chunk_id,model_key) DO UPDATE SET
                    attempts=attempts+1,retry_after=excluded.retry_after,last_error=excluded.last_error
                """, arguments: [chunkID, spaceID, Date().addingTimeInterval(60).timeIntervalSince1970,
                                   String(error.prefix(240))])
        }
    }

    public func clearVisualEmbeddingFailure(chunkID: String, spaceID: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM visual_embedding_attempts WHERE chunk_id=? AND model_key=?",
                           arguments: [chunkID, spaceID])
        }
    }

    public func linkArtifact(sourceVersionID: String, artifactFileID: String, relation: String, rootPaths: [String]) throws {
        try database.write { db in
            let (clause, args) = self.authorization(rootPaths)
            let sourceCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM file_versions v JOIN files f ON f.id=v.file_id JOIN roots r ON r.id=f.root_id WHERE " + clause + " AND v.id=?", arguments: args + [sourceVersionID]) ?? 0
            let targetCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM files f JOIN roots r ON r.id=f.root_id WHERE " + clause + " AND f.id=?", arguments: args + [artifactFileID]) ?? 0
            guard sourceCount == 1, targetCount == 1 else { throw DataLayerError.unauthorizedRoot }
            let now = Date().timeIntervalSince1970
            try db.execute(sql: "INSERT OR IGNORE INTO artifact_links VALUES(?,?,?,?)", arguments: [sourceVersionID, artifactFileID, relation, now])
            let relationType = relation == "reuse" ? "generated_from" : relation
            let relationID = ContentIdentity.digest(
                ["item", artifactFileID, relationType, "item_version", sourceVersionID].joined(separator: ":")
            )
            try db.execute(sql: """
                INSERT INTO relations(
                    id,from_subject_type,from_subject_id,relation_type,to_subject_type,to_subject_id,
                    confidence,evidence_unit_id,producer_run_id,state,created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(from_subject_type,from_subject_id,relation_type,to_subject_type,to_subject_id)
                DO UPDATE SET state='current',confidence=excluded.confidence
                """, arguments: [
                    relationID, "item", artifactFileID, relationType, "item_version", sourceVersionID,
                    1.0, nil, nil, "current", now,
                ])
        }
    }

    public func statistics() throws -> DataStatistics {
        try database.read { db in
            func count(_ table: String) throws -> Int { try Int.fetchOne(db, sql: "SELECT count(*) FROM " + table) ?? 0 }
            return try DataStatistics(files: count("files"), versions: count("file_versions"), chunks: count("chunks"),
                                      semantics: count("semantic_records"),
                                      embeddings: Int.fetchOne(db, sql: "SELECT count(*) FROM features WHERE feature_type='text_embedding'") ?? 0,
                                      failedStages: Int.fetchOne(db, sql: "SELECT count(*) FROM scan_jobs j JOIN files f ON f.current_version_id=j.version_id JOIN roots r ON r.id=f.root_id WHERE f.present=1 AND r.active=1 AND j.status='failed'") ?? 0)
        }
    }

    public func indexCapacity(
        spaceID: String? = nil,
        softLimitBytes: Int64 = ContentStore.defaultIndexSoftLimitBytes
    ) throws -> IndexCapacity {
        let usage = try database.read { db in
            try Self.semanticUsage(db: db, spaceID: spaceID, softLimitBytes: softLimitBytes)
        }
        let vectorBytes = usage.reduce(Int64.zero) { $0 + $1.bytes }
        let fileManager = FileManager.default
        let usedBytes = ["", "-wal", "-shm"].reduce(Int64.zero) { total, suffix in
            let attributes = try? fileManager.attributesOfItem(atPath: filePath + suffix)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return IndexCapacity(
            usedBytes: usedBytes, softLimitBytes: softLimitBytes,
            semanticVectorBytes: vectorBytes, semanticUsage: usage
        )
    }

    /// Read-only production-path benchmark. It samples stored vectors and never records query text
    /// or paths, so exact search remains the recall reference before an ANN backend is considered.
    public func benchmarkVectorIndex(
        rootPaths: [String],
        queryCount: Int = 8,
        topK: Int = 80
    ) throws -> VectorIndexBenchmark {
        guard !rootPaths.isEmpty, queryCount > 0, topK > 0 else {
            throw DataLayerError.invalidEmbedding
        }
        let (clause, auth) = authorization(rootPaths)
        let sample: (spaceID: String, dimensions: Int, count: Int, vectors: [[Float]]) = try database.read { db in
            guard let space = try Row.fetchOne(db, sql: """
                SELECT x.model_key,x.dimensions,count(*) AS candidate_count
                FROM chunks c JOIN files f ON f.current_version_id=c.version_id
                JOIN roots r ON r.id=f.root_id
                JOIN features x ON x.subject_type='content_unit' AND x.subject_id=c.id
                    AND x.content_hash=c.content_hash AND x.feature_type='text_embedding'
                    AND x.vector_format=?
                WHERE \(clause)
                GROUP BY x.model_key,x.dimensions
                ORDER BY candidate_count DESC,x.model_key LIMIT 1
                """, arguments: [VectorCodec.format] + auth),
                  let spaceID: String = space["model_key"],
                  let dimensions: Int = space["dimensions"] else {
                throw DataLayerError.invalidEmbedding
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT x.vector_blob
                FROM chunks c JOIN files f ON f.current_version_id=c.version_id
                JOIN roots r ON r.id=f.root_id
                JOIN features x ON x.subject_type='content_unit' AND x.subject_id=c.id
                    AND x.content_hash=c.content_hash AND x.feature_type='text_embedding'
                    AND x.vector_format=? AND x.model_key=?
                WHERE \(clause)
                ORDER BY c.id LIMIT ?
                """, arguments: [VectorCodec.format, spaceID] + auth + [min(queryCount, 100)])
            return (
                spaceID, dimensions, space["candidate_count"],
                try rows.map { try VectorCodec.decode($0["vector_blob"], expectedDimensions: dimensions) }
            )
        }
        guard !sample.vectors.isEmpty else { throw DataLayerError.invalidEmbedding }
        _ = try searchVector(sample.vectors[0], spaceID: sample.spaceID, rootPaths: rootPaths, limit: topK)
        var timings: [Double] = []
        timings.reserveCapacity(sample.vectors.count)
        for vector in sample.vectors {
            let start = Date()
            _ = try searchVector(vector, spaceID: sample.spaceID, rootPaths: rootPaths, limit: topK)
            timings.append(Date().timeIntervalSince(start) * 1_000)
        }
        timings.sort()
        func percentile(_ fraction: Double) -> Double {
            timings[max(0, min(timings.count - 1, Int(ceil(Double(timings.count) * fraction)) - 1))]
        }
        let capacity = try indexCapacity(spaceID: sample.spaceID)
        return VectorIndexBenchmark(
            backend: vectorIndex.identifier, spaceID: sample.spaceID,
            dimensions: sample.dimensions, candidateCount: sample.count,
            queryCount: timings.count, topK: topK,
            p50Milliseconds: percentile(0.50), p95Milliseconds: percentile(0.95),
            databaseBytes: capacity.usedBytes, vectorBytes: capacity.semanticVectorBytes
        )
    }

    private static let semanticContentClassSQL = """
        CASE
            WHEN f.kind='image' THEN 'image'
            WHEN lower(f.ext) IN ('pdf','ppt','pptx','key','pages') THEN 'paged_document'
            WHEN f.kind IN ('audio','video') THEN 'media'
            WHEN f.kind IN ('document','spreadsheet','code') THEN 'text_document'
            ELSE 'other'
        END
        """

    private static func semanticUsage(
        db: Database,
        spaceID: String?,
        softLimitBytes: Int64,
        currentOnly: Bool = false
    ) throws -> [SemanticIndexUsage] {
        var predicate = "x.feature_type='text_embedding' AND x.vector_blob IS NOT NULL"
        var arguments = StatementArguments()
        if let spaceID {
            predicate += " AND x.model_key=?"
            arguments += [spaceID]
        }
        let fileJoin: String
        if currentOnly {
            fileJoin = "JOIN files f ON f.current_version_id=c.version_id JOIN roots r ON r.id=f.root_id"
            predicate += " AND f.present=1 AND r.active=1"
        } else {
            fileJoin = "JOIN file_versions v ON v.id=c.version_id JOIN files f ON f.id=v.file_id"
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(semanticContentClassSQL) AS budget_class,
                   coalesce(sum(length(x.vector_blob)),0) AS vector_bytes
            FROM features x
            JOIN chunks c ON c.id=x.subject_id AND x.subject_type='content_unit'
            \(fileJoin)
            WHERE \(predicate)
            GROUP BY budget_class
            """, arguments: arguments)
        let bytes = Dictionary(uniqueKeysWithValues: rows.map {
            (SemanticContentClass(rawValue: $0["budget_class"] as String) ?? .other,
             $0["vector_bytes"] as Int64)
        })
        return SemanticContentClass.allCases.map {
            SemanticIndexUsage(
                contentClass: $0,
                bytes: bytes[$0, default: 0],
                targetBytes: Int64(Double(softLimitBytes) * $0.budgetShare)
            )
        }
    }

    public func projectionCounts() throws -> (sources: Int, items: Int, contentUnits: Int, unitContents: Int, searchDocuments: Int) {
        try database.read { db in
            func count(_ table: String) throws -> Int { try Int.fetchOne(db, sql: "SELECT count(*) FROM " + table) ?? 0 }
            return try (count("sources"), count("items"), count("content_units"), count("unit_contents"), count("search_documents"))
        }
    }

    public func understandingStatistics() throws -> UnderstandingStatistics {
        try database.read { db in
            func count(_ table: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM " + table) ?? 0
            }
            return try UnderstandingStatistics(
                sources: count("sources"), items: count("items"),
                contentUnits: count("content_units"), unitContents: count("unit_contents"),
                observations: count("observations"), features: count("features"),
                relations: count("relations"), jobs: count("jobs"), modelRuns: count("model_runs"),
                searchDocuments: count("search_documents")
            )
        }
    }

    public func sourceAuthorization(rootPath: String) throws -> String? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT authorization_state FROM sources WHERE locator=?", arguments: [rootPath])
        }
    }

    private func result(_ row: Row, score: Double = 0) -> ChunkResult {
        let keywords: String = row["keywords_json"]
        return ChunkResult(contentHash: row["content_hash"], id: row["id"], fileID: row["file_id"], versionID: row["version_id"], path: row["path"],
                           relativePath: row["relative_path"], kind: row["kind"], page: row["page"], startSeconds: row["start_seconds"],
                           endSeconds: row["end_seconds"], locationJSON: row["location_json"], text: row["text"], summary: row["summary"],
                           tags: (try? JSONDecoder().decode([String].self, from: Data(keywords.utf8))) ?? [], score: score)
    }
}

/// Pre-tokenize Chinese for FTS5: unicode61 alone treats an uninterrupted Han sentence as one token.
/// Index words plus 1–3 Han-character grams; query expressions quote every token, never execute user syntax.
public enum SearchEncoding {
    public static func tokens(_ text: String) -> [String] {
        let text = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in words.append(String(text[range])); return true }
        // NaturalLanguage can split the same letter+digit token differently depending on
        // surrounding text. Preserve bounded ASCII runs so indexing and querying identifiers
        // such as `regularbodytail731` always produce the same FTS term.
        var asciiRun: [Character] = []
        func flushASCII() {
            if !asciiRun.isEmpty, asciiRun.count <= 128 { words.append(String(asciiRun)) }
            asciiRun.removeAll(keepingCapacity: true)
        }
        for character in text {
            if character.unicodeScalars.count == 1,
               let value = character.unicodeScalars.first?.value,
               (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value) {
                asciiRun.append(character)
            } else {
                flushASCII()
            }
        }
        flushASCII()
        var run: [Character] = []
        func flush() {
            for index in run.indices { for count in 1...min(3, run.count - index) { words.append(String(run[index..<(index + count)])) } }
            run = []
        }
        for character in text {
            if character.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) { run.append(character) } else { flush() }
        }
        flush()
        for number in NumericSearch.runs(text) {
            words += NumericSearch.grams(number, width: 2) + NumericSearch.grams(number, width: 3)
        }
        var seen = Set<String>()
        return words.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    public static func encode(_ text: String) -> String { tokens(text).joined(separator: " ") }
    public static func expression(_ text: String) -> String? {
        let terms = NumericSearch.term(text).map { NumericSearch.grams($0, width: min(3, $0.count)) } ?? tokens(text)
        guard !terms.isEmpty else { return nil }
        return "(" + terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ") + ")"
    }
}
