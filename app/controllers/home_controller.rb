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

    liked_list =
      current_user.liked_list

    @favorite_models =
      if liked_list
        model_scope
          .joins(:list_items)
          .where(list_items: {list_id: liked_list.id})
          .distinct
          .order("list_items.created_at DESC")
          .limit(6)
      else
        model_scope.none
      end

    @recent_model_views =
      ModelView
        .where(
          user: current_user,
          model_id: model_scope.select(:id)
        )
        .includes(:model)
        .recent_first
        .limit(6)

    @recent_download_events =
      DownloadEvent
        .where(
          user: current_user,
          model_id: model_scope.select(:id)
        )
        .includes(:model, :model_file)
        .recent_first
        .limit(6)

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
