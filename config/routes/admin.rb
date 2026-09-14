authenticate :user, lambda { |u| u.is_administrator? } do
  resource :settings, only: [:show, :update] do
    collection do
      get :analysis
      get :derivatives
      get :multiuser
      get :reporting
      get :appearance
      get :discovery
      get :integrations
    end
    resources :libraries, only: [:index]
    resources :plugins, only: [:index, :create]

    resources :preview_enrichment_candidates,
      path: "preview_enrichment",
      only: [:index] do
      collection do
        post :scan
      end

      member do
        get :image
        patch :approve
        patch :reject
      end
    end
  end

  get "/admin/ingestion",
    to: "admin/library_ingests#index",
    as: :admin_library_ingests

  post "/admin/ingestion/scan",
    to: "admin/library_ingests#scan",
    as: :scan_admin_library_ingests

  post "/admin/ingestion/pause",
    to: "admin/library_ingests#pause",
    as: :pause_admin_library_ingests

  post "/admin/ingestion/resume",
    to: "admin/library_ingests#resume",
    as: :resume_admin_library_ingests

  post "/admin/ingestion/run-now",
    to: "admin/library_ingests#run_now",
    as: :run_now_admin_library_ingests

  post "/admin/ingestion/libraries/:id/toggle",
    to: "admin/library_ingests#toggle_library",
    as: :toggle_admin_library_ingestion

  post "/admin/ingestion/:id/retry",
    to: "admin/library_ingests#retry",
    as: :retry_admin_library_ingest


  post "/admin/ingestion/:id/override-duplicate",
    to: "admin/library_ingests#override_duplicate",
    as: :override_duplicate_admin_library_ingest
  get "/admin/catalog-quality",
    to: "admin/catalog_quality#index",
    as: :admin_catalog_quality

  post "/admin/catalog-quality/repair-previews",
    to: "admin/catalog_quality#repair_all_previews",
    as: :repair_all_admin_catalog_quality_previews

  post "/admin/catalog-quality/models/:id/repair-preview",
    to: "admin/catalog_quality#repair_preview",
    as: :repair_admin_catalog_quality_preview

  get "/admin/taxonomy",
    to: "admin/taxonomy#index",
    as: :admin_taxonomy

  get "/admin/audit-log",
    to: "admin/audit_events#index",
    as: :admin_audit_log

  get "/admin/operations",
    to: "admin/operations#index",
    as: :admin_operations

  get "/admin/operations/control-center",
    to: "admin/operations#control_center",
    as: :admin_operations_control_center

  get "/admin/operations/backups",
    to: "admin/operations#backups",
    as: :admin_operations_backups

  post "/admin/operations/backups/request",
    to: "admin/operations#request_backup",
    as: :admin_operations_request_backup

  patch "/admin/operations/backups/settings",
    to: "admin/operations#update_backup_settings",
    as: :admin_operations_backup_settings

  get "/admin/operations/backups/download/:filename",
    to: "admin/operations#download_backup",
    as: :admin_operations_download_backup,
    constraints: {filename: /[^\/]+/}

  get "/admin/operations/dead-jobs",
    to: "admin/operations#dead_jobs",
    as: :admin_operations_dead_jobs

  post "/admin/operations/dead-jobs/:jid/retry",
    to: "admin/operations#retry_dead_job",
    as: :admin_operations_retry_dead_job

  delete "/admin/operations/dead-jobs/:jid",
    to: "admin/operations#delete_dead_job",
    as: :admin_operations_delete_dead_job

  delete "/admin/operations/dead-jobs",
    to: "admin/operations#clear_dead_jobs",
    as: :admin_operations_clear_dead_jobs

  get "/admin/operations/problems/:category",
    to: "admin/operations#problems",
    as: :admin_operations_problems

  get "/admin/integrity",
    to: "admin/integrity#index",
    as: :admin_integrity

  get "/admin/integrity/duplicates",
    to: "admin/integrity#duplicate_sets",
    as: :admin_integrity_duplicate_sets

  post "/admin/integrity/duplicates/remove",
    to: "admin/integrity#remove_duplicates",
    as: :admin_integrity_remove_duplicates

  get "/admin/integrity/nesting",
    to: "admin/integrity#nesting",
    as: :admin_integrity_nesting

  get "/admin/integrity/nesting/merge-preview",
    to: "admin/integrity#nesting_merge_preview",
    as: :admin_integrity_nesting_merge_preview

  post "/admin/integrity/nesting/merge",
    to: "admin/integrity#merge_nesting",
    as: :admin_integrity_merge_nesting

  post "/admin/integrity/nesting/:problem_id/ignore",
    to: "admin/integrity#ignore_nesting",
    as: :admin_integrity_ignore_nesting

  get "/admin/integrity/preview/:category",
    to: "admin/integrity#preview",
    as: :admin_integrity_preview,
    constraints: {category: /missing|duplicate|nesting/}

  post "/admin/integrity/preview/:category/clear-stale",
    to: "admin/integrity#clear_stale",
    as: :admin_integrity_clear_stale,
    constraints: {category: /missing|duplicate|nesting/}

  post "/admin/integrity/missing/remove-records",
    to: "admin/integrity#remove_missing_records",
    as: :admin_integrity_remove_missing_records

  get "/admin/commercial-metadata",
    to: "admin/commercial_metadata#index",
    as: :admin_commercial_metadata

  post "/admin/commercial-metadata/bulk-update",
    to: "admin/commercial_metadata#bulk_update",
    as: :admin_commercial_metadata_bulk_update

  post "/admin/commercial-metadata/generate-skus",
    to: "admin/commercial_metadata#generate_skus",
    as: :admin_commercial_metadata_generate_skus

  get "/admin/commercial-metadata/:model_id/edit",
    to: "admin/commercial_metadata#edit",
    as: :edit_admin_commercial_metadata

  patch "/admin/commercial-metadata/:model_id",
    to: "admin/commercial_metadata#update",
    as: :admin_commercial_metadata_update

  get "/admin/file-storage",
    to: "admin/file_storage#index",
    as: :admin_file_storage

  get "/admin/file-storage/storage-sources/new",
    to: "admin/file_storage#new_storage_source",
    as: :new_admin_storage_source

  post "/admin/file-storage/storage-sources",
    to: "admin/file_storage#create_storage_source",
    as: :admin_storage_sources

  get "/admin/file-storage/storage-sources/:slug",
    to: "admin/file_storage#show_storage_source",
    as: :manage_admin_storage_source

  delete "/admin/file-storage/storage-sources/:slug",
    to: "admin/file_storage#destroy_storage_source",
    as: :admin_storage_source

  post "/admin/file-storage/storage-health/run-all",
  to: "admin/file_storage#run_all_storage_health",
  as: :run_all_admin_storage_health

