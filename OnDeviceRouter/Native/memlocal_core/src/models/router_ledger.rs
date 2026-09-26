use serde::{Deserialize, Serialize};

/// Fixed dimension of the on-device embedding projection used by the app's
/// MemLocal ledger index. The original Swift vector remains in `payload_json`.
pub const ROUTER_LEDGER_EMBEDDING_DIMENSIONS: u32 = 128;
pub const ROUTER_LEDGER_EMBEDDING_PROJECTION_VERSION: u64 = 1;
pub const ROUTER_LEDGER_MAX_SOURCE_EMBEDDING_DIMENSIONS: usize = 4096;

/// Versioned transfer format for importing the app's canonical memory ledger.
/// Payload JSON is stored as an opaque string so a Rust import/export round
/// trip does not rewrite Swift's dates, floats, optional keys, or evidence.
#[derive(Deserialize, Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RouterLedgerEnvelope {
    pub format: String,
    pub schema_version: u32,
    pub source_schema_version: u32,
    pub records: Vec<RouterLedgerRecord>,
}

#[derive(Deserialize, Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RouterLedgerRecord {
    pub kind: String,
    pub id: String,
    pub content: String,
    pub created_at: f64,
    pub updated_at: f64,
    pub invalidated_at: Option<f64>,
    pub payload_json: String,
}

impl RouterLedgerEnvelope {
    pub const FORMAT: &'static str = "on-device-router-ledger";
    pub const SCHEMA_VERSION: u32 = 1;
    pub const SOURCE_SCHEMA_VERSION: u32 = 2;

    pub fn empty() -> Self {
        Self {
            format: Self::FORMAT.to_owned(),
            schema_version: Self::SCHEMA_VERSION,
            source_schema_version: Self::SOURCE_SCHEMA_VERSION,
            records: Vec::new(),
        }
    }
}
