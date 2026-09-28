//! FFI bridge API for flutter_rust_bridge.
//!
//! All complex types cross the FFI boundary as JSON strings.
//! Vec<f32> is passed as native float arrays (FRB handles these efficiently).

use chrono::{TimeZone, Utc};
use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::consolidation::MemoryConsolidator;
use crate::error::Result;
use crate::longterm;
use crate::models::*;
use crate::shortterm::{ConversationBuffer, SensoryBuffer, WorkingMemory};
use crate::storage::MemoryStore;
use crate::tools::{EmbeddingProvider, LlmProvider, ToolCall, ToolExecutor};

fn ledger_datetime(seconds: f64) -> Result<chrono::DateTime<Utc>> {
    if !seconds.is_finite() {
        return Err(crate::error::MemlocalError::InvalidArgument(
            "ledger timestamp must be finite".into(),
        ));
    }
    let floor = seconds.floor();
    if floor < i64::MIN as f64 || floor > i64::MAX as f64 {
        return Err(crate::error::MemlocalError::InvalidArgument(
            "ledger timestamp is outside the supported range".into(),
        ));
    }
    let mut whole_seconds = floor as i64;
    let mut nanos = ((seconds - floor) * 1_000_000_000.0).round() as u32;
    if nanos == 1_000_000_000 {
        whole_seconds = whole_seconds.checked_add(1).ok_or_else(|| {
            crate::error::MemlocalError::InvalidArgument(
                "ledger timestamp is outside the supported range".into(),
            )
        })?;
        nanos = 0;
    }
    Utc.timestamp_opt(whole_seconds, nanos)
        .single()
        .ok_or_else(|| {
            crate::error::MemlocalError::InvalidArgument(
                "ledger timestamp is outside the supported range".into(),
            )
        })
}

fn ledger_payload_timestamp(payload: &serde_json::Value, key: &str) -> Option<f64> {
    // Foundation's default JSONEncoder represents Date as seconds since
    // 2001-01-01, while the transfer envelope uses Unix seconds.
    payload
        .get(key)
        .and_then(serde_json::Value::as_f64)
        .map(|seconds_since_2001| seconds_since_2001 + 978_307_200.0)
}

fn ledger_timestamp_matches(payload: &serde_json::Value, key: &str, unix_seconds: f64) -> bool {
    ledger_payload_timestamp(payload, key)
        .is_some_and(|payload_seconds| (payload_seconds - unix_seconds).abs() <= 0.000_01)
}

