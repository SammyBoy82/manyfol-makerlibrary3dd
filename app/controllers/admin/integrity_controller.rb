module Admin
  class IntegrityController < ApplicationController
    before_action :authenticate_user!
    before_action :require_administrator!

    def index
      skip_policy_scope
      skip_authorization
      @report = Admin::IntegrityAnalyzer.call
    end

    def preview
      skip_policy_scope
      skip_authorization

      @preview = Admin::IntegrityPreview.call(params[:category])
    rescue ArgumentError
      redirect_to admin_integrity_path, alert: "Preview is not available for that integrity category."
    end

    private

    def require_administrator!
      return if current_user&.is_administrator?

      head :forbidden
    end
  end
end
