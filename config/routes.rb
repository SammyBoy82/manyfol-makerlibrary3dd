require "sidekiq/web"
require "sidekiq/cron/web"
require "federails"

Rails.application.routes.draw do
  post "/admin/file-storage/clear-storage-activity", to: "admin/file_storage#clear_storage_activity", as: :clear_storage_activity
  post "/admin/file-storage/storage-sources/:slug/register-library", to: "admin/file_storage#register_storage_library", as: :register_v491_storage_library
  post "/admin/file-storage/storage-sources/:slug/reconnect-v491", to: "admin/file_storage#reconnect_storage_source", as: :reconnect_v491_storage_source
  post "/admin/file-storage/storage-sources/:slug/disconnect-v491", to: "admin/file_storage#disconnect_storage_source", as: :disconnect_v491_storage_source
  draw(:auth)
  draw(:meta)
  draw(:admin)
  draw(:moderation)
  draw(:social)
  draw(:federation)
  draw(:oauth)
  draw(:oembed)
  draw(:upload)
  draw(:print)
  draw(:api)
  draw(:plugins)

  resources :libraries, except: [:index] do
    collection do
      get :preview
    end
    member do
      get :preview
    end
  end

  concern :followable do |options|
    if SiteSettings.multiuser_enabled?
      resources :follows, {only: [:create]}.merge(options) do
        collection do
          delete "/", action: "destroy"
        end
      end
    end
  end

  concern :commentable do |options|
    resources :comments, {only: [:show, :create, :destroy]}.merge(options) do
      concerns :reportable, reportable_class: "Comment"
    end
  end
  concern :reportable do |options|
    resources :reports, {only: [:new, :create]}.merge(options)
  end
  concern :linkable do
    member do
      post :sync
    end
  end

  resources :models do
    concerns :followable, followable_class: "Model"
    concerns :commentable, commentable_class: "Model"
    concerns :reportable, reportable_class: "Model"
    concerns :linkable
    member do
      post "scan"
    end
    collection do
      post "merge"
      get "merge", action: "configure_merge", as: "configure_merge"
      get "edit", action: "bulk_edit"
      patch "/update", action: "bulk_update"
    end
    resources :model_files, except: [:index, :new] do
      collection do
        get "bulk_edit"
        patch "bulk_update"
      end
    end
  end

  # Fallback routes for filename matching and signed downloads
  get "/models/:model_id/model_files/signed/:sig/*id" => "model_files#show", :as => "model_model_file_by_signed_filename"
  get "/models/:model_id/raw/*filename" => "model_files#raw", :as => "model_model_file_raw"

  resources :creators do
    concerns :followable, followable_class: "Creator"
    concerns :commentable, commentable_class: "Creator"
    concerns :reportable, reportable_class: "Creator"
    concerns :linkable
    member do
      get :avatar
      get :banner
    end
    resources :groups
  end
  resources :collections do
    concerns :followable, followable_class: "Collection"
    concerns :commentable, commentable_class: "Collection"
    concerns :reportable, reportable_class: "Collection"
    concerns :linkable
    member do
      get :cover
    end
  end
  resources :problems, only: [:index, :update] do
    collection do
      post "resolve", action: "resolve"
    end
    member do
      post "resolve"
    end
  end

  authenticate :user do
    get "/welcome", to: "home#welcome", as: :welcome

    get "/member/favorites", to: "member_activity#favorites", as: :member_favorites
    get "/member/recently-viewed", to: "member_activity#recently_viewed", as: :member_recently_viewed
    get "/member/downloads", to: "member_activity#downloads", as: :member_downloads
    delete "/member/recently-viewed", to: "member_activity#clear_recently_viewed", as: :member_clear_recently_viewed
    delete "/member/downloads", to: "member_activity#clear_downloads", as: :member_clear_downloads

    resources :lists
    resources :imports, only: [:new, :create]
    resources :scans, only: [:create]
  end
end