fn project_router_embedding(
    values: &[f64],
    dimensions: usize,
    record_id: &str,
) -> Result<Vec<f32>> {
    if dimensions != ROUTER_LEDGER_EMBEDDING_DIMENSIONS as usize {
        return Err(crate::error::MemlocalError::InvalidArgument(format!(
            "router ledger embedding dimension must be {ROUTER_LEDGER_EMBEDDING_DIMENSIONS}"
        )));
    }
    if values.len() > ROUTER_LEDGER_MAX_SOURCE_EMBEDDING_DIMENSIONS {
        return Err(crate::error::MemlocalError::InvalidArgument(format!(
            "source embedding is too large for ledger record {record_id}"
        )));
    }
    let mut projected = vec![0.0_f64; dimensions];
    for (index, value) in values.iter().copied().enumerate() {
        if !value.is_finite() || value.abs() > f32::MAX as f64 {
            return Err(crate::error::MemlocalError::InvalidArgument(format!(
                "invalid embedding value for ledger record {record_id}"
            )));
        }
        if value == 0.0 {
            continue;
        }

        if values.len() == dimensions {
            projected[index] += value;
            continue;
        }

        // Signed feature hashing projects NaturalLanguage vectors of different
        // source sizes into one fixed-size Rust index without altering the
        // source vector preserved in payloadJSON.
        let mut hash = (index as u64) ^ (values.len() as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15);
        hash = hash.wrapping_add(0x9e37_79b9_7f4a_7c15);
        hash = (hash ^ (hash >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        hash = (hash ^ (hash >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        hash ^= hash >> 31;
        let bucket = ((hash >> 1) as usize) % dimensions;
        let sign = if hash & 1 == 0 { 1.0 } else { -1.0 };
        projected[bucket] += value * sign;
    }

    let magnitude = projected
        .iter()
        .map(|value| value * value)
        .sum::<f64>()
        .sqrt();
    if magnitude == 0.0 {
        return Ok(vec![0.0_f32; dimensions]);
    }
    Ok(projected
        .into_iter()
        .map(|value| (value / magnitude) as f32)
        .collect())
}

fn router_ledger_embedding(
    payload: &serde_json::Value,
    kind: &str,
    dimensions: usize,
    record_id: &str,
) -> Result<(Vec<f32>, Option<usize>)> {
    if !matches!(kind, "durableFact" | "invalidatedFact") {
        return Ok((vec![0.0_f32; dimensions], None));
    }
    let Some(source) = payload.get("embedding") else {
        return Ok((vec![0.0_f32; dimensions], None));
    };
    let values = source.as_array().ok_or_else(|| {
        crate::error::MemlocalError::InvalidArgument(format!(
            "embedding is not an array for ledger record {record_id}"
        ))
    })?;
    let values = values
        .iter()
        .map(|value| {
            value.as_f64().ok_or_else(|| {
                crate::error::MemlocalError::InvalidArgument(format!(
                    "invalid embedding array for ledger record {record_id}"
                ))
            })
        })
        .collect::<Result<Vec<_>>>()?;
    let source_dimensions = values.len();
    let embedding = project_router_embedding(&values, dimensions, record_id)?;
    Ok((embedding, Some(source_dimensions)))
}

fn prepare_router_ledger(
    json: &str,
    embedding_dimensions: u32,
) -> Result<(
    RouterLedgerEnvelope,
    Vec<(RouterLedgerRecord, MemoryItem, Vec<f32>)>,
)> {
    if embedding_dimensions != ROUTER_LEDGER_EMBEDDING_DIMENSIONS {
        return Err(crate::error::MemlocalError::InvalidArgument(format!(
            "router ledger storage must use {ROUTER_LEDGER_EMBEDDING_DIMENSIONS}-dimensional embeddings"
        )));
    }
    let envelope: RouterLedgerEnvelope = serde_json::from_str(json)?;
    if envelope.format != RouterLedgerEnvelope::FORMAT
        || envelope.schema_version != RouterLedgerEnvelope::SCHEMA_VERSION
        || envelope.source_schema_version != RouterLedgerEnvelope::SOURCE_SCHEMA_VERSION
    {
        return Err(crate::error::MemlocalError::InvalidArgument(
            "unsupported on-device-router ledger format or schema version".into(),
        ));
    }

    let mut ids = HashSet::with_capacity(envelope.records.len());
    let mut prepared = Vec::with_capacity(envelope.records.len());
    for record in &envelope.records {
        if !ids.insert(record.id.as_str()) {
            return Err(crate::error::MemlocalError::InvalidArgument(format!(
                "duplicate ledger record id: {}",
                record.id
            )));
        }
        uuid::Uuid::parse_str(&record.id).map_err(|_| {
            crate::error::MemlocalError::InvalidArgument(format!(
                "invalid ledger record id: {}",
                record.id
            ))
        })?;

        let payload: serde_json::Value = serde_json::from_str(&record.payload_json)?;
        if payload.get("id").and_then(serde_json::Value::as_str) != Some(record.id.as_str()) {
            return Err(crate::error::MemlocalError::InvalidArgument(format!(
                "payload id does not match ledger record id: {}",
                record.id
            )));
        }

        let payload_content = match record.kind.as_str() {
            "durableFact" | "invalidatedFact" => payload
                .get("statement")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned),
            "relationship" => {
                let triple = payload.get("triple");
                let subject = triple
                    .and_then(|value| value.get("subject"))
                    .and_then(serde_json::Value::as_str);
                let predicate = triple
                    .and_then(|value| value.get("predicate"))
                    .and_then(serde_json::Value::as_str);
                let object = triple
                    .and_then(|value| value.get("object"))
                    .and_then(serde_json::Value::as_str);
                match (subject, predicate, object) {
                    (Some(subject), Some(predicate), Some(object)) => {
                        Some(format!("{subject} {predicate} {object}"))
                    }
                    _ => None,
                }
            }
            "episodic" => payload
                .get("value")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned),
            "conversationTurn" => payload
                .get("userMessage")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned),
            _ => None,
        };
        if payload_content.as_deref() != Some(record.content.as_str()) {
            return Err(crate::error::MemlocalError::InvalidArgument(format!(
                "content does not match {} payload: {}",
                record.kind, record.id
            )));
        }

        let payload_is_invalidated = payload
            .get("invalidatedAt")
            .is_some_and(|value| !value.is_null());
        let wrapper_is_invalidated = record.invalidated_at.is_some();
        let lifecycle_matches = match record.kind.as_str() {
            "durableFact" => !payload_is_invalidated && !wrapper_is_invalidated,
            "invalidatedFact" => payload_is_invalidated && wrapper_is_invalidated,
            "relationship" => payload_is_invalidated == wrapper_is_invalidated,
            "episodic" | "conversationTurn" => !wrapper_is_invalidated,
            _ => false,
        };
        if !lifecycle_matches {
            return Err(crate::error::MemlocalError::InvalidArgument(format!(
                "lifecycle does not match {} payload: {}",
                record.kind, record.id
            )));
        }

        let timestamps_match = match record.kind.as_str() {
            "durableFact" | "invalidatedFact" => {
                ledger_timestamp_matches(&payload, "createdAt", record.created_at)
                    && ledger_timestamp_matches(&payload, "updatedAt", record.updated_at)
                    && match (
                        record.invalidated_at,
                        ledger_payload_timestamp(&payload, "invalidatedAt"),
                    ) {
                        (Some(wrapper), Some(stored)) => (wrapper - stored).abs() <= 0.000_01,
                        (None, None) => true,
                        _ => false,
                    }
            }
            "relationship" | "episodic" => {
                ledger_timestamp_matches(&payload, "createdAt", record.created_at)
                    && (record.created_at - record.updated_at).abs() <= 0.000_01
            }
            "conversationTurn" => {
                ledger_timestamp_matches(&payload, "timestamp", record.created_at)
                    && (record.created_at - record.updated_at).abs() <= 0.000_01
            }
            _ => false,
        };
        if !timestamps_match {
            return Err(crate::error::MemlocalError::InvalidArgument(format!(
                "timestamps do not match {} payload: {}",
                record.kind, record.id
            )));
        }

        let memory_type = match record.kind.as_str() {
            "durableFact" | "invalidatedFact" => MemoryType::Factual,
            "relationship" => MemoryType::Semantic,
            "episodic" => MemoryType::Episodic,
            "conversationTurn" => MemoryType::ConversationBuffer,
            _ => {
                return Err(crate::error::MemlocalError::InvalidArgument(format!(
                    "unsupported ledger record kind: {}",
                    record.kind
                )))
            }
        };

        let created_at = ledger_datetime(record.created_at)?;
        let updated_at = ledger_datetime(record.updated_at)?;
        let (embedding, source_embedding_dimensions) = router_ledger_embedding(
            &payload,
            &record.kind,
            embedding_dimensions as usize,
            &record.id,
        )?;
        let provider_version = payload.get("embeddingProviderVersion")
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty());
        if matches!(record.kind.as_str(), "durableFact" | "invalidatedFact")
            && provider_version.is_none() {
            return Err(crate::error::MemlocalError::InvalidArgument(format!(
                "missing embedding provider version for ledger record {}", record.id
            )));
        }
        let mut item = MemoryItem::new(record.content.clone(), memory_type);
        item.id.clone_from(&record.id);
        item.created_at = created_at;
        item.updated_at = updated_at;
        // Keep every source record readable from the shadow ledger, including
        // records invalidated in the past. Swift lifecycle lives in the opaque
        // source payload; Cozo temporal validity is not the source ledger.
        item.metadata = serde_json::json!({
            "on_device_router_record": serde_json::to_string(record)?,
            "on_device_router_embedding_source_dimensions": source_embedding_dimensions,
            "on_device_router_embedding_provider_version": provider_version,
            "on_device_router_embedding_projection_version": ROUTER_LEDGER_EMBEDDING_PROJECTION_VERSION
        });
        prepared.push((record.clone(), item, embedding));
    }
    Ok((envelope, prepared))
}

