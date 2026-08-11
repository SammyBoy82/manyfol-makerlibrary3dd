module Admin
  class OperationsController < ApplicationController
    before_action :authenticate_user!
    before_action :require_administrator!

    def index
      skip_policy_scope
      skip_authorization

      @snapshot = Admin::OperationsSnapshot.call
    end

    private

    def require_administrator!
      return if current_user&.is_administrator?

      head :forbidden
    end
  end
end
