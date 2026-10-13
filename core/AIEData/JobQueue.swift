import Foundation
import GRDB

extension ContentStore {
    @discardableResult
    public func recoverInterruptedJobs(
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws -> Int {
        try database.write { db in
            try db.execute(sql: """
                UPDATE jobs SET state='pending',not_before=?,lease_owner=NULL,
                    lease_expires_at=NULL,updated_at=? WHERE state='running'
                """, arguments: [now, now])
            return db.changesCount
        }
    }

    public func claimJob(
        subjectType: String = "item_version",
        subjectID: String,
        jobType: String,
        inputHash: String,
        priority: Int,
        owner: String,
        leaseDuration: TimeInterval = 300,
        checkpointJSON: String? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws -> DurableJob? {
        guard !subjectID.isEmpty, !jobType.isEmpty, !inputHash.isEmpty, !owner.isEmpty else {
            throw DataLayerError.invalidDocument("Invalid durable job identity")
        }
        let jobID = ContentIdentity.digest(subjectID + ":" + jobType + ":" + inputHash)
        return try database.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO jobs(
                    id,subject_type,subject_id,job_type,priority,state,attempt_count,not_before,
                    lease_owner,lease_expires_at,input_hash,error_code,created_at,updated_at,
                    checkpoint_json,max_attempts)
                VALUES(?,?,?,?,?,'pending',0,0,NULL,NULL,?,NULL,?,?,?,5)
                """, arguments: [
                    jobID, subjectType, subjectID, jobType, priority, inputHash, now, now,
                    checkpointJSON,
                ])
            try db.execute(sql: """
                UPDATE jobs SET state='running',attempt_count=attempt_count+1,
                    lease_owner=?,lease_expires_at=?,updated_at=?,
                    checkpoint_json=coalesce(?,checkpoint_json),error_code=NULL
                WHERE id=? AND attempt_count<max_attempts AND not_before<=?
                  AND (state IN ('pending','failed') OR (state='running' AND lease_expires_at<=?))
                  AND (?<>'item_version' OR EXISTS (
                      SELECT 1 FROM files f JOIN roots r ON r.id=f.root_id
                      WHERE f.current_version_id=jobs.subject_id AND f.present=1 AND r.active=1
                  ))
                """, arguments: [
                    owner, now + max(1, leaseDuration), now, checkpointJSON, jobID, now, now,
                    subjectType,
                ])
            guard db.changesCount == 1 else { return nil }
            return try Self.durableJob(id: jobID, db: db)
        }
    }

    @discardableResult
    public func renewJobLease(
        id: String, owner: String, leaseDuration: TimeInterval = 300,
        checkpointJSON: String? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws -> Bool {
        try database.write { db in
            try db.execute(sql: """
                UPDATE jobs SET lease_expires_at=?,updated_at=?,
                    checkpoint_json=coalesce(?,checkpoint_json)
                WHERE id=? AND state='running' AND lease_owner=?
                """, arguments: [now + max(1, leaseDuration), now, checkpointJSON, id, owner])
            return db.changesCount == 1
        }
    }

    @discardableResult
    public func completeJob(
        id: String, owner: String, checkpointJSON: String? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws -> Bool {
        try transitionJob(
            id: id, owner: owner, succeeded: true, errorCode: nil,
            retryDelay: 0, checkpointJSON: checkpointJSON, now: now
        )
    }

    @discardableResult
    public func retryJob(
        id: String, owner: String, errorCode: String,
        retryDelay: TimeInterval,
        checkpointJSON: String? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws -> Bool {
        try transitionJob(
            id: id, owner: owner, succeeded: false, errorCode: errorCode,
            retryDelay: retryDelay, checkpointJSON: checkpointJSON, now: now
        )
    }

    @discardableResult
    public func releaseJob(
        id: String, owner: String, checkpointJSON: String? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws -> Bool {
        try database.write { db in
            try db.execute(sql: """
                UPDATE jobs SET state='pending',not_before=?,lease_owner=NULL,
                    lease_expires_at=NULL,updated_at=?,checkpoint_json=coalesce(?,checkpoint_json)
                WHERE id=? AND state='running' AND lease_owner=?
                """, arguments: [now, now, checkpointJSON, id, owner])
            return db.changesCount == 1
        }
    }

    public func durableJob(id: String) throws -> DurableJob? {
        try database.read { db in try Self.durableJob(id: id, db: db) }
    }

    @discardableResult
    public func retryFailedJobs(jobTypes: [String], now: TimeInterval = Date().timeIntervalSince1970) throws -> Int {
        guard !jobTypes.isEmpty else { return 0 }
        let placeholders = jobTypes.map { _ in "?" }.joined(separator: ",")
        return try database.write { db in
            try db.execute(sql: """
                UPDATE jobs SET state='pending',attempt_count=0,not_before=0,error_code=NULL,updated_at=?
                WHERE state IN ('failed','pending') AND job_type IN (\(placeholders))
                  AND subject_type='item_version' AND EXISTS (
                      SELECT 1 FROM files f JOIN roots r ON r.id=f.root_id
                      WHERE f.current_version_id=jobs.subject_id AND f.present=1 AND r.active=1
                  )
                """, arguments: StatementArguments([now] + jobTypes))
            return db.changesCount
        }
    }

    private func transitionJob(
        id: String, owner: String, succeeded: Bool, errorCode: String?,
        retryDelay: TimeInterval, checkpointJSON: String?, now: TimeInterval
    ) throws -> Bool {
        try database.write { db in
            let state = succeeded ? "succeeded" : "pending"
            try db.execute(sql: """
                UPDATE jobs SET
                    state=CASE WHEN ?=1 THEN 'succeeded'
                        WHEN attempt_count>=max_attempts THEN 'failed' ELSE ? END,
                    not_before=?,lease_owner=NULL,lease_expires_at=NULL,error_code=?,updated_at=?,
                    checkpoint_json=coalesce(?,checkpoint_json)
                WHERE id=? AND state='running' AND lease_owner=?
                """, arguments: [
                    succeeded ? 1 : 0, state, succeeded ? 0 : now + max(0, retryDelay),
                    errorCode, now, checkpointJSON, id, owner,
                ])
            return db.changesCount == 1
        }
    }

    private static func durableJob(id: String, db: Database) throws -> DurableJob? {
        try Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE id=?", arguments: [id]).map {
            DurableJob(
                id: $0["id"], subjectType: $0["subject_type"], subjectID: $0["subject_id"],
                jobType: $0["job_type"], priority: $0["priority"], state: $0["state"],
                attemptCount: $0["attempt_count"], maxAttempts: $0["max_attempts"],
                notBefore: $0["not_before"], leaseOwner: $0["lease_owner"],
                leaseExpiresAt: $0["lease_expires_at"], inputHash: $0["input_hash"],
                checkpointJSON: $0["checkpoint_json"], errorCode: $0["error_code"]
            )
        }
    }
}
