use std::ffi::{c_void, CStr, CString};
use std::os::raw::{c_char, c_int};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::{Mutex, MutexGuard};

use memlocal_core::api::MemlocalEngine;
use memlocal_core::models::{CoreConfig, MemoryItem, MemoryType};

static LAST_ERROR: Mutex<String> = Mutex::new(String::new());
static ERROR_FALLBACK: &[u8] = b"panic retrieving last error\0";

fn error_slot() -> MutexGuard<'static, String> {
    LAST_ERROR
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn set_error(message: String) {
    *error_slot() = message;
}

fn clear_error() {
    error_slot().clear();
}

fn read_c_string(pointer: *const c_char) -> Result<String, String> {
    if pointer.is_null() {
        return Err("null input pointer".to_owned());
    }

    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_owned)
        .map_err(|error| error.to_string())
}

fn read_embedding(pointer: *const c_char, expected_dimensions: usize) -> Result<Vec<f32>, String> {
    let json = read_c_string(pointer)?;
    let embedding: Vec<f32> =
        serde_json::from_str(&json).map_err(|error| format!("invalid embedding JSON: {error}"))?;
    if embedding.len() != expected_dimensions {
        return Err(format!(
            "embedding dimension mismatch: expected {expected_dimensions}, received {}",
            embedding.len()
        ));
    }
    if embedding.iter().any(|value| !value.is_finite()) {
        return Err("embedding values must be finite".to_owned());
    }
    Ok(embedding)
}