/// The main engine — held as an opaque pointer by the platform layer.
pub struct MemlocalEngine {
    store: Arc<MemoryStore>,
    sensory_buffer: Mutex<SensoryBuffer>,
    conversation_buffers: Mutex<std::collections::HashMap<String, ConversationBuffer>>,
    working_memory: Mutex<WorkingMemory>,
    tool_executor: ToolExecutor,
    consolidator: MemoryConsolidator,
    config: CoreConfig,
    // Long-term subtypes
    pub episodic: longterm::EpisodicMemory,
    pub semantic: longterm::SemanticMemory,
    pub factual: longterm::FactualMemory,
    pub procedural: longterm::ProceduralMemory,
    pub social: longterm::SocialMemory,
    pub spatial: longterm::SpatialMemory,
    pub prospective: longterm::ProspectiveMemory,
    pub affective: longterm::AffectiveMemory,
}

impl MemlocalEngine {
    /// Create and initialize the engine.
    pub fn open(config: CoreConfig) -> Result<Self> {
        let store = Arc::new(MemoryStore::open(
            &config.storage,
            config.storage.embedding_dimensions,
        )?);

        let sensory_buffer = SensoryBuffer::new(
            config.sensory_buffer_capacity,
            Duration::from_millis(config.sensory_ttl_ms),
        );

        Ok(Self {
            sensory_buffer: Mutex::new(sensory_buffer),
            conversation_buffers: Mutex::new(std::collections::HashMap::new()),
            working_memory: Mutex::new(WorkingMemory::new()),
            tool_executor: ToolExecutor::new(Arc::clone(&store)),
            consolidator: MemoryConsolidator::new(Arc::clone(&store)),
            episodic: longterm::EpisodicMemory::new(Arc::clone(&store)),
            semantic: longterm::SemanticMemory::new(Arc::clone(&store)),
            factual: longterm::FactualMemory::new(Arc::clone(&store)),
            procedural: longterm::ProceduralMemory::new(Arc::clone(&store)),
            social: longterm::SocialMemory::new(Arc::clone(&store)),
            spatial: longterm::SpatialMemory::new(Arc::clone(&store)),
            prospective: longterm::ProspectiveMemory::new(Arc::clone(&store)),
            affective: longterm::AffectiveMemory::new(Arc::clone(&store)),
            config,
            store,
        })
    }

    pub fn close(&self) -> Result<()> {
        self.store.close()
    }

    // --- Memory CRUD ---

    /// Import one Swift ledger into a fresh, disposable MemLocal database.
    ///
    /// Each source record is kept as its original JSON string in metadata.
    /// The generic MemLocal item is only the text-search projection; it is not
    /// a replacement for the source record. A partially imported database is
    /// intentionally rejected on retry and must be discarded by the caller.
    pub fn import_router_ledger(&self, json: &str) -> Result<usize> {
        let (envelope, prepared) =
            prepare_router_ledger(json, self.config.storage.embedding_dimensions)?;
        if self.store.memory_count(None)? != 0 {
            return Err(crate::error::MemlocalError::InvalidArgument(
                "ledger import requires an empty shadow database".into(),
            ));
        }
        for (record, item, embedding) in &prepared {
            self.store.put_memory(item, embedding)?;
            self.reconcile_router_record_graph(record)?;
        }
        Ok(envelope.records.len())
    }

    /// Reconcile the persistent shadow database with a complete Swift snapshot.
    /// The source ledger remains authoritative if an operation fails; a retry
    /// compares record payloads and repairs any writes that already succeeded.
    pub fn sync_router_ledger(&self, json: &str) -> Result<usize> {
        let (_, prepared) = prepare_router_ledger(json, self.config.storage.embedding_dimensions)?;
        let current = self.export_router_ledger()?;
        let current_by_id: std::collections::HashMap<_, _> = current
            .records
            .iter()
            .map(|record| (record.id.clone(), record.clone()))
            .collect();
        let incoming_ids: HashSet<_> = prepared
            .iter()
            .map(|(record, _, _)| record.id.clone())
            .collect();
        let mut changed = 0;

        for (record, item, embedding) in prepared {
            if current_by_id
                .get(&record.id)
                .is_some_and(|old| old == &record)
            {
                continue;
            }
            self.store.put_memory(&item, &embedding)?;
            self.reconcile_router_record_graph(&record)?;
            changed += 1;
        }

        for old in current.records {
            if !incoming_ids.contains(&old.id) {
                self.store.delete_memory(&old.id)?;
                self.remove_router_record_graph(&old)?;
                changed += 1;
            }
        }
        Ok(changed)
    }

    /// Detect contradicting triples via the consolidation engine.
    pub fn find_contradicting_triples(&self) -> Result<Vec<(Triple, Triple)>> {
        self.consolidator.find_contradicting_triples()
    }

    /// Parse the opaque Swift payload of a ledger record.
    fn router_record_payload(record: &RouterLedgerRecord) -> Result<serde_json::Value> {
        serde_json::from_str(&record.payload_json).map_err(|error| {
            crate::error::MemlocalError::InvalidArgument(format!(
                "invalid payload JSON for ledger record {}: {error}",
                record.id
            ))
        })
    }

    /// Extract the fact's own (subject, predicate, object) triple, if present.
    fn router_fact_triple(payload: &serde_json::Value) -> Option<(String, String, String)> {
        let triple = payload.get("triple")?;
        Some((
            triple.get("subject")?.as_str()?.to_owned(),
            triple.get("predicate")?.as_str()?.to_owned(),
            triple.get("object")?.as_str()?.to_owned(),
        ))
    }

