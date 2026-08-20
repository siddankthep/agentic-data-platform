-- Requires shared_preload_libraries=pg_stat_statements on the server (set in docker-compose.yml).
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
