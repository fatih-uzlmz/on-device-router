#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void* memlocal_open(const char* config_json);
int32_t memlocal_close(void* handle);
int32_t memlocal_put_memory(void* handle, const char* config_json, const char* content, const char* embedding_json);
int32_t memlocal_put_memory_with_id(void* handle, const char* config_json, const char* id, const char* content, const char* embedding_json);
int32_t memlocal_delete_memory(void* handle, const char* id);
int32_t memlocal_search_text(void* handle, const char* query, uint32_t k, char** out_json);
int32_t memlocal_search_router_hybrid(void* handle, const char* query, const char* embedding_json, uint32_t k, char** out_json);
int32_t memlocal_sync_router_ledger(void* handle, const char* ledger_json);
int32_t memlocal_import_router_ledger(void* handle, const char* ledger_json);
int32_t memlocal_export_router_ledger(void* handle, char** out_json);
void memlocal_free_string(char* string);
void memlocal_free_error(const char* error);
const char* memlocal_last_error(void);

#ifdef __cplusplus
}
#endif