    /// Reconcile knowledge-graph edges and triple-store entries for a synced
    /// ledger record. Only active durable facts contribute outgoing edges,
    /// mirroring the app's traversal semantics.
    fn reconcile_router_record_graph(&self, record: &RouterLedgerRecord) -> Result<()> {
        // Drop stale outgoing edges; they are rebuilt from the payload below.
        for edge in self.store.get_edges_from(&record.id)? {
            self.store
                .remove_edge(&edge.from_id, &edge.to_id, &edge.relation.to_string())?;
        }
        // Drop the previous triple for this record, if any.
        if let Ok(payload) = Self::router_record_payload(record) {
            if let Some((subject, predicate, object)) = Self::router_fact_triple(&payload) {
                let _ = self.store.remove_triple(&subject, &predicate, &object);
            }
        }
        if record.kind.as_str() != "durableFact" {
            return Ok(());
        }
        let payload = Self::router_record_payload(record)?;
        // Edges from the fact's related-fact adjacency list.
        if let Some(related) = payload.get("relatedFactIDs").and_then(|value| value.as_array()) {
            for target in related.iter().filter_map(|value| value.as_str()) {
                if target == record.id {
                    continue;
                }
                let edge =
                    MemoryEdge::new(record.id.clone(), target.to_owned(), MemoryRelation::RelatesTo);
                self.store.put_edge(&edge)?;
            }
        }
        // Triple-store entry from the fact's own SVO triple, keyed to the fact
        // so contradiction detection can map back to it.
        if let Some((subject, predicate, object)) = Self::router_fact_triple(&payload) {
            let triple = Triple {
                subject,
                predicate,
                object,
                memory_id: record.id.clone(),
                speaker: "user".to_owned(),
                mention_count: 1,
                last_mentioned: record.updated_at,
                session_id: String::new(),
                confidence: payload
                    .get("confidence")
                    .and_then(|value| value.as_f64())
                    .unwrap_or(1.0),
            };
            self.store.put_triple(&triple)?;
        }
        Ok(())
    }

    /// Remove every graph edge and triple that references a deleted record.
    fn remove_router_record_graph(&self, record: &RouterLedgerRecord) -> Result<()> {
        for edge in self.get_edges(&record.id)? {
            self.store
                .remove_edge(&edge.from_id, &edge.to_id, &edge.relation.to_string())?;
        }
        if let Ok(payload) = Self::router_record_payload(record) {
            if let Some((subject, predicate, object)) = Self::router_fact_triple(&payload) {
                let _ = self.store.remove_triple(&subject, &predicate, &object);
            }
        }
        Ok(())
    }

