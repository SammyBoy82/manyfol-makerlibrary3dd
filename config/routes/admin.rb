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
