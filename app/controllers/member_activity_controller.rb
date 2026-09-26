class MemberActivityController < ApplicationController
  before_action :authorize_member_activity

  def favorites
    liked_list = current_user.liked_list
    scope = policy_scope(Model)

    @models =
      if liked_list
        scope
          .joins(:list_items)
          .where(list_items: {list_id: liked_list.id})
          .includes(:library)
          .distinct
          .order("list_items.created_at DESC")
          .page(params[:page])
      else
        scope.none.page(params[:page])
      end
  end

  def recently_viewed
    allowed_model_ids = policy_scope(Model).select(:id)

    @model_views =
      ModelView
        .where(user: current_user, model_id: allowed_model_ids)
        .includes(model: :library)
        .recent_first
        .page(params[:page])
  end

  def downloads
    allowed_model_ids = policy_scope(Model).select(:id)

    @download_events =
      DownloadEvent
        .where(user: current_user, model_id: allowed_model_ids)
        .includes(:model, :model_file)
        .recent_first
        .page(params[:page])
  end

  def clear_recently_viewed
    authorize :member_activity, :destroy?
    ModelView.where(user: current_user).delete_all
    redirect_to member_recently_viewed_path,
      notice: "Recently viewed history was cleared.",
      status: :see_other
  end

  def clear_downloads
    authorize :member_activity, :destroy?
    DownloadEvent.where(user: current_user).delete_all
    redirect_to member_downloads_path,
      notice: "Download history was cleared.",
      status: :see_other
  end

  private

  def authorize_member_activity
    authorize :member_activity, :show?
  end
end
