get "/api/makerlibrary3d/v1/catalog",
  to: "api/makerlibrary3d/v1/catalog#index",
  as: :makerlibrary3d_catalog_api

mount Rswag::Ui::Engine => "/api", :as => :api
mount Rswag::Api::Engine => "/api"
