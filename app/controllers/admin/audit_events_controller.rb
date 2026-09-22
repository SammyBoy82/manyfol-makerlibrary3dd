class Admin::AuditEventsController < ApplicationController
  before_action :require_administrator!

  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  def index
    events =
      AdminAuditEvent
        .recent

    if params[:action_type].present?
      events =
        events.where(
          action: params[:action_type]
        )
    end

    if params[:q].present?
      term =
        "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%"

      events =
        events.where(
          "actor_name ILIKE :term OR target_name ILIKE :term OR action ILIKE :term",
          term: term
        )
    end

    @events =
      events.page(params[:page]).per(50)

    @action_types =
      AdminAuditEvent
        .distinct
        .order(:action)
        .pluck(:action)

    render layout: "settings"
  end

  private

  def require_administrator!
    raise Pundit::NotAuthorizedError unless current_user&.is_administrator?
  end
end