    /// Export and validate the opaque Swift records from the shadow database.
    pub fn export_router_ledger(&self) -> Result<RouterLedgerEnvelope> {
        let count = self.store.memory_count(None)?;
        let items = if count == 0 {
            Vec::new()
        } else {
            self.store.get_memories(None, None, count)?
        };
        if items.len() != count {
            return Err(crate::error::MemlocalError::Internal(format!(
                "ledger export expected {count} rows, found {}",
                items.len()
            )));
        }

        let mut envelope = RouterLedgerEnvelope::empty();
        let mut ids = HashSet::with_capacity(items.len());
        for item in items {
            let record_json = item
                .metadata
                .get("on_device_router_record")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| {
                    crate::error::MemlocalError::InvalidArgument(
                        "shadow database contains a row without a router ledger payload".into(),
                    )
                })?;
            if item
                .metadata
                .get("on_device_router_embedding_projection_version")
                .and_then(serde_json::Value::as_u64)
                != Some(ROUTER_LEDGER_EMBEDDING_PROJECTION_VERSION)
            {
                return Err(crate::error::MemlocalError::InvalidArgument(
                    "shadow database uses an outdated embedding projection".into(),
                ));
            }
            let record: RouterLedgerRecord = serde_json::from_str(record_json)?;
            if !ids.insert(record.id.clone()) {
                return Err(crate::error::MemlocalError::Internal(format!(
                    "duplicate ledger record id after import: {}",
                    record.id
                )));
            }
            envelope.records.push(record);
        }
        envelope.records.sort_by(|left, right| {
            left.kind
                .cmp(&right.kind)
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(envelope)
    }

    pub fn put_memory(&self, item: &MemoryItem, embedding: &[f32]) -> Result<()> {
        self.store.put_memory(item, embedding)
    }

    pub fn get_memory(&self, id: &str) -> Result<Option<MemoryItem>> {
        self.store.get_memory(id)
    }

    pub fn get_memories(
        &self,
        user_id: Option<&str>,
        memory_type: Option<MemoryType>,
        limit: usize,
    ) -> Result<Vec<MemoryItem>> {
        self.store.get_memories(user_id, memory_type, limit)
    }

    pub fn delete_memory(&self, id: &str) -> Result<()> {
        self.store.delete_memory(id)
    }

    pub fn invalidate_memory(&self, id: &str) -> Result<()> {
        self.store.invalidate_memory(id)
    }

    pub fn memory_count(&self, memory_type: Option<MemoryType>) -> Result<usize> {
        self.store.memory_count(memory_type)
    }

    // --- Search ---

    pub fn search_semantic(
        &self,
        embedding: &[f32],
        k: usize,
        user_id: Option<&str>,
        memory_type: Option<MemoryType>,
    ) -> Result<Vec<MemoryItem>> {
        self.store
            .search_semantic(embedding, k, user_id, memory_type)
    }

    pub fn search_text(&self, query: &str, k: usize) -> Result<Vec<MemoryItem>> {
        self.store.search_text(query, k)
    }

    /// Search only active durable facts for the app's supplemental recall path.
    pub fn search_router_facts_text(&self, query: &str, k: usize) -> Result<Vec<MemoryItem>> {
        if k == 0 {
            return Ok(Vec::new());
        }
        let count = self.store.memory_count(None)?;
        if count == 0 {
            return Ok(Vec::new());
        }
        let mut matches = self.store.search_text(query, count)?;
        matches.retain(|item| {
            let Some(record_json) = item
                .metadata
                .get("on_device_router_record")
                .and_then(serde_json::Value::as_str)
            else {
                return false;
            };
            serde_json::from_str::<RouterLedgerRecord>(record_json)
                .map(|record| record.kind == "durableFact" && record.invalidated_at.is_none())
                .unwrap_or(false)
        });
        matches.truncate(k);
        Ok(matches)
    }

    /// Hybrid search over active durable facts. The query vector is projected
    /// with the same fixed dimension as ledger facts, and incompatible source
    /// embedding spaces are excluded before results return to Swift.
    pub fn search_router_facts_hybrid(
        &self,
        query: &str,
        query_embedding: &[f64],
        query_provider_version: &str,
        k: usize,
    ) -> Result<Vec<MemoryItem>> {
        // Hashed fallback facts are text-only; a semantic query requires the
        // exact NaturalLanguage model revision recorded with each vector.
        if k == 0 || query_embedding.is_empty() || !query_provider_version.starts_with("nl-en-rev-") {
            return Ok(Vec::new());
        }
        let projected = project_router_embedding(
            query_embedding,
            self.config.storage.embedding_dimensions as usize,
            "query",
        )?;
        if projected.iter().all(|value| *value == 0.0) {
            return Ok(Vec::new());
        }
        let count = self.store.memory_count(None)?;
        if count == 0 {
            return Ok(Vec::new());
        }
        let compatible = |item: &MemoryItem| {
            let Some(record_json) = item
                .metadata
                .get("on_device_router_record")
                .and_then(serde_json::Value::as_str)
            else {
                return false;
            };
            let Ok(record) = serde_json::from_str::<RouterLedgerRecord>(record_json) else {
                return false;
            };
            record.kind == "durableFact"
                && record.invalidated_at.is_none()
                && item.metadata
                    .get("on_device_router_embedding_provider_version")
                    .and_then(serde_json::Value::as_str)
                    == Some(query_provider_version)
                && item
                    .metadata
                    .get("on_device_router_embedding_source_dimensions")
                    .and_then(serde_json::Value::as_u64)
                    == Some(query_embedding.len() as u64)
                && item
                    .metadata
                    .get("on_device_router_embedding_projection_version")
                    .and_then(serde_json::Value::as_u64)
                    == Some(ROUTER_LEDGER_EMBEDDING_PROJECTION_VERSION)
        };
        // The shared vector index contains every provider. Compare only
        // compatible router rows so another provider cannot affect ranking.
        let mut semantic = Vec::<(MemoryItem, f64)>::new();
        for item in self.store.get_memories(None, None, count)? {
            if !compatible(&item) { continue; }
            let Some(record_json) = item.metadata.get("on_device_router_record").and_then(serde_json::Value::as_str) else { continue; };
            let record: RouterLedgerRecord = serde_json::from_str(record_json)?;
            let payload: serde_json::Value = serde_json::from_str(&record.payload_json)?;
            let source = payload.get("embedding").and_then(serde_json::Value::as_array)
                .ok_or_else(|| crate::error::MemlocalError::InvalidArgument("missing fact embedding".into()))?;
            let values = source.iter().map(|value| value.as_f64().ok_or_else(||
                crate::error::MemlocalError::InvalidArgument("invalid fact embedding".into())))
                .collect::<Result<Vec<_>>>()?;
            let vector = project_router_embedding(&values, projected.len(), &record.id)?;
            let similarity: f64 = projected.iter().zip(vector.iter())
                .map(|(left, right)| f64::from(*left) * f64::from(*right)).sum();
            semantic.push((item, similarity));
        }
        semantic.sort_by(|left, right| right.1.total_cmp(&left.1));
        let lexical = self.store.search_text(query, count)?;
        let mut scores = std::collections::HashMap::<String, (MemoryItem, f64)>::new();
        for (rank, (item, _)) in semantic.into_iter().enumerate() {
            let entry = scores.entry(item.id.clone()).or_insert((item, 0.0));
            entry.1 += 1.0 / (60.0 + rank as f64 + 1.0);
        }
        for (rank, item) in lexical.into_iter().filter(&compatible).enumerate() {
            let entry = scores.entry(item.id.clone()).or_insert((item, 0.0));
            entry.1 += 1.0 / (60.0 + rank as f64 + 1.0);
        }
        let mut ranked: Vec<_> = scores.into_values().collect();
        ranked.sort_by(|left, right| right.1.total_cmp(&left.1).then_with(|| left.0.id.cmp(&right.0.id)));
        Ok(ranked.into_iter().take(k).map(|(item, score)| item.with_score(score)).collect())
    }

    pub fn search_hybrid(
        &self,
        query: &str,
        embedding: &[f32],
        k: usize,
        user_id: Option<&str>,
        memory_type: Option<MemoryType>,
    ) -> Result<Vec<MemoryItem>> {
        self.store
            .search_hybrid(query, embedding, k, user_id, memory_type)
    }

    pub fn search_graph(
        &self,
        embedding: &[f32],
        k: usize,
        user_id: Option<&str>,
        memory_type: Option<MemoryType>,
    ) -> Result<Vec<MemoryItem>> {
        self.store
            .search_graph(embedding, k, user_id, memory_type, 2)
    }

    // --- Edges ---

    pub fn put_edge(&self, edge: &MemoryEdge) -> Result<()> {
        self.store.put_edge(edge)
    }

    pub fn get_edges(&self, memory_id: &str) -> Result<Vec<MemoryEdge>> {
        let mut edges = self.store.get_edges_from(memory_id)?;
        edges.extend(self.store.get_edges_to(memory_id)?);
        Ok(edges)
    }

    // --- Conversation Buffer ---

    pub fn append_message(&self, message: Message, session_id: &str) -> Result<()> {
        let mut buffers = self.conversation_buffers.lock().unwrap();
        let buffer = buffers.entry(session_id.to_string()).or_insert_with(|| {
            ConversationBuffer::new(
                Arc::clone(&self.store),
                session_id.to_string(),
                self.config.conversation_buffer_size,
            )
        });
        buffer.append(message)
    }

    pub fn get_messages(&self, session_id: &str, limit: Option<usize>) -> Result<Vec<Message>> {
        self.store.get_messages(session_id, limit)
    }

    // --- Sensory Buffer ---

    pub fn sensory_add(&self, message: Message) {
        let mut buf = self.sensory_buffer.lock().unwrap();
        buf.add(message);
    }

    pub fn sensory_items(&self) -> Vec<Message> {
        let mut buf = self.sensory_buffer.lock().unwrap();
        buf.items().into_iter().cloned().collect()
    }

    pub fn sensory_clear(&self) {
        let mut buf = self.sensory_buffer.lock().unwrap();
        buf.clear();
    }

    // --- Profile ---

    pub fn put_profile(&self, profile: &UserProfile) -> Result<()> {
        self.store.put_profile(profile)
    }

    pub fn get_profile(&self, user_id: &str) -> Result<Option<UserProfile>> {
        self.store.get_profile(user_id)
    }

    // --- Prospective ---

    pub fn put_prospective(&self, item: &ProspectiveItem) -> Result<()> {
        self.store.put_prospective(item)
    }

    pub fn get_pending_prospective(&self, user_id: Option<&str>) -> Result<Vec<ProspectiveItem>> {
        self.store.get_pending_prospective(user_id)
    }

    pub fn complete_prospective(&self, id: &str) -> Result<()> {
        self.store.complete_prospective(id)
    }

    // --- Working Memory ---

    pub fn working_memory_set_relevant(&self, items: Vec<MemoryItem>) {
        let mut wm = self.working_memory.lock().unwrap();
        wm.set_relevant(items);
    }

    pub fn working_memory_set_important(&self, items: Vec<MemoryItem>) {
        let mut wm = self.working_memory.lock().unwrap();
        wm.set_important(items);
    }

    pub fn working_memory_set_profile(&self, profile: Option<UserProfile>) {
        let mut wm = self.working_memory.lock().unwrap();
        wm.set_profile(profile);
    }

    pub fn working_memory_set_reminders(&self, reminders: Vec<ProspectiveItem>) {
        let mut wm = self.working_memory.lock().unwrap();
        wm.set_triggered_reminders(reminders);
    }

    pub fn working_memory_context_block(&self) -> String {
        let wm = self.working_memory.lock().unwrap();
        wm.to_context_block()
    }

    pub fn working_memory_clear(&self) {
        let mut wm = self.working_memory.lock().unwrap();
        wm.clear();
    }

    // --- Tools ---

    pub fn get_tool_definitions() -> Vec<crate::tools::ToolDefinition> {
        crate::tools::all_tool_definitions()
    }

    pub fn execute_tool(
        &self,
        tool_call: &ToolCall,
        embedding_provider: &dyn EmbeddingProvider,
    ) -> crate::tools::ToolResult {
        self.tool_executor.execute(tool_call, embedding_provider)
    }

    /// Prepare context with iterative retrieval (agent mode).
    /// Uses an LLM to assess context sufficiency and refine queries.
    pub fn prepare_context_iterative(
        &self,
        query: &str,
        embedding_provider: &dyn EmbeddingProvider,
        llm_provider: &dyn LlmProvider,
        user_id: Option<&str>,
        max_results: Option<usize>,
    ) -> Result<String> {
        self.tool_executor
            .prepare_context_iterative(
                query,
                embedding_provider,
                llm_provider,
                user_id,
                max_results,
            )
            .map(|pc| pc.context_block)
    }

    // --- Consolidation ---

    pub fn find_consolidation_clusters(
        &self,
        user_id: Option<&str>,
        embeddings: &[(String, Vec<f32>)],
        min_age_secs: u64,
        min_cluster_size: usize,
    ) -> Result<Vec<Vec<MemoryItem>>> {
        self.consolidator
            .find_clusters(user_id, embeddings, min_cluster_size, min_age_secs)
    }

    // --- Important memories ---

    pub fn get_important_memories(
        &self,
        user_id: Option<&str>,
        limit: usize,
        min_importance: f64,
    ) -> Result<Vec<MemoryItem>> {
        self.store
            .get_important_memories(user_id, limit, min_importance)
    }

    // --- CozoDB-Specific Optimizations ---

    /// Recursive graph search using CozoDB Datalog.
    pub fn search_graph_recursive(
        &self,
        seed_ids: &[String],
        max_hops: usize,
        user_id: Option<&str>,
    ) -> Result<Vec<MemoryItem>> {
        self.store
            .search_graph_recursive(seed_ids, max_hops, user_id)
    }

    /// Time-travel semantic search: finds memories as they existed at a point in time.
    pub fn search_at_time(
        &self,
        embedding: &[f32],
        k: usize,
        at_time: f64,
        user_id: Option<&str>,
    ) -> Result<Vec<MemoryItem>> {
        self.store.search_at_time(embedding, k, at_time, user_id)
    }

    // --- Export/Import ---

    pub fn export_relations(&self) -> Result<serde_json::Value> {
        self.store.export_relations()
    }
}

#[cfg(test)]
mod router_ledger_tests {
    use super::*;
    use std::path::PathBuf;

