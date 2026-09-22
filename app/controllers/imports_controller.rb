class ImportsController < ApplicationController
  skip_after_action :verify_policy_scoped
  before_action :get_url

  def new
    authorize :upload, :create?
  end

  def create
    authorize :upload, :create?

    CreateObjectFromUrlJob.perform_later(
      url: @url,
      owner: current_user
    )
    redirect_to helpers.landing_page_path, notice: t(".success")
  end

  private

  def get_url
    @url = params[:url]
    @deserializer = Link.deserializer_for(url: @url) if @url.present?
    if @deserializer.nil?
      flash.now[:alert] = t("imports.bad_url") if @url.present?
      skip_authorization
    else
      authorize @deserializer.capabilities[:class]
    end
  end
end