post "/admin/file-storage/storage-sources/:slug/test",
    to: "admin/file_storage#test_storage_source",
    as: :test_admin_storage_source

patch "/admin/file-storage/storage-sources/:slug/rename",
  to: "admin/file_storage#rename_storage_source",
  as: :rename_admin_storage_source

  get "/admin/file-storage/anomalies",
    to: "admin/file_storage#anomalies",
    as: :admin_file_storage_anomalies

  post "/admin/file-storage/:library_id/reconcile",
    to: "admin/file_storage#reconcile_library",
    as: :admin_file_storage_reconcile

  get "/admin/media-maintenance",
    to: "admin/media_maintenance#index",
    as: :admin_media_maintenance

  get "/admin/media-maintenance/:library_id/missing-sources",
    to: "admin/media_maintenance#missing_sources",
    as: :admin_media_maintenance_missing_sources

  post "/admin/media-maintenance/:library_id/rescan",
    to: "admin/media_maintenance#rescan",
    as: :admin_media_maintenance_rescan

  post "/admin/media-maintenance/:library_id/repair-stale",
    to: "admin/media_maintenance#repair_stale",
    as: :admin_media_maintenance_repair_stale

  post "/admin/media-maintenance/:library_id/repair-orphans",
    to: "admin/media_maintenance#repair_orphans",
    as: :admin_media_maintenance_repair_orphans

  post "/admin/media-maintenance/:library_id/regenerate-missing",
    to: "admin/media_maintenance#regenerate_missing",
    as: :admin_media_maintenance_regenerate_missing

  mount Sidekiq::Web => "/admin/sidekiq"
  mount RailsPerformance::Engine => "/admin/performance" unless Rails.env.test? || ENV["RAILS_ASSETS_PRECOMPILE"].present?
  mount PgHero::Engine => "/admin/pghero" if defined?(PgHero)
  get "/activity" => "activity#index", :as => :activity
end