    const UNIX_TIME: f64 = 1_700_000_000.25;
    const APPLE_EPOCH_OFFSET: f64 = 978_307_200.0;

    fn record(
        kind: &str,
        content: &str,
        created_at: f64,
        updated_at: f64,
        invalidated_at: Option<f64>,
        payload: serde_json::Value,
    ) -> RouterLedgerRecord {
        RouterLedgerRecord {
            kind: kind.to_owned(),
            id: payload["id"].as_str().unwrap().to_owned(),
            content: content.to_owned(),
            created_at,
            updated_at,
            invalidated_at,
            payload_json: payload.to_string(),
        }
    }

    fn fixture() -> RouterLedgerEnvelope {
        let created_at = UNIX_TIME - APPLE_EPOCH_OFFSET;
        let updated_at = created_at + 45.0;
        let invalidated_at = updated_at + 10.0;
        let active_fact_id = uuid::Uuid::new_v4().to_string();
        let invalidated_fact_id = uuid::Uuid::new_v4().to_string();
        let relationship_id = uuid::Uuid::new_v4().to_string();
        let episode_id = uuid::Uuid::new_v4().to_string();
        let turn_id = uuid::Uuid::new_v4().to_string();

        let mut envelope = RouterLedgerEnvelope::empty();
        envelope.records = vec![
            record(
                "durableFact",
                "User lives in Toronto.",
                UNIX_TIME,
                UNIX_TIME + 45.0,
                None,
                serde_json::json!({
                    "id": active_fact_id,
                    "statement": "User lives in Toronto.",
                    "createdAt": created_at,
                    "updatedAt": updated_at,
                    "invalidatedAt": null,
                    "embedding": [0.5, 0.2, 0.3, 0.4],
                    "embeddingProviderVersion": "nl-en-rev-1",
                    "sources": [{"text": "I live in Toronto", "timestamp": created_at}]
                }),
            ),
            record(
                "invalidatedFact",
                "User previously lived in Toronto.",
                UNIX_TIME,
                UNIX_TIME + 45.0,
                Some(UNIX_TIME + 55.0),
                serde_json::json!({
                    "id": invalidated_fact_id,
                    "statement": "User previously lived in Toronto.",
                    "createdAt": created_at,
                    "updatedAt": updated_at,
                    "invalidatedAt": invalidated_at,
                    "embedding": [0.5, 0.2, 0.3, 0.4],
                    "embeddingProviderVersion": "nl-en-rev-1",
                    "sources": []
                }),
            ),
            record(
                "relationship",
                "User worksAt Acme",
                UNIX_TIME,
                UNIX_TIME,
                None,
                serde_json::json!({
                    "id": relationship_id,
                    "triple": {"subject": "User", "predicate": "worksAt", "object": "Acme"},
                    "createdAt": created_at,
                    "invalidatedAt": null
                }),
            ),
            record(
                "episodic",
                "User shipped the router prototype.",
                UNIX_TIME,
                UNIX_TIME,
                None,
                serde_json::json!({
                    "id": episode_id,
                    "value": "User shipped the router prototype.",
                    "createdAt": created_at
                }),
            ),
            record(
                "conversationTurn",
                "I live in Toronto",
                UNIX_TIME,
                UNIX_TIME,
                None,
                serde_json::json!({
                    "id": turn_id,
                    "userMessage": "I live in Toronto",
                    "timestamp": created_at
                }),
            ),
        ];
        envelope.records.sort_by(|left, right| {
            left.kind
                .cmp(&right.kind)
                .then_with(|| left.id.cmp(&right.id))
        });
        envelope
    }

