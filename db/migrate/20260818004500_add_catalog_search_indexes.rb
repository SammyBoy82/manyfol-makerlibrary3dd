class AddCatalogSearchIndexes < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    # Needed for fast substring / ILIKE-style catalogue searches.
    enable_extension "pg_trgm" unless extension_enabled?("pg_trgm")

    # Collection filtering currently joins through collections_models,
    # which had no indexes at all.
    add_index :collections_models,
      [:collection_id, :model_id],
      name: "idx_collections_models_collection_model",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :collections_models,
      [:model_id, :collection_id],
      name: "idx_collections_models_model_collection",
      algorithm: :concurrently,
      if_not_exists: true

    # Default scoped_search fields.
    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS
        idx_models_name_trgm
      ON models
      USING gin (name gin_trgm_ops)
    SQL

    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS
        idx_models_caption_trgm
      ON models
      USING gin (caption gin_trgm_ops)
    SQL

    # Explicit scoped_search fields useful for the member catalogue.
    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS
        idx_models_path_trgm
      ON models
      USING gin (path gin_trgm_ops)
    SQL

    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS
        idx_model_files_filename_trgm
      ON model_files
      USING gin (filename gin_trgm_ops)
    SQL
  end

  def down
    remove_index :collections_models,
      name: "idx_collections_models_collection_model",
      algorithm: :concurrently,
      if_exists: true

    remove_index :collections_models,
      name: "idx_collections_models_model_collection",
      algorithm: :concurrently,
      if_exists: true

    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_models_name_trgm"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_models_caption_trgm"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_models_path_trgm"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_model_files_filename_trgm"

    # Do not disable pg_trgm; another feature may use it later.
  end
end