fn status_code(operation: impl FnOnce() -> Result<(), String>) -> c_int {
    clear_error();

    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => {
            set_error(error);
            -1
        }
        Err(_) => {
            set_error("panic in memlocal FFI function".to_owned());
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn memlocal_open(config_json: *const c_char) -> *mut c_void {
    clear_error();

    let opened = catch_unwind(AssertUnwindSafe(|| -> Result<*mut c_void, String> {
        let json = read_c_string(config_json)?;
        let config: CoreConfig = serde_json::from_str(&json).map_err(|error| error.to_string())?;
        let engine = MemlocalEngine::open(config).map_err(|error| error.to_string())?;
        Ok(Box::into_raw(Box::new(engine)).cast())
    }));

    match opened {
        Ok(Ok(handle)) => handle,
        Ok(Err(error)) => {
            set_error(error);
            ptr::null_mut()
        }
        Err(_) => {
            set_error("panic in memlocal_open".to_owned());
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn memlocal_close(handle: *mut c_void) -> c_int {
    status_code(|| {
        if handle.is_null() {
            return Ok(());
        }

        let engine = unsafe { Box::from_raw(handle.cast::<MemlocalEngine>()) };
        engine.close().map_err(|error| error.to_string())
    })
}

#[no_mangle]
pub extern "C" fn memlocal_put_memory(
    handle: *mut c_void,
    config_json: *const c_char,
    content: *const c_char,
    embedding_json: *const c_char,
) -> c_int {
    status_code(|| {
        if handle.is_null() {
            return Err("null engine handle".to_owned());
        }

        let json = read_c_string(config_json)?;
        let config: CoreConfig = serde_json::from_str(&json).map_err(|error| error.to_string())?;
        let dimensions = usize::try_from(config.storage.embedding_dimensions)
            .map_err(|error| error.to_string())?;
        let content = read_c_string(content)?;
        let embedding = read_embedding(embedding_json, dimensions)?;
        let item = MemoryItem::new(content, MemoryType::Factual);
        let engine = unsafe { &*handle.cast::<MemlocalEngine>() };

        engine
            .put_memory(&item, &embedding)
            .map_err(|error| error.to_string())
    })
}

#[no_mangle]
pub extern "C" fn memlocal_put_memory_with_id(
    handle: *mut c_void,
    config_json: *const c_char,
    id: *const c_char,
    content: *const c_char,
    embedding_json: *const c_char,
) -> c_int {
    status_code(|| {
        if handle.is_null() {
            return Err("null engine handle".to_owned());
        }

        let json = read_c_string(config_json)?;
        let config: CoreConfig = serde_json::from_str(&json).map_err(|error| error.to_string())?;
        let dimensions = usize::try_from(config.storage.embedding_dimensions)
            .map_err(|error| error.to_string())?;
        let id = read_c_string(id)?;
        let content = read_c_string(content)?;
        let embedding = read_embedding(embedding_json, dimensions)?;
        let mut item = MemoryItem::new(content, MemoryType::Factual);
        item.id = id;
        let engine = unsafe { &*handle.cast::<MemlocalEngine>() };

        engine
            .put_memory(&item, &embedding)
            .map_err(|error| error.to_string())
    })
}

#[no_mangle]
pub extern "C" fn memlocal_delete_memory(handle: *mut c_void, id: *const c_char) -> c_int {
    status_code(|| {
        if handle.is_null() {
            return Err("null engine handle".to_owned());
        }

        let id = read_c_string(id)?;
        let engine = unsafe { &*handle.cast::<MemlocalEngine>() };
        engine.delete_memory(&id).map_err(|error| error.to_string())
    })
}

#[no_mangle]
pub extern "C" fn memlocal_search_text(
    handle: *mut c_void,
    query: *const c_char,
    k: u32,
    out_json: *mut *mut c_char,
) -> c_int {
    status_code(|| {
        if out_json.is_null() {
            return Err("null out pointer".to_owned());
        }
        unsafe {
            *out_json = ptr::null_mut();
        }

        if handle.is_null() {
            return Err("null engine handle".to_owned());
        }

        let query = read_c_string(query)?;
        let engine = unsafe { &*handle.cast::<MemlocalEngine>() };
        let items = engine
            .search_router_facts_text(&query, k as usize)
            .map_err(|error| error.to_string())?;
        let json = serde_json::to_string(&items).map_err(|error| error.to_string())?;
        let result = CString::new(json).map_err(|error| error.to_string())?;

        unsafe {
            *out_json = result.into_raw();
        }
        Ok(())
    })
}

/// Hybrid search using an app-generated on-device embedding vector.
#[no_mangle]
pub extern "C" fn memlocal_search_router_hybrid(
    handle: *mut c_void,
    query: *const c_char,
    embedding_json: *const c_char,
    k: u32,
    out_json: *mut *mut c_char,
) -> c_int {
    status_code(|| {
        if out_json.is_null() {
            return Err("null out pointer".to_owned());
        }
        unsafe {
            *out_json = ptr::null_mut();
        }
        if handle.is_null() {
            return Err("null engine handle".to_owned());
        }
        let query = read_c_string(query)?;
        let embedding_json = read_c_string(embedding_json)?;
        let embedding: Vec<f64> = serde_json::from_str(&embedding_json)
            .map_err(|error| format!("invalid query embedding JSON: {error}"))?;
        let engine = unsafe { &*handle.cast::<MemlocalEngine>() };
        let items = engine
            .search_router_facts_hybrid(&query, &embedding, k as usize)
            .map_err(|error| error.to_string())?;
        let json = serde_json::to_string(&items).map_err(|error| error.to_string())?;
        let result = CString::new(json).map_err(|error| error.to_string())?;
        unsafe {
            *out_json = result.into_raw();
        }
        Ok(())
    })
}

/// Reconcile the persistent shadow ledger with the latest Swift snapshot.
#[no_mangle]
pub extern "C" fn memlocal_sync_router_ledger(
    handle: *mut c_void,
    ledger_json: *const c_char,
) -> c_int {
    status_code(|| {
        if handle.is_null() {
            return Err("null engine handle".to_owned());
        }
        let json = read_c_string(ledger_json)?;
        let engine = unsafe { &*handle.cast::<MemlocalEngine>() };
        engine
            .sync_router_ledger(&json)
            .map(|_| ())
            .map_err(|error| error.to_string())
    })
}

/// Import an entire versioned app-ledger snapshot into an empty shadow DB.
#[no_mangle]
pub extern "C" fn memlocal_import_router_ledger(
    handle: *mut c_void,
    ledger_json: *const c_char,
) -> c_int {
    status_code(|| {
        if handle.is_null() {
            return Err("null engine handle".to_owned());
        }
        let json = read_c_string(ledger_json)?;
        let engine = unsafe { &*handle.cast::<MemlocalEngine>() };
        engine
            .import_router_ledger(&json)
            .map(|_| ())
            .map_err(|error| error.to_string())
    })
}

/// Export the imported app-ledger snapshot for verification after reopen.
#[no_mangle]
pub extern "C" fn memlocal_export_router_ledger(
    handle: *mut c_void,
    out_json: *mut *mut c_char,
) -> c_int {
    status_code(|| {
        if out_json.is_null() {
            return Err("null out pointer".to_owned());
        }
        unsafe {
            *out_json = ptr::null_mut();
        }
        if handle.is_null() {
            return Err("null engine handle".to_owned());
        }

        let engine = unsafe { &*handle.cast::<MemlocalEngine>() };
        let envelope = engine
            .export_router_ledger()
            .map_err(|error| error.to_string())?;
        let json = serde_json::to_string(&envelope).map_err(|error| error.to_string())?;
        let result = CString::new(json).map_err(|error| error.to_string())?;
        unsafe {
            *out_json = result.into_raw();
        }
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn memlocal_free_string(string: *mut c_char) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !string.is_null() {
            drop(unsafe { CString::from_raw(string) });
        }
    }));
}

#[no_mangle]
pub extern "C" fn memlocal_free_error(error: *const c_char) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if error.is_null() || error == ERROR_FALLBACK.as_ptr().cast() {
            return;
        }
        drop(unsafe { CString::from_raw(error.cast_mut()) });
    }));
}

#[no_mangle]
pub extern "C" fn memlocal_last_error() -> *const c_char {
    match catch_unwind(AssertUnwindSafe(|| {
        CString::new(error_slot().clone())
            .map(CString::into_raw)
            .unwrap_or_else(|_| ERROR_FALLBACK.as_ptr().cast_mut().cast())
    })) {
        Ok(pointer) => pointer,
        Err(_) => ERROR_FALLBACK.as_ptr().cast(),
    }
}