    fn database_path() -> PathBuf {
        std::env::temp_dir().join(format!(
            "memlocal-router-ledger-{}.sqlite",
            uuid::Uuid::new_v4()
        ))
    }

    fn config(path: &PathBuf) -> CoreConfig {
        let mut config = CoreConfig::default();
        config.storage.in_memory = false;
        config.storage.db_path = Some(path.to_string_lossy().into_owned());
        config.storage.embedding_dimensions = ROUTER_LEDGER_EMBEDDING_DIMENSIONS;
        config
    }

    fn remove_database(path: &PathBuf) {
        for suffix in ["", "-wal", "-shm"] {
            let path = PathBuf::from(format!("{}{suffix}", path.display()));
            let _ = std::fs::remove_file(path);
        }
    }

    #[test]
    fn hybrid_search_retrieves_paraphrased_facts_above_keyword_distractors() {
        let vectors: std::collections::BTreeMap<String, Vec<f64>> = serde_json::from_str(
            include_str!("../../tests/fixtures/semantic_vectors.json"),
        )
        .unwrap();
        let facts = [
            "My sister Sarah loves chocolate cake",
            "My sibling enjoys hiking on weekends",
            "I live in Toronto",
            "I visited Tokyo last spring",
            "My favorite programming language is Rust",
            "Python is popular for data science",
            "My car gets serviced every six months",
            "The meeting is scheduled for Tuesday morning",
        ];
        let queries = [
            (
                "What dessert does my sibling enjoy?",
                "My sister Sarah loves chocolate cake",
                "My sibling enjoys hiking on weekends",
            ),
            (
                "Which city do I reside in?",
                "I live in Toronto",
                "I visited Tokyo last spring",
            ),
            (
                "What coding language do I prefer?",
                "My favorite programming language is Rust",
                "Python is popular for data science",
            ),
        ];
        assert_eq!(vectors.len(), facts.len() + queries.len());
        assert!(vectors.values().all(|vector| vector.len() == 512));

        let created_at = UNIX_TIME - APPLE_EPOCH_OFFSET;
        let mut envelope = RouterLedgerEnvelope::empty();
        for (index, fact) in facts.iter().enumerate() {
            let id = format!("00000000-0000-4000-8000-{:012x}", index + 1);
            envelope.records.push(record(
                "durableFact",
                fact,
                UNIX_TIME,
                UNIX_TIME,
                None,
                serde_json::json!({
                    "id": id,
                    "statement": fact,
                    "createdAt": created_at,
                    "updatedAt": created_at,
                    "invalidatedAt": null,
                    "embedding": vectors[*fact],
                    "embeddingProviderVersion": "nl-en-rev-1",
                    "sources": []
                }),
            ));
        }

        let path = database_path();
        let engine = MemlocalEngine::open(config(&path)).unwrap();
        let json = serde_json::to_string(&envelope).unwrap();
        assert_eq!(engine.sync_router_ledger(&json).unwrap(), facts.len());

        for (query, expected, distractor) in queries {
            let lexical: Vec<_> = engine
                .search_router_facts_text(query, facts.len())
                .unwrap()
                .into_iter()
                .map(|item| item.content)
                .collect();
            assert!(
                !lexical.iter().any(|fact| fact == expected),
                "text-only search unexpectedly retrieved {expected} for {query}"
            );
            let results = engine
                .search_router_facts_hybrid(query, &vectors[query], "nl-en-rev-1", facts.len())
                .unwrap();
            let ranked: Vec<_> = results.iter().map(|item| item.content.as_str()).collect();
            assert_eq!(ranked.len(), facts.len(), "query: {query}");
            assert_eq!(ranked[0], expected, "query: {query}; ranking: {ranked:?}");
            assert!(
                ranked.iter().position(|fact| *fact == expected)
                    < ranked.iter().position(|fact| *fact == distractor),
                "query: {query}; ranking: {ranked:?}"
            );
        }

        engine.close().unwrap();
        remove_database(&path);
    }

    #[test]
    fn sync_round_trips_full_ledger_after_reopen_and_filters_invalidated_facts() {
        let path = database_path();
        let config = config(&path);
        let envelope = fixture();
        let json = serde_json::to_string(&envelope).unwrap();

        {
            let engine = MemlocalEngine::open(config.clone()).unwrap();
            assert_eq!(
                engine.sync_router_ledger(&json).unwrap(),
                envelope.records.len()
            );
            assert_eq!(engine.export_router_ledger().unwrap(), envelope);
            assert_eq!(engine.sync_router_ledger(&json).unwrap(), 0);

            let facts = engine.search_router_facts_text("Toronto", 10).unwrap();
            assert_eq!(facts.len(), 1);
            assert_eq!(facts[0].content, "User lives in Toronto.");

            let hybrid = engine
                .search_router_facts_hybrid("Toronto", &[0.5, 0.2, 0.3, 0.4], "nl-en-rev-1", 10)
                .unwrap();
            assert_eq!(hybrid.len(), 1);
            assert_eq!(hybrid[0].content, "User lives in Toronto.");
            assert!(engine
                .search_router_facts_hybrid("Toronto", &[0.5, 0.2, 0.3, 0.4, 0.1], "nl-en-rev-1", 10)
                .unwrap()
                .is_empty());
            assert!(engine
                .search_router_facts_hybrid("Toronto", &[0.5, 0.2, 0.3, 0.4], "nl-en-rev-2", 10)
                .unwrap()
                .is_empty());
            assert!(engine
                .search_router_facts_hybrid("Toronto", &[0.5, 0.2, 0.3, 0.4], "hash-v1", 10)
                .unwrap()
                .is_empty());
            engine.close().unwrap();
        }

        {
            let reopened = MemlocalEngine::open(config).unwrap();
            assert_eq!(reopened.memory_count(None).unwrap(), envelope.records.len());
            assert_eq!(reopened.export_router_ledger().unwrap(), envelope);
            let hybrid = reopened
                .search_router_facts_hybrid("Toronto", &[0.5, 0.2, 0.3, 0.4], "nl-en-rev-1", 10)
                .unwrap();
            assert_eq!(hybrid.len(), 1);
            assert_eq!(hybrid[0].content, "User lives in Toronto.");
            reopened.close().unwrap();
        }

        remove_database(&path);
    }

