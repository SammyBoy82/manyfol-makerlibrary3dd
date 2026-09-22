authenticate :user, lambda { |u| u.is_moderator? } do
  if SiteSettings.multiuser_enabled? || Rails.env.test?
    namespace :settings do
      resources :users, constraints: {id: %r{[^/]+}} do
        member do
          post :enable_access
          post :disable_access
          patch :set_role
          patch :update_membership
          post :extend_membership
        end
      end
      resources :membership_plans,
        only: [
          :index,
          :create,
          :update,
          :destroy
        ]

      resources :reports
    end
  end
end
