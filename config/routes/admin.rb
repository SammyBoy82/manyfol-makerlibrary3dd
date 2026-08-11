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