    #[test]
    fn invalid_snapshot_is_rejected_before_any_rows_are_written() {
        let path = database_path();
        let config = config(&path);
        let mut envelope = fixture();
        envelope.records[0].content.push_str(" tampered");
        let json = serde_json::to_string(&envelope).unwrap();

        {
            let engine = MemlocalEngine::open(config).unwrap();
            assert!(engine.sync_router_ledger(&json).is_err());
            assert_eq!(engine.memory_count(None).unwrap(), 0);
            engine.close().unwrap();
        }

        remove_database(&path);
    }

    fn graph_record(
        id: &str,
        statement: &str,
        triple: serde_json::Value,
        related: Vec<&str>,
        created_at: f64,
        updated_at: f64,
    ) -> RouterLedgerRecord {
        record(
            "durableFact",
            statement,
            created_at + APPLE_EPOCH_OFFSET,
            updated_at + APPLE_EPOCH_OFFSET,
            None,
            serde_json::json!({
                "id": id,
                "statement": statement,
                "triple": triple,
                "relatedFactIDs": related,
                "confidence": 0.9,
                "createdAt": created_at,
                "updatedAt": updated_at,
                "invalidatedAt": null,
                "embedding": [0.5, 0.2, 0.3, 0.4],
                "embeddingProviderVersion": "nl-en-rev-1",
                "sources": []
            }),
        )
    }

    #[test]
    fn sync_reconciles_graph_edges_and_triples() {
        let path = database_path();
        let config = config(&path);
        let created_at = UNIX_TIME - APPLE_EPOCH_OFFSET;
        let updated_at = created_at + 10.0;
        let fact_a_id = uuid::Uuid::new_v4().to_string();
        let fact_b_id = uuid::Uuid::new_v4().to_string();

        let mut envelope = RouterLedgerEnvelope::empty();
        envelope.records = vec![
            graph_record(
                &fact_a_id,
                "User likes Rust.",
                serde_json::json!({"subject": "User", "predicate": "likes", "object": "Rust"}),
                vec![&fact_b_id],
                created_at,
                updated_at,
            ),
            graph_record(
                &fact_b_id,
                "Rust is a systems language.",
                serde_json::json!({"subject": "Rust", "predicate": "is", "object": "systems language"}),
                vec![],
                created_at,
                updated_at,
            ),
        ];
        let json = serde_json::to_string(&envelope).unwrap();

        let engine = MemlocalEngine::open(config).unwrap();
        assert_eq!(engine.sync_router_ledger(&json).unwrap(), 2);

        // Edge from A to B exists.
        let edges = engine.get_edges(&fact_a_id).unwrap();
        assert_eq!(edges.len(), 1);
        assert_eq!(edges[0].from_id, fact_a_id);
        assert_eq!(edges[0].to_id, fact_b_id);

        // Graph traversal from A reaches B.
        let reached = engine
            .search_graph_recursive(&[fact_a_id.clone()], 2, None)
            .unwrap();
        let reached_ids: Vec<&str> = reached.iter().map(|item| item.id.as_str()).collect();
        assert!(reached_ids.contains(&fact_a_id.as_str()));
        assert!(reached_ids.contains(&fact_b_id.as_str()));

        // No contradictions yet.
        assert!(engine.find_contradicting_triples().unwrap().is_empty());

        engine.close().unwrap();
        remove_database(&path);
    }

    #[test]
    fn contradicting_triples_are_detected_after_sync() {
        let path = database_path();
        let config = config(&path);
        let created_at = UNIX_TIME - APPLE_EPOCH_OFFSET;
        let fact_old_id = uuid::Uuid::new_v4().to_string();
        let fact_new_id = uuid::Uuid::new_v4().to_string();

        let mut envelope = RouterLedgerEnvelope::empty();
        envelope.records = vec![
            graph_record(
                &fact_old_id,
                "User likes Python.",
                serde_json::json!({"subject": "User", "predicate": "likes", "object": "Python"}),
                vec![],
                created_at,
                created_at + 10.0,
            ),
            graph_record(
                &fact_new_id,
                "User likes Rust.",
                serde_json::json!({"subject": "User", "predicate": "likes", "object": "Rust"}),
                vec![],
                created_at,
                created_at + 20.0,
            ),
        ];
        let json = serde_json::to_string(&envelope).unwrap();

        let engine = MemlocalEngine::open(config).unwrap();
        assert_eq!(engine.sync_router_ledger(&json).unwrap(), 2);

        let contradictions = engine.find_contradicting_triples().unwrap();
        assert_eq!(contradictions.len(), 1);
        let (old, new) = &contradictions[0];
        assert_eq!(old.memory_id, fact_old_id);
        assert_eq!(old.object, "Python");
        assert_eq!(new.memory_id, fact_new_id);
        assert_eq!(new.object, "Rust");

        engine.close().unwrap();
        remove_database(&path);
    }

    #[test]
    fn ledger_requires_the_fixed_embedding_index_dimension() {
        let path = database_path();
        let mut config = config(&path);
        config.storage.embedding_dimensions = 64;
        let json = serde_json::to_string(&fixture()).unwrap();

        {
            let engine = MemlocalEngine::open(config).unwrap();
            assert!(engine.sync_router_ledger(&json).is_err());
            assert_eq!(engine.memory_count(None).unwrap(), 0);
            engine.close().unwrap();
        }

        remove_database(&path);
    }
}
