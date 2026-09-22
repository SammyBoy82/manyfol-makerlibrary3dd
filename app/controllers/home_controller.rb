class HomeController < ApplicationController
  skip_after_action :verify_policy_scoped
  skip_before_action :set_up_first_library, only: [:about]

  before_action :require_member_access, only: [:index]

  def index
    model_scope =
      policy_scope(Model)

    @recent_models =
      model_scope
        .includes(:library)
        .order(created_at: :desc)
        .limit(12)

    @model_count =
      model_scope.count

    @library_count =
      model_scope
        .where.not(library_id: nil)
        .distinct
        .count(:library_id)

    @file_count =
      ModelFile
        .where(
          model_id:
            model_scope.select(:id)
        )
        .count

    @member_role =
      if current_user.is_administrator?
        "Administrator"
      elsif current_user.is_moderator?
        "Moderator"
      elsif current_user.is_contributor?
        "Contributor"
      else
        "Member"
      end
  end

  def welcome
    skip_authorization
  end

  def about
    skip_authorization
  end

  private

  def require_member_access
    return if current_user&.is_member?

    raise Pundit::NotAuthorizedError
  end
end
